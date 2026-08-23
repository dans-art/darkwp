--[[
  darkwp/lib/accounts.lua

  Account list data model + login orchestration.
  specifications.md §3.2 (accounts module) and §3.3 (credential storage).

  Persistence: dt.preferences keys are fixed/named rather than dynamic,
  so the whole account list is stored as one JSON-encoded string under a
  single preference key (§3.3). Each account is
    { url, username, app_password, allow_insecure, mode }
  mode is "full" | "fallback", set on login by probing darkwp/v1/info
  (§2). Credentials are plain text for v1 (§3.3, hardening deferred to
  §7) - never printed, never included in log output or error messages.
]]

local dt = require "darktable"
local json = require "darkwp/lib/json"
local wp_api = require "darkwp/lib/wp_api"

local PREF_SCRIPT = "darkwp"
local PREF_ACCOUNTS_KEY = "accounts"
local PREF_ACTIVE_KEY = "active_index"

local accounts = {}

-- ---------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------

function accounts.list()
  local raw = dt.preferences.read(PREF_SCRIPT, PREF_ACCOUNTS_KEY, "string")
  if not raw or raw == "" then
    return {}
  end
  local decoded, err = json.decode(raw)
  if not decoded then
    dt.print_error("[darkwp] could not parse stored account list: " .. tostring(err))
    return {}
  end
  return decoded
end

function accounts.save(list)
  dt.preferences.write(PREF_SCRIPT, PREF_ACCOUNTS_KEY, "string", json.encode(list))
end

function accounts.get_active_index()
  local idx = dt.preferences.read(PREF_SCRIPT, PREF_ACTIVE_KEY, "integer")
  if not idx or idx < 1 then
    return nil
  end
  local list = accounts.list()
  if idx > #list then
    return nil
  end
  return idx
end

function accounts.set_active_index(index)
  dt.preferences.write(PREF_SCRIPT, PREF_ACTIVE_KEY, "integer", index or 0)
end

function accounts.get_active()
  local idx = accounts.get_active_index()
  if not idx then
    return nil, nil
  end
  return accounts.list()[idx], idx
end

-- ---------------------------------------------------------------------
-- list manipulation
-- ---------------------------------------------------------------------

--- find an existing account by url+username (used to decide whether a
-- login-form submission should update an existing row in place rather
-- than create a duplicate - specifications.md §3.2 "row click behavior").
function accounts.find_index(url, username)
  local list = accounts.list()
  for i, a in ipairs(list) do
    if a.url == url and a.username == username then
      return i
    end
  end
  return nil
end

--- insert or overwrite an account at a specific index (index=nil appends).
-- returns the index the account now lives at.
function accounts.upsert(fields, at_index)
  local list = accounts.list()
  local index = at_index or accounts.find_index(fields.url, fields.username)
  local entry = {
    url = fields.url,
    username = fields.username,
    app_password = fields.app_password,
    allow_insecure = fields.allow_insecure and true or false,
    mode = fields.mode or "fallback",
  }
  if index and list[index] then
    list[index] = entry
  else
    list[#list + 1] = entry
    index = #list
  end
  accounts.save(list)
  return index
end

--- remove the account at `index`. If it was the active account, falls
-- back to another remaining account (if any), otherwise clears the
-- active pointer (empty state) - specifications.md §3.2.
function accounts.remove_at(index)
  local list = accounts.list()
  if not list[index] then
    return
  end
  table.remove(list, index)
  accounts.save(list)

  local active_idx = accounts.get_active_index()
  if active_idx == index then
    if #list > 0 then
      accounts.set_active_index(1)
    else
      accounts.set_active_index(nil)
    end
  elseif active_idx and active_idx > index then
    accounts.set_active_index(active_idx - 1)
  end
end

-- ---------------------------------------------------------------------
-- login
-- ---------------------------------------------------------------------

--- validate + authenticate + detect mode + persist, per specifications.md
-- §3.2. `at_index`, when given, means "update this existing row" (the
-- row-click-then-resubmit flow) rather than match-or-append by url/username.
-- returns: ok, account_or_nil, error_message_or_nil, index_or_nil
function accounts.login(fields, at_index)
  if not fields.url or fields.url == "" or
     not fields.username or fields.username == "" or
     not fields.app_password or fields.app_password == "" then
    return false, nil, "login failed: please fill out all the fields", nil
  end

  if not fields.url:match("^https://") then
    return false, nil, "wordpress address must start with https://", nil
  end

  local candidate = {
    url = fields.url,
    username = fields.username,
    app_password = fields.app_password,
    allow_insecure = fields.allow_insecure,
  }

  local ok, _capabilities, auth_err = wp_api.authenticate_and_check_capability(candidate)
  if not ok then
    return false, nil, auth_err, nil
  end

  candidate.mode = wp_api.probe_darkwp_info(candidate)

  local index = accounts.upsert(candidate, at_index)
  accounts.set_active_index(index)

  return true, candidate, nil, index
end

return accounts
