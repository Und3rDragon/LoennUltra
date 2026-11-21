<#
  lonn-issues-from-commits.ps1
  作用：扫描最近的 git commit，把与 issue 的关联回写到 GitHub。
        - commit 含 fixes / closes / resolves #N  -> 给该 issue 补一条评论；若它还是 open，则关闭
        - commit 只含 #N（没有 fix 关键词）        -> 只补一条评论
        - 同一 commit 对同一 issue 只评论一次（按短 SHA 判重，幂等）
        - 末尾列出「没有引用任何 issue 的 commit」，提醒你补编号

  用法：
    $env:GH_TOKEN = 'ghp_xxx'
    powershell -ExecutionPolicy Bypass -File .\lonn-issues-from-commits.ps1 -LastN 15
    powershell -ExecutionPolicy Bypass -File .\lonn-issues-from-commits.ps1 -LastN 15 -DryRun
#>
[CmdletBinding()]
param(
    [string]$RepoPath = 'F:\celestemod\helperSourceCode\Loenn Ultra\Source Code',
    [string]$Owner    = 'djgrayon',
    [string]$Project  = 'LoennUltra',
    [int]$LastN       = 15,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$token = $env:GH_TOKEN
if (-not $token) { throw '请先设置 GH_TOKEN（scope=repo 的 GitHub PAT）' }

$headers = @{
    'Authorization'        = "token $token"
    'Accept'               = 'application/vnd.github+json'
    'User-Agent'           = 'lonn-issue-commit-sync'
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
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers `
            -Body ($Body | ConvertTo-Json -Depth 5 -Compress) -ContentType 'application/json'
    }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

# ---------- 取 commit ----------
$sep = '<<<C>>>'
$raw = & git -C $RepoPath log -n $LastN --pretty=format:"$sep%H%x01%s%x01%b"
if ($LASTEXITCODE -ne 0) { throw "git log 失败：$RepoPath" }

$commits = @(($raw -split [regex]::Escape($sep)) | Where-Object { $_.Trim() })
Write-Host ("扫描 commit 数: {0}" -f $commits.Count) -ForegroundColor Cyan

$fixPattern   = '(?i)\b(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?)\b([^\r\n]*)'
$issuePattern = '#(\d+)'

$handled   = 0
$unlinked  = New-Object System.Collections.ArrayList

foreach ($c in $commits) {
    $parts = $c -split [char]1, 3
    if ($parts.Count -lt 2) { continue }

    $sha     = $parts[0].Trim()
    $subject = $parts[1].Trim()
    $body    = if ($parts.Count -ge 3) { $parts[2] } else { '' }
    $full    = "$subject`n$body"
    $short   = $sha.Substring(0, [Math]::Min(7, $sha.Length))

    $nums = @{}
    foreach ($m in [regex]::Matches($full, $issuePattern)) { $nums[[int]$m.Groups[1].Value] = $true }

    if ($nums.Count -eq 0) {
        [void]$unlinked.Add(("{0} {1}" -f $short, $subject))
        continue
    }

    # fix 关键词后面跟着的编号 = 应关闭的
    $closing = @{}
    foreach ($m in [regex]::Matches($full, $fixPattern)) {
        foreach ($n in [regex]::Matches($m.Groups[1].Value, $issuePattern)) {
            $closing[[int]$n.Groups[1].Value] = $true
        }
    }

    foreach ($num in ($nums.Keys | Sort-Object)) {
        $issue = Invoke-GH GET "$base/issues/$num"
        if (-not $issue -and -not $DryRun) {
            Write-Host ("  #{0} 取不到（可能不存在），跳过" -f $num) -ForegroundColor Yellow
            continue
        }

        # 幂等：该 issue 的评论里是否已有这个短 SHA
        $already = $false
        if ($issue -and $issue.comments -gt 0) {
            $cs = Invoke-GH GET "$base/issues/$num/comments?per_page=100"
            $already = [bool]($cs | Where-Object { $_.body -match [regex]::Escape($short) })
        }
        if ($already) {
            Write-Host ("  #{0} 已有 {1} 的记录，跳过" -f $num, $short) -ForegroundColor DarkGray
            continue
        }

        $isClosing = $closing.ContainsKey($num)
        $note = "已在 commit ``$short`` 中处理：$subject"
        Write-Host ("  #{0,-4} {1,-10} {2}" -f $num, $(if ($isClosing) { '关闭+评论' } else { '仅评论' }), $note) -ForegroundColor Green

        Invoke-GH POST "$base/issues/$num/comments" @{ body = $note } | Out-Null
        if ($isClosing -and $issue -and $issue.state -eq 'open') {
            Invoke-GH PATCH "$base/issues/$num" @{ state = 'closed' } | Out-Null
        }
        $handled++
    }
}

if ($unlinked.Count -gt 0) {
    Write-Host "`n--- 这些 commit 没有引用任何 issue（可考虑补上 fixes #N） ---" -ForegroundColor Yellow
    foreach ($u in $unlinked) { Write-Host ("  " + $u) }
}

Write-Host "`n完成：处理 $handled 条 issue 关联。" -ForegroundColor Cyan
