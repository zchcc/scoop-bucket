#Requires -Version 5.1
<#
.SYNOPSIS
    检查本仓库 bucket 中已被 Scoop 官方 bucket（Main/Extras）收录的清单。

.DESCRIPTION
    按“上游是同一个产物”判定重复，而不是只看清单名：
    从 `url`、`architecture.*.url`、`autoupdate` 和 `checkver` 里提取 github.com/<owner>/<repo>，
    与官方清单的仓库集合比对。

    - 仓库相同且清单名相同：判定为重复，删除本地清单。
    - 仓库相同但清单名不同：可能是改名后的重复项，只在报告里列出，不删除。

    脚本同时生成一份 Markdown 正文（-BodyFile），供工作流创建 PR 使用。

.PARAMETER BucketPath
    仓库根目录，默认是脚本所在目录的上一级。

.PARAMETER OfficialPath
    官方 bucket 的克隆目录，其下应有 Main 和 Extras 两个子目录。

.PARAMETER BodyFile
    PR 正文输出路径。

.PARAMETER SummaryFile
    GitHub Actions 的步骤摘要文件，默认取 $env:GITHUB_STEP_SUMMARY，留空则不写。

.PARAMETER DryRun
    只报告，不删除清单。

.EXAMPLE
    ./bin/check-duplicates.ps1 -OfficialPath ../official -DryRun

.EXAMPLE
    ./bin/check-duplicates.ps1 -OfficialPath ../official -BodyFile ./pr-body.md
#>
[CmdletBinding()]
param(
    [string] $BucketPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory = $true)]
    [string] $OfficialPath,
    [string] $BodyFile = (Join-Path ([IO.Path]::GetTempPath()) 'scoop-bucket-duplicates.md'),
    [string] $SummaryFile = $env:GITHUB_STEP_SUMMARY,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

# Windows 控制台默认代码页会把中文日志写成乱码，显式切到 UTF-8；没有控制台时忽略
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }

function Get-ManifestUrls {
    param($Manifest)

    $candidates = @($Manifest.url)
    if ($Manifest.architecture) {
        foreach ($arch in $Manifest.architecture.PSObject.Properties) {
            $candidates += @($arch.Value.url)
        }
    }
    if ($Manifest.autoupdate) {
        $candidates += @($Manifest.autoupdate.url)
        if ($Manifest.autoupdate.architecture) {
            foreach ($arch in $Manifest.autoupdate.architecture.PSObject.Properties) {
                $candidates += @($arch.Value.url)
            }
        }
    }
    # checkver 是字符串 "github" 或默认写法时没有可提取的信息，跳过
    if ($Manifest.checkver -and $Manifest.checkver -isnot [string]) {
        $candidates += @($Manifest.checkver.github)
    }

    foreach ($url in $candidates) {
        if ($url -is [string] -and $url) { $url }
    }
}

function Get-RepoKeys {
    param([string[]] $Urls)

    $keys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($url in $Urls) {
        foreach ($match in [regex]::Matches($url, 'github\.com[/:]([^/?#]+)/([^/?#]+)')) {
            $repo = $match.Groups[2].Value -replace '\.git$', ''
            # 排除 github.com/<owner>/releases 这类非仓库路径
            if ($repo -in @('releases', 'raw', 'blob', 'tree', 'archive')) { continue }
            [void] $keys.Add(('{0}/{1}' -f $match.Groups[1].Value, $repo))
        }
    }
    @($keys)
}

function Get-ManifestInfo {
    param([string] $Path, [string] $Bucket)

    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    [pscustomobject] @{
        Name    = [IO.Path]::GetFileNameWithoutExtension($Path)
        Version = [string] $manifest.version
        Path    = $Path
        Bucket  = $Bucket
        Repos   = Get-RepoKeys (Get-ManifestUrls $manifest)
    }
}

function Write-Markdown {
    param([string] $Path, [string[]] $Lines)

    [IO.File]::WriteAllText($Path, ($Lines -join "`n"), [Text.UTF8Encoding]::new($false))
}

if (-not (Test-Path -LiteralPath $OfficialPath -PathType Container)) {
    throw "找不到官方 bucket 目录：$OfficialPath"
}

# 官方清单按上游仓库建索引
$officialIndex = @{}
foreach ($bucketDir in Get-ChildItem -LiteralPath $OfficialPath -Directory) {
    $manifestDir = Join-Path $bucketDir.FullName 'bucket'
    if (-not (Test-Path -LiteralPath $manifestDir -PathType Container)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $manifestDir -Filter '*.json' -File) {
        $info = Get-ManifestInfo -Path $file.FullName -Bucket $bucketDir.Name
        foreach ($repo in $info.Repos) {
            if (-not $officialIndex.ContainsKey($repo)) { $officialIndex[$repo] = @() }
            $officialIndex[$repo] += $info
        }
    }
}

$localBucket = Join-Path $BucketPath 'bucket'
$duplicates = @()
$possible = @()
foreach ($file in Get-ChildItem -LiteralPath $localBucket -Filter '*.json' -File) {
    $local = Get-ManifestInfo -Path $file.FullName -Bucket $null
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($repo in $local.Repos) {
        if (-not $officialIndex.ContainsKey($repo)) { continue }
        foreach ($match in $officialIndex[$repo]) {
            if (-not $seen.Add(('{0}/{1}' -f $match.Bucket, $match.Name))) { continue }
            if ($match.Name -eq $local.Name) {
                $duplicates += [pscustomobject] @{ Local = $local; Official = $match }
            } else {
                $possible += [pscustomobject] @{ Local = $local; Official = $match; Repo = $repo }
            }
        }
    }
}
$duplicates = @($duplicates | Sort-Object { $_.Local.Name })
$possible = @($possible | Sort-Object { $_.Local.Name })

foreach ($dup in $duplicates) {
    $level = if ($DryRun) { '待删除' } else { '已删除' }
    Write-Output "[$level] $($dup.Local.Name) $($dup.Local.Version) -> $($dup.Official.Bucket)/$($dup.Official.Name) $($dup.Official.Version)"
}
foreach ($item in $possible) {
    Write-Output "[待确认] $($item.Local.Name) 与 $($item.Official.Bucket)/$($item.Official.Name) 共用上游 $($item.Repo)，名称不同未处理"
}
if ($duplicates.Count -eq 0) {
    Write-Output '未发现重复清单'
}

if (-not $DryRun) {
    foreach ($dup in $duplicates) {
        Remove-Item -LiteralPath $dup.Local.Path -Force
    }
}

$body = [System.Collections.Generic.List[string]]::new()
$body.Add('## 移除已收录到 Scoop 官方 bucket 的清单')
$body.Add('')
if ($duplicates.Count -gt 0) {
    $body.Add('下列清单与 Scoop 官方 bucket 中的同名清单指向同一个上游产物，属于重复收录，本 PR 将其删除。')
    $body.Add('')
    $body.Add('| 清单 | 本仓库版本 | 官方清单 | 官方版本 |')
    $body.Add('| --- | --- | --- | --- |')
    foreach ($dup in $duplicates) {
        $body.Add("| ``$($dup.Local.Name)`` | $($dup.Local.Version) | ``$($dup.Official.Bucket.ToLower())/$($dup.Official.Name)`` | $($dup.Official.Version) |")
    }
    $body.Add('')
    $body.Add('合并后请改用官方源安装：')
    $body.Add('')
    $body.Add('```pwsh')
    foreach ($dup in $duplicates) {
        $body.Add("scoop uninstall zchcc/$($dup.Local.Name)")
        $body.Add("scoop install $($dup.Official.Bucket.ToLower())/$($dup.Official.Name)")
    }
    $body.Add('```')
} else {
    $body.Add('本次未发现重复清单。')
}
if ($possible.Count -gt 0) {
    $body.Add('')
    $body.Add('### 待确认')
    $body.Add('')
    $body.Add('以下清单与官方清单指向同一个上游仓库，但清单名不同，可能是改名后的重复项，未自动删除：')
    $body.Add('')
    $body.Add('| 本仓库清单 | 官方清单 | 上游仓库 |')
    $body.Add('| --- | --- | --- |')
    foreach ($item in $possible) {
        $body.Add("| ``$($item.Local.Name)`` | ``$($item.Official.Bucket.ToLower())/$($item.Official.Name)`` | ``$($item.Repo)`` |")
    }
}
$body.Add('')
$body.Add('> 本 PR 由 `.github/workflows/duplicates.yml` 定期生成，需要人工确认后才会合并。')

Write-Markdown -Path $BodyFile -Lines $body
if ($SummaryFile) {
    Write-Markdown -Path $SummaryFile -Lines $body
}
