--[[
  darkwp/lib/accounts_ui.lua

  The "darkwp accounts" lighttable module (specifications.md §3.2):
  login form, account list, row click / remove behavior.

  API-constraint notes (darktable's Lua widget set has no image/pixbuf
  widget and no custom CSS is allowed on darktable's own UI - §3.10):
    - the spec's "site favicon, falling back to a generic WordPress
      icon" is dropped - a row shows domain / username as plain text.
    - a "row" is a single button (its label composes domain / username
      / selected marker into one string) with a separate Remove button
      next to it, since box/label widgets have no click callback - only
      buttons do. This is how "click the row, not Remove" is achieved.

  Deviation from specifications.md §3.2, per direct user instruction:
  clicking a row only switches the active account and clears the login
  form below it - it does not load the clicked account's stored details
  into the form fields (the spec's "review or edit them" behavior).
]]

local dt = require "darktable"
local accounts = require "darkwp/lib/accounts"
local util = require "darkwp/lib/util"

local gettext = dt.gettext.gettext
local function _(msgid)
  return gettext(msgid)
end

local MODULE_NAME = "darkwp_accounts"

local acct_ui = {}
acct_ui.module_installed = false
acct_ui.on_account_changed = nil -- set by darkwp.lua to gallery_storage.refresh_from_account

-- ---------------------------------------------------------------------
-- widgets
-- ---------------------------------------------------------------------

local header_label = dt.new_widget("section_label") { label = _("login to wordpress.") }

local list_box = dt.new_widget("box") { orientation = "vertical" }

local url_entry = dt.new_widget("entry") {
  placeholder = _("https://example.com"),
  tooltip = _("your WordPress site address - must start with https://"),
}

local username_entry = dt.new_widget("entry") {
  placeholder = _("username"),
}

local password_entry = dt.new_widget("entry") {
  placeholder = _("application password"),
  is_password = true,
  tooltip = _("a WordPress Application Password - never your real account password"),
}

local insecure_checkbox = dt.new_widget("check_button") {
  label = _("allow insecure connections"),
  value = false,
  tooltip = _("skip TLS certificate validation for self-signed certificates (local dev sites). " ..
    "connections are always made over https:// - this never enables plain http."),
}

local login_error_label = dt.new_widget("label") { label = "" }

local login_button -- forward-declared, clicked_callback references on_login_clicked defined below

-- WordPress error messages sometimes carry HTML markup (e.g.
-- "<strong>Error:</strong> Unknown username..."), and the label widget
-- is single-line and does not wrap - clean and wrap before displaying,
-- otherwise long/marked-up messages get clipped at the panel edge.
local function set_form_error(msg)
  if msg and msg ~= "" then
    login_error_label.label = util.wrap_text(util.strip_html(msg), 40)
  else
    login_error_label.label = ""
  end
end

local function clear_form_fields()
  url_entry.text = ""
  username_entry.text = ""
  password_entry.text = ""
  insecure_checkbox.value = false
  set_form_error("")
end

-- ---------------------------------------------------------------------
-- account list rendering
-- ---------------------------------------------------------------------

local function host_from_url(url)
  return (url:gsub("^https?://", ""):gsub("/.*$", ""))
end

local function clear_list_box()
  for i = #list_box, 1, -1 do
    list_box[i] = nil
  end
end

local refresh -- forward declaration

-- clicking a row switches the active account; it does not load that
-- account's details into the login form below (the form is cleared
-- instead, ready for a fresh login).
local function select_account(index)
  accounts.set_active_index(index)
  clear_form_fields()
  refresh()
  if acct_ui.on_account_changed then
    acct_ui.on_account_changed()
  end
end

local function remove_account(index)
  accounts.remove_at(index)
  refresh()
  if acct_ui.on_account_changed then
    acct_ui.on_account_changed()
  end
end

function refresh()
  clear_list_box()

  local list = accounts.list()
  local active_index = accounts.get_active_index()

  header_label.label = (#list > 0) and _("select the account to use.") or _("login to wordpress.")

  for i, acct in ipairs(list) do
    local is_active = (i == active_index)
    local row_label = string.format("%s  \xE2\x80\x94  %s%s",
      host_from_url(acct.url), acct.username,
      is_active and ("   [" .. _("selected") .. "]") or "")

    local row_button = dt.new_widget("button") {
      label = row_label,
      clicked_callback = function()
        select_account(i)
      end,
    }

    local remove_button = dt.new_widget("button") {
      label = _("remove"),
      clicked_callback = function()
        remove_account(i)
      end,
    }

    local row = dt.new_widget("box") {
      orientation = "horizontal",
      row_button,
      remove_button,
    }

    table.insert(list_box, row)
  end

  list_box.visible = (#list > 0)
end

acct_ui.refresh = refresh

-- ---------------------------------------------------------------------
-- login
-- ---------------------------------------------------------------------

local function on_login_clicked()
  local fields = {
    url = url_entry.text,
    username = username_entry.text,
    app_password = password_entry.text,
    allow_insecure = insecure_checkbox.value,
  }

  set_form_error("")
  login_button.sensitive = false
  dt.print(_("darkwp: logging in..."))

  local ok, account, err, index = accounts.login(fields)

  login_button.sensitive = true

  if not ok then
    set_form_error(err)
    dt.print_log("[darkwp] login failed: " .. tostring(err))
    return
  end

  dt.print(string.format(_("darkwp: connected to %s (%s mode)"),
    host_from_url(account.url), account.mode))

  clear_form_fields()
  refresh()

  if acct_ui.on_account_changed then
    acct_ui.on_account_changed()
  end
end

login_button = dt.new_widget("button") {
  label = _("login"),
  clicked_callback = on_login_clicked,
}

-- ---------------------------------------------------------------------
-- assembly
-- ---------------------------------------------------------------------

local form_box = dt.new_widget("box") {
  orientation = "vertical",
  dt.new_widget("label") { label = _("wordpress address") },
  url_entry,
  dt.new_widget("label") { label = _("username") },
  username_entry,
  dt.new_widget("label") { label = _("application password") },
  password_entry,
  insecure_checkbox,
  login_button,
  login_error_label,
}

acct_ui.container = dt.new_widget("box") {
  orientation = "vertical",
  header_label,
  list_box,
  dt.new_widget("separator") {},
  form_box,
}

-- ---------------------------------------------------------------------
-- script_manager-compatible lifecycle (specifications.md §3.11)
-- ---------------------------------------------------------------------

function acct_ui.install()
  if not acct_ui.module_installed then
    dt.register_lib(
      MODULE_NAME,
      _("darkwp accounts"),
      true,  -- expandable
      false, -- resetable: explicitly false, §3.11 - the built-in reset
             -- button crashed during prototyping, so account management
             -- is handled entirely through each row's own Remove button.
      { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 99 } },
      acct_ui.container,
      nil,
      nil
    )
    acct_ui.module_installed = true
  end
  refresh()
end

function acct_ui.destroy()
  dt.gui.libs[MODULE_NAME].visible = false
end

function acct_ui.show()
  dt.gui.libs[MODULE_NAME].visible = true
end

return acct_ui
