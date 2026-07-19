local M = {}

local anchors = setmetatable({}, { __mode = "k" })
local metrics = {
  direct_count = 0,
  fallback_count = 0,
  direct_text_height_calls = 0,
  fallback_text_height_calls = 0,
}
local text_height_calls = 0

local text_height = function(win, opts)
  text_height_calls = text_height_calls + 1
  return vim.api.nvim_win_text_height(win, opts)
end

local measure_range = function(win, range)
  if range.end_row <= range.start_row then
    return 0
  end
  return text_height(win, {
    start_row = range.start_row,
    start_vcol = 0,
    end_row = range.end_row - 1,
  }).all
end

local measure_prefix = function(win, consumed_lines, line_count)
  if consumed_lines <= 0 then
    return text_height(win, { end_row = 0, end_vcol = 0 }).all
  end
  if consumed_lines >= line_count then
    return text_height(win, {}).all
  end
  return text_height(win, { end_row = consumed_lines, end_vcol = 0 }).all
end

local measure_skipped_rows = function(win, row, skipcol)
  if skipcol <= 0 then
    return 0
  end
  return text_height(win, {
    start_row = row,
    start_vcol = 0,
    end_row = row,
    end_vcol = skipcol,
  }).all
end

local find_skipcol = function(win, row, skipped_rows)
  if skipped_rows <= 0 then
    return 0
  end
  local low = 0
  local high = 1
  while measure_skipped_rows(win, row, high) <= skipped_rows do
    high = high * 2
  end
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

local get_fallback_target_view = function(win, offset, line_count)
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

local resolve_endpoint_view = function(win, offset, line_count, endpoint)
  if endpoint.end_vcol <= 0 or endpoint.end_row < 0 or endpoint.end_row >= line_count then
    return nil
  end
  if endpoint.end_row == line_count - 1 and offset >= endpoint.all then
    return { topline = line_count, topfill = 0, skipcol = 0 }
  end

  local prefix = measure_prefix(win, endpoint.end_row, line_count)
  if offset < prefix then
    return nil
  end
  if offset == prefix then
    return { topline = endpoint.end_row + 1, topfill = 0, skipcol = 0 }
  end

  local skipped_rows = offset - prefix
  if measure_skipped_rows(win, endpoint.end_row, endpoint.end_vcol) ~= skipped_rows then
    return nil
  end
  local line_height = measure_range(win, { start_row = endpoint.end_row, end_row = endpoint.end_row + 1 })
  if skipped_rows < line_height then
    return { topline = endpoint.end_row + 1, topfill = 0, skipcol = endpoint.end_vcol }
  end
  if skipped_rows > line_height or endpoint.end_row == line_count - 1 then
    return nil
  end

  local next_prefix = measure_prefix(win, endpoint.end_row + 1, line_count)
  if next_prefix ~= offset then
    return nil
  end
  return { topline = endpoint.end_row + 2, topfill = 0, skipcol = 0 }
end

local get_direct_target_view = function(win, offset, line_count)
  if offset == 0 then
    return { topline = 1, topfill = measure_prefix(win, 0, line_count), skipcol = 0 }
  end

  local target = resolve_endpoint_view(win, offset, line_count, text_height(win, { max_height = offset }))
  if target or offset == 1 then
    return target
  end
  return resolve_endpoint_view(win, offset, line_count, text_height(win, { max_height = offset - 1 }))
end

function M.capture(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local anchor = {}
  anchors[anchor] = vim.api.nvim_win_call(win, function()
    return {
      cursor = vim.api.nvim_win_get_cursor(win),
      view = vim.fn.winsaveview(),
    }
  end)
  return anchor
end

function M.restore(win, anchor)
  local saved = anchor and anchors[anchor] or nil
  if not saved or not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_win_call(win, function()
    pcall(vim.api.nvim_win_set_cursor, win, saved.cursor)
    vim.fn.winrestview(saved.view)
  end)
end

function M.get_offset(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  local prefix = measure_prefix(win, view.topline - 1, line_count)
  local skipped_rows = measure_skipped_rows(win, view.topline - 1, view.skipcol)
  return math.max(0, prefix - view.topfill + skipped_rows)
end

local clamp_cursor_to_viewport = function(win, cursor, viewport)
  local row = math.max(viewport.topline, math.min(cursor[1], vim.fn.line("w$")))
  local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), row - 1, row, false)[1] or ""
  return { row, math.min(cursor[2], #line) }
end

local apply_target_view = function(win, target_view, preserve_cursor, is_active)
  local cursor = vim.api.nvim_win_get_cursor(win)
  vim.api.nvim_win_set_cursor(win, { target_view.topline, 0 })
  vim.fn.winrestview(target_view)
  if not preserve_cursor then
    return
  end
  local settled = vim.fn.winsaveview()
  local viewport = {
    topline = settled.topline,
    topfill = settled.topfill,
    leftcol = settled.leftcol,
    skipcol = settled.skipcol,
  }
  local restored_cursor = is_active and clamp_cursor_to_viewport(win, cursor, viewport) or cursor
  pcall(vim.api.nvim_win_set_cursor, win, restored_cursor)
  vim.fn.winrestview(viewport)
end

local clamp_topfill = function(win, target_view)
  local low = 0
  local high = target_view.topfill
  while low < high do
    local candidate = math.floor((low + high + 1) / 2)
    vim.api.nvim_win_set_cursor(win, { target_view.topline, 0 })
    vim.fn.winrestview(vim.tbl_extend("force", target_view, { topfill = candidate }))
    local settled = vim.fn.winsaveview()
    if settled.topline == target_view.topline and settled.topfill == candidate then
      low = candidate
    else
      high = candidate - 1
    end
  end
  return vim.tbl_extend("force", target_view, { topfill = low })
end

function M.set_offset(win, offset, opts)
  if not win or not vim.api.nvim_win_is_valid(win) or type(offset) ~= "number" then
    return nil
  end
  offset = math.floor(math.max(0, offset))
  local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  local started_calls = text_height_calls
  local target_view = get_direct_target_view(win, offset, line_count)
  if target_view then
    metrics.direct_count = metrics.direct_count + 1
    metrics.direct_text_height_calls = metrics.direct_text_height_calls + text_height_calls - started_calls
  else
    target_view = get_fallback_target_view(win, offset, line_count)
    metrics.fallback_count = metrics.fallback_count + 1
    metrics.fallback_text_height_calls = metrics.fallback_text_height_calls + text_height_calls - started_calls
  end
  if target_view.skipcol > 0 and not vim.wo[win].smoothscroll then
    local next_offset = measure_prefix(win, target_view.topline, line_count)
    if next_offset <= offset and target_view.topline < line_count then
      next_offset = measure_prefix(win, target_view.topline + 1, line_count)
    end
    if next_offset > offset then
      target_view = get_direct_target_view(win, next_offset, line_count) or get_fallback_target_view(win, next_offset, line_count)
    end
  end
  local is_active = win == vim.api.nvim_get_current_win()
  local preserve_cursor = not (opts and opts.preserve_cursor == false)
  local preserved_cursor = vim.api.nvim_win_get_cursor(win)
  vim.api.nvim_win_call(win, function()
    apply_target_view(win, target_view, preserve_cursor, is_active)
  end)
  local applied_offset = M.get_offset(win)
  if applied_offset ~= offset and target_view.topfill > 0 then
    target_view = vim.api.nvim_win_call(win, function()
      return clamp_topfill(win, target_view)
    end)
    vim.api.nvim_win_call(win, function()
      pcall(vim.api.nvim_win_set_cursor, win, preserved_cursor)
      apply_target_view(win, target_view, preserve_cursor, is_active)
    end)
    applied_offset = M.get_offset(win)
  end
  if applied_offset < offset then
    local next_offset = measure_prefix(win, target_view.topline, line_count)
    if next_offset <= offset and target_view.topline < line_count then
      next_offset = measure_prefix(win, target_view.topline + 1, line_count)
    end
    if next_offset > offset then
      target_view = get_direct_target_view(win, next_offset, line_count) or get_fallback_target_view(win, next_offset, line_count)
      vim.api.nvim_win_call(win, function()
        apply_target_view(win, target_view, false, is_active)
      end)
      applied_offset = M.get_offset(win)
      if applied_offset < offset and target_view.topfill > 0 then
        target_view = vim.api.nvim_win_call(win, function()
          return clamp_topfill(win, target_view)
        end)
        vim.api.nvim_win_call(win, function()
          apply_target_view(win, target_view, false, is_active)
        end)
        applied_offset = M.get_offset(win)
      end
    end
  end
  return applied_offset
end

function M.get_metrics()
  return vim.deepcopy(metrics)
end

function M.reset_metrics()
  metrics.direct_count = 0
  metrics.fallback_count = 0
  metrics.direct_text_height_calls = 0
  metrics.fallback_text_height_calls = 0
  text_height_calls = 0
end

return M
