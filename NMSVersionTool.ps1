# No Man's Sky セーブバージョン変更ツール (GUI)
# 実処理は同じフォルダの NmsSave.cs（nms_downgrade.js の C# 移植）を Add-Type で読み込んで呼ぶ。ここは画面とバックアップ・安全確認だけを持つ。
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ToolDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$NmsSaveCs   = Join-Path $ToolDir 'NmsSave.cs'
$SettingsDir = Join-Path $env:APPDATA 'NMSVersionTool'
$SettingsFn  = Join-Path $SettingsDir 'settings.json'
$NmsRoot     = Join-Path $env:APPDATA 'HelloGames\NMS'
$BackupRoot  = $env:USERPROFILE

# ---------- 文言 (ja / en) ----------
$Lang = if ((Get-Culture).TwoLetterISOLanguageName -eq 'ja') { 'ja' } else { 'en' }
$FontName = if ($Lang -eq 'ja') { 'Yu Gothic UI' } else { 'Segoe UI' }
$Strings = @{
    ja = @{
        title          = 'No Man''s Sky セーブバージョン変更ツール'
        lblDir         = 'セーブフォルダ:'
        btnBrowse      = '参照...'
        colFile        = 'ファイル'
        colSlot        = 'スロット'
        colMode        = 'ゲームモード'
        colVersion     = '現在のバージョン'
        colModified    = '最終更新'
        colState       = '状態'
        lblTarget      = '変更後のバージョン:'
        btnReload      = '再読み込み'
        btnRun         = 'バックアップして変更'
        btnOpenBak     = 'バックアップを開く'
        gameRunning    = 'No Man''s Sky が起動中です。ゲームを終了してから「再読み込み」を押してください。'
        pickDir        = 'セーブフォルダを選んでください。'
        noSaves        = 'このフォルダにセーブデータが見つかりません。'
        modeNormal     = 'ノーマル'
        modeN          = 'モード {0}'
        stError        = 'エラー: {0}'
        stSame         = '変更不要'
        stChange       = '→ {0} に変更'
        allSame        = 'すべてのセーブが {0} です。変更は不要です。'
        canChange      = '{0} 件のセーブを {1} に変更できます。対象を確認して「{2}」を押してください。'
        nothingToDo    = '変更する対象がありません。'
        confirmBody    = "次のセーブのバージョンを変更します。`r`n`r`n{0}`r`n`r`n変更前にセーブフォルダ全体をバックアップします。よろしいですか？"
        titleInfo      = 'NMS'
        titleConfirm   = '確認'
        titleDone      = '完了'
        titleError     = 'エラー'
        logBackup      = 'バックアップ: {0}'
        logChanged     = '{0}.hg: {1} → {2} 完了'
        logSame        = '{0}.hg: すでに {1} のためスキップ'
        logFailed      = '{0}.hg: 失敗 - {1}'
        logError       = 'エラー: {0}'
        doneBody       = "バージョンを {0} に変更しました。`r`n`r`nSteam クラウドの競合が表示されたら「ローカル」を選んでください。"
        partialBody    = "一部のセーブで失敗しました。ログを確認してください。`r`nバックアップ: {0}"
        abortBody      = "処理を中止しました。`r`n{0}"
        browseDesc     = 'セーブフォルダ (save.hg があるフォルダ) を選んでください'
        compileFail    = "処理エンジン (NmsSave.cs) を読み込めませんでした。`r`n`r`n{0}"
    }
    en = @{
        title          = 'No Man''s Sky Save Version Tool'
        lblDir         = 'Save folder:'
        btnBrowse      = 'Browse...'
        colFile        = 'File'
        colSlot        = 'Slot'
        colMode        = 'Game mode'
        colVersion     = 'Current version'
        colModified    = 'Last modified'
        colState       = 'Status'
        lblTarget      = 'Target version:'
        btnReload      = 'Reload'
        btnRun         = 'Back up and change'
        btnOpenBak     = 'Open backup'
        gameRunning    = 'No Man''s Sky is running. Close the game, then press "Reload".'
        pickDir        = 'Please choose a save folder.'
        noSaves        = 'No save data was found in this folder.'
        modeNormal     = 'Normal'
        modeN          = 'Mode {0}'
        stError        = 'Error: {0}'
        stSame         = 'No change needed'
        stChange       = '-> change to {0}'
        allSame        = 'All saves are already {0}. Nothing to change.'
        canChange      = '{0} save(s) can be changed to {1}. Review the selection, then press "{2}".'
        nothingToDo    = 'There is nothing to change.'
        confirmBody    = "The version of the following saves will be changed.`r`n`r`n{0}`r`n`r`nThe whole save folder will be backed up first. Continue?"
        titleInfo      = 'NMS'
        titleConfirm   = 'Confirm'
        titleDone      = 'Done'
        titleError     = 'Error'
        logBackup      = 'Backup: {0}'
        logChanged     = '{0}.hg: {1} -> {2} done'
        logSame        = '{0}.hg: already {1}, skipped'
        logFailed      = '{0}.hg: failed - {1}'
        logError       = 'Error: {0}'
        doneBody       = "Changed the version to {0}.`r`n`r`nIf Steam shows a cloud sync conflict, choose the local (this computer) version."
        partialBody    = "Some saves failed. Please check the log.`r`nBackup: {0}"
        abortBody      = "Operation aborted.`r`n{0}"
        browseDesc     = 'Choose the save folder (the folder that contains save.hg)'
        compileFail    = "Could not load the processing engine (NmsSave.cs).`r`n`r`n{0}"
    }
}
function T([string]$key) {
    $text = $Strings[$Lang][$key]
    if ($null -eq $text) { return $key }
    if ($args.Count -gt 0) { return ($text -f $args) }
    return $text
}

$ModeNames  = @{ 1 = (T 'modeNormal') }   # 確認済みは 1 のみ。他は番号表示

# ---------- 処理エンジン (NmsSave.cs) の読み込み ----------
try {
    if (-not ('NmsSaveTool.NmsSave' -as [type])) { Add-Type -LiteralPath $NmsSaveCs -ErrorAction Stop }   # -Path だと [ ] を含むフォルダで失敗する
    [NmsSaveTool.NmsSave]::Lang = $Lang
} catch {
    [void][Windows.Forms.MessageBox]::Show((T 'compileFail' $_.Exception.Message), (T 'titleError'), 'OK', 'Error')
    exit 1
}

function Load-Settings {
    if (-not (Test-Path -LiteralPath $SettingsFn)) { return $null }
    try { return Get-Content -LiteralPath $SettingsFn -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { return $null }
}
function Save-Settings($target, $dir) {
    try {
        if (-not (Test-Path -LiteralPath $SettingsDir)) { [void](New-Item -ItemType Directory -Path $SettingsDir -Force) }
        $json = @{ target = $target; saveDir = $dir } | ConvertTo-Json
        [IO.File]::WriteAllText($SettingsFn, $json, (New-Object Text.UTF8Encoding $false))
    } catch { }
}

# セーブ処理（$target が $null なら読み取りのみ。$only が空でなければその名前だけ）
function Get-SaveResults([string]$dir, $target, [bool]$write, $only) {
    $names = @([NmsSaveTool.NmsSave]::ListSaves($dir))
    if ($only) { $names = @($names | Where-Object { $only -contains $_ }) }
    $out = @()
    foreach ($n in $names) { $out += [NmsSaveTool.NmsSave]::Process($dir, $n, $target, $write) }
    return $out
}

# %APPDATA%\HelloGames\NMS 配下で save*.hg を含むサブフォルダ（Steam: st_<id>, GOG: DefaultUser 等）。更新日時の新しい順
function Get-SaveDirs {
    if (-not (Test-Path -LiteralPath $NmsRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $NmsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Where-Object { try { @([NmsSaveTool.NmsSave]::ListSaves($_.FullName)).Count -gt 0 } catch { $false } } |
        ForEach-Object { $_.FullName })
}

function Test-GameRunning { return [bool](Get-Process -Name NMS -ErrorAction SilentlyContinue) }

# ---------- 画面 ----------
$form = New-Object Windows.Forms.Form
$form.Text = (T 'title')
$form.Size = New-Object Drawing.Size(760, 560)
$form.MinimumSize = New-Object Drawing.Size(640, 460)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font($FontName, 9.5)

$lblDir = New-Object Windows.Forms.Label
$lblDir.Text = (T 'lblDir'); $lblDir.Location = '12,16'; $lblDir.AutoSize = $true
$cmbDir = New-Object Windows.Forms.ComboBox
$cmbDir.Location = '110,12'; $cmbDir.Size = '520,24'; $cmbDir.DropDownStyle = 'DropDown'
$cmbDir.Anchor = 'Top,Left,Right'
$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = (T 'btnBrowse'); $btnBrowse.Location = '638,11'; $btnBrowse.Size = '94,26'; $btnBrowse.Anchor = 'Top,Right'

$list = New-Object Windows.Forms.ListView
$list.Location = '12,48'; $list.Size = '720,200'; $list.Anchor = 'Top,Left,Right'
$list.View = 'Details'; $list.CheckBoxes = $true; $list.FullRowSelect = $true; $list.GridLines = $true
foreach ($c in @(@((T 'colFile'), 90), @((T 'colSlot'), 70), @((T 'colMode'), 110), @((T 'colVersion'), 120), @((T 'colModified'), 150), @((T 'colState'), 160))) {
    [void]$list.Columns.Add($c[0], $c[1])
}

$lblTarget = New-Object Windows.Forms.Label
$lblTarget.Text = (T 'lblTarget'); $lblTarget.Location = '12,262'; $lblTarget.AutoSize = $true
$numTarget = New-Object Windows.Forms.NumericUpDown
$numTarget.Location = '140,258'; $numTarget.Size = '90,24'; $numTarget.Minimum = 1000; $numTarget.Maximum = 9999; $numTarget.Value = 4225

$btnReload = New-Object Windows.Forms.Button
$btnReload.Text = (T 'btnReload'); $btnReload.Location = '250,256'; $btnReload.Size = '100,28'
$btnRun = New-Object Windows.Forms.Button
$btnRun.Text = (T 'btnRun'); $btnRun.Location = '360,256'; $btnRun.Size = '170,28'
$btnRun.Font = New-Object Drawing.Font($FontName, 9.5, [Drawing.FontStyle]::Bold)
$btnOpenBak = New-Object Windows.Forms.Button
$btnOpenBak.Text = (T 'btnOpenBak'); $btnOpenBak.Location = '540,256'; $btnOpenBak.Size = '140,28'

$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Location = '12,292'; $lblStatus.Size = '720,20'; $lblStatus.Anchor = 'Top,Left,Right'

$log = New-Object Windows.Forms.TextBox
$log.Location = '12,316'; $log.Size = '720,190'; $log.Anchor = 'Top,Bottom,Left,Right'
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
$log.Font = New-Object Drawing.Font('Consolas', 9)

$form.Controls.AddRange(@($lblDir, $cmbDir, $btnBrowse, $list, $lblTarget, $numTarget, $btnReload, $btnRun, $btnOpenBak, $lblStatus, $log))

function Write-Log([string]$msg) {
    $log.AppendText(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg) + "`r`n")
}

function Set-Status([string]$msg, [string]$color = 'Black') {
    $lblStatus.Text = $msg; $lblStatus.ForeColor = [Drawing.Color]::FromName($color)
}

function Update-RunState {
    if (Test-GameRunning) {
        $btnRun.Enabled = $false
        Set-Status (T 'gameRunning') 'Firebrick'
        return $false
    }
    $btnRun.Enabled = $true
    return $true
}

function Refresh-List {
    $list.Items.Clear()
    $dir = $cmbDir.Text
    if (-not $dir) { Set-Status (T 'pickDir') 'Firebrick'; $btnRun.Enabled = $false; return }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Set-Status (T 'noSaves') 'Firebrick'; $btnRun.Enabled = $false; return
    }
    try { $res = @(Get-SaveResults $dir $null $false $null) } catch { Set-Status $_.Exception.Message 'Firebrick'; return }
    if ($res.Count -eq 0) {
        Set-Status (T 'noSaves') 'Firebrick'; $btnRun.Enabled = $false; return
    }
    $target = [int]$numTarget.Value
    foreach ($r in $res) {
        $slotNo = if ($null -ne $r.Slot) { [string]([math]::Floor(($r.Slot - 2) / 2) + 1) } else { '?' }
        $mode = if ($null -ne $r.Mode -and $ModeNames.ContainsKey([int]$r.Mode)) { $ModeNames[[int]$r.Mode] } else { (T 'modeN' ([string]$r.Mode)) }
        $ver = if ($null -ne $r.Base) { [string]$r.Base } else { '-' }
        $time = if ($null -ne $r.MTime) { $r.MTime.ToString('yyyy/MM/dd HH:mm') } else { '' }
        $state = if ($r.Error) { (T 'stError' $r.Error) } elseif ($r.Base -eq $target) { (T 'stSame') } else { (T 'stChange' $target) }
        $item = New-Object Windows.Forms.ListViewItem($r.Name + '.hg')
        foreach ($s in @($slotNo, $mode, $ver, $time, $state)) { [void]$item.SubItems.Add($s) }
        $item.Tag = $r
        $item.Checked = (-not $r.Error) -and ($r.Base -ne $target)
        if ($r.Error) { $item.ForeColor = [Drawing.Color]::Firebrick }
        [void]$list.Items.Add($item)
    }
    if (Update-RunState) {
        $n = @($list.Items | Where-Object { $_.Checked }).Count
        if ($n -eq 0) { Set-Status (T 'allSame' $target) 'DarkGreen' }
        else { Set-Status (T 'canChange' $n $target (T 'btnRun')) 'Black' }
    }
}

function Invoke-Run {
    if (-not (Update-RunState)) { return }
    $dir = $cmbDir.Text
    $target = [int]$numTarget.Value
    $names = @($list.Items | Where-Object { $_.Checked -and -not $_.Tag.Error -and $_.Tag.Base -ne $target } | ForEach-Object { $_.Tag.Name })
    if ($names.Count -eq 0) { [void][Windows.Forms.MessageBox]::Show((T 'nothingToDo'), (T 'titleInfo'), 'OK', 'Information'); return }
    $lines = @($list.Items | Where-Object { $names -contains $_.Tag.Name } | ForEach-Object { "  $($_.Text)  :  $($_.Tag.Base) → $target" }) -join "`r`n"
    $ans = [Windows.Forms.MessageBox]::Show((T 'confirmBody' $lines), (T 'titleConfirm'), 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    $form.UseWaitCursor = $true; $btnRun.Enabled = $false
    try {
        $bak = Join-Path $BackupRoot ('NMS_backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Copy-Item -LiteralPath $dir -Destination $bak -Recurse -ErrorAction Stop
        Write-Log (T 'logBackup' $bak)
        $res = @(Get-SaveResults $dir $target $true $names)
        foreach ($r in $res) {
            if ($r.Action -eq 'changed') { Write-Log (T 'logChanged' $r.Name $r.Base $r.Target) }
            elseif ($r.Action -eq 'same') { Write-Log (T 'logSame' $r.Name $r.Target) }
            else { Write-Log (T 'logFailed' $r.Name $r.Error) }
        }
        Save-Settings $target $dir
        Refresh-List
        $failed = @($res | Where-Object { $_.Action -eq 'error' })
        if ($failed.Count -eq 0) {
            [void][Windows.Forms.MessageBox]::Show((T 'doneBody' $target), (T 'titleDone'), 'OK', 'Information')
        } else {
            [void][Windows.Forms.MessageBox]::Show((T 'partialBody' $bak), (T 'titleError'), 'OK', 'Warning')
        }
    } catch {
        Write-Log (T 'logError' $_.Exception.Message)
        [void][Windows.Forms.MessageBox]::Show((T 'abortBody' $_.Exception.Message), (T 'titleError'), 'OK', 'Error')
    } finally {
        $form.UseWaitCursor = $false; [void](Update-RunState)
    }
}

# ---------- イベント ----------
$btnBrowse.Add_Click({
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = (T 'browseDesc')
    if (Test-Path -LiteralPath $cmbDir.Text) { $dlg.SelectedPath = $cmbDir.Text }
    if ($dlg.ShowDialog() -eq 'OK') {
        $before = $cmbDir.SelectedIndex
        $cmbDir.Text = $dlg.SelectedPath
        # 候補一覧にあるフォルダなら SelectedIndexChanged 側で読み込まれる
        if ($cmbDir.SelectedIndex -lt 0 -or $cmbDir.SelectedIndex -eq $before) { Refresh-List }
    }
})
$cmbDir.Add_SelectedIndexChanged({ Refresh-List })

$btnReload.Add_Click({ Refresh-List })
$btnRun.Add_Click({ Invoke-Run })
$btnOpenBak.Add_Click({
    $latest = Get-ChildItem $BackupRoot -Directory -Filter 'NMS_backup_*' | Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { Start-Process explorer.exe $latest.FullName } else { Start-Process explorer.exe $BackupRoot }
})
$form.Add_Activated({ if ($list.Items.Count -gt 0) { [void](Update-RunState) } })

# ---------- 起動時 ----------
$settings = Load-Settings
$dirs = @(Get-SaveDirs)
foreach ($d in $dirs) { [void]$cmbDir.Items.Add($d) }
$startDir = ''
if ($settings -and $settings.saveDir -and (Test-Path -LiteralPath $settings.saveDir)) { $startDir = [string]$settings.saveDir }
elseif ($dirs.Count -gt 0) { $startDir = $dirs[0] }

# 目標バージョンの初期値: 前回値 → 無ければ読み込めたセーブの最大の現在バージョン（何も変更されない状態）
$initTarget = $null
if ($settings -and $settings.target) { try { $initTarget = [int]$settings.target } catch { $initTarget = $null } }
if (-not $initTarget -and $startDir) {
    try {
        $bases = @(Get-SaveResults $startDir $null $false $null | Where-Object { $_.Action -eq 'scan' } | ForEach-Object { $_.Base })
        if ($bases.Count -gt 0) { $initTarget = [int]($bases | Measure-Object -Maximum).Maximum }
    } catch { $initTarget = $null }
}
if (-not $initTarget) { $initTarget = [int]$numTarget.Value }
$numTarget.Value = [math]::Min(9999, [math]::Max(1000, $initTarget))
if ($startDir) { $cmbDir.Text = $startDir }

$numTarget.Add_ValueChanged({ Refresh-List })
$form.Add_Shown({ Refresh-List })
[void]$form.ShowDialog()
