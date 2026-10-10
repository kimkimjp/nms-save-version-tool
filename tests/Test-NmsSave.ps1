# Tests for NmsSave.cs using synthetic saves (no real save data needed).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-NmsSave.ps1
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Cs = Join-Path $Root 'NmsSave.cs'

$script:Pass = 0
$script:Fail = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:Pass++; Write-Host "PASS  $name" }
    else { $script:Fail++; Write-Host "FAIL  $name  $detail" -ForegroundColor Red }
}

function Test-SameBytes([byte[]]$a, [byte[]]$b) {
    return ([Convert]::ToBase64String($a) -ceq [Convert]::ToBase64String($b))
}

function Set-U32([byte[]]$buf, [int]$off, [long]$v) {
    [BitConverter]::GetBytes([uint32]$v).CopyTo($buf, $off)
}

# LZ4 block that contains only literals (the decoder stops when input ends after the literal run)
function New-Lz4Block([byte[]]$data) {
    $ms = New-Object IO.MemoryStream
    $len = $data.Length
    if ($len -ge 15) {
        $ms.WriteByte(0xF0)
        $rem = $len - 15
        while ($rem -ge 255) { $ms.WriteByte(255); $rem -= 255 }
        $ms.WriteByte([byte]$rem)
    } else {
        $ms.WriteByte([byte]($len -shl 4))
    }
    $ms.Write($data, 0, $len)
    return ,$ms.ToArray()
}

# save.hg bytes: 16-byte header (magic, compressed size, decompressed size, 0) + block, split every $chunk bytes
function New-SaveBytes([byte[]]$raw, [int]$chunk) {
    $ms = New-Object IO.MemoryStream
    for ($off = 0; $off -lt $raw.Length; $off += $chunk) {
        $n = [Math]::Min($chunk, $raw.Length - $off)
        $part = New-Object byte[] $n
        [Array]::Copy($raw, $off, $part, 0, $n)
        $blk = New-Lz4Block $part
        $h = New-Object byte[] 16
        Set-U32 $h 0 0xFEEDA1E5L
        Set-U32 $h 4 $blk.Length
        Set-U32 $h 8 $n
        $ms.Write($h, 0, 16)
        $ms.Write($blk, 0, $blk.Length)
    }
    return ,$ms.ToArray()
}

function New-MetaPlain([int]$expandedLen, [int]$fileLen, [int]$base, [int]$mode) {
    $m = New-Object byte[] 432
    Set-U32 $m 0 0xEEEEEEBEL
    Set-U32 $m 56 $expandedLen
    Set-U32 $m 60 $fileLen
    Set-U32 $m 68 $base
    Set-U32 $m 72 $mode
    Set-U32 $m 84 $expandedLen
    return ,$m
}

# Creates <name>.hg and mf_<name>.hg (meta encrypted with slot 2)
function New-Fixture([string]$dir, [string]$name, [int]$base, [int]$mode, [int]$f2p, [int]$chunk) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $json = '{"F2P":' + $f2p + ',"x":"' + ('abcdefghij' * 1500) + '"}'
    $raw = [Text.Encoding]::ASCII.GetBytes($json)
    $save = New-SaveBytes $raw $chunk
    $meta = New-MetaPlain $raw.Length $save.Length $base $mode
    [IO.File]::WriteAllBytes((Join-Path $dir ($name + '.hg')), $save)
    [IO.File]::WriteAllBytes((Join-Path $dir ('mf_' + $name + '.hg')), [NmsSaveTool.NmsSave]::EncryptMeta($meta, 2))
}

try {
    if (-not ('NmsSaveTool.NmsSave' -as [type])) { Add-Type -Path $Cs -ErrorAction Stop }
} catch {
    Write-Host "Compile failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
[NmsSaveTool.NmsSave]::Lang = 'en'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('NmsSaveTest_' + [guid]::NewGuid().ToString('N'))
try {
    # --- ListSaves ordering ---
    $d0 = Join-Path $tmp 'list'
    New-Item -ItemType Directory -Path $d0 -Force | Out-Null
    foreach ($f in @('save.hg', 'mf_save.hg', 'save10.hg', 'save2.hg', 'save3.hg', 'notes.txt', 'save_old.hg', 'save.hg.tmp')) {
        [IO.File]::WriteAllBytes((Join-Path $d0 $f), [byte[]]@(0))
    }
    $names = @([NmsSaveTool.NmsSave]::ListSaves($d0))
    Check 'ListSaves: numeric order, only save*.hg' (($names -join ',') -ceq 'save,save2,save3,save10') ($names -join ',')

    # --- scan (multi-chunk) ---
    $d1 = Join-Path $tmp 'a'
    New-Fixture $d1 'save' 4226 1 4738 0x1000
    $sf = Join-Path $d1 'save.hg'; $mf = Join-Path $d1 'mf_save.hg'
    $origS = [IO.File]::ReadAllBytes($sf); $origM = [IO.File]::ReadAllBytes($mf)
    $r = [NmsSaveTool.NmsSave]::Process($d1, 'save', $null, $false)
    Check 'scan: action' ($r.Action -eq 'scan') "$($r.Action) $($r.Error)"
    Check 'scan: Base' ($r.Base -eq 4226) "$($r.Base)"
    Check 'scan: Mode' ($r.Mode -eq 1) "$($r.Mode)"
    Check 'scan: F2P' ($r.F2P -eq 4738) "$($r.F2P)"
    Check 'scan: Slot' ($r.Slot -eq 2) "$($r.Slot)"
    Check 'scan: MTime set' ($null -ne $r.MTime)

    # --- scan (single chunk of 0x80000) ---
    $d1b = Join-Path $tmp 'a2'
    New-Fixture $d1b 'save' 4226 1 4738 0x80000
    $r = [NmsSaveTool.NmsSave]::Process($d1b, 'save', $null, $false)
    Check 'scan (0x80000 chunk): Base/F2P' (($r.Action -eq 'scan') -and ($r.Base -eq 4226) -and ($r.F2P -eq 4738)) "$($r.Action) $($r.Error)"

    # --- dry run changes nothing ---
    $r = [NmsSaveTool.NmsSave]::Process($d1, 'save', 4225, $false)
    Check 'dry run: would-change' ($r.Action -eq 'would-change') "$($r.Action) $($r.Error)"
    Check 'dry run: files untouched' ((Test-SameBytes $origS ([IO.File]::ReadAllBytes($sf))) -and (Test-SameBytes $origM ([IO.File]::ReadAllBytes($mf))))

    # --- 4226 -> 4225 write and re-read ---
    $r = [NmsSaveTool.NmsSave]::Process($d1, 'save', 4225, $true)
    Check 'write 4226->4225: changed' ($r.Action -eq 'changed') "$($r.Action) $($r.Error)"
    $r2 = [NmsSaveTool.NmsSave]::Process($d1, 'save', $null, $false)
    Check 'write: re-read Base/F2P' (($r2.Base -eq 4225) -and ($r2.F2P -eq 4737) -and ($r2.Mode -eq 1)) "$($r2.Base) $($r2.F2P) $($r2.Mode) $($r2.Error)"
    Check 'write: sizes unchanged' (([IO.File]::ReadAllBytes($sf).Length -eq $origS.Length) -and ([IO.File]::ReadAllBytes($mf).Length -eq 432))
    Check 'write: files actually changed' (-not (Test-SameBytes $origS ([IO.File]::ReadAllBytes($sf))))
    Check 'write: no leftover .tmp' (-not (Test-Path ($sf + '.tmp')) -and -not (Test-Path ($mf + '.tmp')))

    # --- same target ---
    $r = [NmsSaveTool.NmsSave]::Process($d1, 'save', 4225, $true)
    Check 'same: action' ($r.Action -eq 'same') "$($r.Action) $($r.Error)"

    # --- round trip 4226 -> 4225 -> 4226 is byte-identical ---
    $r = [NmsSaveTool.NmsSave]::Process($d1, 'save', 4226, $true)
    Check 'round trip: changed back' ($r.Action -eq 'changed') "$($r.Action) $($r.Error)"
    Check 'round trip: save.hg byte-identical' (Test-SameBytes $origS ([IO.File]::ReadAllBytes($sf)))
    Check 'round trip: mf_save.hg byte-identical' (Test-SameBytes $origM ([IO.File]::ReadAllBytes($mf)))

    # --- digit count change (F2P 4738 -> 10012) is refused and nothing is written ---
    $r = [NmsSaveTool.NmsSave]::Process($d1, 'save', 9500, $true)
    Check 'digit change: error' (($r.Action -eq 'error') -and ($r.Error -match 'digits')) "$($r.Action) $($r.Error)"
    Check 'digit change: files untouched' ((Test-SameBytes $origS ([IO.File]::ReadAllBytes($sf))) -and (Test-SameBytes $origM ([IO.File]::ReadAllBytes($mf))))

    # --- F2P inconsistent with meta base/mode ---
    $d2 = Join-Path $tmp 'b'
    New-Fixture $d2 'save' 4000 1 4738 0x1000
    $r = [NmsSaveTool.NmsSave]::Process($d2, 'save', $null, $false)
    Check 'inconsistent F2P/base: error' ($r.Action -eq 'error') "$($r.Action) $($r.Error)"

    # --- meta length other than 432 ---
    $d3 = Join-Path $tmp 'c'
    New-Fixture $d3 'save' 4226 1 4738 0x1000
    $short = New-Object byte[] 104
    Set-U32 $short 0 0xEEEEEEBEL
    [IO.File]::WriteAllBytes((Join-Path $d3 'mf_save.hg'), [NmsSaveTool.NmsSave]::EncryptMeta($short, 2))
    $before = [IO.File]::ReadAllBytes((Join-Path $d3 'save.hg'))
    $r = [NmsSaveTool.NmsSave]::Process($d3, 'save', 4225, $true)
    Check 'meta length != 432: error (en)' (($r.Action -eq 'error') -and ($r.Error -match '104')) "$($r.Action) $($r.Error)"
    Check 'meta length != 432: save untouched' (Test-SameBytes $before ([IO.File]::ReadAllBytes((Join-Path $d3 'save.hg'))))
    [NmsSaveTool.NmsSave]::Lang = 'ja'
    $rJa = [NmsSaveTool.NmsSave]::Process($d3, 'save', 4225, $true)
    [NmsSaveTool.NmsSave]::Lang = 'en'
    Check 'Lang switch changes message' (($rJa.Action -eq 'error') -and ($rJa.Error -ne $r.Error) -and ($rJa.Error -match '104')) "$($rJa.Error)"

    # --- missing folder ---
    $nope = Join-Path $tmp 'does_not_exist'
    $r = [NmsSaveTool.NmsSave]::Process($nope, 'save', $null, $false)
    Check 'missing folder: Process returns error' (($r.Action -eq 'error') -and $r.Error) "$($r.Action)"
    $threw = $false
    try { [void][NmsSaveTool.NmsSave]::ListSaves($nope) } catch { $threw = $true }
    Check 'missing folder: ListSaves throws' $threw
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ("Passed: {0}  Failed: {1}" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
