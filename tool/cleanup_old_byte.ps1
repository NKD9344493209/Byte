# BYTE - delete the empty leftovers of the old (assistant) BYTE.
#
# Safe by design. It only deletes:
#   1. .dart / .kt files that contain the marker  [byte-removed]
#      (empty files written on 18 Nov 2026 in place of removed features)
#   2. the old wake-word model files (already emptied)
#   3. the old home-screen widget resources and the old alarm sound
#   4. the unused sherpa-onnx library, if it is still there
# It shows the list first and asks before deleting anything.
#
# Run from the project folder:
#   powershell -ExecutionPolicy Bypass -File tool\cleanup_old_byte.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$targets = New-Object System.Collections.Generic.List[string]

# 1. marker files
$codeDirs = @('lib', 'test', 'android\app\src\main\kotlin')
foreach ($d in $codeDirs) {
    if (-not (Test-Path $d)) { continue }
    Get-ChildItem -Path $d -Recurse -File | Where-Object { $_.Extension -eq '.dart' -or $_.Extension -eq '.kt' } | ForEach-Object {
        if (Select-String -LiteralPath $_.FullName -SimpleMatch '[byte-removed]' -Quiet) { $targets.Add($_.FullName) }
    }
}

# 2. old wake-word models
foreach ($d in @('android\app\src\main\assets\oww', 'android\app\src\main\assets\kws')) {
    if (Test-Path $d) { Get-ChildItem -Path $d -File | ForEach-Object { $targets.Add($_.FullName) } }
}

# 3. old widget resources + alarm sound (nothing refers to them any more)
$res = 'android\app\src\main\res'
foreach ($f in @("$res\layout\sticky_widget.xml", "$res\xml\sticky_widget_info.xml", "$res\drawable\sticky_widget_bg.xml", "$res\values\sticky_widget.xml", "$res\raw\byte_alarm.wav")) {
    if (Test-Path $f) { $targets.Add((Resolve-Path $f).Path) }
}

# 4. unused native library
if (Test-Path 'android\app\libs') {
    Get-ChildItem -Path 'android\app\libs' -File | Where-Object { $_.Name -like '*sherpa*' } | ForEach-Object { $targets.Add($_.FullName) }
}

if ($targets.Count -eq 0) {
    Write-Host 'Nothing to clean. The project is already tidy.'
    exit 0
}

Write-Host ''
Write-Host "These $($targets.Count) leftover files will be deleted:"
foreach ($t in $targets) { Write-Host ('  ' + $t.Substring($root.Length + 1)) }
Write-Host ''
$answer = Read-Host 'Type YES to delete them'
if ($answer -ne 'YES') {
    Write-Host 'Nothing was deleted.'
    exit 0
}

foreach ($t in $targets) { Remove-Item -LiteralPath $t -Force }

# folders that are now empty
foreach ($d in @('lib\features', 'android\app\src\main\assets', "$res\layout", 'android\app\libs')) {
    if (-not (Test-Path $d)) { continue }
    Get-ChildItem -Path $d -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
        if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) { Remove-Item -LiteralPath $_.FullName -Force }
    }
    if (-not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d -Force }
}

Write-Host ''
Write-Host "Deleted $($targets.Count) files. Now run:  flutter analyze"
