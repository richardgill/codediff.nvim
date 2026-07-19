local M = {}

local layers = setmetatable({}, { __mode = "k" })
local window_layers = {}
local filler_line = { { string.rep("╱", 500), "CodeDiffFiller" } }

local is_supported = function()
  return type(vim.api.nvim__ns_set) == "function"
end

local get_state = function(layer)
  local state = layers[layer]
  if not state then
    error("invalid or destroyed display layer")
  end
  return state
end

local require_valid_window = function(win)
  if not vim.api.nvim_win_is_valid(win) then
    error("display layer requires a valid window")
  end
end

local clear_marks = function(state)
  local removed = vim.tbl_count(state.entries)
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, state.namespace, 0, -1)
  end
  state.entries = {}
  return removed
end

local scope = function(state, wins)
  if not is_supported() then
    error("window-scoped namespaces are unavailable")
  end
  vim.api.nvim__ns_set(state.namespace, { wins = wins })
end

local entries_equal = function(existing, entry)
  return existing.boundary_row == entry.boundary_row and existing.anchor_row == entry.anchor_row and existing.above == entry.above and existing.count == entry.count
end

local get_extmark_position = function(buf, entry)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local above = entry.boundary_row <= 0 or entry.above
  local default_row = above and math.min(entry.boundary_row, line_count - 1) or math.min(entry.boundary_row - 1, line_count - 1)
  return math.max(entry.anchor_row or default_row, 0), above
end

local build_virtual_lines = function(count)
  local virtual_lines = {}
  for _ = 1, count do
    virtual_lines[#virtual_lines + 1] = filler_line
  end
  return virtual_lines
end

local set_extmark = function(state, entry, id)
  local row, above = get_extmark_position(state.buf, entry)
  return vim.api.nvim_buf_set_extmark(state.buf, state.namespace, row, 0, {
    id = id,
    virt_lines = build_virtual_lines(entry.count),
    virt_lines_above = above,
    strict = false,
  })
end

function M._is_supported()
  return is_supported()
end

function M._owns_namespace(layer, namespace)
  local state = layers[layer]
  return state ~= nil and state.namespace == namespace
end

function M.create_layer(win)
  if not is_supported() then
    error("window-scoped namespaces are unavailable")
  end
  require_valid_window(win)
  if window_layers[win] then
    error("window already owns a display layer")
  end

  local layer = {}
  local state = {
    win = win,
    namespace = vim.api.nvim_create_namespace(""),
    entries = {},
  }
  scope(state, { win })
  layers[layer] = state
  window_layers[win] = layer
  return layer
end

function M.set_layer(layer, buf, entries)
  local state = get_state(layer)
  require_valid_window(state.win)
  if not vim.api.nvim_buf_is_valid(buf) then
    error("display layer requires a valid buffer")
  end

  scope(state, { state.win })
  local stats = { removed = 0, reused = 0, updated = 0 }
  if state.buf ~= buf then
    stats.removed = clear_marks(state)
    state.buf = buf
  end

  local desired = {}
  for _, entry in ipairs(entries) do
    if entry.count > 0 then
      if entry.key == nil or desired[entry.key] then
        error("display layer entries require unique keys")
      end
      desired[entry.key] = {
        boundary_row = entry.boundary_row,
        anchor_row = entry.anchor_row,
        above = entry.above == true,
        count = entry.count,
      }
    end
  end
  for key, entry in pairs(desired) do
    local existing = state.entries[key]
    if existing and entries_equal(existing, entry) then
      stats.reused = stats.reused + 1
    else
      entry.id = set_extmark(state, entry, existing and existing.id or nil)
      state.entries[key] = entry
      stats.updated = stats.updated + 1
    end
  end
  for key, existing in pairs(state.entries) do
    if not desired[key] then
      pcall(vim.api.nvim_buf_del_extmark, state.buf, state.namespace, existing.id)
      state.entries[key] = nil
      stats.removed = stats.removed + 1
    end
  end
  return stats
end

function M.clear_layer(layer)
  return clear_marks(get_state(layer))
end

function M.destroy_layer(layer)
  local state = layers[layer]
  if not state then
    return
  end

  clear_marks(state)
  pcall(scope, state, {})
  layers[layer] = nil
  if window_layers[state.win] == layer then
    window_layers[state.win] = nil
  end
end

return M
