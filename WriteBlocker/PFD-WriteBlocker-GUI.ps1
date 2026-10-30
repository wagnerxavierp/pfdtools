#Requires -Version 5.1
<#
.SYNOPSIS
  Interface gráfica do PFD-WriteBlocker para gerenciar o fluxo forense completo.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdminLocal {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# WinForms exige STA; políticas exigem admin
$needSta = [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'
$needAdmin = -not (Test-IsAdminLocal)
if ($needSta -or $needAdmin) {
    $arg = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $startParams = @{ FilePath = 'powershell.exe'; ArgumentList = $arg; WindowStyle = 'Normal' }
    if ($needAdmin) { $startParams['Verb'] = 'RunAs' }
    try {
        Start-Process @startParams | Out-Null
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            'É necessário executar como Administrador (STA).',
            'PFD WriteBlocker', 'OK', 'Warning'
        ) | Out-Null
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$modulePath = Join-Path $PSScriptRoot 'PFD-WriteBlocker.Core.psm1'
Import-Module $modulePath -Force

Initialize-PfdSession -Quiet -Operator $env:USERNAME -LogDir (Join-Path $PSScriptRoot 'logs')
Write-PfdCustodyLog -Event 'gui_session_start'

# -----------------------------------------------------------------------------
# Paleta / helpers UI
# -----------------------------------------------------------------------------
$ui = @{
    Bg       = [System.Drawing.Color]::FromArgb(245, 247, 250)
    Panel    = [System.Drawing.Color]::FromArgb(255, 255, 255)
    Ink      = [System.Drawing.Color]::FromArgb(28, 35, 43)
    Muted    = [System.Drawing.Color]::FromArgb(90, 102, 114)
    Accent   = [System.Drawing.Color]::FromArgb(14, 90, 110)   # teal forense
    AccentHi = [System.Drawing.Color]::FromArgb(18, 120, 140)
    Ok       = [System.Drawing.Color]::FromArgb(26, 127, 70)
    Warn     = [System.Drawing.Color]::FromArgb(166, 110, 10)
    Bad      = [System.Drawing.Color]::FromArgb(170, 45, 45)
    Line     = [System.Drawing.Color]::FromArgb(220, 226, 232)
    Side     = [System.Drawing.Color]::FromArgb(22, 40, 48)
    SideText = [System.Drawing.Color]::FromArgb(210, 222, 228)
}

function New-Font([string]$Name, [float]$Size, [System.Drawing.FontStyle]$Style = 'Regular') {
    return New-Object System.Drawing.Font($Name, $Size, $Style)
}

function Add-UiLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, $Font, $Color)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.Font = $Font
    $l.ForeColor = $Color
    $l.BackColor = [System.Drawing.Color]::Transparent
    [void]$Parent.Controls.Add($l)
    return $l
}

function New-FlatButton {
    param([string]$Text, [int]$W, [int]$H, $Back, $Fore = $null)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back
    $b.ForeColor = $(if ($Fore) { $Fore } else { [System.Drawing.Color]::White })
    $b.Font = New-Font 'Segoe UI Semibold' 9
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.TabStop = $true
    return $b
}

function Append-Activity {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'HH:mm:ss'
    $prefix = switch ($Level) {
        'OK'    { '[OK]   ' }
        'WARN'  { '[WARN] ' }
        'ERROR' { '[ERRO] ' }
        'STEP'  { '[PASSO]' }
        default { '[INFO] ' }
    }
    $tbActivity.AppendText("$stamp  $prefix  $Message`r`n")
    $tbActivity.SelectionStart = $tbActivity.TextLength
    $tbActivity.ScrollToCaret()
}

# -----------------------------------------------------------------------------
# Form principal
# -----------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'PFD WriteBlocker — Gestão Forense'
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1100, 720)
$form.Size = New-Object System.Drawing.Size(1180, 780)
$form.BackColor = $ui.Bg
$form.Font = New-Font 'Segoe UI' 9
$form.KeyPreview = $true

# Sidebar fluxo
$side = New-Object System.Windows.Forms.Panel
$side.Dock = 'Left'
$side.Width = 250
$side.BackColor = $ui.Side
$form.Controls.Add($side)

$lblBrand = Add-UiLabel $side 'PFD' 20 22 210 28 (New-Font 'Segoe UI Semibold' 18) ([System.Drawing.Color]::White)
$lblBrandSub = Add-UiLabel $side 'WriteBlocker' 20 50 210 22 (New-Font 'Segoe UI' 11) $ui.SideText
$lblFlow = Add-UiLabel $side 'FLUXO OPERACIONAL' 20 100 210 18 (New-Font 'Segoe UI Semibold' 8) ([System.Drawing.Color]::FromArgb(120, 150, 160))

$stepLabels = @(
    '1  Identificar caso',
    '2  Ativar bloqueio',
    '3  Validar (mídia teste)',
    '4  Proteger disco evidência',
    '5  Adquirir imagem',
    '6  Encerrar / Disable'
)
$script:stepCtrls = @()
$y = 128
foreach ($t in $stepLabels) {
    $s = Add-UiLabel $side $t 20 $y 210 22 (New-Font 'Segoe UI' 9) $ui.SideText
    $script:stepCtrls += $s
    $y += 28
}

$lblWarnSide = Add-UiLabel $side "Software ≠ hardware`r`nValide antes da evidência." 20 480 210 50 (New-Font 'Segoe UI' 8.5) ([System.Drawing.Color]::FromArgb(220, 180, 120))

# Conteúdo
$content = New-Object System.Windows.Forms.Panel
$content.Dock = 'Fill'
$content.Padding = New-Object System.Windows.Forms.Padding(18)
$content.BackColor = $ui.Bg
$form.Controls.Add($content)
$content.BringToFront()

# --- Header caso ---
$pnlCase = New-Object System.Windows.Forms.Panel
$pnlCase.Location = New-Object System.Drawing.Point(18, 16)
$pnlCase.Size = New-Object System.Drawing.Size(860, 70)
$pnlCase.Anchor = 'Top,Left,Right'
$pnlCase.BackColor = $ui.Panel
$content.Controls.Add($pnlCase)

Add-UiLabel $pnlCase 'Caso / ID' 16 10 120 18 (New-Font 'Segoe UI' 8) $ui.Muted | Out-Null
$txtCase = New-Object System.Windows.Forms.TextBox
$txtCase.Location = New-Object System.Drawing.Point(16, 30)
$txtCase.Size = New-Object System.Drawing.Size(220, 26)
$txtCase.Font = New-Font 'Consolas' 10
$pnlCase.Controls.Add($txtCase)

Add-UiLabel $pnlCase 'Operador' 256 10 120 18 (New-Font 'Segoe UI' 8) $ui.Muted | Out-Null
$txtOp = New-Object System.Windows.Forms.TextBox
$txtOp.Location = New-Object System.Drawing.Point(256, 30)
$txtOp.Size = New-Object System.Drawing.Size(180, 26)
$txtOp.Text = $env:USERNAME
$txtOp.Font = New-Font 'Segoe UI' 10
$pnlCase.Controls.Add($txtOp)

$btnSaveMeta = New-FlatButton 'Salvar metadados' 140 32 $ui.Accent
$btnSaveMeta.Location = New-Object System.Drawing.Point(460, 26)
$pnlCase.Controls.Add($btnSaveMeta)

$lblStatusBig = Add-UiLabel $pnlCase 'STATUS: —' 620 22 220 30 (New-Font 'Segoe UI Semibold' 14) $ui.Muted

# --- Status camadas ---
$pnlStatus = New-Object System.Windows.Forms.Panel
$pnlStatus.Location = New-Object System.Drawing.Point(18, 98)
$pnlStatus.Size = New-Object System.Drawing.Size(420, 250)
$pnlStatus.Anchor = 'Top,Left'
$pnlStatus.BackColor = $ui.Panel
$content.Controls.Add($pnlStatus)

Add-UiLabel $pnlStatus 'Camadas de bloqueio' 16 12 300 22 (New-Font 'Segoe UI Semibold' 11) $ui.Ink | Out-Null
$lstLayers = New-Object System.Windows.Forms.ListView
$lstLayers.Location = New-Object System.Drawing.Point(16, 42)
$lstLayers.Size = New-Object System.Drawing.Size(388, 160)
$lstLayers.View = 'Details'
$lstLayers.FullRowSelect = $true
$lstLayers.HeaderStyle = 'Nonclickable'
$lstLayers.Columns.Add('Camada', 260) | Out-Null
$lstLayers.Columns.Add('Estado', 100) | Out-Null
$lstLayers.Font = New-Font 'Segoe UI' 9
$pnlStatus.Controls.Add($lstLayers)

$btnRefresh = New-FlatButton 'Atualizar status' 130 28 $ui.Accent
$btnRefresh.Location = New-Object System.Drawing.Point(16, 212)
$pnlStatus.Controls.Add($btnRefresh)

$lblLayersCount = Add-UiLabel $pnlStatus '' 160 216 230 22 (New-Font 'Segoe UI' 9) $ui.Muted

# --- Ações principais ---
$pnlActions = New-Object System.Windows.Forms.Panel
$pnlActions.Location = New-Object System.Drawing.Point(454, 98)
$pnlActions.Size = New-Object System.Drawing.Size(424, 250)
$pnlActions.Anchor = 'Top,Left,Right'
$pnlActions.BackColor = $ui.Panel
$content.Controls.Add($pnlActions)

Add-UiLabel $pnlActions 'Controles' 16 12 300 22 (New-Font 'Segoe UI Semibold' 11) $ui.Ink | Out-Null

$btnEnable = New-FlatButton '1. Ativar bloqueio' 190 40 $ui.Ok
$btnEnable.Location = New-Object System.Drawing.Point(16, 48)
$pnlActions.Controls.Add($btnEnable)

$btnDisable = New-FlatButton 'Desativar bloqueio' 190 40 $ui.Bad
$btnDisable.Location = New-Object System.Drawing.Point(220, 48)
$pnlActions.Controls.Add($btnDisable)

$btnValidate = New-FlatButton '2. Validar disco teste' 190 40 $ui.Accent
$btnValidate.Location = New-Object System.Drawing.Point(16, 100)
$pnlActions.Controls.Add($btnValidate)

$btnProtect = New-FlatButton '3. Proteger evidência' 190 40 $ui.AccentHi
$btnProtect.Location = New-Object System.Drawing.Point(220, 100)
$pnlActions.Controls.Add($btnProtect)

$btnClearRO = New-FlatButton 'Limpar readonly' 190 34 ([System.Drawing.Color]::FromArgb(90, 102, 114))
$btnClearRO.Location = New-Object System.Drawing.Point(16, 156)
$pnlActions.Controls.Add($btnClearRO)

$btnAutoOff = New-FlatButton 'Automount OFF' 90 34 ([System.Drawing.Color]::FromArgb(70, 85, 95))
$btnAutoOff.Location = New-Object System.Drawing.Point(220, 156)
$pnlActions.Controls.Add($btnAutoOff)

$btnAutoOn = New-FlatButton 'Automount ON' 90 34 ([System.Drawing.Color]::FromArgb(70, 85, 95))
$btnAutoOn.Location = New-Object System.Drawing.Point(320, 156)
$pnlActions.Controls.Add($btnAutoOn)

Add-UiLabel $pnlActions 'Conecte a evidência somente após Status = ENABLED e validação PASS.' 16 204 390 30 (New-Font 'Segoe UI' 8.5) $ui.Warn | Out-Null

# --- Discos ---
$pnlDisks = New-Object System.Windows.Forms.Panel
$pnlDisks.Location = New-Object System.Drawing.Point(18, 360)
$pnlDisks.Size = New-Object System.Drawing.Size(860, 200)
$pnlDisks.Anchor = 'Top,Left,Right,Bottom'
$pnlDisks.BackColor = $ui.Panel
$content.Controls.Add($pnlDisks)

Add-UiLabel $pnlDisks 'Discos conectados' 16 10 300 22 (New-Font 'Segoe UI Semibold' 11) $ui.Ink | Out-Null
$btnRescan = New-FlatButton 'Rescan' 90 28 $ui.Accent
$btnRescan.Location = New-Object System.Drawing.Point(750, 8)
$btnRescan.Anchor = 'Top,Right'
$pnlDisks.Controls.Add($btnRescan)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(16, 42)
$grid.Size = New-Object System.Drawing.Size(828, 142)
$grid.Anchor = 'Top,Left,Right,Bottom'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.ReadOnly = $true
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.BorderStyle = 'None'
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(236, 241, 245)
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $ui.Ink
$grid.ColumnHeadersDefaultCellStyle.Font = New-Font 'Segoe UI Semibold' 8.5
$grid.DefaultCellStyle.Font = New-Font 'Consolas' 9
$grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(210, 232, 238)
$grid.DefaultCellStyle.SelectionForeColor = $ui.Ink
$pnlDisks.Controls.Add($grid)

# --- Atividade ---
$pnlAct = New-Object System.Windows.Forms.Panel
$pnlAct.Dock = 'Bottom'
$pnlAct.Height = 150
$pnlAct.BackColor = [System.Drawing.Color]::FromArgb(18, 28, 34)
$content.Controls.Add($pnlAct)
$pnlAct.BringToFront()

Add-UiLabel $pnlAct 'Atividade / cadeia de custódia (sessão)' 12 6 400 18 (New-Font 'Segoe UI Semibold' 8.5) ([System.Drawing.Color]::FromArgb(160, 180, 190)) | Out-Null
$btnOpenLog = New-FlatButton 'Abrir log' 90 24 ([System.Drawing.Color]::FromArgb(40, 60, 70))
$btnOpenLog.Location = New-Object System.Drawing.Point(760, 4)
$btnOpenLog.Anchor = 'Top,Right'
$pnlAct.Controls.Add($btnOpenLog)

$tbActivity = New-Object System.Windows.Forms.TextBox
$tbActivity.Multiline = $true
$tbActivity.ScrollBars = 'Vertical'
$tbActivity.ReadOnly = $true
$tbActivity.BorderStyle = 'None'
$tbActivity.BackColor = [System.Drawing.Color]::FromArgb(18, 28, 34)
$tbActivity.ForeColor = [System.Drawing.Color]::FromArgb(200, 220, 210)
$tbActivity.Font = New-Font 'Consolas' 8.5
$tbActivity.Location = New-Object System.Drawing.Point(12, 28)
$tbActivity.Size = New-Object System.Drawing.Size(836, 110)
$tbActivity.Anchor = 'Top,Left,Right,Bottom'
$pnlAct.Controls.Add($tbActivity)

# Ajuste layout quando form redimensiona
$form.Add_Resize({
    $w = $content.ClientSize.Width - 36
    if ($w -lt 400) { return }
    $pnlCase.Width = $w
    $pnlDisks.Width = $w
    $pnlActions.Width = [Math]::Max(300, $w - 454 - 18)
    $half = [Math]::Floor(($w - 16) / 2)
    # keep status fixed width; actions fills rest
    $lblStatusBig.Left = [Math]::Max(620, $pnlCase.Width - 240)
    $btnRescan.Left = $pnlDisks.Width - 106
    $grid.Width = $pnlDisks.Width - 32
    $btnOpenLog.Left = $pnlAct.Width - 110
    $tbActivity.Width = $pnlAct.Width - 24
})

# -----------------------------------------------------------------------------
# Lógica UI
# -----------------------------------------------------------------------------
function Sync-Meta {
    Set-PfdSessionMeta -CaseId $txtCase.Text.Trim() -Operator $txtOp.Text.Trim()
}

function Get-SelectedDiskNumber {
    if ($grid.SelectedRows.Count -lt 1) { return $null }
    $row = $grid.SelectedRows[0]
    return [int]$row.Cells['Number'].Value
}

function Update-StepHighlight {
    param([int]$ActiveIndex)
    for ($i = 0; $i -lt $script:stepCtrls.Count; $i++) {
        if ($i -eq $ActiveIndex) {
            $script:stepCtrls[$i].ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 200)
            $script:stepCtrls[$i].Font = New-Font 'Segoe UI Semibold' 9
        } elseif ($i -lt $ActiveIndex) {
            $script:stepCtrls[$i].ForeColor = [System.Drawing.Color]::FromArgb(90, 180, 140)
            $script:stepCtrls[$i].Font = New-Font 'Segoe UI' 9
        } else {
            $script:stepCtrls[$i].ForeColor = $ui.SideText
            $script:stepCtrls[$i].Font = New-Font 'Segoe UI' 9
        }
    }
}

function Refresh-StatusUi {
    $s = Get-PfdWriteBlockStatus
    $lstLayers.Items.Clear()
    foreach ($k in $s.Layers.Keys) {
        $on = [bool]$s.Layers[$k]
        $item = New-Object System.Windows.Forms.ListViewItem($k)
        [void]$item.SubItems.Add($(if ($on) { 'ON' } else { 'OFF' }))
        $item.ForeColor = $(if ($on) { $ui.Ok } else { $ui.Bad })
        [void]$lstLayers.Items.Add($item)
    }
    $lblLayersCount.Text = "$($s.LayersActive)/$($s.LayersTotal) camadas ativas"
    $lblStatusBig.Text = "STATUS: $($s.Verdict)"
    $lblStatusBig.ForeColor = switch ($s.Verdict) {
        'ENABLED' { $ui.Ok }
        'PARTIAL' { $ui.Warn }
        default   { $ui.Bad }
    }
    $step = switch ($s.Verdict) {
        'ENABLED' { 2 }
        'PARTIAL' { 1 }
        default   { 1 }
    }
    if ($txtCase.Text.Trim()) { $step = [Math]::Max($step, 1) }
    Update-StepHighlight $step
    return $s
}

function Refresh-DisksUi {
    $rows = @(Get-PfdDiskInventory)
    $table = New-Object System.Data.DataTable
    foreach ($c in @('Number','FriendlyName','BusType','SizeGB','IsSystem','IsExternal','IsReadOnly','IsOffline','Letters','SerialNumber')) {
        [void]$table.Columns.Add($c)
    }
    foreach ($r in $rows) {
        [void]$table.Rows.Add(@(
            $r.Number, $r.FriendlyName, $r.BusType, $r.SizeGB,
            $r.IsSystem, $r.IsExternal, $r.IsReadOnly, $r.IsOffline,
            $r.Letters, $r.SerialNumber
        ))
    }
    $grid.DataSource = $table
    Append-Activity "Inventário: $($rows.Count) disco(s)." 'INFO'
}

function Invoke-UiAction {
    param([scriptblock]$Work, [string]$BusyText)
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    foreach ($c in @($btnEnable,$btnDisable,$btnValidate,$btnProtect,$btnClearRO,$btnAutoOff,$btnAutoOn,$btnRefresh,$btnRescan)) {
        $c.Enabled = $false
    }
    Append-Activity $BusyText 'STEP'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        Sync-Meta
        & $Work
    } catch {
        Append-Activity $_.Exception.Message 'ERROR'
        Write-PfdCustodyLog -Event 'error' -Data @{ message = $_.Exception.Message }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Erro', 'OK', 'Error') | Out-Null
    } finally {
        foreach ($c in @($btnEnable,$btnDisable,$btnValidate,$btnProtect,$btnClearRO,$btnAutoOff,$btnAutoOn,$btnRefresh,$btnRescan)) {
            $c.Enabled = $true
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        Refresh-StatusUi | Out-Null
        Refresh-DisksUi
    }
}

$btnSaveMeta.Add_Click({
    Sync-Meta
    Write-PfdCustodyLog -Event 'meta_saved' -Data @{ case = $txtCase.Text; operator = $txtOp.Text }
    Append-Activity "Metadados salvos: caso='$($txtCase.Text)' operador='$($txtOp.Text)'." 'OK'
    Update-StepHighlight 1
})

$btnRefresh.Add_Click({
    Invoke-UiAction -BusyText 'Atualizando status...' -Work {
        $s = Refresh-StatusUi
        Append-Activity "Status: $($s.Verdict) ($($s.LayersActive)/$($s.LayersTotal))." 'OK'
    }
})

$btnRescan.Add_Click({
    Invoke-UiAction -BusyText 'Reescaneando discos...' -Work {
        Refresh-DisksUi
    }
})

$btnEnable.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Ativar bloqueio em camadas AGORA?`r`n`r`nConecte a evidência somente DEPOIS de Status = ENABLED.",
        'Ativar bloqueio', 'YesNo', 'Question'
    )
    if ($r -ne 'Yes') { return }
    Invoke-UiAction -BusyText 'Aplicando políticas de write-block...' -Work {
        $s = Enable-PfdWriteBlock
        Append-Activity "Bloqueio ativado: $($s.Verdict)." 'OK'
        Update-StepHighlight 2
        [System.Windows.Forms.MessageBox]::Show(
            "Bloqueio: $($s.Verdict)`r`n$($s.LayersActive)/$($s.LayersTotal) camadas.`r`n`r`nPróximo: conecte mídia de TESTE e valide.",
            'Enable', 'OK', 'Information'
        ) | Out-Null
    }
})

$btnDisable.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        'Desativar bloqueio? Escrita em USB/removíveis voltará a ser permitida.',
        'Desativar', 'YesNo', 'Warning'
    )
    if ($r -ne 'Yes') { return }
    Invoke-UiAction -BusyText 'Removendo políticas de write-block...' -Work {
        $s = Disable-PfdWriteBlock
        Append-Activity "Bloqueio desativado: $($s.Verdict)." 'WARN'
        Update-StepHighlight 5
    }
})

$btnValidate.Add_Click({
    $n = Get-SelectedDiskNumber
    if ($null -eq $n) {
        [System.Windows.Forms.MessageBox]::Show('Selecione um disco de TESTE na grade.', 'Validar', 'OK', 'Information') | Out-Null
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "VALIDAÇÃO no disco #$n.`r`n`r`nConfirme que NÃO é evidência. Será feita tentativa de escrita para testar o bloqueio.`r`n`r`nDigite OK mentalmente e confirme.",
        'Validar mídia de teste', 'OKCancel', 'Warning'
    )
    if ($r -ne 'OK') { return }
    Invoke-UiAction -BusyText "Validando disco #$n..." -Work {
        $v = Invoke-PfdWriteBlockValidation -Number $n -Force
        $level = if ($v.Verdict -eq 'PASS') { 'OK' } else { 'ERROR' }
        Append-Activity "Validação disco #$n : $($v.Verdict)" $level
        foreach ($res in $v.Results) {
            $tag = if ($res.WriteBlocked) { 'BLOQUEADO' } else { 'ESCREVEU' }
            Append-Activity "  [$tag] $($res.Target) — $($res.Detail)" $(if ($res.WriteBlocked) { 'OK' } else { 'ERROR' })
        }
        if ($v.Verdict -eq 'PASS') { Update-StepHighlight 3 }
        [System.Windows.Forms.MessageBox]::Show(
            "Resultado: $($v.Verdict)`r`nDisco #$($v.Disk) $($v.Model) ($($v.BusType))",
            'Validação', 'OK', $(if ($v.Verdict -eq 'PASS') { 'Information' } else { 'Error' })
        ) | Out-Null
    }
})

$btnProtect.Add_Click({
    $n = Get-SelectedDiskNumber
    if ($null -eq $n) {
        [System.Windows.Forms.MessageBox]::Show('Selecione o disco de EVIDÊNCIA na grade.', 'Proteger', 'OK', 'Information') | Out-Null
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Marcar disco #$n como READONLY (attributes disk set readonly)?",
        'Proteger evidência', 'YesNo', 'Question'
    )
    if ($r -ne 'Yes') { return }
    Invoke-UiAction -BusyText "Aplicando readonly no disco #$n..." -Work {
        Set-PfdDiskReadOnly -Number $n | Out-Null
        Append-Activity "Disco #$n marcado READONLY." 'OK'
        Update-StepHighlight 4
    }
})

$btnClearRO.Add_Click({
    $n = Get-SelectedDiskNumber
    if ($null -eq $n) {
        [System.Windows.Forms.MessageBox]::Show('Selecione um disco.', 'Limpar readonly', 'OK', 'Information') | Out-Null
        return
    }
    Invoke-UiAction -BusyText "Removendo readonly do disco #$n..." -Work {
        Set-PfdDiskReadOnly -Number $n -Clear | Out-Null
        Append-Activity "Readonly removido do disco #$n." 'WARN'
    }
})

$btnAutoOff.Add_Click({
    Invoke-UiAction -BusyText 'Desabilitando automount...' -Work {
        Disable-PfdAutomount | Out-Null
        Append-Activity 'Automount OFF.' 'OK'
    }
})

$btnAutoOn.Add_Click({
    Invoke-UiAction -BusyText 'Habilitando automount...' -Work {
        Enable-PfdAutomount | Out-Null
        Append-Activity 'Automount ON.' 'WARN'
    }
})

$btnOpenLog.Add_Click({
    $path = Get-PfdLogPath
    if (Test-Path -LiteralPath $path) {
        Start-Process explorer.exe "/select,`"$path`""
    } else {
        Start-Process explorer.exe ((Get-PfdSessionMeta).LogDir)
    }
})

# Init
$form.Add_Shown({
    Append-Activity "Sessão GUI iniciada em $env:COMPUTERNAME como $env:USERNAME." 'INFO'
    Append-Activity 'Fluxo: Caso → Ativar → Validar (teste) → Proteger evidência → Adquirir → Disable.' 'STEP'
    Refresh-StatusUi | Out-Null
    Refresh-DisksUi
    Update-StepHighlight 0
})

[void][System.Windows.Forms.Application]::Run($form)
