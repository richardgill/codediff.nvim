local M = {}

local display = require("codediff.nvim.display")

local pane_states = {}
local metrics = { rebuild_count = 0, rebuild_reasons = {} }

local elapsed_ms = function(started_at)
  return (vim.uv.hrtime() - started_at) / 1000000
end

local get_pane_state = function(pane)
  local state = pane_states[pane.win]
  if not state then
    state = { layer = display.create_layer(pane.win), height_cache = {} }
    pane_states[pane.win] = state
  elseif state.buf ~= pane.buf then
    state.height_cache = {}
    state.measurement_context = nil
    state.decoration_key = nil
  end

  state.buf = pane.buf
  return state
end

local get_fold_ends = function(intervals, pane)
  local rows = {}
  for _, interval in ipairs(intervals) do
    rows[#rows + 1] = interval.ranges[pane.side].start_row
  end
  return display.closed_folds(pane.win, rows)
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

local get_decoration_key = function(pane, plan_token)
  return plan_token and string.format("%d:%s", vim.api.nvim_buf_get_changedtick(pane.buf), tostring(plan_token)) or nil
end

local build_cache_contexts = function(panes, states, compact_mode, plan_token)
  local contexts = {}
  local needs_layer_clear = false
  for _, pane in ipairs(panes) do
    local state = states[pane.side]
    local context = display.measurement_context(pane.win, { exclude_layer = state.layer })
    local layout_changed = not state.measurement_context or not context:has_same_signature(state.measurement_context)
    local decoration_key = get_decoration_key(pane, plan_token)
    local context_changed = layout_changed or not decoration_key or state.decoration_key ~= decoration_key
    if layout_changed then
      state.height_cache = {}
    end
    if context_changed then
      state.measurement_context = context
      state.decoration_key = decoration_key
      needs_layer_clear = true
    end
    contexts[pane.side] = {
      cache = state.height_cache,
      decorated_rows = state.measurement_context:height_decorated_rows(),
      enabled = not compact_mode and not state.measurement_context:has_active_conceal(),
    }
  end
  return contexts, needs_layer_clear
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

local build_stats = function(intervals, opts)
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
    layer_entries_removed = opts.layer_entries_removed or 0,
    layer_entries_reused = 0,
    layer_entries_updated = 0,
    rebuild_count = metrics.rebuild_count,
    rebuild_reason = reason,
    timings = {
      plan_ms = opts.plan_ms or 0,
      prepare_ms = opts.prepare_ms,
      fold_scan_ms = opts.fold_scan_ms,
      redraw_measure_ms = opts.redraw_measure_ms,
      padding_ms = 0,
      view_sync_ms = 0,
      total_ms = elapsed_ms(opts.started_at),
    },
  }
  metrics.latest = stats
  return stats
end

local set_layers = function(states, panes, entries)
  local stats = { removed = 0, reused = 0, updated = 0 }
  for _, pane in ipairs(panes) do
    local layer_stats = display.set_layer(states[pane.side].layer, pane.buf, entries[pane.side])
    stats.removed = stats.removed + layer_stats.removed
    stats.reused = stats.reused + layer_stats.reused
    stats.updated = stats.updated + layer_stats.updated
  end
  return stats
end

local clear_layers = function(states, panes)
  local removed = 0
  for _, pane in ipairs(panes) do
    removed = removed + display.clear_layer(states[pane.side].layer)
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

local calculate_padding = function(interval, panes, natural_heights)
  local heights = {}
  local target_height = 0
  for _, pane in ipairs(panes) do
    local height = natural_heights[pane.side] + ((interval.leading_rows and interval.leading_rows[pane.side]) or 0)
    heights[pane.side] = height
    target_height = math.max(target_height, height)
  end

  local padding = {}
  for _, pane in ipairs(panes) do
    padding[pane.side] = target_height - heights[pane.side]
  end
  return padding
end

local measure_pane_ranges = function(pane, intervals, context, measurement_plan, counts)
  local pending_ranges = {}
  local pending_indexes = {}
  for index, interval in ipairs(intervals) do
    local measurement = measurement_plan[index]
    counts.requests = counts.requests + 1
    if measurement.heights[pane.side] ~= nil then
      counts.hits = counts.hits + 1
    else
      pending_ranges[#pending_ranges + 1] = interval.ranges[pane.side]
      pending_indexes[#pending_indexes + 1] = index
    end
  end

  local heights = display.measure_ranges(pane.win, pending_ranges)
  counts.measurements = counts.measurements + #heights
  for pending_index, height in ipairs(heights) do
    local measurement = measurement_plan[pending_indexes[pending_index]]
    measurement.heights[pane.side] = height
    if measurement.cacheable_line then
      context.cache[measurement.cacheable_line] = height
    end
  end
end

local add_padding_entries = function(entries, index, interval, padding, panes)
  for _, pane in ipairs(panes) do
    local count = padding[pane.side]
    if count > 0 then
      entries[pane.side][#entries[pane.side] + 1] = {
        key = index,
        boundary_row = interval.ranges[pane.side].end_row,
        anchor_row = interval.padding_rows and interval.padding_rows[pane.side],
        above = interval.padding_above and interval.padding_above[pane.side] or false,
        count = count,
      }
    end
  end
end

local build_measurement_plan = function(intervals, panes, contexts, retain_cached_padding)
  local plan = {}
  local entries = {}
  local pending_padding = {}
  for _, pane in ipairs(panes) do
    entries[pane.side] = {}
  end
  for index, interval in ipairs(intervals) do
    local cacheable_line, heights = get_cached_heights(interval, panes, contexts)
    local fully_cached = true
    for _, pane in ipairs(panes) do
      fully_cached = fully_cached and heights[pane.side] ~= nil
    end
    if fully_cached and retain_cached_padding then
      add_padding_entries(entries, index, interval, calculate_padding(interval, panes, heights), panes)
    else
      pending_padding[#pending_padding + 1] = index
    end
    plan[index] = { cacheable_line = cacheable_line, heights = heights }
  end
  return plan, entries, pending_padding
end

local set_filler_stats = function(entries, panes, stats)
  for _, pane in ipairs(panes) do
    local count = 0
    for _, entry in ipairs(entries[pane.side]) do
      count = count + entry.count
    end
    stats.fillers[pane.side] = count
    stats[pane.side .. "_fillers"] = count
  end
end

function M.apply(opts)
  local states = {}
  for _, pane in ipairs(opts.panes) do
    states[pane.side] = get_pane_state(pane)
  end
  local prepare_ms = elapsed_ms(opts.prepare_started_at)

  local fold_scan_started_at = vim.uv.hrtime()
  local intervals = opts.intervals
  if opts.compact_mode or opts.fold_tracking then
    intervals = collapse_folded_intervals(intervals, opts.panes)
  end
  local fold_scan_ms = elapsed_ms(fold_scan_started_at)

  local measurement_started_at = vim.uv.hrtime()
  local incremental_padding = opts.plan_cache_hits == 1 and not opts.compact_mode and not opts.fold_tracking
  local layers_cleared = not incremental_padding
  local layer_entries_removed = layers_cleared and clear_layers(states, opts.panes) or 0
  local layer_entries_updated = 0
  vim.cmd("redraw")

  local contexts, context_requires_clear = build_cache_contexts(opts.panes, states, opts.compact_mode, opts.plan_token)
  if context_requires_clear and not layers_cleared then
    layer_entries_removed = layer_entries_removed + clear_layers(states, opts.panes)
    layers_cleared = true
    vim.cmd("redraw")
  end

  local measurement_plan, entries, pending_padding = build_measurement_plan(intervals, opts.panes, contexts, not layers_cleared)

  if not layers_cleared then
    local retained_stats = set_layers(states, opts.panes, entries)
    layer_entries_removed = layer_entries_removed + retained_stats.removed
    layer_entries_updated = layer_entries_updated + retained_stats.updated
    if retained_stats.removed > 0 or retained_stats.updated > 0 then
      vim.cmd("redraw")
    end
  end

  local counts = { requests = 0, measurements = 0, hits = 0 }
  for _, pane in ipairs(opts.panes) do
    measure_pane_ranges(pane, intervals, contexts[pane.side], measurement_plan, counts)
  end
  local padding_started_at = vim.uv.hrtime()
  local stats = build_stats(intervals, {
    reason = opts.reason,
    measurement_requests = counts.requests,
    measurements = counts.measurements,
    cache_hits = counts.hits,
    plan_cache_hits = opts.plan_cache_hits,
    layer_entries_removed = layer_entries_removed,
    plan_ms = opts.plan_ms,
    prepare_ms = prepare_ms,
    fold_scan_ms = fold_scan_ms,
    redraw_measure_ms = elapsed_ms(measurement_started_at),
    started_at = opts.started_at,
  })
  for _, index in ipairs(pending_padding) do
    local interval = intervals[index]
    local padding = calculate_padding(interval, opts.panes, measurement_plan[index].heights)
    add_padding_entries(entries, index, interval, padding, opts.panes)
  end
  set_filler_stats(entries, opts.panes, stats)
  local installed_stats = set_layers(states, opts.panes, entries)
  stats.layer_entries_removed = stats.layer_entries_removed + installed_stats.removed
  stats.layer_entries_reused = installed_stats.reused
  stats.layer_entries_updated = layer_entries_updated + installed_stats.updated
  stats.timings.padding_ms = elapsed_ms(padding_started_at)
  stats.timings.total_ms = elapsed_ms(opts.started_at)
  return stats
end

function M.clear_window(win)
  local state = pane_states[win]
  if state then
    display.destroy_layer(state.layer)
    pane_states[win] = nil
  end
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
