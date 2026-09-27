# download-stats.ps1 - GitHub release download counts for every VaultSoft repo.
#
# How to run it (needs the GitHub CLI, logged in as VaultSoft: `gh auth status`):
#   powershell -ExecutionPolicy Bypass -File scripts\download-stats.ps1    # Windows PowerShell 5.1
#   pwsh -File scripts\download-stats.ps1                                  # PowerShell 7
#
# Prints every release asset with its download count (sorted by repo), a total
# per repo and a grand total. Each run appends one row per repo to
# stats\download-stats.csv (git-ignored) so you can see the trend week to week.
#
# It also rewrites downloads.json at the repo root (committed, public) with the
# total per PUBLIC repo; scripts\build-site.ps1 uses it to order the homepage
# cards within each category. Private repos never go into that file.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 misreads UTF-8 without a BOM.

param(
    [string]$Owner = 'VaultSoft'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) not found on PATH.'
}

# Public and private repos (private ones show up because we're logged in as the owner).
$repoList = gh repo list $Owner --limit 1000 --json name,visibility
if ($LASTEXITCODE -ne 0) { throw "gh repo list failed for $Owner." }
# Assign before wrapping: 5.1's ConvertFrom-Json emits the whole array as ONE object.
$parsed = ($repoList -join "`n") | ConvertFrom-Json
$repoList = @($parsed)
$repos = @($repoList | ForEach-Object { $_.name } | Sort-Object)
$publicRepos = @($repoList | Where-Object { $_.visibility -eq 'PUBLIC' } | ForEach-Object { $_.name })

# The jq filter has no double quotes in it on purpose: Windows PowerShell 5.1
# strips/mangles embedded double quotes when passing arguments to native exes.
# One compact JSON object per asset comes out per line.
$jq = '.[] | .tag_name as $t | .assets[] | {tag: $t, name: .name, downloads: .download_count}'

$rows = New-Object System.Collections.Generic.List[object]
$order = 0
foreach ($repo in $repos) {
    $lines = gh api --paginate "repos/$Owner/$repo/releases?per_page=100" --jq $jq
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not read releases for $repo - skipped."; continue }
    foreach ($line in @($lines | Where-Object { $_ })) {
        $a = $line | ConvertFrom-Json
        $rows.Add([pscustomobject]@{
            Repo      = $repo
            Release   = $a.tag
            File      = $a.name
            Downloads = [int]$a.downloads
            Order     = $order++    # keeps GitHub's newest-first order within a repo (5.1 has no Sort -Stable)
        })
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No release assets found under $Owner."
    return
}

$rows |
    Sort-Object Repo, Order |
    Format-Table Repo, Release, File, @{ Label = 'Downloads'; Expression = { $_.Downloads }; Align = 'Right' } -AutoSize |
    Out-Host

$totals = $rows |
    Group-Object Repo |
    ForEach-Object {
        [pscustomobject]@{
            Repo      = $_.Name
            Downloads = [long]($_.Group | Measure-Object Downloads -Sum).Sum   # PS 7 returns a double
        }
    } |
    Sort-Object Repo

$totals | Format-Table Repo, @{ Label = 'Total downloads'; Expression = { $_.Downloads }; Align = 'Right' } -AutoSize | Out-Host
$grand = [long]($totals | Measure-Object Downloads -Sum).Sum
Write-Host ("Grand total: {0} downloads across {1} repos" -f $grand, @($totals).Count)

# Trend log: one row per repo per run.
$statsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'stats'
if (-not (Test-Path $statsDir)) { New-Item -ItemType Directory -Path $statsDir | Out-Null }
$csv = Join-Path $statsDir 'download-stats.csv'
$today = Get-Date -Format 'yyyy-MM-dd'
$totals |
    ForEach-Object { [pscustomobject]@{ Date = $today; Repo = $_.Repo; TotalDownloads = $_.Downloads } } |
    Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8
Write-Host "Appended $(@($totals).Count) rows to $csv"

# downloads.json for the homepage build: public repos only, keyed "Owner/Repo".
$json = [ordered]@{ generated = $today; downloads = [ordered]@{} }
foreach ($t in $totals) {
    if ($publicRepos -contains $t.Repo) { $json.downloads["$Owner/$($t.Repo)"] = $t.Downloads }
}
$jsonPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'downloads.json'
[IO.File]::WriteAllText($jsonPath, ($json | ConvertTo-Json) + "`n", (New-Object Text.UTF8Encoding $false))
Write-Host "Wrote $jsonPath - run scripts\build-site.ps1 to re-order the homepage."
