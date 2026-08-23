--[[
  darkwp - upload images from darktable directly to WordPress.
  See specifications.md in this directory for the full spec.

  USAGE
  * require this script from your main lua file, or install it via
    script_manager:
      require "darkwp/darkwp"

  This is the darktable-side half only (specifications.md §1) - the
  WordPress companion plugin is a separate, not-yet-built project.
  darkwp works standalone today in fallback mode, uploading straight to
  WordPress core's POST /wp/v2/media (§4.8).
]]

local dt = require "darktable"
local du = require "lib/dtutils"

du.check_min_api_version("9.7.0", "darkwp")

local accounts_ui = require "darkwp/lib/accounts_ui"
local export_storage = require "darkwp/lib/export_storage"

local gettext = dt.gettext.gettext
local function _(msgid)
  return gettext(msgid)
end

local script_data = {}

script_data.metadata = {
  name = _("darkwp"),
  purpose = _("upload images from darktable directly to WordPress"),
  author = "dansart",
  help = "https://github.com/dansart/darkwp",
}

local darkwp = {}
darkwp.event_registered = false

local function install_module()
  accounts_ui.install()
  export_storage.install()
  accounts_ui.on_account_changed = export_storage.refresh_from_account
end

local function destroy()
  export_storage.destroy()
  accounts_ui.destroy()
end

local function restart()
  accounts_ui.show()
  export_storage.install() -- storage is fully torn down on destroy, unlike a lib - re-register it
end

local function show()
  accounts_ui.show()
end

if dt.gui.current_view().id == "lighttable" then
  install_module()
else
  if not darkwp.event_registered then
    dt.register_event(
      "darkwp", "view-changed",
      function(event, old_view, new_view)
        if new_view.name == "lighttable" and old_view.name == "darkroom" then
          install_module()
        end
      end
    )
    darkwp.event_registered = true
  end
end

script_data.destroy = destroy
script_data.restart = restart
script_data.destroy_method = "hide" -- the accounts lib can only be hidden, not unregistered (§3.11)
script_data.show = show

return script_data
