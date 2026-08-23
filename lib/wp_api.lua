--[[
  darkwp/lib/wp_api.lua

  WordPress-facing REST calls.

  Implemented against WordPress core's stable, documented REST API:
    - authenticate_and_check_capability()  GET /wp-json/wp/v2/users/me
    - probe_darkwp_info()                  GET /wp-json/darkwp/v1/info
                                            (status-code probe only - a
                                            404 vs. 200 check, per §2,
                                            does not depend on the shape
                                            of the companion plugin's
                                            response body)
    - upload_media_core()                  POST /wp-json/wp/v2/media

  And against the darkwp/v1 custom routes, per specifications.md §4.1:
    - get_info()          GET /wp-json/darkwp/v1/info - full response
    - upload_media_full()  POST /wp-json/darkwp/v1/media

  The exact shape used to distinguish an adapter-specific failure from a
  plain upload failure (§4.6 step 5) isn't pinned down by the spec beyond
  "must be distinguishable" - see the comment on upload_media_full() for
  the assumption this makes, to be adjusted once the companion plugin's
  real error shape is confirmed.
]]

local dt = require "darktable"
local http = require "darkwp/lib/http"
local json = require "darkwp/lib/json"

local wp_api = {}

-- ---------------------------------------------------------------------
-- core, stable WordPress REST API
-- ---------------------------------------------------------------------

--- GET /wp-json/wp/v2/users/me - confirms the credentials are valid and
-- that the account has the upload_files capability (specifications.md §3.2).
-- returns: ok, capabilities_or_nil, error_message_or_nil
function wp_api.authenticate_and_check_capability(account)
  local result = http.with_retry(function()
    return http.get(account, "/wp-json/wp/v2/users/me?context=edit")
  end)

  if not result.ok then
    return false, nil, result.transport_error or ("unreachable (status " .. tostring(result.status) .. ")")
  end

  if result.status ~= 200 then
    local decoded = json.decode(result.body)
    local msg = decoded and decoded.message or ("HTTP " .. result.status)
    return false, nil, msg
  end

  local user, decode_err = json.decode(result.body)
  if not user then
    return false, nil, "could not parse WordPress response: " .. tostring(decode_err)
  end

  local capabilities = user.capabilities or {}
  if not capabilities.upload_files then
    return false, nil, "this account does not have the upload_files capability"
  end

  return true, capabilities, nil
end

--- GET /wp-json/darkwp/v1/info - existence probe only.
-- specifications.md §2: "A 404 (route doesn't exist) means the
-- companion plugin isn't installed... A successful response means full
-- mode is available."
-- returns: mode ("full" | "fallback")
function wp_api.probe_darkwp_info(account)
  local result = http.get(account, "/wp-json/darkwp/v1/info")

  if result.ok and result.status == 200 then
    return "full"
  end

  -- any non-200 (404, or a transport error reaching this optional
  -- route) is treated as fallback mode - the companion plugin is
  -- either absent or unreachable, and darkwp still works without it.
  return "fallback"
end

--- POST /wp-json/wp/v2/media - fallback-mode / "WordPress Library"
-- upload path. `metadata` is { title, alt_text, caption, description }
-- (already variable-expanded - see export_storage.lua). No tags field:
-- specifications.md §3.1.2 - WP core media attachments have no native
-- tag taxonomy, by design.
-- returns: ok, media_id_or_nil, error_message_or_nil
function wp_api.upload_media_core(account, filepath, metadata)
  local fields = {
    title = metadata.title or "",
    alt_text = metadata.alt_text or "",
    caption = metadata.caption or "",
    description = metadata.description or "",
  }

  local result = http.with_retry(function()
    return http.post_multipart(account, "/wp-json/wp/v2/media", filepath, fields)
  end)

  if not result.ok then
    return false, nil, result.transport_error or "upload failed: no response from server"
  end

  if result.status < 200 or result.status >= 300 then
    local decoded = json.decode(result.body)
    local msg = decoded and decoded.message or ("HTTP " .. result.status)
    return false, nil, msg
  end

  local media, decode_err = json.decode(result.body)
  if not media then
    return false, nil, "upload succeeded but response could not be parsed: " .. tostring(decode_err)
  end

  return true, media.id, nil
end

-- ---------------------------------------------------------------------
-- darkwp/v1 custom routes
-- ---------------------------------------------------------------------

--- flatten a WP_Error-style `{ code = {message, ...}, ... }` errors
-- object (specifications.md §4.1) into one human-readable string.
function wp_api.flatten_errors(errors_obj)
  if not errors_obj then
    return "unknown error"
  end
  local parts = {}
  for _, messages in pairs(errors_obj) do
    if type(messages) == "table" then
      for _, msg in ipairs(messages) do
        parts[#parts + 1] = tostring(msg)
      end
    else
      parts[#parts + 1] = tostring(messages)
    end
  end
  if #parts == 0 then
    return "unknown error"
  end
  return table.concat(parts, "; ")
end

--- GET /wp-json/darkwp/v1/info - full response, specifications.md §4.1:
-- a slug-keyed map of adapters, each either { slug, name, meta } (a
-- working adapter, `meta` possibly empty - both valid) or
-- { errors, error_data } (a broken adapter - still returned, not
-- omitted, so darkwp can show it disabled rather than hide it).
--
-- A non-2xx status here is a *third*, distinct state from "404 =
-- fallback mode" / "2xx = full mode" (§2): the whole request failed
-- (e.g. 400/no_permission) independent of any single adapter, and
-- returns a flat (non-slug-keyed) { errors, error_data } body instead.
--
-- This is a live call every time it's invoked - it does not consult or
-- rely on an account's previously-cached `mode` field (§2: the mode
-- probe "runs once per login/account-switch", i.e. is meant to be
-- re-checked on every switch, not remembered indefinitely).
-- returns: info_table, nil, nil        - success (2xx)
--          nil, nil, "fallback"        - 404, companion plugin not present
--          nil, error_message, "error" - transport/parse failure, or a
--                                        non-2xx, non-404 flat error body
function wp_api.get_info(account)
  local result = http.with_retry(function()
    return http.get(account, "/wp-json/darkwp/v1/info")
  end)

  if not result.ok then
    return nil, result.transport_error or ("unreachable (status " .. tostring(result.status) .. ")"), "error"
  end

  if result.status == 404 then
    return nil, nil, "fallback"
  end

  local decoded, decode_err = json.decode(result.body)
  if not decoded then
    return nil, "could not parse WordPress response: " .. tostring(decode_err), "error"
  end

  if result.status < 200 or result.status >= 300 then
    return nil, wp_api.flatten_errors(decoded.errors), "error"
  end

  return decoded, nil, nil
end

--- POST /wp-json/darkwp/v1/media - gallery-target upload path, per
-- specifications.md §3.5/§4.1/§4.6. `fields` is the dynamic per-adapter
-- meta id -> value map from dynamic_fields.gather() (text values already
-- variable-expanded); `target` is the adapter's slug from /info.
--
-- specifications.md requires the response to let darktable distinguish
-- an adapter-specific failure from a plain upload failure (§4.6 step 5)
-- but doesn't pin down the exact field name to do it with. This assumes
-- a WP_Error-style body (`message`, and `data.scope == "adapter"` when
-- the failure happened inside the adapter's own upload_image() rather
-- than auth/validation before it) - adjust once the companion plugin's
-- real error shape is confirmed.
-- returns: ok, media_id_or_nil, error_message_or_nil, is_adapter_error
function wp_api.upload_media_full(account, filepath, fields, target)
  local post_fields = { target = target }
  for id, value in pairs(fields or {}) do
    post_fields[id] = value
  end

  local result = http.with_retry(function()
    return http.post_multipart(account, "/wp-json/darkwp/v1/media", filepath, post_fields)
  end)

  if not result.ok then
    return false, nil, result.transport_error or "upload failed: no response from server", false
  end

  if result.status < 200 or result.status >= 300 then
    local decoded = json.decode(result.body)
    local msg = decoded and (decoded.message or wp_api.flatten_errors(decoded.errors)) or ("HTTP " .. result.status)
    local is_adapter_error = decoded and decoded.data and decoded.data.scope == "adapter"
    return false, nil, msg, is_adapter_error or false
  end

  local media, decode_err = json.decode(result.body)
  if not media then
    return false, nil, "upload succeeded but response could not be parsed: " .. tostring(decode_err), false
  end

  return true, media.id, nil, false
end

return wp_api
