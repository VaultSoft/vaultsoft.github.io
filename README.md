# vaultsoft.github.io

The VaultSoft homepage, served at <https://vaultsoft.co.uk/> (GitHub Pages + `CNAME`).

The homepage app list is generated from **`apps.json`**. The cards, the Featured row, the
filter bar, the JSON-LD and `sitemap.xml` are all built from it. Don't hand-edit anything
between the `<!-- build:... -->` markers in `index.html`; the next build overwrites it.

## Adding an app

1. Add one entry to `apps` in `apps.json`:

   ```json
   {
     "id": "myapp",
     "name": "MyApp",
     "description": "One or two sentences for the card.",
     "category": "System & PC",
     "badge": "Free",
     "link": "https://vaultsoft.co.uk/myapp/",
     "download": "https://github.com/VaultSoft/MyApp/releases/latest",
     "repo": "VaultSoft/MyApp",
     "released": "2026-10-01",
     "icon": "icons/myapp.svg"
   }
   ```

2. Rebuild, check the page, commit and push:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\build-site.ps1
   ```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Lowercase, unique. |
| `name`, `description` | yes | Plain text; HTML-escaped by the build. |
| `category` | yes | One of `categories` at the top of the file. A new name gets its own section at the end; add it to `categories` to place it. |
| `badge` | yes | `Free` or `Free trial` (a trial badge gets its own style and a "Download trial" button). |
| `link` | yes | The app's page, or its GitHub repo if it has no page ("View on GitHub"). |
| `released` | yes | `YYYY-MM-DD`, first public release. The card shows **New** for 30 days. |
| `download` | no | Adds a secondary Download button. |
| `repo` | no | `Owner/Repo`. Used for the live version pill and download-count ordering. |
| `icon` | no | Path to a 24x24 stroke SVG (see `icons/`). Missing = a plain square. |
| `featured` | no | `1`, `2`, ... puts the app in the Featured row in that order. |
| `hub` | no | VaultSoft Hub only; the site ignores it. `{"exe": "MyApp.exe"}` = the Hub installs it from `repo`'s newest release (betas included) and launches that exe. `{"mode": "link"}` = the Hub shows the card with an "Open page" button to `link`, no install. `false` = not listed in the Hub. Missing = installed like `{}`, guessing the exe. |

## How the list behaves

- **Order within a category** is by total release downloads, from `downloads.json`.
  Refresh it with `scripts\download-stats.ps1` (needs `gh`, logged in as VaultSoft),
  then run `build-site.ps1` again. Only public repos go into `downloads.json`.
- **"New"** is set at build time and re-checked in the browser against today's date,
  so it drops off after 30 days without a rebuild.
- **Filter buttons** are always built but stay hidden until the list has 8+ apps
  (`$minAppsForFilters` in `build-site.ps1`).
- Everything works without JavaScript: all cards show, and only the filters and
  version pills need JS. No libraries or external scripts.
- `apps.json` is public at <https://vaultsoft.co.uk/apps.json>. VaultSoft Hub v1.1.0+ reads its
  app list from it (and its banner from the top-level `hub_promo`: `enabled`, `text`, `url`).

## apps.json can only gain fields

Hubs already on people's PCs read this file and can't be updated from here. **Add new fields
freely, but never remove or rename an existing field, or change what its values mean.** To stop
using a field, leave it in place. The Hub's own `manifest.json` stays frozen for v1.0.x Hubs.

## Not listed here

sound-vault and PBEWatch are deliberately left out of the site. `download-stats.ps1`
still reports their downloads.
