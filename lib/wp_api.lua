--[[
  darkwp/lib/wp_api.lua

  WordPress-facing REST calls.

  Fully implemented against WordPress core's stable, documented REST API:
    - authenticate_and_check_capability()  GET /wp-json/wp/v2/users/me
    - probe_darkwp_info()                  GET /wp-json/darkwp/v1/info
                                            (status-code probe only - a
                                            404 vs. 200 check, per §2,
                                            does not depend on the shape
                                            of the companion plugin's
                                            response body)
    - upload_media_core()                  POST /wp-json/wp/v2/media

  NOT implemented yet, by explicit instruction: parsing/consuming the
  darkwp/v1/info response body and calling POST darkwp/v1/media. Those
  routes belong to the darkwp companion WordPress plugin, which is still
  being designed - the response/request shape isn't definitive yet, so
  wiring them up now would mean re-doing it once it is. The functions
  below are prepared (signature + call sites already wired from
  accounts.lua / export_storage.lua) but stubbed until that structure is
  settled - see get_info() and upload_media_full().
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
-- darkwp/v1 custom routes - STUBBED, see module comment above.
-- ---------------------------------------------------------------------

--- GET /wp-json/darkwp/v1/info - full response (targets/statuses/
-- modes/fields, per specifications.md §4.1). NOT YET IMPLEMENTED: the
-- companion plugin's response shape isn't finalized. Once it is, this
-- should call http.get(account, "/wp-json/darkwp/v1/info"), json.decode
-- the body, and return the parsed `targets` list - each gallery target
-- becomes its own darktable.register_storage() module (per direct user
-- instruction - see export_storage.lua's module comment), not an entry
-- in a shared destination selector.
function wp_api.get_info(account)
  dt.print_log("[darkwp] wp_api.get_info() called but not yet implemented - awaiting definitive darkwp/v1/info response structure")
  return nil, "not implemented: darkwp/v1/info response structure is not finalized yet"
end

--- POST /wp-json/darkwp/v1/media - gallery-target upload path, per
-- specifications.md §3.5/§4.1/§4.6. NOT YET IMPLEMENTED: the request
-- shape (how per-target dynamic fields, status, and tags are sent)
-- isn't finalized. Once it is, this should mirror upload_media_core()
-- but POST to darkwp/v1/media with the target id and its dynamic
-- fields included, and surface the response's adapter-vs-plain failure
-- distinction (§4.6 step 5) back to the caller.
function wp_api.upload_media_full(account, filepath, metadata, target)
  dt.print_log("[darkwp] wp_api.upload_media_full() called but not yet implemented - awaiting definitive darkwp/v1/media request/response structure")
  return false, nil, "not implemented: darkwp/v1/media request structure is not finalized yet"
end

return wp_api
