#Requires -Version 5.1
<#
.SYNOPSIS
  Núcleo do PFD-WriteBlocker (CLI e GUI).
#>

Set-StrictMode -Version Latest

$script:GuidDisk   = '{53f56307-b6bf-11d0-94f2-00a0c91efb8b}'
$script:GuidVolume = '{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}'
$script:ToolName   = 'PFD-WriteBlocker'
$script:ToolVer    = '1.1.0'
$script:DenyWriteSddl = 'D:(D;;DCLCRPCRSD;;;IU)(A;;FA;;;SY)(A;;FA;;;LS)(A;;0x1200a9;;;IU)'
$script:HotplugSdHex = @(
    '0100048000000000000000000000000014000000020058000400000001001400',
    '1601010001010000000000050400000000001400ff011f000101000000000005',
    '1200000000001400ff011f0001010000000000051300000000001400a9001200',
    '010100000000000504000000'
) -join ''

$script:CaseId   = ''
$script:Operator = $env:USERNAME
$script:LogDir   = Join-Path $PSScriptRoot 'logs'
$script:Quiet    = $false

function Initialize-PfdSession {
    [CmdletBinding()]
    param(
        [string]$CaseId = '',
        [string]$Operator = $env:USERNAME,
        [string]$LogDir = (Join-Path $PSScriptRoot 'logs'),
        [switch]$Quiet
    )
    $script:CaseId   = $CaseId
    $script:Operator = $Operator
    $script:LogDir   = $LogDir
    $script:Quiet    = [bool]$Quiet
}

function Set-PfdSessionMeta {
    param([string]$CaseId, [string]$Operator)
    if ($PSBoundParameters.ContainsKey('CaseId'))   { $script:CaseId = $CaseId }
    if ($PSBoundParameters.ContainsKey('Operator')) { $script:Operator = $Operator }
}

function Get-PfdSessionMeta {
    [pscustomobject]@{
        CaseId   = $script:CaseId
        Operator = $script:Operator
        LogDir   = $script:LogDir
        Tool     = $script:ToolName
        Version  = $script:ToolVer
    }
}

function Write-PfdHost {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    if (-not $script:Quiet) {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Test-PfdAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-PfdAdministrator {
    if (-not (Test-PfdAdministrator)) {
        throw 'Execute como Administrador (UAC elevado).'
    }
}

function Ensure-PfdLogDir {
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
}

function Get-PfdLogPath {
    Ensure-PfdLogDir
    $stamp = Get-Date -Format 'yyyyMMdd'
    return (Join-Path $script:LogDir ("pfd_writeblocker_{0}.jsonl" -f $stamp))
}

function Write-PfdCustodyLog {
    param(
        [Parameter(Mandatory)][string]$Event,
        [hashtable]$Data = @{}
    )
    Ensure-PfdLogDir
    $entry = [ordered]@{
        timestamp_utc   = (Get-Date).ToUniversalTime().ToString('o')
        timestamp_local = (Get-Date).ToString('o')
        tool            = $script:ToolName
        version         = $script:ToolVer
        event           = $Event
        operator        = $script:Operator
        case_id         = $script:CaseId
        computer        = $env:COMPUTERNAME
        windows         = [System.Environment]::OSVersion.VersionString
        data            = $Data
    }
    Add-Content -LiteralPath (Get-PfdLogPath) -Value (($entry | ConvertTo-Json -Compress -Depth 8)) -Encoding UTF8
}

function Get-PfdCustodyLogTail {
    param([int]$Lines = 80)
    $path = Get-PfdLogPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path -Tail $Lines -ErrorAction SilentlyContinue)
}

function ConvertFrom-PfdHexBytes {
    param([Parameter(Mandatory)][string]$Hex)
    $clean = ($Hex -replace '[^0-9A-Fa-f]', '')
    if ($clean.Length % 2 -ne 0) { throw 'Hex inválido: comprimento ímpar.' }
    $bytes = New-Object byte[] ($clean.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($clean.Substring($i * 2, 2), 16)
    }
    return $bytes
}

function Set-PfdRegDword {
    param([string]$Path, [string]$Name, [int]$Value)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

function Set-PfdRegString {
    param([string]$Path, [string]$Name, [string]$Value)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType String -Value $Value -Force | Out-Null
}

function Set-PfdRegBinary {
    param([string]$Path, [string]$Name, [byte[]]$Value)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType Binary -Value $Value -Force | Out-Null
}

function Get-PfdRegDwordOrNull {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return [int]$p.$Name
    } catch { return $null }
}

function Invoke-PfdDiskpart {
    param([Parameter(Mandatory)][string[]]$Commands)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $tmp -Value ($Commands -join "`r`n") -Encoding ASCII
        return (& diskpart.exe /s $tmp 2>&1 | Out-String)
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Enable-PfdDenyGpClass {
    param([Parameter(Mandatory)][string]$Guid)
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Storage\EnabledDenyGP\$Guid"
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    Set-PfdRegDword -Path $path -Name 'EnumerateDevices' -Value 1
    Set-PfdRegDword -Path $path -Name 'AccessBitMask' -Value 0
    Set-PfdRegDword -Path $path -Name 'UserPolicy' -Value 0
    Set-PfdRegDword -Path $path -Name 'AuditPolicyOnly' -Value 0
    Set-PfdRegString -Path $path -Name 'SecurityDescriptor' -Value $script:DenyWriteSddl
}

function Enable-PfdWriteBlock {
    Assert-PfdAdministrator
    $rsd = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices'
    $diskKey = Join-Path $rsd $script:GuidDisk
    $volKey  = Join-Path $rsd $script:GuidVolume
    $custom  = Join-Path $rsd 'Custom\Deny_Write'
    $list    = Join-Path $custom 'List'

    foreach ($p in @($rsd, $diskKey, $volKey, $custom, $list)) {
        if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
    }

    Set-PfdRegDword -Path $diskKey -Name 'Deny_Write' -Value 1
    Set-PfdRegDword -Path $volKey  -Name 'Deny_Write' -Value 1
    Set-PfdRegDword -Path $custom  -Name 'Deny_Write' -Value 1
    Set-PfdRegString -Path $list -Name $script:GuidDisk   -Value $script:GuidDisk
    Set-PfdRegString -Path $list -Name $script:GuidVolume -Value $script:GuidVolume
    Set-PfdRegDword -Path $rsd -Name 'Deny_Write' -Value 1

    $sdp = 'HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies'
    if (-not (Test-Path -LiteralPath $sdp)) { New-Item -Path $sdp -Force | Out-Null }
    Set-PfdRegDword -Path $sdp -Name 'WriteProtect' -Value 1

    $edgp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Storage\EnabledDenyGP'
    if (-not (Test-Path -LiteralPath $edgp)) { New-Item -Path $edgp -Force | Out-Null }
    Set-PfdRegDword -Path $edgp -Name 'DenyAllGPState' -Value 1
    Enable-PfdDenyGpClass -Guid $script:GuidDisk
    Enable-PfdDenyGpClass -Guid $script:GuidVolume

    $bytes = ConvertFrom-PfdHexBytes -Hex $script:HotplugSdHex
    Set-PfdRegBinary -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Storage' -Name 'HotplugSecurityDescriptor' -Value $bytes
    Set-PfdRegDword -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'NoDriveTypeAutoRun' -Value 255
    Disable-PfdAutomount | Out-Null
    Start-Sleep -Seconds 2

    $status = Get-PfdWriteBlockStatus
    Write-PfdCustodyLog -Event 'enable' -Data @{ status = $status }
    return $status
}

function Disable-PfdWriteBlock {
    Assert-PfdAdministrator
    $rsd = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices'
    if (Test-Path -LiteralPath $rsd) {
        Remove-Item -LiteralPath $rsd -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($g in @($script:GuidDisk, $script:GuidVolume)) {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Control\Storage\EnabledDenyGP\$g"
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $sdp = 'HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies'
    if (-not (Test-Path -LiteralPath $sdp)) { New-Item -Path $sdp -Force | Out-Null }
    Set-PfdRegDword -Path $sdp -Name 'WriteProtect' -Value 0
    Remove-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Storage' -Name 'HotplugSecurityDescriptor' -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'NoDriveTypeAutoRun' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $status = Get-PfdWriteBlockStatus
    Write-PfdCustodyLog -Event 'disable' -Data @{ status = $status }
    return $status
}

function Disable-PfdAutomount {
    Assert-PfdAdministrator
    $out = Invoke-PfdDiskpart -Commands @('automount disable', 'exit')
    Set-PfdRegDword -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\MountMgr' -Name 'NoAutoMount' -Value 1
    Write-PfdCustodyLog -Event 'automount_off'
    return $out
}

function Enable-PfdAutomount {
    Assert-PfdAdministrator
    $out = Invoke-PfdDiskpart -Commands @('automount enable', 'exit')
    Set-PfdRegDword -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\MountMgr' -Name 'NoAutoMount' -Value 0
    Write-PfdCustodyLog -Event 'automount_on'
    return $out
}

function Get-PfdWriteBlockStatus {
    $sdp = Get-PfdRegDwordOrNull -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies' -Name 'WriteProtect'
    $denyVol = Get-PfdRegDwordOrNull -Path ("HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{0}" -f $script:GuidVolume) -Name 'Deny_Write'
    $denyDisk = Get-PfdRegDwordOrNull -Path ("HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{0}" -f $script:GuidDisk) -Name 'Deny_Write'
    $edgpVol = Test-Path -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Control\Storage\EnabledDenyGP\{0}" -f $script:GuidVolume)
    $edgpDisk = Test-Path -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Control\Storage\EnabledDenyGP\{0}" -f $script:GuidDisk)
    $hotplug = $false
    try {
        $hotplug = $null -ne (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Storage' -Name 'HotplugSecurityDescriptor' -ErrorAction Stop).HotplugSecurityDescriptor
    } catch { $hotplug = $false }
    $noAuto = Get-PfdRegDwordOrNull -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\MountMgr' -Name 'NoAutoMount'
    $autoRun = Get-PfdRegDwordOrNull -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'NoDriveTypeAutoRun'

    $layersOk = @(
        ($sdp -eq 1),
        ($denyVol -eq 1),
        ($denyDisk -eq 1),
        $edgpVol,
        $edgpDisk,
        [bool]$hotplug,
        ($noAuto -eq 1)
    )
    $enabledCount = @($layersOk | Where-Object { $_ }).Count
    $verdict = if ($enabledCount -ge 6) { 'ENABLED' } elseif ($enabledCount -ge 3) { 'PARTIAL' } else { 'DISABLED' }

    [pscustomobject]@{
        Verdict              = $verdict
        LayersActive         = $enabledCount
        LayersTotal          = $layersOk.Count
        WriteProtect         = $sdp
        DenyWrite_Volume     = $denyVol
        DenyWrite_Disk       = $denyDisk
        EnabledDenyGP_Volume = $edgpVol
        EnabledDenyGP_Disk   = $edgpDisk
        HotplugSD            = [bool]$hotplug
        AutomountDisabled    = ($noAuto -eq 1)
        AutoRunBlocked       = ($autoRun -eq 255)
        Layers = [ordered]@{
            'WriteProtect (USB clássico)' = ($sdp -eq 1)
            'Deny_Write Volume'           = ($denyVol -eq 1)
            'Deny_Write Disk (UAS/HDD)'   = ($denyDisk -eq 1)
            'EnabledDenyGP Volume'        = $edgpVol
            'EnabledDenyGP Disk'          = $edgpDisk
            'HotplugSecurityDescriptor'   = [bool]$hotplug
            'Automount desabilitado'      = ($noAuto -eq 1)
            'AutoRun bloqueado'           = ($autoRun -eq 255)
        }
    }
}

function Get-PfdSystemDiskNumber {
    $systemDrive = $env:SystemDrive.TrimEnd('\')
    return (Get-Partition -DriveLetter $systemDrive.Substring(0, 1) -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty DiskNumber -First 1)
}

function Get-PfdDiskInventory {
    $sysDisk = Get-PfdSystemDiskNumber
    Get-Disk | ForEach-Object {
        $disk = $_
        $isSystem = ($disk.Number -eq $sysDisk)
        $parts = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)
        $letters = @($parts | Where-Object DriveLetter | ForEach-Object { "$($_.DriveLetter):" })
        [pscustomobject]@{
            Number         = $disk.Number
            FriendlyName   = $disk.FriendlyName
            BusType        = "$($disk.BusType)"
            SizeGB         = [math]::Round($disk.Size / 1GB, 2)
            PartitionStyle = "$($disk.PartitionStyle)"
            IsSystem       = $isSystem
            IsOffline      = [bool]$disk.IsOffline
            IsReadOnly     = [bool]$disk.IsReadOnly
            IsExternal     = ((-not $isSystem) -and ($disk.BusType -in @('USB', 'SCSI', 'SAS', 'SD', 'File Backed Virtual')))
            Letters        = ($letters -join ',')
            SerialNumber   = $disk.SerialNumber
            Model          = $disk.Model
        }
    }
}

function Set-PfdDiskReadOnly {
    param(
        [Parameter(Mandatory)][int]$Number,
        [switch]$Clear
    )
    Assert-PfdAdministrator
    $disk = Get-Disk -Number $Number -ErrorAction Stop
    $sysDisk = Get-PfdSystemDiskNumber
    if ($Number -eq $sysDisk) {
        throw "Recusado: disco $Number é o disco do sistema ($($env:SystemDrive))."
    }

    if ($Clear) {
        $out = Invoke-PfdDiskpart -Commands @("select disk $Number", 'attributes disk clear readonly', 'exit')
        Write-PfdCustodyLog -Event 'disk_readonly_cleared' -Data @{ disk = $Number; model = $disk.Model; output = $out }
    } else {
        $out = Invoke-PfdDiskpart -Commands @(
            "select disk $Number",
            'attributes disk set readonly',
            'attributes disk',
            'exit'
        )
        Write-PfdCustodyLog -Event 'disk_readonly_set' -Data @{
            disk = $Number; model = $disk.Model; serial = $disk.SerialNumber; output = $out
        }
    }
    return $out
}

function Invoke-PfdWriteBlockValidation {
    param(
        [Parameter(Mandatory)][int]$Number,
        [switch]$Force
    )
    Assert-PfdAdministrator
    $status = Get-PfdWriteBlockStatus
    if ($status.Verdict -eq 'DISABLED') {
        throw 'Bloqueio desativado. Ative o bloqueio antes de validar.'
    }

    $disk = Get-Disk -Number $Number -ErrorAction Stop
    $sysDisk = Get-PfdSystemDiskNumber
    if ($Number -eq $sysDisk) { throw 'Não valide no disco do sistema.' }
    if (-not $Force) { throw 'Confirmação necessária: use -Force após confirmar mídia de teste.' }

    Set-PfdDiskReadOnly -Number $Number | Out-Null
    $parts = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })
    $results = [System.Collections.Generic.List[object]]::new()

    if ($parts.Count -eq 0) {
        $phys = "\\.\PhysicalDrive$Number"
        $writeDenied = $false
        $detail = ''
        try {
            $fs = [System.IO.File]::Open($phys, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $fs.Close()
            $detail = 'CreateFile WRITE abriu com sucesso (FALHA do bloqueio).'
            $writeDenied = $false
        } catch {
            $writeDenied = $true
            $detail = $_.Exception.Message
        }
        $results.Add([pscustomobject]@{ Target = $phys; WriteBlocked = $writeDenied; Detail = $detail })
    } else {
        foreach ($p in $parts) {
            $root = "$($p.DriveLetter):\"
            $probe = Join-Path $root ("PFD_WB_PROBE_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
            $writeDenied = $false
            $detail = ''
            try {
                [System.IO.File]::WriteAllText($probe, "PFD-WriteBlocker validation probe $(Get-Date -Format o)")
                if (Test-Path -LiteralPath $probe) {
                    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                }
                $detail = 'Escrita de arquivo SUCEDEU (FALHA do bloqueio).'
                $writeDenied = $false
            } catch {
                $writeDenied = $true
                $detail = $_.Exception.Message
            }
            $results.Add([pscustomobject]@{ Target = $root; WriteBlocked = $writeDenied; Detail = $detail })
        }
    }

    $allBlocked = -not (@($results | Where-Object { -not $_.WriteBlocked }).Count -gt 0)
    $verdict = if ($allBlocked) { 'PASS' } else { 'FAIL' }
    Write-PfdCustodyLog -Event 'validation' -Data @{
        disk = $Number; model = $disk.Model; bus = "$($disk.BusType)"
        serial = $disk.SerialNumber; status = $status; results = @($results); verdict = $verdict
    }

    [pscustomobject]@{
        Verdict = $verdict
        Disk    = $Number
        Model   = $disk.FriendlyName
        BusType = "$($disk.BusType)"
        Results = @($results)
    }
}

Export-ModuleMember -Function @(
    'Initialize-PfdSession',
    'Set-PfdSessionMeta',
    'Get-PfdSessionMeta',
    'Test-PfdAdministrator',
    'Assert-PfdAdministrator',
    'Get-PfdLogPath',
    'Write-PfdCustodyLog',
    'Get-PfdCustodyLogTail',
    'Enable-PfdWriteBlock',
    'Disable-PfdWriteBlock',
    'Disable-PfdAutomount',
    'Enable-PfdAutomount',
    'Get-PfdWriteBlockStatus',
    'Get-PfdDiskInventory',
    'Get-PfdSystemDiskNumber',
    'Set-PfdDiskReadOnly',
    'Invoke-PfdWriteBlockValidation'
)
