# download-stats.ps1 - GitHub release download counts for every VaultSoft repo.
#
# How to run it (needs the GitHub CLI, logged in as VaultSoft: `gh auth status`):
#   powershell -ExecutionPolicy Bypass -File scripts\download-stats.ps1    # Windows PowerShell 5.1
#   pwsh -File scripts\download-stats.ps1                                  # PowerShell 7
#
# Prints every release asset with its download count (sorted by repo), a total
# per repo and a grand total. Each run appends one row per repo to
# stats\download-stats.csv (git-ignored), and the totals table shows the change
# since the previous run in that file plus the change over the last 7 days.
#
# It also rewrites downloads.json at the repo root (committed, public) with the
# total per PUBLIC repo; scripts\build-site.ps1 uses it to order the homepage
# cards within each category. Private repos never go into that file. At the end
# it asks whether to run build-site.ps1 now and shows the resulting git diff;
# it never commits or pushes.
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

# Trend log: read the earlier runs before this one is appended.
$statsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'stats'
if (-not (Test-Path $statsDir)) { New-Item -ItemType Directory -Path $statsDir | Out-Null }
$csv = Join-Path $statsDir 'download-stats.csv'
$inv = [Globalization.CultureInfo]::InvariantCulture
$now = Get-Date
$today = $now.ToString('yyyy-MM-dd', $inv)

# Split the log back into runs. Older rows carry only a date and one day can
# hold several runs, so a run also ends when a repo turns up a second time.
$runs = New-Object System.Collections.Generic.List[object]
if (Test-Path $csv) {
    $run = $null
    foreach ($r in @(Import-Csv -Path $csv)) {
        if (-not $run -or $run.Stamp -ne $r.Date -or $run.Totals.ContainsKey($r.Repo)) {
            $run = [pscustomobject]@{
                Stamp   = $r.Date
                When    = [datetime]::ParseExact($r.Date, [string[]]@('yyyy-MM-dd HH:mm', 'yyyy-MM-dd'), $inv, 'None')
                HasTime = $r.Date.Length -gt 10
                Totals  = @{}
            }
            $runs.Add($run)
        }
        $run.Totals[$r.Repo] = [long]$r.TotalDownloads
    }
}
$prev = if ($runs.Count) { $runs[$runs.Count - 1] } else { $null }   # 5.1 lists don't take [-1]

function Get-RunLabel($Run) {
    if ($Run.HasTime) { $Run.When.ToString('d MMM yyyy, HH:mm', $inv) } else { $Run.When.ToString('d MMM yyyy', $inv) }
}

# Returns the change text and its colour. Colour goes through Write-Host
# -ForegroundColor rather than ANSI codes so 5.1's console shows it too.
function Get-Change([long]$Current, $Before) {
    if ($null -eq $Before) { return 'new', 'Cyan' }
    $d = $Current - [long]$Before
    if ($d -gt 0) { return "+$d", 'Green' }
    if ($d -eq 0) { return '+0', 'DarkGray' }
    return "$d", 'Yellow'
}

$grand = [long]($totals | Measure-Object Downloads -Sum).Sum
$repoWidth = [Math]::Max(11, [int]($totals | ForEach-Object { $_.Repo.Length } | Measure-Object -Maximum).Maximum)
$numWidth = [Math]::Max(5, "$grand".Length)
$fmt = "{0,-$repoWidth}  {1,$numWidth}"

Write-Host ''
if ($prev) {
    Write-Host (($fmt -f 'Repo', 'Total') + '   Change')
    Write-Host (($fmt -f '----', '-----') + '   ------')
} else {
    Write-Host ($fmt -f 'Repo', 'Total')
    Write-Host ($fmt -f '----', '-----')
}
foreach ($t in $totals) {
    $line = $fmt -f $t.Repo, $t.Downloads
    if ($prev) {
        $text, $colour = Get-Change $t.Downloads $prev.Totals[$t.Repo]
        Write-Host ($line + '   ') -NoNewline
        Write-Host $text -ForegroundColor $colour
    } else {
        Write-Host $line
    }
}
$line = $fmt -f 'Grand total', $grand
if ($prev) {
    $text, $colour = Get-Change $grand ($prev.Totals.Values | Measure-Object -Sum).Sum
    Write-Host ($line + '   ') -NoNewline
    Write-Host $text.PadRight(6) -ForegroundColor $colour -NoNewline
    Write-Host "(since $(Get-RunLabel $prev))"

    # The run nearest to a week ago, if one falls within two days of it.
    $weekAgo = $now.AddDays(-7)
    $week = $runs |
        Where-Object { [Math]::Abs(($_.When - $weekAgo).TotalDays) -le 2 } |
        Sort-Object { [Math]::Abs(($_.When - $weekAgo).TotalDays) } |
        Select-Object -First 1
    if ($week) {
        $text, $colour = Get-Change $grand ($week.Totals.Values | Measure-Object -Sum).Sum
        Write-Host 'Last 7 days: ' -NoNewline
        Write-Host $text.PadRight(6) -ForegroundColor $colour -NoNewline
        Write-Host "(since $(Get-RunLabel $week))"
    } else {
        Write-Host "Last 7 days: no run from around $($weekAgo.ToString('d MMM', $inv)) yet" -ForegroundColor DarkGray
    }
} else {
    Write-Host $line
}
Write-Host ''

# One row per repo per run, stamped with date and time (older rows are date-only).
$stamp = $now.ToString('yyyy-MM-dd HH:mm', $inv)
$totals |
    ForEach-Object { [pscustomobject]@{ Date = $stamp; Repo = $_.Repo; TotalDownloads = $_.Downloads } } |
    Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8
Write-Host "Appended $(@($totals).Count) rows to $csv"

# downloads.json for the homepage build: public repos only, keyed "Owner/Repo".
# Written by hand in Windows PowerShell 5.1's ConvertTo-Json layout, because 7
# indents differently and every run from the other version showed a whole-file
# diff. Names need no escaping: GitHub owner/repo names are only [A-Za-z0-9._-].
$entries = @($totals |
    Where-Object { $publicRepos -contains $_.Repo } |
    ForEach-Object { (' ' * 22) + ('"{0}/{1}":  {2}' -f $Owner, $_.Repo, $_.Downloads) })
$lines = @('{', ('    "generated":  "{0}",' -f $today), '    "downloads":  {') +
    ($entries -join ",`r`n") + @(((' ' * 18) + '}'), '}')
$jsonPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'downloads.json'
[IO.File]::WriteAllText($jsonPath, ($lines -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))
Write-Host "Wrote $jsonPath"

# Offer to rebuild the homepage with the new order. This only touches files:
# committing and pushing is left to you. Where nobody can answer (e.g. run with
# -NonInteractive) Read-Host throws, which counts as No.
try { $answer = Read-Host 'Rebuild the site with these numbers? (y/N)' } catch { $answer = '' }
if ($answer -match '^\s*y(es)?\s*$') {
    & (Join-Path $PSScriptRoot 'build-site.ps1')
    $root = Split-Path $PSScriptRoot -Parent
    Write-Host ''
    $files = 'downloads.json', 'index.html', 'sitemap.xml'
    # safecrlf=false silences git's "LF will be replaced by CRLF" warnings.
    git -C $root -c core.safecrlf=false diff --quiet -- $files
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'No changes to the site files.'
    } else {
        git -C $root -c core.safecrlf=false --no-pager diff --stat -- $files
        git -C $root -c core.safecrlf=false --no-pager diff -- $files
        Write-Host 'Nothing committed or pushed.'
    }
} else {
    Write-Host 'Site not rebuilt - run scripts\build-site.ps1 to re-order the homepage.'
}
