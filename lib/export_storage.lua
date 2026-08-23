--[[
  darkwp/lib/export_storage.lua

  The "Export to WordPress" storage module - the WordPress Library
  upload path (specifications.md §3.1.2).

  Deviation from specifications.md §3.1.1/§3.1.3, per direct user
  instruction: there is no internal "destination" combobox choosing
  between WordPress Library and a gallery plugin. Each gallery plugin
  gets its own separate darktable.register_storage() entry in the
  native target-storage dropdown instead (e.g. "Export to WordPress
  (NextGEN Gallery)") - see lib/gallery_storage.lua, which builds those
  dynamically per account from GET /darkwp/v1/info and requires
  wp_api.upload_media_full()/get_info() the same way this module
  requires wp_api.upload_media_core(). This module only ever handles the
  plain media-library path - it has nothing to dispatch on.
]]

local dt = require "darktable"
local df = require "lib/dtutils.file"
local accounts = require "darkwp/lib/accounts"
local wp_api = require "darkwp/lib/wp_api"
local util = require "darkwp/lib/util"

local gettext = dt.gettext.gettext
local function _(msgid)
  return gettext(msgid)
end

local STORAGE_NAME = "darkwp_export"

local export_mod = {}
export_mod.module_installed = false

-- per-run bookkeeping, reset in initialize(), read in finalize()
-- (specifications.md §3.6: "Track per-image results across the run...
-- report the final tally in finalize").
local run_results = {}

-- ---------------------------------------------------------------------
-- widgets
-- ---------------------------------------------------------------------

local connected_label = dt.new_widget("label") { label = "" }
local not_logged_in_label = dt.new_widget("label") { label = _("not logged in - log in via the darkwp accounts module") }

local title_entry = dt.new_widget("entry") { text = "$(FILE_NAME)", tooltip = _("supports darktable's $(...) export variables") }
local alt_entry = dt.new_widget("entry") { text = "$(Xmp.dc.title)", tooltip = _("supports darktable's $(...) export variables") }
local caption_entry = dt.new_widget("entry") { text = "$(Xmp.dc.headline)", tooltip = _("supports darktable's $(...) export variables") }
local description_entry = dt.new_widget("entry") { text = "$(Xmp.dc.description)", tooltip = _("supports darktable's $(...) export variables") }

local library_fields_box = dt.new_widget("box") {
  orientation = "vertical",
  dt.new_widget("label") { label = _("title") },
  title_entry,
  dt.new_widget("label") { label = _("alt text") },
  alt_entry,
  dt.new_widget("label") { label = _("caption") },
  caption_entry,
  dt.new_widget("label") { label = _("description") },
  description_entry,
}

local logged_in_box = dt.new_widget("box") {
  orientation = "vertical",
  connected_label,
  library_fields_box,
}

export_mod.container = dt.new_widget("box") {
  orientation = "vertical",
  not_logged_in_label,
  logged_in_box,
}

-- ---------------------------------------------------------------------
-- account-state -> UI sync (called from accounts_ui.lua on
-- login/switch/remove, and once at install time)
-- ---------------------------------------------------------------------

local function host_from_url(url)
  return (url:gsub("^https?://", ""):gsub("/.*$", ""))
end

function export_mod.refresh_from_account()
  local account = accounts.get_active()

  if not account then
    not_logged_in_label.visible = true
    logged_in_box.visible = false
    return
  end

  not_logged_in_label.visible = false
  logged_in_box.visible = true
  connected_label.label = string.format(_("connected to: %s"), host_from_url(account.url))
end

-- ---------------------------------------------------------------------
-- storage callbacks
-- ---------------------------------------------------------------------

local function gather_library_metadata(image, sequence)
  return {
    title = util.expand_variables(image, sequence, title_entry.text),
    alt_text = util.expand_variables(image, sequence, alt_entry.text),
    caption = util.expand_variables(image, sequence, caption_entry.text),
    description = util.expand_variables(image, sequence, description_entry.text),
  }
end

local function supported(storage, format)
  return accounts.get_active() ~= nil
end

local function initialize(storage, img_format, images, high_quality, extra_data)
  run_results = {}
  local account = accounts.get_active()
  if not account then
    dt.print(_("darkwp: no active account - log in via the darkwp accounts module first"))
  end
  -- WordPress Library has no required fields (specifications.md
  -- §3.1.2), so there is nothing else to validate before the run starts.
end

local function store(storage, image, format, filename, number, total, high_quality, extra_data)
  local account = accounts.get_active()
  local basename = df.get_filename(image.filename)

  if not account then
    run_results[image] = { filename = basename, ok = false, message = _("no active account") }
    dt.print(string.format(_("darkwp: %s failed - no active account"), basename))
    return
  end

  dt.print(string.format(_("darkwp: uploading %s (%d/%d)"), basename, number, total))

  local metadata = gather_library_metadata(image, number)
  local ok, result_id, err = wp_api.upload_media_core(account, filename, metadata)

  if ok then
    run_results[image] = { filename = basename, ok = true }
    dt.print(string.format(_("darkwp: uploaded %s"), basename))
    util.remove_file(filename)
  else
    run_results[image] = { filename = basename, ok = false, message = err }
    dt.print(string.format(_("darkwp: failed to upload %s: %s"), basename, tostring(err)))
  end
end

local function finalize(storage, image_table, extra_data)
  local uploaded, failed = 0, 0

  for _, result in pairs(run_results) do
    if result.ok then
      uploaded = uploaded + 1
    else
      failed = failed + 1
    end
  end

  if uploaded + failed == 0 then
    return
  end

  dt.print(string.format(_("darkwp: %d uploaded, %d failed"), uploaded, failed))

  run_results = {}
end

-- ---------------------------------------------------------------------
-- script_manager-compatible lifecycle (specifications.md §3.11)
-- ---------------------------------------------------------------------

function export_mod.install()
  if not export_mod.module_installed then
    dt.register_storage(
      STORAGE_NAME,
      _("Export to WordPress"),
      store,
      finalize,
      supported,
      initialize,
      export_mod.container
    )
    export_mod.module_installed = true
  end
  export_mod.refresh_from_account()
end

function export_mod.destroy()
  dt.destroy_storage(STORAGE_NAME)
  -- unlike a lib, a storage is fully torn down (§3.1.1) rather than
  -- hidden, so restart() needs to register it again from scratch.
  export_mod.module_installed = false
end

return export_mod
