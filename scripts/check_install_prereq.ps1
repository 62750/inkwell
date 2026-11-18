# 安装前置体检：跑一遍就知道卡在哪
#
# 用法：
#   pwsh ./scripts/check_install_prereq.ps1
#   pwsh ./scripts/check_install_prereq.ps1 -Ipa .\dist\Inkwell-xxx-unsigned.ipa

param([string]$Ipa = "")

$ErrorActionPreference = "Continue"
$results = @()

function Add-Result($name, $ok, $detail, $fix) {
    $script:results += [pscustomobject]@{
        Name   = $name
        Ok     = $ok
        Detail = $detail
        Fix    = $fix
    }
}

# 1) IPA
if ($Ipa -and (Test-Path $Ipa)) {
    $sizeMB = [math]::Round((Get-Item $Ipa).Length / 1MB, 1)
    Add-Result "IPA 文件" $true "$([System.IO.Path]::GetFileName($Ipa))  ($sizeMB MB)" ""
} else {
    $found = Get-ChildItem (Join-Path (Split-Path -Parent $PSScriptRoot) "dist") -Filter *.ipa -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($found) {
        Add-Result "IPA 文件" $true "$($found.Name) — 可用 -Ipa 指定其它文件" ""
    } else {
        Add-Result "IPA 文件" $false "dist\ 下没有 .ipa" "先跑 scripts\build_ipa.ps1 出包"
    }
}

# 2) Apple Mobile Device 服务
$svc = Get-Service -Name "Apple Mobile Device Service" -ErrorAction SilentlyContinue
Add-Result "Apple Mobile Device 服务" ($svc -and $svc.Status -eq "Running") `
    ($(if ($svc) { $svc.Status } else { "未安装" })) `
    "装官网版 iTunes：https://www.apple.com/itunes/download/win64"

# 3) MobileDevice 库
$md = Test-Path "C:\Program Files\Common Files\Apple\Mobile Device Support\MobileDevice.dll"
$itmd = Test-Path "C:\Program Files\Common Files\Apple\Mobile Device Support\iTunesMobileDevice.dll"
Add-Result "MobileDevice.dll" $md $(if ($md) { "存在" } else { "缺失" }) "重装 iTunes 官网版"
Add-Result "iTunesMobileDevice.dll" $itmd `
    $(if ($itmd) { "存在" } else { "缺失（Store 版 iTunes 或残留安装常见）" }) `
    "卸载 Store 版 iTunes，装官网版 iTunes 并打开一次"

# 4) iTunes 本体
$itunes = @(
    "C:\Program Files\iTunes\iTunes.exe",
    "C:\Program Files (x86)\iTunes\iTunes.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
$storeItunes = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "iTunes" }
if ($itunes) {
    Add-Result "iTunes" $true "官网版：$itunes" ""
} elseif ($storeItunes) {
    Add-Result "iTunes" $false "只有 Microsoft Store 版（Sideloadly 常认不到设备）" "改装官网版 iTunes"
} else {
    Add-Result "iTunes" $false "未安装" "https://www.apple.com/itunes/download/win64"
}

# 5) iPhone 连接
$dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
       Where-Object { $_.FriendlyName -match "Apple iPhone|Apple iPad" -and $_.Status -eq "OK" }
if ($dev) {
    Add-Result "iPhone 连接" $true ($dev | ForEach-Object { $_.FriendlyName } | Select-Object -First 1) ""
} else {
    $any = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
           Where-Object { $_.FriendlyName -match "Apple" }
    if ($any) {
        Add-Result "iPhone 连接" $false ("检测到 Apple 设备但状态异常：" + (($any | ForEach-Object { "$($_.FriendlyName)=$($_.Status)" }) -join ", ")) `
            "拔插数据线，手机上点「信任」，换 USB 口"
    } else {
        Add-Result "iPhone 连接" $false "没插手机（或线不通数据）" "用原装/数据线连接电脑，手机点「信任」"
    }
}

# 6) Sideloadly
$sl = Get-ChildItem "$env:USERPROFILE\Downloads","$env:USERPROFILE\Desktop","C:\Program Files","C:\Program Files (x86)" `
      -Filter "sideloadly*" -Recurse -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1
Add-Result "Sideloadly" ([bool]$sl) $(if ($sl) { $sl.FullName } else { "未找到" }) "https://sideloadly.io"

# 7) 系统架构
Add-Result "系统" $true "$env:PROCESSOR_ARCHITECTURE / $([System.Environment]::OSVersion.VersionString)" ""

# 输出
Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " 墨阅安装前置体检" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$fail = 0
foreach ($r in $results) {
    $mark = if ($r.Ok) { "✓" } else { "✗"; }
    $color = if ($r.Ok) { "Green" } else { "Red" }
    if (-not $r.Ok) { $fail++ }
    Write-Host ("  {0} {1}" -f $mark, $r.Name) -ForegroundColor $color
    Write-Host ("      " + $r.Detail) -ForegroundColor DarkGray
    if (-not $r.Ok -and $r.Fix) {
        Write-Host ("      → " + $r.Fix) -ForegroundColor Yellow
    }
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host " 全部就绪，可以开始签装了。" -ForegroundColor Green
    Write-Host " 打开 Sideloadly → 拖入 IPA → Apple account 填邮箱 → App 专用密码 → Start"
} else {
    Write-Host (" 有 $fail 项待处理，按上面黄色提示逐条修。") -ForegroundColor Yellow
    Write-Host " 完整步骤见 INSTALL.md"
}
Write-Host ""
