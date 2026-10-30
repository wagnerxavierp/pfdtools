#Requires -RunAsAdministrator
<#
.SYNOPSIS
  CLI do PFD-WriteBlocker. Para interface gráfica use PFD-WriteBlocker-GUI.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'Enable', 'Disable', 'Status', 'Disks', 'ProtectDisk',
        'ClearDiskProtect', 'AutomountOff', 'AutomountOn',
        'Validate', 'Gui', 'Help'
    )]
    [string]$Action = 'Help',

    [int]$DiskNumber = -1,
    [string]$CaseId = '',
    [string]$Operator = $env:USERNAME,
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs'),
    [switch]$SkipConfirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PFD-WriteBlocker.Core.psm1') -Force
Initialize-PfdSession -CaseId $CaseId -Operator $Operator -LogDir $LogDir
Assert-PfdAdministrator

if ($Action -eq 'Gui') {
    & (Join-Path $PSScriptRoot 'PFD-WriteBlocker-GUI.ps1')
    exit
}

Write-Host ''
Write-Host "PFD-WriteBlocker CLI v$((Get-PfdSessionMeta).Version)" -ForegroundColor Cyan
Write-Host 'Interface gráfica: .\PFD-WriteBlocker-GUI.ps1  ou  .\Iniciar-WriteBlocker.cmd' -ForegroundColor DarkGray
Write-Host ''

Write-PfdCustodyLog -Event 'cli_session_start' -Data @{ action = $Action; disk = $DiskNumber }

try {
    switch ($Action) {
        'Enable' {
            if (-not $SkipConfirm) {
                $ans = Read-Host 'Ativar bloqueio? Conecte evidência só depois. (S/N)'
                if ($ans -notmatch '^[sS]') { throw 'Cancelado.' }
            }
            $s = Enable-PfdWriteBlock
            Write-Host "Status: $($s.Verdict) ($($s.LayersActive)/$($s.LayersTotal))" -ForegroundColor Green
        }
        'Disable' {
            if (-not $SkipConfirm) {
                $ans = Read-Host 'Desativar bloqueio? (S/N)'
                if ($ans -notmatch '^[sS]') { throw 'Cancelado.' }
            }
            $s = Disable-PfdWriteBlock
            Write-Host "Status: $($s.Verdict)" -ForegroundColor Yellow
        }
        'Status' {
            $s = Get-PfdWriteBlockStatus
            Write-Host "Status: $($s.Verdict) ($($s.LayersActive)/$($s.LayersTotal))"
            foreach ($k in $s.Layers.Keys) {
                Write-Host ("  {0}: {1}" -f $k, $(if ($s.Layers[$k]) { 'ON' } else { 'OFF' }))
            }
        }
        'Disks' {
            Get-PfdDiskInventory | Format-Table Number, FriendlyName, BusType, SizeGB, IsSystem, IsExternal, IsReadOnly, Letters, SerialNumber -AutoSize
        }
        'ProtectDisk' {
            if ($DiskNumber -lt 0) { throw 'Informe -DiskNumber' }
            Set-PfdDiskReadOnly -Number $DiskNumber | Out-Null
            Write-Host "Disco $DiskNumber READONLY." -ForegroundColor Green
        }
        'ClearDiskProtect' {
            if ($DiskNumber -lt 0) { throw 'Informe -DiskNumber' }
            Set-PfdDiskReadOnly -Number $DiskNumber -Clear | Out-Null
            Write-Host "Readonly removido do disco $DiskNumber." -ForegroundColor Yellow
        }
        'AutomountOff' {
            Disable-PfdAutomount | Out-Null
            Write-Host 'Automount OFF.' -ForegroundColor Green
        }
        'AutomountOn' {
            Enable-PfdAutomount | Out-Null
            Write-Host 'Automount ON.' -ForegroundColor Yellow
        }
        'Validate' {
            if ($DiskNumber -lt 0) { throw 'Informe -DiskNumber do disco de TESTE' }
            if (-not $SkipConfirm) {
                $ans = Read-Host 'Confirma mídia de TESTE (não evidência)? Digite VALIDAR'
                if ($ans -ne 'VALIDAR') { throw 'Cancelado.' }
            }
            $v = Invoke-PfdWriteBlockValidation -Number $DiskNumber -Force
            Write-Host "Validação: $($v.Verdict)" -ForegroundColor $(if ($v.Verdict -eq 'PASS') { 'Green' } else { 'Red' })
            $v.Results | Format-Table -AutoSize
        }
        'Help' {
            @"
GUI:  .\Iniciar-WriteBlocker.cmd
      .\PFD-WriteBlocker-GUI.ps1

CLI:  .\PFD-WriteBlocker.ps1 Enable|Disable|Status|Disks|Validate|ProtectDisk|...
      .\PFD-WriteBlocker.ps1 Gui
"@ | Write-Host
        }
    }
} catch {
    Write-Host ("ERRO: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-PfdCustodyLog -Event 'error' -Data @{ message = $_.Exception.Message; action = $Action }
    exit 1
}
