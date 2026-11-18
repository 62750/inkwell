# 墨阅 Inkwell —— Windows 上触发云端构建并把 IPA 抓回本地
#
# 前置：
#   1. 安装 git 与 GitHub CLI：winget install --id GitHub.cli
#   2. gh auth login（一次即可）
#
# 用法：
#   pwsh ./scripts/build_ipa.ps1 -RepoOwner 你的用户名 -RepoName inkwell
#   pwsh ./scripts/build_ipa.ps1 -RepoOwner 你的用户名 -RepoName inkwell -Private
#
# 流程：建仓库 → 推送 → 触发 Actions → 等构建 → 下载 IPA 到 dist/

param(
    [Parameter(Mandatory = $true)][string]$RepoOwner,
    [string]$RepoName = "inkwell",
    [switch]$Private,
    [switch]$SkipPush,
    [int]$TimeoutMinutes = 40
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Need($name, $hint) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Host "缺少 $name。$hint" -ForegroundColor Red
        exit 1
    }
}

Need git "安装 Git for Windows：winget install --id Git.Git"
Need gh  "安装 GitHub CLI：winget install --id GitHub.cli"

Write-Host "==> 检查 gh 登录状态" -ForegroundColor Cyan
gh auth status 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "未登录，请先运行：gh auth login" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path ".git")) {
    Write-Host "==> 初始化仓库" -ForegroundColor Cyan
    git init | Out-Null
    git add -A
    git -c user.name="$RepoOwner" -c user.email="$RepoOwner@users.noreply.github.com" commit -m "init: Inkwell reader" | Out-Null
} else {
    Write-Host "==> 提交当前改动" -ForegroundColor Cyan
    git add -A
    git -c user.name="$RepoOwner" -c user.email="$RepoOwner@users.noreply.github.com" commit -m "update: sync before build" 2>$null | Out-Null
}

if (-not $SkipPush) {
    Write-Host "==> 创建/推送仓库 $RepoOwner/$RepoName" -ForegroundColor Cyan
    $exists = gh repo view "$RepoOwner/$RepoName" 2>$null
    if (-not $exists) {
        $vis = if ($Private) { "--private" } else { "--public" }
        gh repo create "$RepoOwner/$RepoName" $vis --source . --remote origin --push
    } else {
        git remote remove origin 2>$null | Out-Null
        git remote add origin "https://github.com/$RepoOwner/$RepoName.git"
        git branch -M main
        git push -u origin main
    }
}

Write-Host "==> 触发 GitHub Actions 构建" -ForegroundColor Cyan
gh workflow run build-ipa.yml --repo "$RepoOwner/$RepoName" 2>$null
if ($LASTEXITCODE -ne 0) {
    # 首次没有 workflow 时需要先有一次 push 让 Actions 注册
    Start-Sleep -Seconds 8
    gh workflow run build-ipa.yml --repo "$RepoOwner/$RepoName"
}
Start-Sleep -Seconds 10

Write-Host "==> 等待构建（最长 $TimeoutMinutes 分钟）" -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$runId = $null
while ((Get-Date) -lt $deadline) {
    $runs = gh run list --repo "$RepoOwner/$RepoName" --workflow build-ipa.yml --limit 1 --json databaseId,status,conclusion | ConvertFrom-Json
    if ($runs -and $runs.Count -gt 0) {
        $runId = $runs[0].databaseId
        $status = $runs[0].status
        Write-Host ("    状态：" + $status)
        if ($status -eq "completed") { break }
    }
    Start-Sleep -Seconds 20
}

if (-not $runId) {
    Write-Host "没有找到构建记录。" -ForegroundColor Red
    exit 1
}

gh run view $runId --repo "$RepoOwner/$RepoName"
$conclusion = (gh run view $runId --repo "$RepoOwner/$RepoName" --json conclusion | ConvertFrom-Json).conclusion
if ($conclusion -ne "success") {
    Write-Host "构建失败，日志：" -ForegroundColor Red
    gh run view $runId --repo "$RepoOwner/$RepoName" --log-failed
    exit 1
}

Write-Host "==> 下载 IPA" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path "dist" | Out-Null
gh run download $runId --repo "$RepoOwner/$RepoName" --name Inkwell-ipa --dir "dist/_raw"

$ipa = Get-ChildItem "dist/_raw" -Filter *.ipa -Recurse | Select-Object -First 1
if (-not $ipa) {
    Write-Host "产物里没有 .ipa" -ForegroundColor Red
    exit 1
}
$target = Join-Path "dist" ("Inkwell-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-unsigned.ipa")
Move-Item $ipa.FullName $target -Force
Remove-Item "dist/_raw" -Recurse -Force

Write-Host ""
Write-Host "==> 完成" -ForegroundColor Green
Get-Item $target | Format-List Name, Length, FullName
Write-Host "下一步：用 Sideloadly（Windows 可用）侧载这个未签名 IPA。"
