--[[
  darkwp/lib/gallery_storage.lua

  Per-adapter "Export to WordPress (<gallery>)" storage modules, full
  mode only (specifications.md §3.1.1/§3.1.3/§4.1).

  Deviation from specifications.md §3.1.1, per direct user instruction:
  instead of one storage with an internal destination combo box, each
  adapter GET /darkwp/v1/info describes gets its own
  darktable.register_storage() entry - the same deviation
  export_storage.lua documents for the WordPress Library path.

  IMPORTANT lifecycle constraint (specifications.md §3.11): "darktable
  cannot fully unregister a lib or storage module once created in a
  session." export_storage.lua's destroy()/restart() pair only exercises
  a destroy_storage()+register_storage() cycle *once*, at script
  disable/enable - that single cycle is the one thing already assumed to
  work. Account switching happens far more often (every login/switch/
  remove), so this module never destroys and re-registers a gallery's
  storage on that path - each slug is registered with darktable exactly
  once per session, the first time it's ever seen, and every later
  refresh (a different account, a changed adapter, or the same adapter
  going away) just mutates that storage's state and widget contents in
  place:
    - `supported()` reads a live "is this slug part of the *currently
      active* account's info right now" flag, so a gallery that doesn't
      apply to the account you just switched to greys out rather than
      being destroyed.
    - the fields box handed to register_storage() is a persistent outer
      box whose *children* get swapped (fields.gather()) whenever the
      adapter's `meta` is (re)applied.
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

-- slug -> state table, see the module comment above for the fields
-- (name/outer_box are fixed at first registration; kind/available/
-- label/fields/run_results are updated in place on every refresh).
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
-- adapter's meta/errors/availability changes across later refreshes.
-- ---------------------------------------------------------------------

local function get_or_create(slug, label)
  local st = storages[slug]
  if st then
    return st
  end

  st = { available = false, label = label }
  storages[slug] = st

  local function supported(storage, format)
    return st.available and accounts.get_active() ~= nil
  end

  local function initialize(storage, img_format, images, high_quality, extra_data)
    if st.kind ~= "adapter" then
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
    if st.kind ~= "adapter" then
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
    local ok, result_id, err, is_adapter_error = wp_api.upload_media_full(account, filename, metadata, slug)

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
    if st.kind ~= "adapter" or not st.run_results then
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

  st.name = storage_name_for(slug)
  st.outer_box = dt.new_widget("box") { orientation = "vertical" }

  dt.print_log("[darkwp] gallery_storage: registering '" .. st.name .. "' for the first time this session")
  dt.register_storage(
    st.name,
    string.format(_("Export to WordPress (%s)"), label),
    store, finalize, supported, initialize,
    st.outer_box
  )

  return st
end

-- ---------------------------------------------------------------------
-- apply the current account's view of one slug to its (persistent)
-- storage - registers it on first sight, just updates state otherwise.
-- ---------------------------------------------------------------------

local function apply_adapter(slug, entry, label)
  local st = get_or_create(slug, label)
  st.kind = "adapter"
  st.available = true
  st.label = label
  st.fields = dynamic_fields.build(entry.meta or {})
  set_box_child(st.outer_box, st.fields.box)
end

local function apply_broken(slug, entry, label)
  local st = get_or_create(slug, label)
  st.kind = "broken"
  st.available = false
  st.label = label

  local message = wp_api.flatten_errors(entry.errors)
  set_box_child(st.outer_box, dt.new_widget("box") {
    orientation = "vertical",
    dt.new_widget("label") { label = util.wrap_text(message, 40) },
  })

  dt.print(string.format(_("darkwp: gallery '%s' is unavailable: %s"), label, message))
  dt.print_log("[darkwp] adapter '" .. tostring(slug) .. "' errored: " .. message)
end

-- ---------------------------------------------------------------------
-- refresh from the active account's /darkwp/v1/info - called from
-- accounts_ui.lua's on_account_changed (login/switch/remove), and once
-- at install/restart time for an already-active account.
-- ---------------------------------------------------------------------

function gallery_storage.refresh_from_account()
  local account = accounts.get_active()
  dt.print_log("[darkwp] gallery_storage.refresh_from_account: account=" .. (account and account.url or "none"))

  -- mark every previously-seen slug unavailable first; the loop below
  -- re-marks whichever ones the (possibly new) active account actually
  -- has right now. This - not destroy_storage() - is what makes a
  -- gallery grey out when it doesn't apply to the account you just
  -- switched to; see the module comment for why.
  for _, st in pairs(storages) do
    st.available = false
  end

  if not account then
    return
  end

  -- always a live GET /darkwp/v1/info - specifications.md §2 says this
  -- check "runs once per login/account-switch", i.e. it's meant to be
  -- re-checked every time, not read back from the account's cached
  -- `mode` field (that field is set once, at login, and can go stale -
  -- e.g. the companion plugin gets installed on the site afterwards).
  local info, err, state = wp_api.get_info(account)

  if state == "fallback" then
    dt.print_log("[darkwp] gallery_storage.refresh_from_account: 404 - fallback mode, no galleries")
    return
  end

  if not info then
    -- specifications.md §4.1: the whole /info response failing outright
    -- (e.g. 400/no_permission) is distinct from fallback mode - the
    -- account stays selectable, it just has no gallery targets to show.
    if err then
      dt.print(string.format(_("darkwp: could not load gallery destinations: %s"), err))
    end
    dt.print_log("[darkwp] gallery_storage.refresh_from_account: get_info failed: " .. tostring(err))
    return
  end

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
  dt.print_log("[darkwp] gallery_storage.refresh_from_account: " .. count .. " adapter(s) in /info")
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
