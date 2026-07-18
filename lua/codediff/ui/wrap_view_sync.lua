local M = {}

local measure_range = function(win, range)
  if range.end_row <= range.start_row then
    return 0
  end
  return vim.api.nvim_win_text_height(win, {
    start_row = range.start_row,
    start_vcol = 0,
    end_row = range.end_row - 1,
  }).all
end

local measure_prefix = function(win, consumed_lines, line_count)
  if consumed_lines <= 0 then
    return vim.api.nvim_win_text_height(win, { end_row = 0, end_vcol = 0 }).all
  end
  if consumed_lines >= line_count then
    return vim.api.nvim_win_text_height(win, {}).all
  end
  return vim.api.nvim_win_text_height(win, { end_row = consumed_lines, end_vcol = 0 }).all
end

local measure_skipped_rows = function(win, row, skipcol)
  if skipcol <= 0 then
    return 0
  end
  return vim.api.nvim_win_text_height(win, {
    start_row = row,
    start_vcol = 0,
    end_row = row,
    end_vcol = skipcol,
  }).all
end

local find_skipcol_upper_bound
find_skipcol_upper_bound = function(win, row, skipped_rows, candidate)
  if measure_skipped_rows(win, row, candidate) > skipped_rows then
    return candidate
  end
  return find_skipcol_upper_bound(win, row, skipped_rows, candidate * 2)
end

local find_skipcol = function(win, row, skipped_rows)
  if skipped_rows <= 0 then
    return 0
  end
  local low = 0
  local high = find_skipcol_upper_bound(win, row, skipped_rows, 1)
  while low < high do
    local middle = math.floor((low + high + 1) / 2)
    if measure_skipped_rows(win, row, middle) <= skipped_rows then
      low = middle
    else
      high = middle - 1
    end
  end
  return low
end

local capture_view = function(win)
  return vim.api.nvim_win_call(win, function()
    return {
      cursor = vim.api.nvim_win_get_cursor(win),
      view = vim.fn.winsaveview(),
    }
  end)
end

local restore_view = function(win, saved)
  if not saved or not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_win_call(win, function()
    pcall(vim.api.nvim_win_set_cursor, win, saved.cursor)
    vim.fn.winrestview(saved.view)
  end)
end

local get_view_offset = function(win)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  local prefix = measure_prefix(win, view.topline - 1, line_count)
  local skipped_rows = measure_skipped_rows(win, view.topline - 1, view.skipcol)
  return math.max(0, prefix - view.topfill + skipped_rows)
end

local get_target_view = function(win, offset, line_count)
  local low = 0
  local high = line_count
  while low < high do
    local middle = math.floor((low + high) / 2)
    if measure_prefix(win, middle, line_count) < offset then
      low = middle + 1
    else
      high = middle
    end
  end

  local prefix = measure_prefix(win, low, line_count)
  local view = {
    topline = math.min(low + 1, line_count),
    topfill = math.max(0, prefix - offset),
    skipcol = 0,
  }
  if low <= 0 then
    return view
  end

  local previous_prefix = measure_prefix(win, low - 1, line_count)
  local line_height = measure_range(win, { start_row = low - 1, end_row = low })
  if offset < previous_prefix or offset >= previous_prefix + line_height then
    return view
  end
  return {
    topline = low,
    topfill = 0,
    skipcol = find_skipcol(win, low - 1, offset - previous_prefix),
  }
end

local sync_target = function(target_win, offset)
  local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(target_win))
  local target_view = get_target_view(target_win, offset, line_count)
  vim.api.nvim_win_call(target_win, function()
    local cursor = vim.api.nvim_win_get_cursor(target_win)
    vim.fn.winrestview(target_view)
    local view = vim.fn.winsaveview()
    pcall(vim.api.nvim_win_set_cursor, target_win, cursor)
    vim.fn.winrestview(view)
  end)
end

function M.capture(wins)
  local current_win = vim.api.nvim_get_current_win()
  local captured = { panes = {} }
  for _, win in ipairs(wins) do
    if win and vim.api.nvim_win_is_valid(win) then
      captured.panes[#captured.panes + 1] = { win = win, saved = capture_view(win) }
      if win == current_win then
        captured.source_win = win
      end
    end
  end
  return captured
end

function M.restore(captured)
  for _, pane in ipairs((captured and captured.panes) or {}) do
    restore_view(pane.win, pane.saved)
  end
end

function M.sync(group, source_win)
  if not group or not vim.api.nvim_win_is_valid(source_win) then
    return
  end
  local offset = get_view_offset(source_win)
  group.ignore_wins = group.ignore_wins or {}
  for _, pane in ipairs(group.panes) do
    if pane.win ~= source_win and vim.api.nvim_win_is_valid(pane.win) then
      group.ignore_wins[pane.win] = true
      sync_target(pane.win, offset)
    end
  end
end

return M
