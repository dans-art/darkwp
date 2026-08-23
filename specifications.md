# darkwp - darktable to WordPress Upload Plugin
### Technical Specification
 
**Status:** Ready for implementation
**Author:** dans-art [https://github.com/dans-art]
**Component name:** darkwp
 
---
 
## 1. Overview
 
darkwp lets a photographer upload images directly from darktable into WordPress, without manually exporting to disk and uploading through the browser. It has two halves that talk to each other over REST:
 
1. **darktable-side Lua module** - runs inside darktable, handles credentials, image selection/export, and the upload call.
2. **WordPress-side companion plugin** - exposes a REST API surface, handles authentication, media library insertion, and routes the image into whichever gallery plugin the site uses (or plain media library if none).
The two-piece design exists because WordPress core's `/wp/v2/media` endpoint only puts a file into the media library. It does not know about gallery plugins (NextGEN, FooGallery, Envira, etc.), so a custom route on the WordPress side is required to support "upload AND assign to a specific gallery/album."
 
**The companion plugin is optional.** If it isn't installed on the target site, darkwp still works as a plain media-library uploader (see §3.1 and §4.8).
 
---
 
## 2. Architecture
 
**Without the WordPress companion plugin (fallback mode):**
```
Login / select account -> Export -> REST (wp/v2/media)
```
No gallery selection, no plugin-specific metadata - just a straight upload into the media library using WordPress core's own endpoint.
 
**With the WordPress companion plugin:**
```
Login / select account -> get plugin and metadata info -> Export -> REST (darkwp/v1/media) with metadata for the current target
```
The darktable module only ever sends the image and metadata via REST. All logic around gallery creation/assignment lives in the WordPress plugin - darktable has no knowledge of how any given gallery plugin works internally.
 
**Detecting which mode applies:** on login, the Lua module calls `GET /darkwp/v1/info`. A 404 (route doesn't exist) means the companion plugin isn't installed, and the account is flagged as fallback-mode. A successful response means full mode is available. This check runs once per login/account-switch, not per upload.
 
---
 
## 3. darktable-side module (Lua)
 
### 3.1 Registration of the export module
 
- Registers as a darktable export storage module via `dt.register_storage()`, so it shows up as a destination in the Export panel alongside Disk, Email, etc. (This is the primary trigger point - not a separate lighttable action.)
- Module id: `darkwp`, must pass `du.check_min_api_version()` against the darktable Lua API in use (currently targeting 9.7.0 / darktable 5.6, verify against the runtime's `dt.configuration.api_version_string` at load time rather than hardcoding).
- This module depends on the login and account status:
  - **Not logged in** -> shows a message telling the user to log in first (via the accounts module).
  - **Logged in, full mode** -> shows the **destination selector** and plugin-specific fields, populated from `/darkwp/v1/info`.
  - **Logged in, fallback mode** (companion plugin not detected) -> shows only standard fields (title/alt/caption, no tags), no destination selector beyond "WordPress Library," uploads go straight to `wp/v2/media`.
- Header shows the currently connected site (`connected to: <domain>`).
- Registration uses all four `register_storage` callbacks, not just `store`:
  - **`store`** - runs once per exported image; builds the metadata table from the widget fields and calls the upload function.
  - **`finalize`** - accumulates per-image results tracked during `store` and reports a final summary ("X uploaded, Y failed") via `darktable.print(...)`.
  - **`supported`** - returns `false` (disabling this storage in the export panel) when no account is currently active/logged in, rather than letting the user select it and fail per-image.
  - **`initialize`** - validates the currently configured fields (e.g. a mode-specific field like gallery id/name is filled in) before the export run starts, so a missing required field is caught immediately rather than after several images have already uploaded.
#### 3.1.1 Registration and destination selector
 
- One `darktable.register_storage()` call creates a single entry (e.g. "Export to WordPress") in darktable's native, already-existing target storage dropdown, alongside Disk, Email, etc. There is no separate or custom storage-registration mechanism - this is the only registration darkwp needs.
- `darktable.destroy_storage()` tears it down (used in the script's `destroy()` lifecycle function, §3.11).
- Inside that one storage's own settings widget (the box passed as the last argument to `register_storage`), an ordinary combo box widget lets the user choose the upload destination: "WordPress Library" or any detected gallery plugin (e.g. "NextGEN Gallery"). This is just a widget within darkwp's own box, not an additional entry in darktable's native storage dropdown and not a second registration of any kind. Changing it swaps the field set shown below it (§3.1.2 / §3.1.3), driven by the fixed core fields plus whatever `/darkwp/v1/info` returned for that destination.
#### 3.1.2 Field set - "WordPress Library" target
 
- **title** - text entry, default value `$(FILE_NAME)`
- **alt text** - text entry, default value `$(Xmp.dc.title)`
- **caption** - text entry, default value `$(Xmp.dc.headline)`
- **description** - text entry, default value `$(Xmp.dc.description)`
- No tags field - WordPress core media attachments have no native tag taxonomy.
All four fields use darktable's variable-placeholder syntax (the same `$(...)` pattern darktable already uses for export filename templates), pre-filled with sensible defaults, editable per export run. Use darktable's existing variable-expansion mechanism (as used by the core export filename pattern, or the community `dtutils` variable-expansion helper if the core mechanism isn't exposed to Lua storage modules) to resolve these against each image's actual metadata at export time - don't reimplement variable parsing from scratch.
 
#### 3.1.3 Field set - gallery target (e.g. "NextGEN Gallery")
 
- **status** - dropdown, e.g. publish/draft - options come from `/darkwp/v1/info` for that target (not all targets need to define this).
- **mode** - dropdown, populated from that target's `modes` in `/darkwp/v1/info` (e.g. "Add to gallery" / "Create gallery").
- **dynamic field** - exactly one field, whichever the selected mode defines (e.g. "gallery id" text entry for Add mode, "gallery name" text entry for Create mode). Swaps when mode changes.
- **alt text** - text entry (no default placeholder shown for gallery targets)
- **description** - text entry
- **tags (comma-separated)** - text entry
Gallery targets intentionally omit title and caption - confirmed as by design, not a gap to fill in later. Each gallery target brings its own set of meta fields, which are defined by the companion plugin and delivered via the `/darkwp/v1/info` endpoint.
 
### 3.2 Registration of the accounts module
 
A separate module (labelled "darkwp accounts") that allows logging in, switching between accounts, and removing an account via its own Remove button (§3.2 account list rows) - there is no separate global logout action.
 
Login form fields:
- **wordpress address** (text entry, validated to start with `https://`)
- **username** (text entry)
- **password** (masked text entry - the Application Password, never the real account password)
- **Allow insecure connections** (checkbox) - see §3.4 for exact behavior; this does **not** permit plain HTTP.
- **login** button - calls a lightweight authenticated WP endpoint (`/wp-json/wp/v2/users/me`) to confirm credentials and check for the `upload_files` capability, then probes `/darkwp/v1/info` to determine full vs. fallback mode, before adding/updating the account.
**Client-side validation:** before attempting any network call, check all three fields are filled in. If not, show an inline error below the login button: *"login failed: please fill out all the fields"*. This is separate from server-side auth failure handling (wrong credentials, unreachable host, etc.), which should show the actual error returned by WordPress.
 
**States:**
- **Empty state** (no accounts saved yet) - just the login form, header reads "login to wordpress."
- **Populated state** (one or more accounts saved) - an account list appears above the login form under the header "select the account to use." The login form stays visible below it, always available for adding another account.
**Account list rows** - each row shows:
- Site favicon (fetched from the site), falling back to a generic WordPress logo icon if the favicon can't be fetched or hasn't loaded yet.
- Website domain
- Username
- **"selected"** label, shown only on the currently active account.
- **Remove** button - deletes that account from the saved list and its stored credentials from preferences. If the removed account was the active one, fall back to another remaining account (if any) or show the empty-state login form if none remain. There is no separate global "Logout" action - removing an account via its own button is how you log out of it.
**Row click behavior:** clicking an account row (not its Remove button) does two things at once - it makes that account the active one (moves the "selected" label to it, and repopulates the export module with its credentials/mode), **and** it loads that account's stored details into the login form fields below, so the user can review or edit them (e.g. update a rotated application password) without having to retype the URL/username. Submitting the login form again with edited fields updates the stored credentials for that same account rather than creating a duplicate.
 
### 3.3 Credential storage
 
- Stored via `dt.preferences.write()` / `dt.preferences.read()` (darktable's Lua-accessible persistence layer - it does not expose the internal library.db to Lua, so preferences.xml is the only durable option).
- Since multiple accounts must be supported, and `dt.preferences` keys are fixed/named rather than dynamic, store the account list as a single JSON-encoded string under one preference key (e.g. `darkwp_accounts`), containing an array of `{ url, username, app_password, allow_insecure, mode }` objects - `allow_insecure` is per-account (tied to that specific site's certificate situation, e.g. a local dev install vs. a production site), not a single global setting. Read/parse on load, re-serialize and write on any change.
- Store URL and username in plain values; treat the application password as sensitive - do not print it, do not include it in any log output or error message.
- Plain text for v1, see §7 (Future Extensions) for credential storage hardening options.
### 3.4 Upload mechanism
 
- Images are exported to a temporary local path first using darktable's normal export pipeline (format/size/quality controlled by the standard Export panel controls - darkwp does not reinvent those).
- The plugin shells out to `curl` for the actual HTTP call. Use `jq` for parsing JSON responses, or minimal hand-rolled JSON handling in Lua if the payloads stay simple enough to avoid the extra dependency (see §3.9 cross-platform notes).
- **Security requirements for the curl call:**
  - Do not pass credentials via `--user user:pass` on the command line (visible in process listings / `ps aux`). Use `--netrc-file` pointed at a temp file with restrictive permissions.
  - Always connect over `https://`. Plain HTTP is never used, regardless of the "Allow insecure connections" setting.
  - **"Allow insecure connections" means: connect over HTTPS but skip certificate validation** (curl `--insecure` / `-k`), for local dev environments running self-signed certificates (Local, Valet, Docker + mkcert, etc.). It does not permit falling back to `http://`.
  - Any value interpolated into a shell command (filenames, titles, captions, tags) must be shell-escaped. Any value passed to `printf` for JSON construction must go through the data argument (`printf '%s'`), never through the format string.
- One curl call per image for the initial version; batch/concurrency is a v2 concern (see §7).
### 3.5 Metadata mapping
 
The exact field set sent depends on the selected target storage - see §3.1.2 (WordPress Library) and §3.1.3 (gallery target) for which fields appear in each case. In both cases:
- Text fields are resolved through darktable's variable-placeholder expansion (§3.1.2) before sending, not sent as literal `$(...)` strings.
- **Tags/keywords** (gallery targets only) - comma-separated free text as entered, mapped to WP tags or a gallery-plugin-specific taxonomy on the WordPress side, per the target adapter.
- **Status** (gallery targets that define it) - sent as the selected status id from `/darkwp/v1/info`.
- **Embedded metadata** - the exported file already carries whatever EXIF/XMP data darktable writes into it during export; this travels with the file itself and does not need to be duplicated as separate JSON fields.
- **Plugin-specific data** - the dynamic mode field (§3.1.3) and its value are sent under the field id defined per-target in `GET /darkwp/v1/info` (§4.1); the Lua module has no built-in knowledge of any specific gallery plugin's fields, it only renders and relays whatever `/info` describes.
### 3.6 Progress & feedback
 
- Use `darktable.print(...)` for user-visible messages (per-image progress, final summary counts) - this is the actual darktable Lua function for on-screen messages, not a "notification API." Use `darktable.print_error(...)` / `darktable.print_log(...)` additionally for the log/debugging trail, but never as the only feedback for something the user needs to see.
- On failure, show the specific image (via `image.filename` or the `filename`/`number` args already passed to the `store` callback - never `tostring(image)`, which won't produce a readable string) and the HTTP status / error message returned by WordPress - never just "upload failed."
- Track per-image results across the run (e.g. in a table keyed by image, populated in `store`) and report the final tally in `finalize` - "X uploaded, Y failed," not just a running stream of individual messages.
- Actions like account switch, login, upload, target change, etc. are logged to the terminal when darktable is run with the `-d lua` debug flag (i.e. via `darktable.print_log(...)`, which only surfaces there, as distinct from `darktable.print(...)` which is always user-visible on screen).
### 3.7 Error handling & retry
 
- **Long batches must not die silently mid-run.** If a connection drops, the module must report exactly which images succeeded and which didn't, not just stop.
- **Gallery-specific failures are reported distinctly from plain upload failures** (see §4.6/§4.8 for how the API response distinguishes these). If a gallery-target upload fails, show the image, the target it was headed to, and the error returned by the custom REST route - not a generic "upload failed."
- Retry policy: one automatic retry on network-level failure (timeout, connection reset) with a short backoff; no automatic retry on 4xx responses (those are configuration/auth problems, not transient).
### 3.8 OS support
 
- Linux, macOS, and Windows. Linux is the primary/reference platform.
### 3.9 Cross-platform requirements
 
- **File permissions on temp credential files.** `chmod 600` (POSIX) has no equivalent meaning on Windows/NTFS. Branch on OS: apply `chmod` on Linux/macOS; on Windows, rely on the OS-provided per-user temp directory already being access-restricted, or set an ACL explicitly if stronger guarantees are needed.
- **Temp file/directory resolution.** Do not rely on `os.tmpname()` alone - inconsistent across Lua builds on Windows. Prefer darktable's own configured temp/cache path if exposed by the Lua API, otherwise read `TMPDIR`/`TEMP`/`TMP` environment variables directly per OS.
- **curl availability.** Present on virtually all Linux/macOS installs; present on Windows 10 1803+ but not guaranteed. Check for curl on the PATH at module load and surface a clear "curl not found" message rather than failing during an upload.
- **jq availability.** Not bundled on any of the three OSes by default. Prefer minimal hand-written JSON construction/parsing in Lua for this plugin's small, predictable payloads. Only require jq if response parsing genuinely needs it, and check for it the same way as curl.
- **Shell escaping.** POSIX shell quoting rules do not apply on Windows `cmd`/PowerShell. Any escaping function needs an OS branch, or use argument-array style invocation where the platform allows it.
- **Path separators.** Use darktable/Lua's own path-joining behavior rather than hardcoding `/`.
### 3.10 Design system
 
- Only the native darktable design system is used (standard Lua/GTK widgets exposed by the darktable API). No custom CSS styling of darktable's own UI.
### 3.11 Known darktable Lua API constraints
 
These were discovered during prototyping and must be accounted for, not rediscovered by the coder:
 
- **Storage lifecycle is the plain darktable API, nothing custom.** `darktable.register_storage()` creates the single "Export to WordPress" entry once; `darktable.destroy_storage()` tears it down in `destroy()`. The WordPress Library / gallery-plugin choice is an internal combo box widget inside that one storage's settings box (§3.1.1), not a second storage-registration mechanism.
- **Don't rely on `register_lib`'s built-in reset button at all.** Earlier prototyping hit a crash there; rather than root-causing it, account management is handled entirely through explicit UI instead - each account row's own "Remove" button (§3.2), not a panel-wide reset. Set `resetable = false` on the lib registration so the built-in mechanism is never invoked in the first place.
- **Login/logged-in state switching** should use a `stack` widget with two pages (login form / account+export settings), toggling `.active` between them on successful login and on logout - this is the clean way to swap the panel contents in place without destroying/recreating widgets.
- **darktable cannot fully unregister a lib or storage module once created in a session.** The script must follow the standard script_manager-compatible structure: a `script_data` table with `name`/`purpose`/`author`/`help` metadata plus `destroy`, `destroy_method` (`"hide"`), `restart`, and `show` functions, and a `module_installed` guard around registration calls so re-running `restart` doesn't attempt to double-register.
- **JSON values passed through `printf` for parsing (e.g. via `jq`) must go through the data argument, never the format string** - `printf '%s' '<json>' | jq ...`, not `printf '<json>' | jq ...`. A `%` character in the JSON will otherwise be misinterpreted as a conversion specifier. (This restates §3.4's printf guidance - flagging again here since it's easy to reintroduce in a new helper function that isn't the one originally reviewed for it.)
---
 
## 4. WordPress-side plugin (PHP)
 
### 4.1 REST namespace
 
Custom namespace: `darkwp/v1`
 
Routes:
- **`GET /darkwp/v1/info`** - returns available upload destinations. Detects which gallery plugins are active and returns only relevant options (e.g. NextGEN galleries if NextGEN is active, FooGallery galleries if that's active, otherwise just "Media Library"). Example shape:
```
  targets:
    - id: nextgen
      label: "NextGEN Gallery"
      statuses:                        # optional per target - omit if not applicable
        - id: publish
          label: "Publish"
        - id: draft
          label: "Draft"
      modes:
        - id: add
          label: "Add to gallery"
          fields:
            - id: add_to_gall
              label: "Add to gallery (id)"
              input: int
              required: true
        - id: create
          label: "Create gallery"
          fields:
            - id: create_gall
              label: "Create gallery"
              input: text
              required: true
    - id: foogallery
      label: "FooGallery"
      ...
```
  `statuses` is optional per target - a target that has no concept of publish/draft (or the Media Library pseudo-target) simply omits it, and the darktable module doesn't render a status dropdown for that target.
  (A missing route / 404 here is how the darktable module detects fallback mode - see §2.)
- **`POST /darkwp/v1/media`** - accepts the image file (multipart) plus metadata (title, alt, caption, tags, target id, and any additional plugin-specific fields described by `/info`).
### 4.2 Authentication
 
- WordPress Application Passwords (Basic Auth: `username:application_password`, base64-encoded in the `Authorization` header). No custom auth scheme, no OAuth.
### 4.3 Gallery plugin adapter layer
 
- An abstraction interface (e.g. `Darkwp_Gallery_Adapter`) with a method contract like `get_plugin_metadata()`, `upload_image( $file, $metadata )`.
- **Routing decision:** if a gallery target was specified in the request, the matching adapter's `upload_image()` owns the entire upload for that image - it is responsible for storing the file however that gallery plugin expects (which may or may not involve creating a standard WP attachment internally) and returning success/failure plus a reference id. If no gallery target was specified (plain "Media Library" upload), the core plugin calls native `wp_insert_attachment()` / `wp_generate_attachment_metadata()` directly - **no adapter is invoked** for that path.
- Because statistics/logging (§4.4) need to work the same way regardless of which path was taken, both paths fire a common hook (e.g. `do_action( 'darkwp_after_upload', $result )`) after completion - adapters call it themselves at the end of `upload_image()`, and the native path calls it right after `wp_insert_attachment()` succeeds or fails. Logging/statistics code only ever needs to listen on that one hook.
- Ship with a "Media Library" pseudo-target as the baseline (routes through the native path above, not an adapter class).
- Additional adapters (NextGEN, FooGallery, etc.) can be added without touching the upload/auth core - this is the extension point for future gallery support.
- All gallery-specific fields are defined and validated in the WordPress plugin; the darktable module only renders whatever fields `/darkwp/v1/info` describes and passes the values back - it has no built-in knowledge of any adapter's internals.
- Detection: check `is_plugin_active()` for each supported gallery plugin, but plugin activity alone does not put it in `/darkwp/v1/info` - the admin must also have it enabled under General Settings' "Supported endpoints" (§4.5). An adapter only appears as an available target when both are true: the plugin is active, and the admin has checked it on.
### 4.4 Logging
 
- Every upload gets logged, unless the user has turned logging off (see §4.5, "Keep logs for: No logging").
- Logging is driven by the `darkwp_after_upload` hook (§4.3), so it behaves identically whether the image went through an adapter or the native media-library path.
- Uploads are bundled for display, not shown individually: e.g. "User X uploaded Y images to gallery Z."
### 4.5 Menu
 
The plugin adds a "DarkWP" submenu under Settings, using WordPress's own admin design system (no external UI libraries). Custom style via CSS is allowed here (this is the plugin's own admin screen, distinct from darktable's UI in §3.10). Three tabs: **General settings**, **Statistics & History**, **Help**.
 
> **Naming note:** mockups mix "DarkWP" (page title, menu item) with "DarkWePe" (admin bar plugin name, support-forum link text) - leftover from before the rename. Settle on one final display name (recommend "DarkWP," matching the REST namespace and everywhere else in this spec) before the coder builds the admin screens, so it isn't shipped inconsistent.
 
**General settings tab:**
- **Supported endpoints** - one checkbox per target: "WordPress Media Library" (the baseline, always available), plus one per detected gallery plugin (e.g. "NextGEN Gallery"). A checkbox is only checked (and that target included in `/darkwp/v1/info`) if the admin has explicitly enabled it - an active-but-unchecked gallery plugin shows an available, unchecked box. If the gallery plugin isn't installed at all, its checkbox is disabled/greyed out with helper text ("Plugin not installed. Install [Plugin] to export to it").
- **Max upload size** - numeric input, in KB, with helper text ("Max upload size in kb"). Can be set lower than the site's own `wp_max_upload_size()` (never higher - still bounded by it) as an admin-facing extra restriction specific to darkwp uploads.
- **Keep logs for** - select dropdown: 90 days / 60 days / 30 days / 7 days / Forever / No logging (Existing logs will be deleted). Default: 90 days. Helper text under the field explains the default and that switching to "No logging" deletes existing logs immediately.
- **Save** button.
**Statistics & History tab:**
- **Statistics** - three summary cards: "Total images uploaded" (a single count), "Uploads per gallery" (per-target breakdown, e.g. WordPress Media Library vs. NextGEN Gallery), "Uploads by user" (per-WordPress-user breakdown). Format large counts with WordPress's own localized number formatting (`number_format_i18n()`) rather than a hardcoded separator.
- **History** - a searchable, filterable table. Filters: Date, Gallery, User - shown as removable chips once applied (e.g. "Date is 13.01.2026 ×"), plus an "Add filter" control and a "Reset" link to clear all filters. Table columns: thumbnail, label, date, gallery.
  - **Label format** follows the bundled logging convention from §4.4: `"Uploaded {N} Pictures"` (gallery column shows "WordPress") for plain Media Library uploads, or `"Uploaded {N} Pictures to gallery {name}"` (gallery column shows the actual gallery plugin's name) when a gallery target was used. Each row also carries a small badge with the WordPress username who did the upload.
  - Paginated ("Page X of Y" with prev/next controls).
**Help tab:**
- **"How to install the Darktable script"** - explains that the darktable-side Lua module is a separate install step (not bundled inside this WordPress plugin's own package/zip), with a link/button out to its GitHub repo and a pointer to follow the README there.
- **"Do you like the plugin?"** - a review prompt (star display) linking out to the plugin's wordpress.org review page.
- **"Need help?"** - links to the WP.org support forum thread and a direct support email address.
### 4.6 Upload flow detail
 
1. Validate auth + capability (`upload_files`, plus any adapter-specific capability).
2. Validate file (type, size against configured max, extension allow-list).
3. **If a gallery target was specified:** call the matching adapter's `upload_image( $file, $metadata )`. The adapter is fully responsible for storing the image and returns a success/failure result plus its own reference id.
   **If no gallery target was specified (Media Library only):** call `wp_insert_attachment()` / `wp_generate_attachment_metadata()` directly, set title/alt/caption from the request.
4. Fire `darkwp_after_upload` with the result, regardless of which path was taken (drives logging/statistics).
5. Respond with a structured result that distinguishes:
   - overall success/failure,
   - HTTP status code,
   - for adapter-path uploads specifically: whether the failure happened inside the adapter (gallery-specific) vs. before it (auth/validation), so darktable can show "uploaded fine, gallery step failed" vs. "upload itself failed" as genuinely different messages.
### 4.7 Non-functional / packaging requirements
 
- **i18n**: all user-facing strings wrapped for translation, text domain `darkwp`.
- **Uninstall/cleanup**: `uninstall.php` removes plugin options; does not delete already-uploaded media (that's user content, not plugin state).
- **Security testing**: this plugin accepts binary uploads over a public REST route - needs explicit testing for MIME-type spoofing, oversized payloads, and path traversal in filenames, beyond WordPress core's own upload handling.
- **readme.txt**: standard WP.org format, maintained as its own asset from day one.
- **SVN deployment**: if this goes to WP.org, plan the `/trunk` + `/tags` SVN workflow separately from the GitHub development repo.
### 4.8 Fallback mode (companion plugin not installed)
 
If the target WordPress site does not have the darkwp companion plugin installed, darkwp still works as a plain uploader:
 
- The darktable module detects this via a 404 on `GET /darkwp/v1/info` (§2, §3.1).
- No gallery target selector is shown; no plugin-specific fields are rendered.
- Uploads go directly to WordPress core's `POST /wp/v2/media` using the same Application Password auth.
- Only standard fields are sent: title, alt text, caption, tags (as WP core supports them natively).
- No custom logging/statistics are possible in this mode (there's no companion plugin to record them).
---
 
## 5. End-to-end flow (happy path, full mode)
 
1. User logs in or selects the account via the accounts module. Login also determines full vs. fallback mode (§2).
2. Destination selector in the export module populates from `/darkwp/v1/info` (full mode only).
3. User selects images in lighttable, opens the Export panel.
4. User picks a target, sets normal export settings (format/size/quality), sets gallery-specific metadata, clicks Export.
5. darktable exports each image to a temp file as usual.
6. For each exported file, the Lua module builds metadata, shell-escapes values, and calls `/darkwp/v1/media` via curl with a netrc-based auth file.
7. WordPress creates the media item and/or runs the adapter's gallery-specific handling, returns a structured status.
8. darktable module reports per-image result via notification; temp files cleaned up after each successful upload.
9. On completion, a summary is shown: uploaded count, gallery-attached count, failures with reasons (adapter-path failures called out separately from plain upload failures).
---
 
## 6. Out of scope for v1
 
- Editing/replacing an already-uploaded image from darktable.
- Concurrent/parallel uploads (v1 is sequential, one curl call at a time).
- Marking already-uploaded images (via color label or metadata) so they're recognizable in lighttable.
---
 
## 7. Future extensions (not v1, but architecture should not block these)
 
- Parallel/batch upload with a concurrency limit.
- Filters to let third parties register custom adapters/targets.
- **Credential storage hardening (v2).** V1 stores the application password in plain text via `dt.preferences` (preferences.xml, unencrypted). Acceptable for v1. For a future version, consider: OS keyring integration (`secret-tool`/libsecret on Linux, Keychain on macOS) so the password never touches disk in plaintext, and/or restrictive file permissions (`chmod 600`) on the preferences file as a cheaper interim step.
---
 
## 8. Design
 
darktable and WordPress plugin UI design is in the attached Figma file:
https://www.figma.com/design/YE7AcowgO276vwEnPDVS1d/DarkWP?node-id=0-1&t=sffcKbPTMpezhOIp-1
 
---
 
## 9. Acceptance criteria
 
- [ ] A user can configure WP URL + app password once and have it persist across darktable restarts, across multiple accounts.
- [ ] "Test connection" clearly reports success/failure with a real WP error message on failure (not a generic curl exit code).
- [ ] On login, the module correctly detects full vs. fallback mode and adjusts the export panel UI accordingly.
- [ ] Destination selector (full mode) reflects only galleries that are both actively installed and enabled by the admin under "Supported endpoints" (§4.3/§4.5).
- [ ] Uploading a batch of 10+ images reports per-image status; killing the network mid-batch does not lose track of which images succeeded.
- [ ] An adapter/gallery-specific failure is visibly distinct from a plain upload failure, both in the WP API response and in the darktable notification.
- [ ] "Allow insecure connections" skips certificate validation but never falls back to plain HTTP.
- [ ] Fallback mode (no companion plugin) successfully uploads to `wp/v2/media` with no gallery UI shown.
- [ ] No credential ever appears in a process listing, log file, or error message.
- [ ] Plugin passes basic upload-endpoint security testing (oversized file, spoofed MIME type, malicious filename).
 