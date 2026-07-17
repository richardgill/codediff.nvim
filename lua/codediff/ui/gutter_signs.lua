local M = {}

local config = require("codediff.config")

local namespace = vim.api.nvim_create_namespace("codediff-gutter-signs")
local supports_native_signs = vim.fn.has("nvim-0.9") == 1
local default_move_priority = 250
local default_options = {
  insert_text = " +",
  delete_text = " -",
  highlight_numbers = true,
  changed_priority = 100,
}
local signs = {
  original = {
    text_option = "delete_text",
    hl_group = "CodeDiffGutterDelete",
    number_hl_group = "CodeDiffGutterDeleteNumber",
  },
  modified = {
    text_option = "insert_text",
    hl_group = "CodeDiffGutterInsert",
    number_hl_group = "CodeDiffGutterInsertNumber",
  },
  unchanged = { text = "  ", hl_group = "Normal" },
  move_single = { text = "─", hl_group = "CodeDiffMoveTo" },
  move_first = { text = "┌", hl_group = "CodeDiffMoveTo" },
  move_middle = { text = "│", hl_group = "CodeDiffMoveTo" },
  move_last = { text = "└", hl_group = "CodeDiffMoveTo" },
}

local get_options = function()
  local options = config.options.diff.gutter_signs
  if type(options) ~= "table" then
    return nil
  end
  if not supports_native_signs then
    vim.notify_once("[codediff] diff.gutter_signs requires Neovim 0.9 or newer", vim.log.levels.WARN)
    return nil
  end
  return vim.tbl_extend("force", default_options, options)
end

local get_changed_sign = function(side, options)
  local sign = signs[side]
  return {
    text = options[sign.text_option],
    hl_group = sign.hl_group,
    number_hl_group = options.highlight_numbers and sign.number_hl_group or nil,
  }
end

local set_sign_range = function(bufnr, range, sign, priority)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not range or range.end_line <= range.start_line then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_row = math.max(range.start_line - 1, 0)
  local end_row = math.min(range.end_line - 1, line_count)
  if end_row <= start_row then
    return
  end

  vim.api.nvim_buf_set_extmark(bufnr, namespace, start_row, 0, {
    end_row = end_row - 1,
    end_col = 0,
    sign_text = sign.text,
    sign_hl_group = sign.hl_group,
    number_hl_group = sign.number_hl_group,
    priority = priority,
    strict = false,
  })
end

local set_whole_buffer_sign = function(bufnr, sign, priority, tracks_appends)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_set_extmark(bufnr, namespace, 0, 0, {
    end_row = tracks_appends and line_count or line_count - 1,
    end_col = 0,
    end_right_gravity = tracks_appends,
    sign_text = sign.text,
    sign_hl_group = sign.hl_group,
    number_hl_group = sign.number_hl_group,
    priority = priority,
    strict = false,
  })
end

M.clear_buffer = function(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
end

M.set_changed_ranges = function(left_bufnr, right_bufnr, changes)
  M.clear_buffer(left_bufnr)
  M.clear_buffer(right_bufnr)

  local options = get_options()
  if not options then
    return
  end

  if options.unchanged_priority then
    set_whole_buffer_sign(left_bufnr, signs.unchanged, options.unchanged_priority, false)
    set_whole_buffer_sign(right_bufnr, signs.unchanged, options.unchanged_priority, false)
  end

  local priority = options.changed_priority
  local original_sign = get_changed_sign("original", options)
  local modified_sign = get_changed_sign("modified", options)
  for _, change in ipairs(changes or {}) do
    set_sign_range(left_bufnr, change.original, original_sign, priority)
    set_sign_range(right_bufnr, change.modified, modified_sign, priority)
  end
end

M.set_move_range = function(bufnr, first, last)
  local options = get_options()
  if not supports_native_signs or last < first then
    return
  end

  local priority = options and options.changed_priority or default_move_priority
  if first == last then
    set_sign_range(bufnr, { start_line = first, end_line = first + 1 }, signs.move_single, priority)
    return
  end

  set_sign_range(bufnr, { start_line = first, end_line = first + 1 }, signs.move_first, priority)
  set_sign_range(bufnr, { start_line = first + 1, end_line = last }, signs.move_middle, priority)
  set_sign_range(bufnr, { start_line = last, end_line = last + 1 }, signs.move_last, priority)
end

M.set_whole_file = function(bufnr, side)
  M.clear_buffer(bufnr)

  local options = get_options()
  if not options then
    return
  end

  set_whole_buffer_sign(bufnr, get_changed_sign(side, options), options.changed_priority, true)
end

return M
