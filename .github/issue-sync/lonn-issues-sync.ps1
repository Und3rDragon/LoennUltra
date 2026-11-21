<#
  lonn-issues-sync.ps1
  作用：把 lonn-issues.json 里的 labels / milestones / issues 同步到 GitHub 仓库。
        幂等：已存在的 label / milestone / issue（按名字或标题匹配）会自动跳过，可反复运行。

  用法：
    $env:GH_TOKEN = 'ghp_xxx'
    powershell -ExecutionPolicy Bypass -File .\lonn-issues-sync.ps1
    powershell -ExecutionPolicy Bypass -File .\lonn-issues-sync.ps1 -DryRun      # 只看要做什么（不需要 token）
    powershell -ExecutionPolicy Bypass -File .\lonn-issues-sync.ps1 -SkipIssues  # 只建 label/milestone

  PAT 生成：https://github.com/settings/tokens/new  ->  Scope 勾 repo

  踩过的两个坑：
  1) param 块里不能引用 $PSScriptRoot（那时它还没定义），所以 DataFile 默认留空、进脚本体再算。
  2) Windows PowerShell 5.1 的 Invoke-RestMethod 用 -Body <string> 时按 Latin-1 发送，
     且大请求会走 chunked；中文与长 body 会被 GitHub 判成 Problems parsing JSON。
     因此统一改成「UTF-8 字节数组 + charset=utf-8」，并带 ContentLength。
#>
[CmdletBinding()]
param(
    [string]$Owner    = 'djgrayon',
    [string]$Project  = 'LoennUltra',
    [string]$DataFile = '',
    [switch]$DryRun,
    [switch]$SkipIssues
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $DataFile) {
    $DataFile = Join-Path $PSScriptRoot 'lonn-issues.json'
}

$token = $env:GH_TOKEN
if (-not $token -and -not $DryRun) { throw '请先设置环境变量 GH_TOKEN（GitHub Personal Access Token，scope=repo）' }
if (-not (Test-Path -LiteralPath $DataFile)) { throw "找不到数据文件: $DataFile" }

$headers = @{
    'Authorization'        = "token $token"
    'Accept'               = 'application/vnd.github+json'
    'User-Agent'           = 'lonn-ultra-issue-sync'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$base = "https://api.github.com/repos/$Owner/$Project"

function Invoke-GH {
    param([string]$Method, [string]$Uri, $Body)

    if ($DryRun) {
        Write-Host ("  [dry] {0} {1}" -f $Method, $Uri) -ForegroundColor DarkGray
        return $null
    }

    if ($Body) {
        $json  = $Body | ConvertTo-Json -Depth 6 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        Write-Host ("        [{0} 字节 UTF-8]" -f $bytes.Length) -ForegroundColor DarkGray
        try {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers `
                -Body $bytes -ContentType 'application/json; charset=utf-8'
        } catch {
            Write-Host ("  失败: {0}" -f $_.ErrorDetails.Message) -ForegroundColor Red
            throw
        }
    }

    try {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    } catch {
        Write-Host ("  失败: {0}" -f $_.ErrorDetails.Message) -ForegroundColor Red
        throw
    }
}

Write-Host ("数据文件: {0}" -f $DataFile) -ForegroundColor DarkGray
$data = Get-Content -LiteralPath $DataFile -Raw -Encoding UTF8 | ConvertFrom-Json

# ---------- 1) Labels ----------
Write-Host '== 1/3 Labels ==' -ForegroundColor Cyan
$existingLabels = @{}
foreach ($l in (Invoke-GH GET "$base/labels?per_page=100")) { $existingLabels[$l.name] = $l }
$added = 0
foreach ($l in $data.labels) {
    if ($existingLabels.ContainsKey($l.name)) {
        Write-Host ("  skip  {0}" -f $l.name) -ForegroundColor DarkGray
    } else {
        Write-Host ("  +     {0}" -f $l.name) -ForegroundColor Green
        Invoke-GH POST "$base/labels" @{ name = $l.name; color = $l.color; description = $l.description } | Out-Null
        $added++
    }
}

# ---------- 2) Milestones ----------
Write-Host '== 2/3 Milestones ==' -ForegroundColor Cyan
$existingMs = @{}
foreach ($m in (Invoke-GH GET "$base/milestones?state=all&per_page=100")) { $existingMs[$m.title] = $m }
foreach ($m in $data.milestones) {
    if ($existingMs.ContainsKey($m.title)) {
        Write-Host ("  skip  {0}" -f $m.title) -ForegroundColor DarkGray
    } else {
        Write-Host ("  +     {0}" -f $m.title) -ForegroundColor Green
        Invoke-GH POST "$base/milestones" @{ title = $m.title; description = $m.description } | Out-Null
    }
}

if ($SkipIssues) { Write-Host "`n已跳过 issues。" -ForegroundColor Cyan; return }

# ---------- 3) Issues ----------
Write-Host '== 3/3 Issues ==' -ForegroundColor Cyan
$existingIssues = @{}
foreach ($i in (Invoke-GH GET "$base/issues?state=all&per_page=100")) { $existingIssues[$i.title] = $i }

# milestone 号只查一次
$msCache = @{}
foreach ($m in (Invoke-GH GET "$base/milestones?state=all&per_page=100")) { $msCache[$m.title] = $m.number }

$issuesAdded = 0
foreach ($it in $data.issues) {
    if ($existingIssues.ContainsKey($it.title)) {
        Write-Host ("  skip  {0}" -f $it.title) -ForegroundColor DarkGray
        continue
    }
    $payload = @{ title = $it.title; body = $it.body; labels = @($it.labels) }
    if ($it.milestone -and $msCache.ContainsKey($it.milestone)) { $payload['milestone'] = $msCache[$it.milestone] }
    Write-Host ("  +     {0}" -f $it.title) -ForegroundColor Green
    $created = Invoke-GH POST "$base/issues" $payload
    $issuesAdded++

    # JSON 里可以写 "state": "closed"，表示这条 issue 建完立即关闭（用于「已实现」的记录）
    if ($it.state -eq 'closed' -and $created -and $created.number) {
        Write-Host ("        -> 立即关闭 #{0}（已实现）" -f $created.number) -ForegroundColor DarkGray
        Invoke-GH PATCH "$base/issues/$($created.number)" @{ state = 'closed' } | Out-Null
    }
}

Write-Host "`n完成：新增 label $added 个、issue $issuesAdded 条。" -ForegroundColor Cyan
Write-Host "查看：https://github.com/$Owner/$Project/issues" -ForegroundColor Cyan
