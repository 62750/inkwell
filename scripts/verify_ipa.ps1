# 校验 IPA 结构是否完整（拿到产物后先跑一遍，再丢给侧载工具）
#
# 用法：
#   pwsh ./scripts/verify_ipa.ps1 -Ipa .\dist\Inkwell-20261118-141500-unsigned.ipa

param([Parameter(Mandatory = $true)][string]$Ipa)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $Ipa)) { Write-Host "找不到文件：$Ipa" -ForegroundColor Red; exit 1 }

$tmp = Join-Path $env:TEMP ("inkwell_verify_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zipCopy = Join-Path $tmp "pkg.zip"
Copy-Item $Ipa $zipCopy -Force

Expand-Archive -Path $zipCopy -DestinationPath $tmp -Force
$payload = Join-Path $tmp "Payload"
if (-not (Test-Path $payload)) {
    Write-Host "✗ 缺少 Payload 目录 —— 这不是合法的 IPA" -ForegroundColor Red
    exit 1
}

$app = Get-ChildItem $payload -Directory -Filter *.app | Select-Object -First 1
if (-not $app) {
    Write-Host "✗ Payload 里没有 .app" -ForegroundColor Red
    exit 1
}

$checks = @()
$plist = Join-Path $app.FullName "Info.plist"
$checks += [pscustomobject]@{ Item = "Info.plist"; Ok = (Test-Path $plist) }

$exeName = $app.BaseName
$exe = Join-Path $app.FullName $exeName
if (-not (Test-Path $exe)) {
    $candidate = Get-ChildItem $app.FullName -File | Where-Object { $_.Name -notlike "*.*" } | Select-Object -First 1
    if ($candidate) { $exe = $candidate.FullName }
}
$checks += [pscustomobject]@{ Item = "可执行文件 ($exeName)"; Ok = (Test-Path $exe) }

if (Test-Path $exe) {
    $bytes = [System.IO.File]::ReadAllBytes($exe)[0..3]
    $magic = ($bytes | ForEach-Object { $_.ToString("X2") }) -join " "
    # arm64 Mach-O: CF FA ED FE ；FAT: CA FE BA BE
    $isMachO = ($magic -eq "CF FA ED FE") -or ($magic -eq "CA FE BA BE")
    $checks += [pscustomobject]@{ Item = "Mach-O 头 ($magic)"; Ok = $isMachO }
}

$checks += [pscustomobject]@{ Item = "Assets.car"; Ok = (Test-Path (Join-Path $app.FullName "Assets.car")) }

$info = $null
if (Test-Path $plist) {
    try {
        $info = Get-Content $plist -Raw | ConvertFrom-StringData -ErrorAction SilentlyContinue
    } catch { }
}

Write-Host ""
Write-Host "IPA 结构校验：$([System.IO.Path]::GetFileName($Ipa))" -ForegroundColor Cyan
foreach ($c in $checks) {
    $mark = if ($c.Ok) { "✓" } else { "✗" }
    $color = if ($c.Ok) { "Green" } else { "Red" }
    Write-Host ("  $mark " + $c.Item) -ForegroundColor $color
}

# 用 plutil（macOS）或 python 提取 Bundle ID
$bundleId = $null
foreach ($line in (Get-Content $plist -ErrorAction SilentlyContinue)) {
    if ($line -match "CFBundleIdentifier") { }
}
if (Get-Command python -ErrorAction SilentlyContinue) {
    $py = @"
import plistlib,sys
with open(r'$plist','rb') as f:
    d = plistlib.load(f)
print(d.get('CFBundleIdentifier',''))
print(d.get('CFBundleShortVersionString',''))
"@
    $py | Out-File (Join-Path $tmp "read.py") -Encoding utf8
    $out = & python (Join-Path $tmp "read.py") 2>$null
    if ($out) {
        $bundleId = $out[0]
        Write-Host ""
        Write-Host "  Bundle ID : $bundleId"
        if ($out.Count -gt 1) { Write-Host "  版本      : $($out[1])" }
    }
}

$sizeMB = [math]::Round((Get-Item $Ipa).Length / 1MB, 1)
Write-Host "  体积      : $sizeMB MB"
Write-Host ""

$failed = $checks | Where-Object { -not $_.Ok }
if ($failed) {
    Write-Host "有 $($failed.Count) 项不通过，IPA 不可用。" -ForegroundColor Red
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "结构完整。下一步：" -ForegroundColor Green
Write-Host "  Windows → Sideloadly：拖入 IPA，填 Apple ID，Start"
Write-Host "  macOS   → ./scripts/build_ipa.sh --sign 或 SideStore"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
