--[[
  darkwp/lib/http.lua

  curl wrapper for talking to a WordPress site. Implements the security
  requirements from specifications.md §3.4:
    - credentials go through --netrc-file, never --user user:pass
      (which would be visible in `ps aux`)
    - always connects over https://; "allow insecure" only ever adds
      curl --insecure (skip cert validation), it never permits
      falling back to http://
    - every value interpolated into the shell command is escaped via
      darkwp.util.shell_escape (dtutils.string.sanitize)

  This module is transport-only and generic: it knows nothing about
  WordPress core's REST API (wp-json/wp/v2/...) vs. darkwp's own custom
  routes (wp-json/darkup/v1/...) - both are built on top of it in
  wp_api.lua.
]]

local dt = require "darktable"
local df = require "lib/dtutils.file"
local dsys = require "lib/dtutils.system"
local util = require "darkwp/lib/util"

local http = {}

local DEFAULT_TIMEOUT_SECS = 30
local CONNECT_TIMEOUT_SECS = 10

-- ---------------------------------------------------------------------
-- per-run batch id - sent as a header on every request below so the
-- receiving site can tell which images were uploaded together in one
-- export run. Rotated once per run by each storage's initialize()
-- callback (gallery_storage.lua), not per individual image.
-- ---------------------------------------------------------------------

local current_batch_id = nil

function http.rotate_batch_id()
  current_batch_id = util.new_batch_id()
  return current_batch_id
end

-- ---------------------------------------------------------------------
-- netrc credential file
-- ---------------------------------------------------------------------

--- curl's netrc matching is by hostname only (no scheme, no port), so
-- pull just the host out of a https://host[:port]/... URL.
local function host_from_url(url)
  local host = url:match("^https?://([^/]+)")
  if not host then
    return nil
  end
  -- strip a port, netrc "machine" entries don't carry one
  host = host:gsub(":%d+$", "")
  return host
end

--- netrc field values can't contain literal whitespace; application
-- passwords are space-separated groups (xxxx xxxx xxxx xxxx xxxx xxxx)
-- so quote the value in double quotes, which netrc supports, and escape
-- any embedded double quote or backslash.
local function netrc_quote(value)
  local escaped = tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. escaped .. '"'
end

local function write_netrc_file(host, username, password)
  local path, err = util.create_tmp_file(".netrc")
  if not path then
    return nil, err
  end

  local f, ferr = io.open(path, "w")
  if not f then
    util.remove_file(path)
    return nil, tostring(ferr)
  end
  f:write(string.format(
    "machine %s\n\tlogin %s\n\tpassword %s\n",
    host, netrc_quote(username), netrc_quote(password)))
  f:close()

  if not util.restrict_file_permissions(path) then
    dt.print_log("[darkwp] warning: could not restrict permissions on netrc temp file " .. path)
  end

  return path
end

-- ---------------------------------------------------------------------
-- curl invocation
-- ---------------------------------------------------------------------

--- run curl, capturing the HTTP status code and response body.
-- `args` is a table of already-shell-escaped curl arguments (strings).
-- returns a result table: { ok, status, body, transport_error }
--   ok              - true if we got any HTTP response at all
--   status          - integer HTTP status code (0 if no response)
--   body            - response body as a string ("" if none)
--   transport_error - set (and ok=false) on curl-level failure
--                     (couldn't connect, timed out, etc.) as opposed to
--                     an HTTP-level error status
local function run_curl(account, args)
  if not util.ensure_curl() then
    return { ok = false, status = 0, body = "", transport_error = "curl not found" }
  end

  local host = host_from_url(account.url)
  if not host then
    return { ok = false, status = 0, body = "", transport_error = "invalid site URL" }
  end
  if not account.url:match("^https://") then
    -- specifications.md §3.4: always connect over https, regardless of
    -- the "allow insecure connections" setting.
    return { ok = false, status = 0, body = "", transport_error = "refusing non-https URL" }
  end

  local netrc_path, netrc_err = write_netrc_file(host, account.username, account.app_password)
  if not netrc_path then
    return { ok = false, status = 0, body = "", transport_error = "could not write credential file: " .. tostring(netrc_err) }
  end

  local body_path = util.create_tmp_file(".body")

  local cmd_parts = {
    "curl", "-sS",
    "-m", tostring(DEFAULT_TIMEOUT_SECS),
    "--connect-timeout", tostring(CONNECT_TIMEOUT_SECS),
    "--netrc-file", df.sanitize_filename(netrc_path),
    "-o", df.sanitize_filename(body_path),
    "-w", "%{http_code}",
  }

  if account.allow_insecure then
    table.insert(cmd_parts, "--insecure")
  end

  if current_batch_id then
    table.insert(cmd_parts, "-H")
    table.insert(cmd_parts, util.shell_escape("X-Darkup-Batch: " .. current_batch_id))
  end

  for _, a in ipairs(args) do
    table.insert(cmd_parts, a)
  end

  local cmd = table.concat(cmd_parts, " ")
  dt.print_log("[darkwp] curl: " .. cmd:gsub(df.sanitize_filename(netrc_path), "<netrc>"))

  local handle = io.popen(cmd)
  local status_str = handle and handle:read("*a") or ""
  local close_ok = true
  if handle then
    close_ok = handle:close()
  end

  util.remove_file(netrc_path)

  local body = ""
  local bf = io.open(body_path, "r")
  if bf then
    body = bf:read("*a") or ""
    bf:close()
  end
  util.remove_file(body_path)

  local status = tonumber((status_str or ""):match("%d+")) or 0

  local logged_body = body
  if #logged_body > 2000 then
    logged_body = logged_body:sub(1, 2000) .. "... (truncated)"
  end
  dt.print_log("[darkwp] curl response: status=" .. tostring(status) .. " body=" .. logged_body)

  if status == 0 then
    return { ok = false, status = 0, body = body, transport_error = "no response (network error or timeout)" }
  end

  return { ok = true, status = status, body = body }
end

-- ---------------------------------------------------------------------
-- public request helpers
-- ---------------------------------------------------------------------

--- GET a URL, no request body. Used for both core WP endpoints and the
-- darkup/v1/info existence probe (§2).
function http.get(account, path)
  local url = account.url:gsub("/+$", "") .. path
  return run_curl(account, { "-X", "GET", util.shell_escape(url) })
end

--- POST multipart/form-data: one file field plus arbitrary text fields.
-- `fields` is a table of { name = value } string pairs.
function http.post_multipart(account, path, filepath, fields)
  local url = account.url:gsub("/+$", "") .. path
  local args = { "-X", "POST" }

  table.insert(args, "-F")
  table.insert(args, util.shell_escape("file=@" .. filepath))

  for name, value in pairs(fields or {}) do
    table.insert(args, "-F")
    table.insert(args, util.shell_escape(name .. "=" .. tostring(value)))
  end

  table.insert(args, util.shell_escape(url))

  return run_curl(account, args)
end

--- one automatic retry on transport-level failure only, with a short
-- backoff, per specifications.md §3.7 ("no automatic retry on 4xx
-- responses - those are configuration/auth problems, not transient").
function http.with_retry(request_fn)
  local result = request_fn()
  if not result.ok and result.transport_error then
    dt.print_log("[darkwp] transport error, retrying once: " .. tostring(result.transport_error))
    dt.control.sleep(1500)
    result = request_fn()
  end
  return result
end

return http
