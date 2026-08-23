--[[
  darkwp/lib/util.lua

  Small OS-branching helpers that sit on top of the bundled `dtutils`
  library (lib/dtutils, lib/dtutils.file, lib/dtutils.string,
  lib/dtutils.system) that ships with darktable. specifications.md §3.9
  explicitly allows relying on that community helper for variable
  expansion / shell escaping / temp files instead of reimplementing them,
  so darkwp does not duplicate what dtutils already provides - this
  module only adds the bits dtutils doesn't have (netrc permissions,
  curl/jq presence checks surfaced as user messages).
]]

local dt = require "darktable"
local df = require "lib/dtutils.file"
local ds = require "lib/dtutils.string"
local dsys = require "lib/dtutils.system"

local gettext = dt.gettext.gettext
local function _(msgid)
  return gettext(msgid)
end

local util = {}

util.PS = dt.configuration.running_os == "windows" and "\\" or "/"
util.is_windows = dt.configuration.running_os == "windows"

-- ---------------------------------------------------------------------
-- temp directory / files
-- ---------------------------------------------------------------------

--- resolve a usable temp directory, preferring darktable's own configured
-- cache/tmp path (dt.configuration.tmp_dir) and falling back to the
-- platform's env vars per specifications.md §3.9.
function util.tmp_dir()
  if dt.configuration.tmp_dir and dt.configuration.tmp_dir ~= "" then
    return dt.configuration.tmp_dir
  end
  if util.is_windows then
    return os.getenv("TEMP") or os.getenv("TMP") or "."
  end
  return os.getenv("TMPDIR") or "/tmp"
end

--- create a new empty temp file and return its path, or nil + message.
function util.create_tmp_file(suffix)
  local path = df.create_tmp_file()
  if not path then
    return nil, "could not create a temporary file"
  end
  if suffix and suffix ~= "" then
    local renamed = path .. suffix
    if df.file_move(path, renamed) then
      path = renamed
    end
  end
  return path
end

--- restrict a file to owner-only read/write.
-- POSIX: chmod 600. Windows: no-op - the per-user temp directory is
-- already access-restricted (specifications.md §3.9).
function util.restrict_file_permissions(path)
  if util.is_windows then
    return true
  end
  local ok = dsys.external_command("chmod 600 " .. df.sanitize_filename(path))
  return ok == 0 or ok == true
end

function util.remove_file(path)
  if path then
    os.remove(path)
  end
end

-- ---------------------------------------------------------------------
-- shell escaping / variable expansion - thin wrappers over dtutils so
-- call sites in the rest of darkwp read as darkwp.util.*, not a mix of
-- dtutils namespaces.
-- ---------------------------------------------------------------------

function util.shell_escape(str)
  return ds.sanitize(str or "")
end

--- expand darktable's $(...) variable placeholders against a given image.
-- delegates to lib/dtutils.string, which is exactly the "community
-- dtutils variable-expansion helper" specifications.md §3.1.2 points to.
function util.expand_variables(image, sequence, str)
  if not str or str == "" then
    return ""
  end
  local ok, result = pcall(ds.substitute, image, sequence, str)
  if not ok then
    dt.print_log("[darkwp] variable expansion failed for '" .. tostring(str) .. "': " .. tostring(result))
    return str
  end
  return result
end

-- ---------------------------------------------------------------------
-- required external tools
-- ---------------------------------------------------------------------

local checked_curl = nil

--- check for curl on the PATH once, memoized, per specifications.md §3.9
-- ("check for curl on the PATH at module load and surface a clear
-- 'curl not found' message rather than failing during an upload").
function util.curl_path()
  if checked_curl == nil then
    checked_curl = df.check_if_bin_exists("curl") or false
  end
  return checked_curl or nil
end

function util.ensure_curl()
  local path = util.curl_path()
  if not path then
    dt.print(_("darkwp: curl was not found on the PATH - uploads are disabled"))
    return false
  end
  return true
end

-- ---------------------------------------------------------------------
-- text display helpers - darktable's Lua "label" widget is single-line
-- and does not wrap, so messages of unpredictable length (WordPress
-- error text in particular) need cleaning up before they're put in one.
-- ---------------------------------------------------------------------

local HTML_ENTITIES = {
  ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">",
  ["&quot;"] = '"', ["&apos;"] = "'", ["&#039;"] = "'", ["&nbsp;"] = " ",
}

--- strip HTML tags and decode common entities. WordPress REST error
-- messages are frequently wrapped in markup (e.g.
-- "<strong>Error:</strong> Unknown username...") that has no business
-- reaching a plain-text darktable widget.
function util.strip_html(str)
  if not str or str == "" then
    return str
  end
  local out = str:gsub("<[^>]*>", "")
  for entity, replacement in pairs(HTML_ENTITIES) do
    out = out:gsub(entity, replacement)
  end
  return out:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

--- turn an adapter slug (e.g. "dummy_gall") into a human-readable label
-- ("Dummy Gall") - the fallback label for a broken adapter that has no
-- `name` of its own (specifications.md §4.1: "don't fabricate a
-- friendlier name than what the endpoint actually provides").
function util.humanize_slug(slug)
  local spaced = (slug or ""):gsub("[_%-]+", " ")
  return (spaced:gsub("(%a)([%w']*)", function(first, rest)
    return first:upper() .. rest:lower()
  end))
end

--- greedy word-wrap into a "\n"-joined string, for single-line label
-- widgets that would otherwise clip long text at the panel edge.
function util.wrap_text(str, width)
  if not str or str == "" then
    return str
  end
  width = width or 42
  local lines = {}
  local line = ""
  for word in str:gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      table.insert(lines, line)
      line = word
    end
  end
  if line ~= "" then
    table.insert(lines, line)
  end
  return table.concat(lines, "\n")
end

return util
