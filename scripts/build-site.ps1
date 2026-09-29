# build-site.ps1 - regenerate the homepage app list from apps.json.
#
#   powershell -ExecutionPolicy Bypass -File scripts\build-site.ps1    # Windows PowerShell 5.1
#   pwsh -File scripts\build-site.ps1                                  # PowerShell 7
#
# Rewrites four generated regions and leaves everything else alone:
#   index.html   between <!-- build:spotlight --> and <!-- /build:spotlight --> (full-width band per spotlight app)
#   index.html   between <!-- build:apps --> and <!-- /build:apps -->   (filter bar, category grids)
#   index.html   between <!-- build:jsonld --> and <!-- /build:jsonld --> (Organization JSON-LD)
#   sitemap.xml  (whole file: homepage + every app link that is not on github.com)
#
# Apps with "spotlight": true get the band under the hero instead of a card:
# they are left out of the category grids and the filter bar.
# Two or more consecutive categories with one app each share a <div class="group-row">
# so their cards sit side by side; a category with 2+ apps always gets its own block.
# Card order within a category comes from downloads.json (written by
# scripts\download-stats.ps1); apps missing from it count as 0 downloads.
# Running it twice in a row produces no changes.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 misreads UTF-8 without a BOM.
# (apps.json itself can hold any UTF-8 - it is read explicitly as UTF-8.)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$utf8 = New-Object Text.UTF8Encoding $false
$site = 'https://vaultsoft.co.uk/'
$newDays = 30          # "New" pill: released within this many days
$minAppsForFilters = 8 # filter bar only appears (via JS) at this many apps

function Read-Utf8([string]$path) { [IO.File]::ReadAllText($path, $utf8) }
function Enc([string]$s) { [Net.WebUtility]::HtmlEncode($s) }
function Slug([string]$s) { ($s.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }
function JsonStr([string]$s) {
    # ConvertTo-Json escapes quotes/backslashes/control chars; 5.1 also escapes <>&' which is fine in JSON-LD.
    ConvertTo-Json $s
}

# ---- load data -------------------------------------------------------------

$data = Read-Utf8 (Join-Path $root 'apps.json') | ConvertFrom-Json
$apps = @($data.apps)
foreach ($a in $apps) {
    foreach ($f in 'id', 'name', 'description', 'category', 'badge', 'link', 'released') {
        if (-not $a.$f) { throw "apps.json: app '$($a.id)$($a.name)' is missing '$f'." }
    }
    [void][datetime]::ParseExact($a.released, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

$downloads = @{}
$dlPath = Join-Path $root 'downloads.json'
if (Test-Path $dlPath) {
    $dl = Read-Utf8 $dlPath | ConvertFrom-Json
    foreach ($p in $dl.downloads.PSObject.Properties) { $downloads[$p.Name] = [long]$p.Value }
} else {
    Write-Warning 'downloads.json not found - ordering by name only. Run scripts\download-stats.ps1.'
}
function Get-Downloads($app) { if ($app.repo -and $downloads.ContainsKey($app.repo)) { $downloads[$app.repo] } else { 0 } }

# Category order: the "categories" list first, then any new ones in the order they appear.
$categories = New-Object System.Collections.Generic.List[string]
foreach ($c in @($data.categories)) { if ($c -and -not $categories.Contains($c)) { $categories.Add($c) } }
foreach ($a in $apps) { if (-not $categories.Contains($a.category)) { $categories.Add($a.category) } }

$todayUtc = [datetime]::UtcNow.Date
$fallbackIcon = '<svg viewBox="0 0 24 24" fill="none" stroke="#2AFFD5" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="4" width="16" height="16" rx="3"/></svg>'

$arrowSvg = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12h14M12 5l7 7-7 7"/></svg>'
$downSvg  = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12M7 10l5 5 5-5M5 21h14"/></svg>'

# ---- card markup -----------------------------------------------------------

function Get-Icon($app, [string]$ind) {
    $icon = $fallbackIcon
    if ($app.icon) {
        $iconPath = Join-Path $root $app.icon
        if (Test-Path $iconPath) { $icon = (Read-Utf8 $iconPath).Trim() }
        else { Write-Warning "$($app.name): icon '$($app.icon)' not found - using the fallback." }
    }
    ($icon -split "\r?\n" | ForEach-Object { "$ind$_" }) -join "`n"
}

function Get-NewAttr($app) {
    $released = [datetime]::ParseExact($app.released, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $age = ($todayUtc - $released).TotalDays
    if ($age -ge 0 -and $age -le $newDays) { '' } else { ' hidden' }
}

function Get-Card($app) {
    $ind = '        '
    $icon = Get-Icon $app "$ind    "
    $newAttr = Get-NewAttr $app

    $badgeClass = if ($app.badge -match 'trial') { 'tag tag-trial' } else { 'tag' }
    $isGitHub = $app.link -match '^https://github\.com/'
    $viewLabel = if ($isGitHub) { 'View on GitHub' } else { 'View App' }
    $dlLabel = if ($app.badge -match 'trial') { 'Download trial' } else { 'Download' }

    $lines = @(
        "$ind<div class=`"app-card`" data-app=`"$(Enc $app.id)`" data-released=`"$(Enc $app.released)`">"
        "$ind  <div class=`"app-card-icon`">"
        $icon
        "$ind  </div>"
        "$ind  <div class=`"app-label`">$(Enc $app.category)</div>"
        "$ind  <h3>$(Enc $app.name)</h3>"
        "$ind  <p>$(Enc $app.description)</p>"
        "$ind  <div class=`"app-tags`">"
        "$ind    <span class=`"tag tag-new`"$newAttr>New</span>"
        "$ind    <span class=`"$badgeClass`">$(Enc $app.badge)</span>"
    )
    if ($app.repo) { $lines += "$ind    <span class=`"tag tag-version`" data-repo=`"$(Enc $app.repo)`"></span>" }
    $lines += "$ind  </div>"
    $lines += "$ind  <div class=`"app-actions`">"
    $lines += "$ind    <a class=`"btn-view`" href=`"$(Enc $app.link)`">$viewLabel $arrowSvg</a>"
    if ($app.download) { $lines += "$ind    <a class=`"btn-ghost-sm`" href=`"$(Enc $app.download)`">$dlLabel $downSvg</a>" }
    $lines += "$ind  </div>"
    $lines += "$ind</div>"
    $lines -join "`n"
}

function Get-Group([string]$title, [string]$categorySlug, $groupApps) {
    $cards = ($groupApps | ForEach-Object { Get-Card $_ }) -join "`n`n"
    @(
        "    <div class=`"app-group`" data-category=`"$categorySlug`">"
        "      <h2 class=`"group-title`">$(Enc $title)</h2>"
        "      <div class=`"apps-grid`">"
        $cards
        "      </div>"
        "    </div>"
    ) -join "`n"
}

# Full-width band for a spotlight app: Download is the primary action.
function Get-Spotlight($app) {
    $ind = '    '
    $viewLabel = if ($app.link -match '^https://github\.com/') { 'View on GitHub' } else { 'View App' }
    $dlHref = if ($app.download) { $app.download } else { $app.link }
    $lines = @(
        "<section class=`"spotlight`" id=`"$(Enc $app.id)`" aria-label=`"$(Enc $app.name)`">"
        '  <div class="spotlight-inner">'
        "$ind<div class=`"app-card spotlight-card`" data-app=`"$(Enc $app.id)`" data-released=`"$(Enc $app.released)`">"
        "$ind  <div class=`"app-card-icon`">"
        (Get-Icon $app "$ind    ")
        "$ind  </div>"
        "$ind  <div class=`"spotlight-body`">"
        "$ind    <div class=`"app-label`">$(Enc $app.category)</div>"
        "$ind    <h2>$(Enc $app.name)</h2>"
        "$ind    <p>$(Enc $app.description)</p>"
        "$ind    <div class=`"app-tags`">"
        "$ind      <span class=`"tag tag-new`"$(Get-NewAttr $app)>New</span>"
        "$ind      <span class=`"tag`">$(Enc $app.badge)</span>"
    )
    if ($app.repo) { $lines += "$ind      <span class=`"tag tag-version`" data-repo=`"$(Enc $app.repo)`"></span>" }
    $lines += "$ind    </div>"
    $lines += "$ind    <div class=`"app-actions`">"
    $lines += "$ind      <a class=`"btn-view`" href=`"$(Enc $dlHref)`">Download $downSvg</a>"
    $lines += "$ind      <a class=`"btn-ghost-sm`" href=`"$(Enc $app.link)`">$viewLabel $arrowSvg</a>"
    $lines += "$ind    </div>"
    $lines += "$ind  </div>"
    $lines += "$ind</div>"
    $lines += '  </div>'
    $lines += '</section>'
    $lines -join "`n"
}

# ---- build the regions -----------------------------------------------------

$spotlightApps = @($apps | Where-Object { $_.spotlight } | Sort-Object name)
$gridApps = @($apps | Where-Object { -not $_.spotlight })
$spotlightHtml = ($spotlightApps | ForEach-Object { Get-Spotlight $_ }) -join "`n`n"

$parts = New-Object System.Collections.Generic.List[string]

$filterLines = @("    <div class=`"filters`" id=`"app-filters`" data-min-apps=`"$minAppsForFilters`" role=`"group`" aria-label=`"Filter apps by category`" hidden>")
$filterLines += '      <button type="button" class="filter" data-filter="all" aria-pressed="true">All</button>'
foreach ($c in $categories) {
    if (@($gridApps | Where-Object { $_.category -eq $c }).Count -eq 0) { continue }
    $filterLines += "      <button type=`"button`" class=`"filter`" data-filter=`"$(Slug $c)`" aria-pressed=`"false`">$(Enc $c)</button>"
}
$filterLines += '    </div>'
$parts.Add($filterLines -join "`n")

$groups = @(foreach ($c in $categories) {
    $inCat = @($gridApps | Where-Object { $_.category -eq $c } |
        Sort-Object @{ Expression = { Get-Downloads $_ }; Descending = $true }, @{ Expression = { $_.name }; Descending = $false })
    if ($inCat.Count) { [pscustomobject]@{ Count = $inCat.Count; Html = (Get-Group $c (Slug $c) $inCat) } }
})

# Flush a run of single-app groups: one alone stays as it is, 2+ go into a group-row.
$run = New-Object System.Collections.Generic.List[string]
function Add-Run {
    if ($run.Count -eq 1) { $parts.Add($run[0]) }
    elseif ($run.Count -gt 1) {
        $inner = ($run | ForEach-Object { ($_ -split "`n" | ForEach-Object { if ($_) { "  $_" } else { $_ } }) -join "`n" }) -join "`n"
        $parts.Add((@('    <div class="group-row">', $inner, '    </div>') -join "`n"))
    }
    $run.Clear()
}
foreach ($g in $groups) {
    if ($g.Count -eq 1) { $run.Add($g.Html) }
    else { Add-Run; $parts.Add($g.Html) }
}
Add-Run
$appsHtml = $parts -join "`n`n"

# JSON-LD: one Offer per app. ScribeVault-style work apps are BusinessApplication.
$offers = foreach ($a in $apps) {
    $appCat = if ($a.category -eq 'Privacy & Work') { 'BusinessApplication' } else { 'UtilitiesApplication' }
    @(
        '      {'
        '        "@type": "Offer",'
        '        "itemOffered": {'
        '          "@type": "SoftwareApplication",'
        "          `"name`": $(JsonStr $a.name),"
        "          `"description`": $(JsonStr $a.description),"
        "          `"url`": $(JsonStr $a.link),"
        "          `"applicationCategory`": `"$appCat`","
        '          "operatingSystem": "Windows 10, Windows 11"'
        '        }'
        '      }'
    ) -join "`n"
}
$jsonLd = @(
    '  <script type="application/ld+json">'
    '  {'
    '    "@context": "https://schema.org",'
    '    "@type": "Organization",'
    '    "name": "VaultSoft",'
    "    `"url`": `"$site`","
    '    "description": "Portable, bloat-free Windows utilities from VaultSoft. No installers, no subscriptions, no nonsense.",'
    '    "makesOffer": ['
    ($offers -join ",`n")
    '    ]'
    '  }'
    '  </script>'
) -join "`n"

# ---- splice into index.html ------------------------------------------------

function Set-Region([string]$text, [string]$name, [string]$body) {
    $start = [regex]::Match($text, "<!-- build:$name\b[^>]*-->")
    $endTag = "<!-- /build:$name -->"
    if (-not $start.Success) { throw "index.html: marker <!-- build:$name --> not found." }
    $end = $text.IndexOf($endTag, $start.Index + $start.Length)
    if ($end -lt 0) { throw "index.html: marker $endTag not found." }
    $lineStart = $text.LastIndexOf("`n", $end) + 1
    $indent = $text.Substring($lineStart, $end - $lineStart)
    $text.Substring(0, $start.Index + $start.Length) + "`n" + $body + "`n" + $indent + $text.Substring($end)
}

$indexPath = Join-Path $root 'index.html'
$raw = Read-Utf8 $indexPath
$crlf = $raw.Contains("`r`n")
$html = $raw.Replace("`r`n", "`n")
$html = Set-Region $html 'jsonld' $jsonLd
$html = Set-Region $html 'spotlight' $spotlightHtml
$html = Set-Region $html 'apps' $appsHtml
if ($crlf) { $html = $html.Replace("`n", "`r`n") }
if ($html -ne $raw) { [IO.File]::WriteAllText($indexPath, $html, $utf8); Write-Host 'index.html updated.' }
else { Write-Host 'index.html already up to date.' }

# ---- sitemap.xml -----------------------------------------------------------

$newest = ($apps | ForEach-Object { $_.released } | Sort-Object -Descending | Select-Object -First 1)
$sm = @('<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">', '')
$sm += '  <url>', "    <loc>$site</loc>", "    <lastmod>$newest</lastmod>", '    <changefreq>monthly</changefreq>', '  </url>', ''
foreach ($a in $apps) {
    if ($a.link -match '^https://github\.com/') { continue }   # repos are not our pages
    $sm += '  <url>', "    <loc>$(Enc $a.link)</loc>", '    <changefreq>monthly</changefreq>', '  </url>', ''
}
$sm += '</urlset>'
$smPath = Join-Path $root 'sitemap.xml'
$smText = ($sm -join "`r`n") + "`r`n"
$old = if (Test-Path $smPath) { Read-Utf8 $smPath } else { '' }
if ($smText -ne $old) { [IO.File]::WriteAllText($smPath, $smText, $utf8); Write-Host 'sitemap.xml updated.' }
else { Write-Host 'sitemap.xml already up to date.' }

Write-Host ("{0} apps in {1} categories, {2} in the spotlight." -f $apps.Count, $categories.Count, $spotlightApps.Count)
