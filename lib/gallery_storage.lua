--[[
  darkwp/lib/gallery_storage.lua

  Owns every "Export to WordPress"-family darktable storage: one per
  gallery adapter the active account's /darkup/v1/info describes
  (specifications.md §3.1.1/§3.1.3/§4.1), plus the WordPress Media
  Library target itself under the fixed slug "media-library".

  Deviation from specifications.md §3.1.1, per direct user instruction:
  instead of one storage with an internal destination combo box, each
  target - including the Library - gets its own darktable.register_storage()
  entry.

  Why the Library merged in here (rather than its own always-registered
  module, the earlier design): in full mode "media-library" is just
  another slug in /darkup/v1/info, gated by the same admin "Supported
  endpoints" checkbox (§4.5) as any gallery - and darktable's storage
  dropdown shows every registered storage regardless of supported()
  (greyed out, not hidden), so an *always*-registered fixed Library
  entry and this module's *live*, /info-driven Library entry would
  appear as two separate, confusingly similar rows the moment an
  account was ever in full mode this session. There is only ever one
  "media-library" row now because both paths below register (lazily,
  on first knowledge - see refresh_from_account()) under that same slug
  key, so get_or_create() returns the same `st` regardless of which
  mode got there first:
    - fallback mode (no companion plugin, §4.8): apply_library_fallback()
      registers it with a fixed, hardcoded field set (title/alt text/
      caption/description) and uploads go straight to core's
      `wp/v2/media` (wp_api.upload_media_core).
    - full mode: it flows through the exact same apply_adapter() path
      as any other gallery slug, IF the admin has enabled it - its
      `meta` field ids (title/alt_text/caption/description) are fixed
      by convention to match the fallback fields one-for-one, so the
      rendered UI looks the same either way. Uploads go through
      `/darkup/v1/media` (wp_api.upload_media_full) like any gallery,
      so the companion plugin's own accept/reject and logging (§4.4)
      apply - there is no bypass back to wp/v2/media in full mode.
  A mode change mid-session (e.g. the companion plugin gets installed
  on the site, or the account switches) just mutates the same `st` in
  place - see the lifecycle note below for why that, not
  destroy_storage(), is how this module reacts to change.

  IMPORTANT lifecycle constraint (specifications.md §3.11): "darktable
  cannot fully unregister a lib or storage module once created in a
  session." Nothing here is registered until refresh_from_account()
  first has an answer to register it *with* (an active account whose
  mode - fallback or full - is now known) - registering eagerly at
  install() with a placeholder "not logged in" state, the way this
  module used to, is exactly what produced the duplicate-row problem
  above. Once a slug is registered, it stays registered for the rest of
  the session: every later refresh (a different account, a changed
  adapter, mode flipping between fallback and full, or a target going
  away) just mutates that storage's state and widget contents in place:
    - `supported()` reads a live "is this slug part of the *currently
      active* account's info right now" flag, so a target that doesn't
      apply to the account you just switched to greys out rather than
      being destroyed.
    - the fields box handed to register_storage() is a persistent outer
      box whose *children* get swapped (fields.gather()) whenever the
      target's field set is (re)applied.
  gallery_storage.destroy_all() still does a real destroy_storage() per
  slug, but only for the script-level disable/enable cycle
  (darkwp.lua's destroy()/restart()) - the one cycle already known to be
  safe, and it also clears this module's bookkeeping so a subsequent
  restart() re-registers everything from scratch.

  API-constraint note: darktable's native storage dropdown has no
  per-entry tooltip mechanism reachable from Lua. A broken adapter (an
  `errors` entry instead of `meta`, §4.1) is still registered - greyed
  out via `supported() -> false`, matching the spec's "disabled, not
  hidden" requirement - but the error text can only be surfaced via
  darktable.print()/print_log() when the adapter list is (re)built, not
  as a literal tooltip on the disabled dropdown row.
]]

local dt = require "darktable"
local df = require "lib/dtutils.file"
local accounts = require "darkwp/lib/accounts"
local wp_api = require "darkwp/lib/wp_api"
local http = require "darkwp/lib/http"
local util = require "darkwp/lib/util"
local dynamic_fields = require "darkwp/lib/dynamic_fields"

local gettext = dt.gettext.gettext
local function _(msgid)
  return gettext(msgid)
end

local gallery_storage = {}

-- the fixed slug/label/field-set for the Library target - shared by
-- both the fallback path (registers it directly, below) and the full
-- mode path (registers it via apply_adapter() like any other slug, iff
-- the admin has enabled it and the companion plugin's /info includes
-- it). Field ids are fixed by convention (not adapter-defined, unlike a
-- real gallery's meta) to match core's own wp/v2/media field names
-- (specifications.md §3.1.2/§4.1/§4.8), and required:false throughout -
-- WordPress Library has no required fields.
local LIBRARY_SLUG = "media-library"
local LIBRARY_LABEL = _("WordPress Media Library")
local LIBRARY_FALLBACK_META = {
  { id = "title", label = _("title"), type = "text", required = false, placeholder = "$(FILE_NAME)" },
  { id = "alt_text", label = _("alt text"), type = "text", required = false, placeholder = "$(Xmp.dc.title)" },
  { id = "caption", label = _("caption"), type = "text", required = false, placeholder = "$(Xmp.dc.headline)" },
  { id = "description", label = _("description"), type = "text", required = false, placeholder = "$(Xmp.dc.description)" },
}

-- slug -> state table, see the module comment above for the fields
-- (name/outer_box are fixed at first registration; kind/available/
-- label/fields/run_results are updated in place on every refresh).
-- `kind` is "adapter" (a real /info-driven gallery, or the Library in
-- full mode), "library_fallback" (the Library in fallback mode - same
-- rendering/validation machinery as "adapter", different upload call),
-- or "broken" (a misconfigured adapter, §4.1).
local storages = {}

local function storage_name_for(slug)
  return "darkwp_gallery_" .. tostring(slug):gsub("[^%w_]", "_")
end

local function set_box_child(outer_box, widget)
  for i = #outer_box, 1, -1 do
    outer_box[i] = nil
  end
  outer_box[1] = widget
end

-- ---------------------------------------------------------------------
-- one-time registration - the callbacks below all read current state
-- from the closed-over `st` table at call time, so a single
-- registration keeps working no matter how many times the underlying
-- target's meta/errors/availability/kind changes across later refreshes.
--
-- Registration is deliberately split into two steps - find_or_init()
-- (just creates the bookkeeping table, no darktable call) and
-- register() (the actual dt.register_storage() call) - and every
-- apply_*() function below sets the real kind/available/label/fields on
-- `st` *before* calling register(). Registering while `st.available` was
-- still its just-created default of `false`, then flipping it to `true`
-- a moment later, produced a storage whose "file format" selector
-- stayed permanently disabled even once `supported()` was correctly
-- returning `true` - darktable appears to snapshot format-compatibility
-- once at registration time rather than re-querying `supported()` live
-- on every check, so the very first (stale, "false") answer stuck for
-- the rest of the session. Diagnosed by comparing against a dummy
-- storage registered eagerly with a `supported()` that's unconditionally
-- `true` from the start, which worked fine.
-- ---------------------------------------------------------------------

local function find_or_init(slug, label)
  local st = storages[slug]
  if st then
    return st, false
  end

  st = { available = false, label = label, name = storage_name_for(slug) }
  st.outer_box = dt.new_widget("box") { orientation = "vertical" }
  storages[slug] = st

  return st, true
end

local function register(st, slug)
  local function supported(storage, format)
    return st.available and accounts.get_active() ~= nil
  end

  local function initialize(storage, img_format, images, high_quality, extra_data)
    if st.kind ~= "adapter" and st.kind ~= "library_fallback" then
      return
    end
    st.run_results = {}
    http.rotate_batch_id()
    local ok, missing = st.fields.validate()
    if not ok then
      dt.print(string.format(_("darkwp: %s - missing required field(s): %s"), st.label, table.concat(missing, ", ")))
    end
  end

  local function store(storage, image, format, filename, number, total, high_quality, extra_data)
    if st.kind ~= "adapter" and st.kind ~= "library_fallback" then
      return
    end
    local account = accounts.get_active()
    local basename = df.get_filename(image.filename)

    if not account then
      st.run_results[image] = { filename = basename, ok = false, message = _("no active account") }
      dt.print(string.format(_("darkwp: %s failed - no active account"), basename))
      return
    end

    dt.print(string.format(_("darkwp: uploading %s to %s (%d/%d)"), basename, st.label, number, total))

    local metadata = st.fields.gather(image, number)
    local ok, result_id, err, is_adapter_error
    if st.kind == "library_fallback" then
      -- fallback mode: no companion plugin, straight to core's own
      -- media-library endpoint - never an "adapter-specific" failure.
      ok, result_id, err = wp_api.upload_media_core(account, filename, metadata)
      is_adapter_error = false
    else
      ok, result_id, err, is_adapter_error = wp_api.upload_media_full(account, filename, metadata, slug)
    end

    if ok then
      st.run_results[image] = { filename = basename, ok = true }
      dt.print(string.format(_("darkwp: uploaded %s to %s"), basename, st.label))
      util.remove_file(filename)
    else
      -- specifications.md §3.7/§4.6: a gallery-specific failure is
      -- reported distinctly from a plain upload failure, showing the
      -- image, the target it was headed to, and the returned error.
      st.run_results[image] = { filename = basename, ok = false, message = err, adapter_error = is_adapter_error }
      if is_adapter_error then
        dt.print(string.format(_("darkwp: %s uploaded, but the gallery step failed for %s: %s"), basename, st.label, tostring(err)))
      else
        dt.print(string.format(_("darkwp: failed to upload %s to %s: %s"), basename, st.label, tostring(err)))
      end
    end
  end

  local function finalize(storage, image_table, extra_data)
    if (st.kind ~= "adapter" and st.kind ~= "library_fallback") or not st.run_results then
      return
    end
    local uploaded, failed = 0, 0
    for _, result in pairs(st.run_results) do
      if result.ok then
        uploaded = uploaded + 1
      else
        failed = failed + 1
      end
    end
    if uploaded + failed == 0 then
      return
    end
    dt.print(string.format(_("darkwp: %s - %d uploaded, %d failed"), st.label, uploaded, failed))
    st.run_results = {}
  end

  dt.print_log("[darkwp] gallery_storage: registering '" .. st.name .. "' for the first time this session (available=" .. tostring(st.available) .. ")")
  dt.register_storage(
    st.name,
    st.label,
    store, finalize, supported, initialize,
    st.outer_box
  )
end

-- ---------------------------------------------------------------------
-- apply the current account's view of one slug to its (persistent)
-- storage - registers it on first sight (with its real state already
-- set), just updates state in place otherwise.
-- ---------------------------------------------------------------------

local function apply_adapter(slug, entry, label)
  local st, is_new = find_or_init(slug, label)
  st.kind = "adapter"
  st.available = true
  st.label = label
  st.fields = dynamic_fields.build(entry.meta or {})
  set_box_child(st.outer_box, st.fields.box)
  if is_new then
    register(st, slug)
  end
end

local function apply_broken(slug, entry, label)
  local st, is_new = find_or_init(slug, label)
  st.kind = "broken"
  st.available = false
  st.label = label

  local message = wp_api.flatten_errors(entry.errors)
  set_box_child(st.outer_box, dt.new_widget("box") {
    orientation = "vertical",
    dt.new_widget("label") { label = util.wrap_text(message, 40) },
  })

  if is_new then
    register(st, slug)
  end

  dt.print(string.format(_("darkwp: gallery '%s' is unavailable: %s"), label, message))
  dt.print_log("[darkwp] adapter '" .. tostring(slug) .. "' errored: " .. message)
end

--- fallback mode (no companion plugin): the Library target, with its
-- fixed local field set - see the LIBRARY_* constants above. Shares
-- find_or_init(LIBRARY_SLUG, ...) with the full-mode path in
-- apply_adapter(), so whichever one runs first is the only registration
-- that ever happens for this slug.
local function apply_library_fallback()
  local st, is_new = find_or_init(LIBRARY_SLUG, LIBRARY_LABEL)
  st.kind = "library_fallback"
  st.available = true
  st.label = LIBRARY_LABEL
  st.fields = dynamic_fields.build(LIBRARY_FALLBACK_META)
  set_box_child(st.outer_box, st.fields.box)
  if is_new then
    register(st, LIBRARY_SLUG)
  end
end

-- ---------------------------------------------------------------------
-- refresh from the active account's /darkup/v1/info - called from
-- accounts_ui.lua's on_account_changed (login/switch/remove), and once
-- at install/restart time for an already-active account.
-- ---------------------------------------------------------------------

function gallery_storage.refresh_from_account()
  local account = accounts.get_active()
  dt.print_log("[darkwp] gallery_storage.refresh_from_account: account=" .. (account and account.url or "none"))

  -- snapshot of what was available going into this refresh, so we can
  -- tell the user what just dropped out. darktable's dropdown greys an
  -- unsupported entry out silently - no message, no tooltip (see the
  -- API-constraint note at the top of this file) - so this refresh is
  -- the only chance to say something about it.
  local was_available = {}
  for slug, st in pairs(storages) do
    if st.available then
      was_available[slug] = st.label
    end
  end

  -- mark every previously-seen slug unavailable first; whichever branch
  -- below runs re-marks whatever the (possibly new) active account
  -- actually has right now. This - not destroy_storage() - is what
  -- makes a target grey out when it doesn't apply to the account you
  -- just switched to; see the module comment for why.
  for _, st in pairs(storages) do
    st.available = false
  end

  if account then
    -- always a live GET /darkup/v1/info - specifications.md §2 says
    -- this check "runs once per login/account-switch", i.e. it's meant
    -- to be re-checked every time, not read back from the account's
    -- cached `mode` field (that field is set once, at login, and can go
    -- stale - e.g. the companion plugin gets installed on the site
    -- afterwards).
    local info, err, state = wp_api.get_info(account)

    if state == "fallback" then
      dt.print_log("[darkwp] gallery_storage.refresh_from_account: 404 - fallback mode, plain media-library upload")
      apply_library_fallback()
    elseif not info then
      -- specifications.md §4.1: the whole /info response failing
      -- outright (e.g. 400/no_permission) is distinct from fallback
      -- mode - the account stays selectable, it just has no targets to
      -- show (not even the Library - the companion plugin is present
      -- but refusing to say what's enabled, so there's nothing valid to
      -- offer).
      if err then
        dt.print(string.format(_("darkwp: could not load upload destinations: %s"), err))
      end
      dt.print_log("[darkwp] gallery_storage.refresh_from_account: get_info failed: " .. tostring(err))
    else
      local count = 0
      for slug, entry in pairs(info) do
        count = count + 1
        local label = entry.name or util.humanize_slug(slug)
        if entry.meta then
          apply_adapter(slug, entry, label)
        elseif entry.errors then
          apply_broken(slug, entry, label)
        end
      end
      dt.print_log("[darkwp] gallery_storage.refresh_from_account: " .. count .. " target(s) in /info")
    end
  end

  -- anything that was available before this refresh and isn't now gets
  -- one message - except a target apply_broken() just handled above,
  -- which already printed its own, more specific reason.
  for slug, label in pairs(was_available) do
    local st = storages[slug]
    if st and not st.available and st.kind ~= "broken" then
      dt.print(string.format(_("darkwp: %s is not available for this account. Restart Darktable to refresh the storage targets"), label))
    end
  end
end

--- real, one-time teardown - only for the script-level disable/enable
-- cycle (darkwp.lua's destroy()/restart()), not for account switching.
-- Clears this module's bookkeeping too, so the next refresh_from_account()
-- re-registers everything from scratch rather than finding stale state.
function gallery_storage.destroy_all()
  for slug, st in pairs(storages) do
    dt.destroy_storage(st.name)
  end
  storages = {}
end

return gallery_storage
