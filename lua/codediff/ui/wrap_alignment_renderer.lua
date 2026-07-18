local M = {}

local window_namespace = require("codediff.nvim.window_namespace")

local pane_states = {}
local metrics = { rebuild_count = 0, rebuild_reasons = {} }
local filler_line = { { string.rep("╱", 500), "CodeDiffFiller" } }

local elapsed_ms = function(started_at)
  return (vim.uv.hrtime() - started_at) / 1000000
end

local clear_state = function(state)
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  end
  if state then
    pcall(window_namespace.clear_scope, state.ns)
  end
end

local get_pane_state = function(pane)
  local state = pane_states[pane.win]
  if state and state.buf ~= pane.buf then
    clear_state(state)
    state = nil
  end
  if not state then
    state = { ns = window_namespace.create("", pane.win), height_cache = {}, padding = {} }
    pane_states[pane.win] = state
  else
    window_namespace.scope(state.ns, pane.win)
  end

  state.buf = pane.buf
  return state
end

local get_fold_ends = function(intervals, pane)
  local line_count = vim.api.nvim_buf_line_count(pane.buf)
  return vim.api.nvim_win_call(pane.win, function()
    local fold_ends = {}
    for _, interval in ipairs(intervals) do
      local row = interval.ranges[pane.side].start_row
      if row >= 0 and row < line_count and fold_ends[row] == nil then
        local start_line = vim.fn.foldclosed(row + 1)
        if start_line >= 0 then
          fold_ends[row] = vim.fn.foldclosedend(row + 1)
        end
      end
    end
    return fold_ends
  end)
end

local merge_interval = function(target, source)
  for side, range in pairs(source.ranges) do
    local target_range = target.ranges[side]
    target_range.start_row = math.min(target_range.start_row, range.start_row)
    target_range.end_row = math.max(target_range.end_row, range.end_row)
  end
end

local get_fold_limits = function(interval, panes, fold_ends)
  local limits = {}
  for _, pane in ipairs(panes) do
    local range = interval.ranges[pane.side]
    limits[pane.side] = fold_ends[pane.side][range.start_row] or range.end_row
  end
  return limits
end

local needs_fold_extension = function(interval, limits, panes)
  for _, pane in ipairs(panes) do
    if interval.ranges[pane.side].end_row < limits[pane.side] then
      return true
    end
  end
  return false
end

local mark_fold_padding = function(interval, panes, fold_ends)
  for _, pane in ipairs(panes) do
    local side = pane.side
    local range = interval.ranges[side]
    for _, fold_end in pairs(fold_ends[side]) do
      if fold_end == range.end_row then
        interval.padding_above = interval.padding_above or {}
        interval.padding_above[side] = true
        if range.end_row >= pane.line_count then
          interval.padding_rows = interval.padding_rows or {}
          interval.padding_rows[side] = range.end_row
        end
      end
    end
  end
end

local collapse_folded_intervals = function(intervals, panes)
  local fold_ends = {}
  for _, pane in ipairs(panes) do
    fold_ends[pane.side] = get_fold_ends(intervals, pane)
  end

  local collapsed = {}
  local consumed = 0
  for index, interval in ipairs(intervals) do
    if index > consumed then
      local combined = vim.deepcopy(interval)
      local limits = get_fold_limits(combined, panes, fold_ends)
      consumed = index
      for next_index = index + 1, #intervals do
        if needs_fold_extension(combined, limits, panes) then
          local next_interval = intervals[next_index]
          merge_interval(combined, next_interval)
          local next_limits = get_fold_limits(next_interval, panes, fold_ends)
          for side, limit in pairs(next_limits) do
            limits[side] = math.max(limits[side], limit)
          end
          consumed = next_index
        end
      end
      mark_fold_padding(combined, panes, fold_ends)
      collapsed[#collapsed + 1] = combined
    end
  end
  return collapsed
end

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

local get_height_decorated_rows = function(buf, padding_namespace)
  local rows = {}
  local extmarks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
  for _, extmark in ipairs(extmarks) do
    local details = extmark[4]
    local affects_height = details.virt_lines or details.virt_text or details.conceal
    if details.ns_id ~= padding_namespace and affects_height then
      rows[extmark[2]] = true
    end
  end
  return rows
end

local get_render_signature = function(pane)
  local window_info = vim.fn.getwininfo(pane.win)[1]
  local values = {
    vim.api.nvim_win_get_width(pane.win),
    window_info and window_info.textoff or 0,
    vim.wo[pane.win].linebreak,
    vim.wo[pane.win].breakindent,
    vim.wo[pane.win].breakindentopt,
    vim.wo[pane.win].showbreak,
    vim.wo[pane.win].list,
    vim.wo[pane.win].listchars,
    vim.wo[pane.win].number,
    vim.wo[pane.win].relativenumber,
    vim.wo[pane.win].numberwidth,
    vim.wo[pane.win].signcolumn,
    vim.wo[pane.win].foldcolumn,
    vim.wo[pane.win].statuscolumn,
    vim.wo[pane.win].conceallevel,
    vim.wo[pane.win].concealcursor,
    vim.bo[pane.buf].tabstop,
    vim.bo[pane.buf].vartabstop,
    vim.o.ambiwidth,
    vim.o.display,
  }
  return table.concat(vim.tbl_map(tostring, values), "\31")
end

local build_cache_contexts = function(panes, states, compact_mode, plan_token)
  local contexts = {}
  for _, pane in ipairs(panes) do
    local state = states[pane.side]
    local signature = get_render_signature(pane)
    if state.height_cache_signature ~= signature then
      state.height_cache = {}
      state.height_cache_signature = signature
    end
    local decoration_key = plan_token and string.format("%d:%s", vim.api.nvim_buf_get_changedtick(pane.buf), tostring(plan_token)) or nil
    if not decoration_key or state.decoration_key ~= decoration_key then
      state.decorated_rows = get_height_decorated_rows(pane.buf, state.ns)
      state.decoration_key = decoration_key
    end
    contexts[pane.side] = {
      cache = state.height_cache,
      decorated_rows = state.decorated_rows,
      enabled = not compact_mode and vim.wo[pane.win].conceallevel == 0,
    }
  end
  return contexts
end

local get_cacheable_line = function(interval, panes, contexts)
  if interval.leading_rows then
    return nil
  end

  local line = nil
  for _, pane in ipairs(panes) do
    local range = interval.ranges[pane.side]
    local context = contexts[pane.side]
    if not context.enabled or range.end_row - range.start_row ~= 1 or context.decorated_rows[range.start_row] then
      return nil
    end
    local pane_line = pane.lines and pane.lines[range.start_row + 1] or nil
    if pane_line == nil or (line ~= nil and pane_line ~= line) then
      return nil
    end
    line = pane_line
  end
  return line
end

local insert_padding = function(state, consumed_lines, line_count, count, above_boundary, padding_row)
  local above = consumed_lines <= 0 or above_boundary
  local row = padding_row or (above and math.min(consumed_lines, line_count - 1) or math.min(consumed_lines - 1, line_count - 1))
  local virt_lines = {}
  for _ = 1, count do
    virt_lines[#virt_lines + 1] = filler_line
  end

  return vim.api.nvim_buf_set_extmark(state.buf, state.ns, math.max(row, 0), 0, {
    virt_lines = virt_lines,
    virt_lines_above = above,
    strict = false,
  })
end

local build_stats = function(panes, intervals, opts)
  local reason = opts.reason or "render"
  metrics.rebuild_count = metrics.rebuild_count + 1
  metrics.rebuild_reasons[reason] = (metrics.rebuild_reasons[reason] or 0) + 1

  local stats = {
    intervals = #intervals,
    fillers = {},
    measurement_requests = opts.measurement_requests,
    measurements = opts.measurements,
    cache_hits = opts.cache_hits,
    plan_cache_hits = opts.plan_cache_hits or 0,
    padding_extmarks_removed = opts.padding_extmarks_removed or 0,
    padding_extmarks_reused = 0,
    padding_extmarks_updated = 0,
    pane_wins = {},
    rebuild_count = metrics.rebuild_count,
    rebuild_reason = reason,
    timings = {
      plan_ms = opts.plan_ms or 0,
      prepare_ms = opts.prepare_ms,
      fold_scan_ms = opts.fold_scan_ms,
      redraw_measure_ms = opts.redraw_measure_ms,
      padding_ms = opts.padding_ms,
      view_sync_ms = 0,
      total_ms = elapsed_ms(opts.started_at),
    },
  }
  for _, pane in ipairs(panes) do
    stats.fillers[pane.side] = 0
    stats[pane.side .. "_fillers"] = 0
    stats.pane_wins[#stats.pane_wins + 1] = pane.win
  end
  metrics.latest = stats
  return stats
end

local remove_padding_entry = function(state, index)
  local entry = state.padding[index]
  if not entry then
    return 0
  end
  pcall(vim.api.nvim_buf_del_extmark, state.buf, state.ns, entry.id)
  state.padding[index] = nil
  return 1
end

local clear_padding = function(states, panes)
  local removed = 0
  for _, pane in ipairs(panes) do
    local state = states[pane.side]
    for _ in pairs(state.padding) do
      removed = removed + 1
    end
    vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
    state.padding = {}
  end
  return removed
end

local remove_interval_padding = function(states, panes, index)
  local removed = 0
  for _, pane in ipairs(panes) do
    removed = removed + remove_padding_entry(states[pane.side], index)
  end
  return removed
end

local get_cached_heights = function(interval, panes, contexts)
  local cacheable_line = get_cacheable_line(interval, panes, contexts)
  local heights = {}
  for _, pane in ipairs(panes) do
    heights[pane.side] = cacheable_line and contexts[pane.side].cache[cacheable_line] or nil
  end
  return cacheable_line, heights
end

local measure_interval_padding = function(interval, panes, contexts, measurement, counts)
  local heights = {}
  local target_height = 0
  for _, pane in ipairs(panes) do
    local range = interval.ranges[pane.side]
    local context = contexts[pane.side]
    local height = measurement.heights[pane.side]
    counts.requests = counts.requests + 1
    if height ~= nil then
      counts.hits = counts.hits + 1
    else
      counts.measurements = counts.measurements + 1
      height = measure_range(pane.win, range)
      if measurement.cacheable_line then
        context.cache[measurement.cacheable_line] = height
      end
    end
    height = height + ((interval.leading_rows and interval.leading_rows[pane.side]) or 0)
    heights[pane.side] = height
    target_height = math.max(target_height, height)
  end

  local padding = {}
  for _, pane in ipairs(panes) do
    padding[pane.side] = target_height - heights[pane.side]
  end
  return padding
end

local render_interval_padding = function(index, interval, padding, panes, states, stats)
  for _, pane in ipairs(panes) do
    local count = padding[pane.side]
    local state = states[pane.side]
    local existing = state.padding[index]
    if count <= 0 then
      stats.padding_extmarks_removed = stats.padding_extmarks_removed + remove_padding_entry(state, index)
    elseif existing and existing.count == count then
      stats.padding_extmarks_reused = stats.padding_extmarks_reused + 1
    else
      stats.padding_extmarks_removed = stats.padding_extmarks_removed + remove_padding_entry(state, index)
      local above_boundary = interval.padding_above and interval.padding_above[pane.side]
      local padding_row = interval.padding_rows and interval.padding_rows[pane.side]
      local id = insert_padding(state, interval.ranges[pane.side].end_row, pane.line_count, count, above_boundary, padding_row)
      state.padding[index] = { id = id, count = count }
      stats.padding_extmarks_updated = stats.padding_extmarks_updated + 1
    end
    stats.fillers[pane.side] = stats.fillers[pane.side] + count
    stats[pane.side .. "_fillers"] = stats[pane.side .. "_fillers"] + count
  end
end

function M.apply(opts)
  local states = {}
  for _, pane in ipairs(opts.panes) do
    states[pane.side] = get_pane_state(pane)
  end
  opts.prepare_ms = elapsed_ms(opts.prepare_started_at)

  local fold_scan_started_at = vim.uv.hrtime()
  local intervals = opts.intervals
  if opts.compact_mode or opts.fold_tracking then
    intervals = collapse_folded_intervals(intervals, opts.panes)
  end
  opts.fold_scan_ms = elapsed_ms(fold_scan_started_at)

  local measurement_started_at = vim.uv.hrtime()
  local incremental_padding = opts.plan_cache_hits == 1 and not opts.compact_mode and not opts.fold_tracking
  opts.padding_extmarks_removed = incremental_padding and 0 or clear_padding(states, opts.panes)
  vim.cmd("redraw")
  local contexts = build_cache_contexts(opts.panes, states, opts.compact_mode, opts.plan_token)
  local measurement_plan = {}
  for index, interval in ipairs(intervals) do
    local cacheable_line, heights = get_cached_heights(interval, opts.panes, contexts)
    local needs_measurement = false
    for _, pane in ipairs(opts.panes) do
      needs_measurement = needs_measurement or heights[pane.side] == nil
    end
    if needs_measurement then
      opts.padding_extmarks_removed = opts.padding_extmarks_removed + remove_interval_padding(states, opts.panes, index)
    end
    measurement_plan[index] = { cacheable_line = cacheable_line, heights = heights }
  end
  if opts.padding_extmarks_removed > 0 then
    vim.cmd("redraw")
  end

  local counts = { requests = 0, measurements = 0, hits = 0 }
  local measured_padding = {}
  for index, interval in ipairs(intervals) do
    measured_padding[index] = measure_interval_padding(interval, opts.panes, contexts, measurement_plan[index], counts)
  end
  opts.measurement_requests = counts.requests
  opts.measurements = counts.measurements
  opts.cache_hits = counts.hits
  opts.redraw_measure_ms = elapsed_ms(measurement_started_at)

  local padding_started_at = vim.uv.hrtime()
  local stats = build_stats(opts.panes, intervals, opts)
  for index, interval in ipairs(intervals) do
    render_interval_padding(index, interval, measured_padding[index], opts.panes, states, stats)
  end
  stats.timings.padding_ms = elapsed_ms(padding_started_at)
  stats.timings.total_ms = elapsed_ms(opts.started_at)
  return stats
end

function M.clear_window(win)
  clear_state(pane_states[win])
  pane_states[win] = nil
end

function M.invalidate_window(win)
  local state = pane_states[win]
  if state then
    state.height_cache = {}
    state.decoration_key = nil
  end
end

function M.get_metrics()
  return vim.deepcopy(metrics)
end

function M.reset_metrics()
  metrics = { rebuild_count = 0, rebuild_reasons = {} }
end

return M
