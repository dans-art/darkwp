# darkwp
Version: 0.2.2

Upload images from [darktable](https://www.darktable.org/) straight to WordPress.

This is the darktable-side Lua module only. A companion WordPress plugin (custom REST routes for gallery-plugin support) is a separate, not-yet-built project - see [Status](#status) below.

## What it does

- Adds **WordPress Media Library** as a destination in darktable's Export panel (lighttable view), alongside Disk, Email, etc. - uploads straight to the WordPress media library. Registered lazily, the first time an account is active, so there's only ever one row for it regardless of mode (see [Status](#status)).
- If the companion WordPress plugin is installed on the target site *and* the admin has enabled it there, also adds one destination per active/enabled gallery plugin (e.g. NextGEN Gallery), with that plugin's own dynamic fields.
- Adds a **darkwp accounts** panel for logging in, switching between, and removing WordPress accounts.
- Uploads exported images straight to WordPress core's `wp/v2/media` REST endpoint, authenticated with a [WordPress Application Password](https://make.wordpress.org/core/2020/11/05/application-passwords-integration-guide/).
- Resolves title / alt text / caption / description per image using darktable's own `$(...)` export variables (e.g. `$(FILE_NAME)`, `$(Xmp.dc.title)`).
- Reports per-image upload progress and a final "X uploaded, Y failed" summary.

## Requirements

- darktable 5.6+ (Lua API 9.7.0+)
- `curl` on the PATH
- A WordPress site with [Application Passwords](https://make.wordpress.org/core/2020/11/05/application-passwords-integration-guide/) enabled and a user with the `upload_files` capability

## Installation

1. Copy (or clone) this `darkwp/` folder into your darktable Lua scripts directory:
   - Linux/macOS: `~/.config/darktable/lua/`
   - Windows: `%LOCALAPPDATA%\darktable\lua\`
2. Enable it from darktable's **scripts** module (lighttable view, under `darkwp` → `darkwp`), or add `require "darkwp/darkwp"` to your `luarc` file.
3. Restart darktable if you edited `luarc` directly.

## Usage

1. Open the **darkwp accounts** panel (lighttable, right side) and log in with your WordPress site URL, username, and Application Password.
2. Select images in lighttable, open the **Export** panel, and pick **WordPress Media Library** (or a gallery destination, in full mode) as the target storage.
3. Set the usual format/size/quality options, adjust the title/alt text/caption/description fields if needed, and click Export.
4. Enjoy the hassle free way of uploading pictures.

## Status

- **Uploading to the WordPress media library works today** - via WordPress core's stable `wp/v2/media` endpoint in fallback mode (no companion plugin), or via the companion plugin's `darkup/v1/media` (target `media-library`) in full mode, if the admin has it enabled. Either way it's a single storage entry (`lib/gallery_storage.lua`) - registered lazily, the first time an account's mode is known, so switching modes mid-session never produces a second row for it.
- **Gallery plugin support (NextGEN, FooGallery, etc.) is implemented on the darktable side**, against the companion plugin's custom REST routes (`darkup/v1/info`, `darkup/v1/media` - see `lib/wp_api.lua`). It only takes effect once that companion WordPress plugin - a separate, not-yet-built project - is installed on the target site; until then, every account works in fallback mode (media library only, §4.8 of `specifications.md`).
- Credentials are currently stored in `dt.preferences` (`preferences.xml`) in plain text. OS keyring integration is a planned hardening step.

## Changelog
2026.08.28 - 0.2.2
- Changed rest route name from darkwp to darkup
- WordPress Media Library is no longer always offered in full mode - it's now gated on the "media-library" slug in `/darkup/v1/info`, same as any gallery target
- Switching accounts (or a target losing/gaining admin approval) now prints a message for anything that changed availability

2026.08.26 - 0.2.1
- Added batch ID to http header

2026.08.23 - 0.2
- Added support for companion plugin
- Added dynamic field creation in export module

2026.08.23 - 0.1
- Initial version

## License

TBD.
