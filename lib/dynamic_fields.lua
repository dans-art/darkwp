--[[
  darkwp/lib/dynamic_fields.lua

  Builds a widget box from a gallery adapter's `meta` array
  (specifications.md §3.1.3/§4.1) and gives back a small handle to read
  it back at export time:
    - box       - the widget to hand to darktable.register_storage()
    - gather()  - id -> resolved value, for every field, per image
    - validate()- required-and-currently-visible fields are filled in

  Field types: "text" (entry, placeholder pre-filled and resolved via
  darktable's variable expansion, same as the Library target's fields;
  tooltip lists every $(...) placeholder since the Lua API exposes no
  equivalent of the export module's "$" popup button), "select"
  (combobox, options list is the source of truth for valid values),
  "checkbox" (check_button, boolean default).

  show_when (`{ field, compare, value }`) hides/shows a field based on
  another field's current value. Only "select" and "checkbox" fields can
  be show_when *drivers* - darktable's lua_entry widget has no
  changed_callback (no "text changed" event to react to), so a
  show_when referencing a text field is left always-visible rather than
  silently misbehaving.
]]

local dt = require "darktable"
local util = require "darkwp/lib/util"

local dynamic_fields = {}

local function build_select(field)
  local options = field.options or {}
  local labels = {}
  local default_index = 1
  for i, opt in ipairs(options) do
    labels[i] = opt.label or opt.value
    if field.default ~= nil and opt.value == field.default then
      default_index = i
    end
  end
  if #labels == 0 then
    labels[1] = ""
  end
  return dt.new_widget("combobox") {
    label = field.label or field.id,
    tooltip = field.hint,
    editable = false,
    value = default_index,
    table.unpack(labels),
  }
end

local function build_checkbox(field)
  return dt.new_widget("check_button") {
    label = field.label or field.id,
    tooltip = field.hint,
    value = field.default == true,
  }
end

local function build_text(field)
  local tooltip = util.variable_hint()
  if field.hint and field.hint ~= "" then
    tooltip = field.hint .. "\n\n" .. tooltip
  end
  return dt.new_widget("entry") {
    text = field.placeholder or "",
    tooltip = tooltip,
  }
end

--- build the field box + accessors for one adapter's `meta` array.
-- `meta` may be an empty table (specifications.md §4.1/§3.1.3 - a valid,
-- supported state: render the destination with nothing below it).
function dynamic_fields.build(meta)
  meta = meta or {}

  local entries = {}
  local by_id = {}
  local dependents = {} -- driver field id -> array of dependent entries
  local rows = {}

  for _, field in ipairs(meta) do
    local widget
    if field.type == "select" then
      widget = build_select(field)
    elseif field.type == "checkbox" then
      widget = build_checkbox(field)
    else
      widget = build_text(field)
    end

    local row = dt.new_widget("box") {
      orientation = "vertical",
      dt.new_widget("label") { label = field.label or field.id },
      widget,
    }

    local entry = { id = field.id, type = field.type, field = field, widget = widget, row = row }
    entries[#entries + 1] = entry
    by_id[field.id] = entry
    rows[#rows + 1] = row

    if field.show_when and field.show_when.field then
      local list = dependents[field.show_when.field] or {}
      list[#list + 1] = entry
      dependents[field.show_when.field] = list
    end
  end

  local function driver_current_value(driver)
    if driver.type == "select" then
      local idx = driver.widget.selected
      local opt = driver.field.options and idx and driver.field.options[idx]
      return opt and opt.value
    elseif driver.type == "checkbox" then
      return driver.widget.value and true or false
    end
    return nil
  end

  local function evaluate(entry)
    local show_when = entry.field.show_when
    if not show_when then
      return true
    end
    local driver = by_id[show_when.field]
    if not driver or driver.type == "text" then
      -- unknown driver, or a text field (no change event to react to
      -- in the first place) - fail open rather than hide the field
      -- permanently.
      return true
    end
    local current = driver_current_value(driver)
    if show_when.compare == "!=" then
      return current ~= show_when.value
    end
    return current == show_when.value
  end

  local function refresh_visibility()
    for _, entry in ipairs(entries) do
      entry.row.visible = evaluate(entry)
    end
  end

  for driver_id, _ in pairs(dependents) do
    local driver = by_id[driver_id]
    if driver then
      if driver.type == "select" then
        driver.widget.changed_callback = refresh_visibility
      elseif driver.type == "checkbox" then
        driver.widget.clicked_callback = refresh_visibility
      end
    end
  end

  refresh_visibility()

  local function gather(image, sequence)
    local data = {}
    for _, entry in ipairs(entries) do
      if entry.type == "select" then
        local idx = entry.widget.selected
        local opt = entry.field.options and idx and entry.field.options[idx]
        data[entry.id] = opt and opt.value or ""
      elseif entry.type == "checkbox" then
        data[entry.id] = entry.widget.value and true or false
      else
        data[entry.id] = util.expand_variables(image, sequence, entry.widget.text)
      end
    end
    return data
  end

  local function validate()
    local missing = {}
    for _, entry in ipairs(entries) do
      if entry.field.required and entry.row.visible then
        local empty
        if entry.type == "select" then
          empty = not entry.widget.selected or entry.widget.selected == 0
        elseif entry.type == "checkbox" then
          empty = false -- a checkbox is never "empty" - it's always true or false
        else
          empty = entry.widget.text == nil or entry.widget.text == ""
        end
        if empty then
          missing[#missing + 1] = entry.field.label or entry.id
        end
      end
    end
    return (#missing == 0), missing
  end

  return {
    box = dt.new_widget("box") { orientation = "vertical", table.unpack(rows) },
    gather = gather,
    validate = validate,
  }
end

return dynamic_fields
