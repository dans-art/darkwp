--[[
  darkwp/lib/json.lua

  Minimal hand-rolled JSON encode/decode, per specifications.md §3.4/§3.9:
  jq is not bundled on any target OS by default, and darkwp's payloads
  (account list, WP REST responses) are small and predictable enough not
  to need it.
]]

local json = {}

-- ---------------------------------------------------------------------
-- encode
-- ---------------------------------------------------------------------

local escape_map = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
}

local function encode_string(s)
  local out = s:gsub('[%c"\\]', function(c)
    return escape_map[c] or string.format('\\u%04x', c:byte())
  end)
  return '"' .. out .. '"'
end

local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  if n == 0 then return true end -- empty table encodes as []
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

local encode_value

local function encode_array(t)
  local parts = {}
  for i = 1, #t do
    parts[i] = encode_value(t[i])
  end
  return '[' .. table.concat(parts, ',') .. ']'
end

local function encode_object(t)
  local parts = {}
  for k, v in pairs(t) do
    parts[#parts + 1] = encode_string(tostring(k)) .. ':' .. encode_value(v)
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

encode_value = function(v)
  local t = type(v)
  if t == 'string' then
    return encode_string(v)
  elseif t == 'number' then
    return tostring(v)
  elseif t == 'boolean' then
    return v and 'true' or 'false'
  elseif t == 'nil' then
    return 'null'
  elseif t == 'table' then
    if is_array(v) then
      return encode_array(v)
    else
      return encode_object(v)
    end
  end
  error('json.encode: unsupported type ' .. t)
end

function json.encode(value)
  return encode_value(value)
end

-- ---------------------------------------------------------------------
-- decode
-- ---------------------------------------------------------------------

local function skip_ws(str, pos)
  local _, e = str:find('^%s*', pos)
  return e + 1
end

local decode_value

local function decode_error(str, pos, msg)
  error(string.format('json.decode: %s at position %d', msg, pos))
end

local function decode_string(str, pos)
  -- pos points at the opening quote
  local i = pos + 1
  local out = {}
  while true do
    local c = str:sub(i, i)
    if c == '' then
      decode_error(str, i, 'unterminated string')
    elseif c == '"' then
      return table.concat(out), i + 1
    elseif c == '\\' then
      local nc = str:sub(i + 1, i + 1)
      if nc == 'u' then
        local hex = str:sub(i + 2, i + 5)
        local code = tonumber(hex, 16) or 0
        if code < 0x80 then
          out[#out + 1] = string.char(code)
        elseif code < 0x800 then
          out[#out + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
        else
          out[#out + 1] = string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40))
        end
        i = i + 6
      else
        local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', ['n'] = '\n', ['r'] = '\r', ['t'] = '\t', ['b'] = '\b', ['f'] = '\f' }
        out[#out + 1] = map[nc] or nc
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

local function decode_number(str, pos)
  local s, e = str:find('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', pos)
  if not s then
    decode_error(str, pos, 'invalid number')
  end
  return tonumber(str:sub(s, e)), e + 1
end

local function decode_array(str, pos)
  local arr = {}
  local i = skip_ws(str, pos + 1)
  if str:sub(i, i) == ']' then
    return arr, i + 1
  end
  while true do
    local value
    value, i = decode_value(str, i)
    arr[#arr + 1] = value
    i = skip_ws(str, i)
    local c = str:sub(i, i)
    if c == ',' then
      i = skip_ws(str, i + 1)
    elseif c == ']' then
      return arr, i + 1
    else
      decode_error(str, i, "expected ',' or ']'")
    end
  end
end

local function decode_object(str, pos)
  local obj = {}
  local i = skip_ws(str, pos + 1)
  if str:sub(i, i) == '}' then
    return obj, i + 1
  end
  while true do
    if str:sub(i, i) ~= '"' then
      decode_error(str, i, 'expected string key')
    end
    local key
    key, i = decode_string(str, i)
    i = skip_ws(str, i)
    if str:sub(i, i) ~= ':' then
      decode_error(str, i, "expected ':'")
    end
    i = skip_ws(str, i + 1)
    local value
    value, i = decode_value(str, i)
    obj[key] = value
    i = skip_ws(str, i)
    local c = str:sub(i, i)
    if c == ',' then
      i = skip_ws(str, i + 1)
    elseif c == '}' then
      return obj, i + 1
    else
      decode_error(str, i, "expected ',' or '}'")
    end
  end
end

decode_value = function(str, pos)
  local i = skip_ws(str, pos)
  local c = str:sub(i, i)
  if c == '{' then
    return decode_object(str, i)
  elseif c == '[' then
    return decode_array(str, i)
  elseif c == '"' then
    return decode_string(str, i)
  elseif c == 't' and str:sub(i, i + 3) == 'true' then
    return true, i + 4
  elseif c == 'f' and str:sub(i, i + 4) == 'false' then
    return false, i + 5
  elseif c == 'n' and str:sub(i, i + 3) == 'null' then
    return nil, i + 4
  elseif c:match('[%-%d]') then
    return decode_number(str, i)
  else
    decode_error(str, i, 'unexpected character ' .. ('%q'):format(c))
  end
end

--- decode a JSON string into a Lua value.
-- returns `value, nil` on success, or `nil, error_message` on failure.
function json.decode(str)
  if type(str) ~= 'string' or str == '' then
    return nil, 'json.decode: empty input'
  end
  local ok, value_or_err, pos_or_nil = pcall(decode_value, str, 1)
  if not ok then
    return nil, value_or_err
  end
  return value_or_err, nil
end

return json
