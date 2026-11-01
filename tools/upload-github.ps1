#requires -Version 5.1
<#
.SYNOPSIS
    一键提交并推送 Ruinsss格式快转 源码到 GitHub。

.DESCRIPTION
    - 在项目根目录初始化 Git（如果没有）；
    - 自动暂存、提交；
    - 使用你输入的 GitHub Token 验证身份；
    - 仓库不存在时自动创建公开/私有仓库；
    - 将 origin 指向仓库并推送 main 分支；
    - Token 只在本进程内存中使用，不写入 Git 配置或磁盘。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\upload-github.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\upload-github.ps1 -Owner Ruinsss233 -Repo RuinsssFormat

.NOTES
    推荐使用 classic PAT，勾选 repo 权限。
    细粒度 Token 需要 Contents: Read and write；自动建仓还需要 Administration: Read and write。
#>
[CmdletBinding()]
param(
    [string]$Owner = 'Ruinsss233',
    [string]$Repo = 'RuinsssFormat',
    [string]$Branch = 'main',
    [string]$Message = '',
    [string]$Token = '',
    [switch]$Private,
    [switch]$NoPush,
    [switch]$SkipCreate,
    [switch]$SkipCommit
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$remoteUrl = "https://github.com/$Owner/$Repo.git"
$apiBase = 'https://api.github.com'
$headers = $null
$me = $null
$pushedLocation = $false
$oldTerminalPrompt = $env:GIT_TERMINAL_PROMPT

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-Ok([string]$Text) {
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-Warn([string]$Text) {
    Write-Host "  [!]  $Text" -ForegroundColor Yellow
}

function Read-SecretToken {
    $secure = Read-Host '请输入 GitHub Token（输入不会显示，也不会保存）' -AsSecureString
    if ($null -eq $secure) { return '' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Get-HttpStatus($ErrorRecord) {
    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response -and $null -ne $response.StatusCode) {
            return [int]$response.StatusCode
        }
    }
    catch {
        # Fall through to 0.
    }
    return 0
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') 失败（退出码 $LASTEXITCODE）"
    }
}

function Ensure-GitHubRepo {
    param(
        [string]$RepoOwner,
        [string]$RepoName,
        [string]$Login
    )

    $repoApi = "$apiBase/repos/$RepoOwner/$RepoName"
    $exists = $false
    try {
        $null = Invoke-RestMethod -Uri $repoApi -Headers $headers -Method Get -TimeoutSec 30
        $exists = $true
        Write-Ok "GitHub 仓库已存在：$RepoOwner/$RepoName"
    }
    catch {
        $status = Get-HttpStatus $_
        if ($status -ne 404) {
            throw "检查 GitHub 仓库失败（HTTP $status）：$($_.Exception.Message)"
        }
    }

    if ($exists) { return }

    if ($RepoOwner -ne $Login) {
        throw "仓库 $RepoOwner/$RepoName 不存在，且当前 Token 属于 $Login，不能在别人的账号下自动建仓。请先在 GitHub 手动创建空仓库，再重新运行。"
    }

    Write-Step "创建 GitHub 仓库 $RepoOwner/$RepoName"
    $body = @{
        name        = $RepoName
        private     = [bool]$Private
        description = 'RuinsssFormat source code'
        auto_init   = $false
        has_issues  = $true
        has_wiki    = $false
    } | ConvertTo-Json

    try {
        $created = Invoke-RestMethod -Uri "$apiBase/user/repos" -Headers $headers -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 30
        Write-Ok "仓库已创建：$($created.html_url)"
    }
    catch {
        $status = Get-HttpStatus $_
        if ($status -eq 422) {
            throw "GitHub 拒绝创建仓库（HTTP 422）。可能是仓库名已存在或 Token 权限不足。请检查 $RepoOwner/$RepoName。"
        }
        throw "创建仓库失败（HTTP $status）：$($_.Exception.Message)"
    }
}

try {
    Write-Host ""
    Write-Host "Ruinsss格式快转 · 一键上传源码" -ForegroundColor Magenta
    Write-Host "项目目录：$root"
    Write-Host "目标仓库：https://github.com/$Owner/$Repo"

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw '没有找到 git。请先安装 Git for Windows：https://git-scm.com/download/win'
    }

    $needToken = (-not $NoPush) -or (-not $SkipCreate)
    if ($needToken) {
        if ([string]::IsNullOrWhiteSpace($Token)) {
            $Token = Read-SecretToken
        }
        $Token = $Token.Trim()
        if ([string]::IsNullOrWhiteSpace($Token)) {
            throw '没有输入 Token，已取消上传。'
        }

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{
            Authorization = "Bearer $Token"
            Accept        = 'application/vnd.github+json'
            'User-Agent'  = 'RuinsssFormat-Uploader'
        }

        Write-Step '验证 GitHub Token'
        try {
            $me = Invoke-RestMethod -Uri "$apiBase/user" -Headers $headers -Method Get -TimeoutSec 30
        }
        catch {
            $status = Get-HttpStatus $_
            if ($status -eq 401) {
                throw 'Token 验证失败（401）。请确认 Token 没有过期、复制完整，并且有 repo / Contents 权限。'
            }
            throw "Token 验证失败（HTTP $status）：$($_.Exception.Message)"
        }
        Write-Ok "已登录 GitHub：$($me.login)"
    }
    else {
        Write-Warn '当前为本地演练模式（-NoPush -SkipCreate），不需要 Token。'
    }

    Push-Location $root
    $pushedLocation = $true

    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        Write-Step '初始化 Git 仓库'
        Invoke-Git -GitArgs @('init')
        Write-Ok '已初始化'
    }
    else {
        Write-Ok '已存在 Git 仓库'
    }

    $name = (& git config user.name 2>$null)
    if ([string]::IsNullOrWhiteSpace($name)) {
        Invoke-Git -GitArgs @('config', 'user.name', 'Ruinsss233')
        Write-Ok '已设置提交用户名 Ruinsss233'
    }

    $email = (& git config user.email 2>$null)
    if ([string]::IsNullOrWhiteSpace($email)) {
        Invoke-Git -GitArgs @('config', 'user.email', 'Ruinsss233@users.noreply.github.com')
        Write-Ok '已设置提交邮箱 Ruinsss233@users.noreply.github.com'
    }

    $currentBranch = (& git branch --show-current 2>$null)
    if ([string]::IsNullOrWhiteSpace($currentBranch)) {
        Invoke-Git -GitArgs @('symbolic-ref', 'HEAD', "refs/heads/$Branch")
    }
    elseif ($currentBranch.Trim() -ne $Branch) {
        Write-Step "切换分支到 $Branch"
        Invoke-Git -GitArgs @('branch', '-M', $Branch)
    }

    if (-not $SkipCommit) {
        Write-Step '暂存源码'
        Invoke-Git -GitArgs @('add', '-A')

        & git diff --cached --quiet
        $hasStaged = ($LASTEXITCODE -ne 0)
        if ($hasStaged) {
            if ([string]::IsNullOrWhiteSpace($Message)) {
                $Message = '更新 Ruinsss格式快转 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
            }
            Write-Step "提交：$Message"
            Invoke-Git -GitArgs @('commit', '-m', $Message)
            Write-Ok '提交完成'
        }
        else {
            Write-Ok '没有需要提交的新改动'
        }
    }
    else {
        Write-Warn '已指定 -SkipCommit，未提交本地改动。'
    }

    if ($needToken -and -not $SkipCreate) {
        Ensure-GitHubRepo -RepoOwner $Owner -RepoName $Repo -Login $me.login
    }
    elseif ($SkipCreate) {
        Write-Warn '已指定 -SkipCreate，不检查/创建远程仓库。'
    }

    $remoteUrl = "https://github.com/$Owner/$Repo.git"
    $remotes = @(& git remote)
    if ($remotes -contains 'origin') {
        Invoke-Git -GitArgs @('remote', 'set-url', 'origin', $remoteUrl)
    }
    else {
        Invoke-Git -GitArgs @('remote', 'add', 'origin', $remoteUrl)
    }
    Write-Ok "origin -> $remoteUrl"

    if ($NoPush) {
        Write-Warn '已指定 -NoPush，没有推送。确认无误后可重新运行并输入 Token。'
    }
    else {
        Write-Step "推送 $Branch 到 GitHub"
        $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$Token"))
        $env:GIT_TERMINAL_PROMPT = '0'
        try {
            & git -c 'credential.helper=' -c "http.extraheader=AUTHORIZATION: basic $basic" push -u origin $Branch
            if ($LASTEXITCODE -ne 0) {
                throw @"
推送失败。常见原因：
  1. Token 没有 repo / Contents: Read and write 权限，或已过期；
  2. 远程仓库已有提交，和本地历史不一致；先在本地执行 git pull --rebase origin $Branch 再试；
  3. 网络无法访问 github.com。

仓库地址：https://github.com/$Owner/$Repo
"@
            }
        }
        finally {
            $env:GIT_TERMINAL_PROMPT = $oldTerminalPrompt
        }

        Write-Host ""
        Write-Host "上传完成：https://github.com/$Owner/$Repo" -ForegroundColor Green
        Write-Host "分支：$Branch"
        Write-Host "Token 没有写入磁盘；关闭窗口后即失效。" -ForegroundColor DarkGray
    }
}
catch {
    Write-Host ""
    Write-Host "上传失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($pushedLocation) {
        Pop-Location
    }
    $env:GIT_TERMINAL_PROMPT = $oldTerminalPrompt
}
