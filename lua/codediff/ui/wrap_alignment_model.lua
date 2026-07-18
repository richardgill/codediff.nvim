local M = {}

local add_interval = function(intervals, base_start, base_end, pane_start, pane_end, changed)
  if base_end <= base_start and pane_end <= pane_start then
    return
  end
  intervals[#intervals + 1] = {
    base_start = base_start,
    base_end = base_end,
    pane_start = pane_start,
    pane_end = pane_end,
    changed = changed,
  }
end

local add_equal_intervals = function(intervals, base_start, base_end, pane_start, pane_end)
  local base_count = base_end - base_start
  local pane_count = pane_end - pane_start
  if base_count ~= pane_count then
    add_interval(intervals, base_start, base_end, pane_start, pane_end, true)
    return
  end

  for offset = 0, base_count - 1 do
    add_interval(intervals, base_start + offset, base_start + offset + 1, pane_start + offset, pane_start + offset + 1, false)
  end
end

local project_boundary = function(position, source_start, source_end, target_start, target_end)
  local source_count = source_end - source_start
  local target_count = target_end - target_start
  local scaled = (position - source_start) * target_count / source_count
  return target_start + math.floor(scaled + 0.5)
end

local add_changed_intervals = function(intervals, mapping, base_lines)
  local base_start = mapping.original.start_line - 1
  local base_end = mapping.original.end_line - 1
  local pane_start = mapping.modified.start_line - 1
  local pane_end = mapping.modified.end_line - 1
  if not mapping.inner_changes or #mapping.inner_changes == 0 then
    add_interval(intervals, base_start, base_end, pane_start, pane_end, true)
    return
  end

  local current_base = base_start
  local current_pane = pane_start
  local first = true
  local emit = function(next_base, next_pane)
    if next_base < current_base or next_pane < current_pane then
      return
    end
    if first then
      first = false
    elseif next_base == current_base or next_pane == current_pane then
      return
    end
    add_interval(intervals, current_base, next_base, current_pane, next_pane, true)
    current_base = next_base
    current_pane = next_pane
  end

  for _, inner in ipairs(mapping.inner_changes) do
    if inner.original.start_col > 1 and inner.modified.start_col > 1 then
      emit(inner.original.start_line - 1, inner.modified.start_line - 1)
    end
    local line = base_lines[inner.original.end_line]
    if inner.original.end_col <= #(line or "") then
      emit(inner.original.end_line - 1, inner.modified.end_line - 1)
    end
  end
  emit(base_end, pane_end)
  if current_base < base_end or current_pane < pane_end then
    add_interval(intervals, current_base, base_end, current_pane, pane_end, true)
  end
end

local build_pair = function(base_count, pane_count, base_lines, diff)
  if not diff then
    local intervals = {}
    add_equal_intervals(intervals, 0, base_count, 0, pane_count)
    return intervals
  end

  local intervals = {}
  local base_position = 0
  local pane_position = 0
  for _, mapping in ipairs(diff.changes or {}) do
    local base_start = math.max(base_position, mapping.original.start_line - 1)
    local pane_start = math.max(pane_position, mapping.modified.start_line - 1)
    add_equal_intervals(intervals, base_position, base_start, pane_position, pane_start)
    add_changed_intervals(intervals, mapping, base_lines)
    base_position = math.max(base_start, mapping.original.end_line - 1)
    pane_position = math.max(pane_start, mapping.modified.end_line - 1)
  end
  add_equal_intervals(intervals, base_position, base_count, pane_position, pane_count)
  return intervals
end

local map_boundary = function(intervals, position)
  for _, interval in ipairs(intervals) do
    if interval.base_start == position and interval.base_end > position then
      return interval.pane_start
    end
  end
  for _, interval in ipairs(intervals) do
    if interval.base_start < position and interval.base_end > position then
      return project_boundary(position, interval.base_start, interval.base_end, interval.pane_start, interval.pane_end)
    end
  end
  for index = #intervals, 1, -1 do
    local interval = intervals[index]
    if interval.base_end == position and interval.base_end > interval.base_start then
      return interval.pane_end
    end
  end
  return 0
end

local map_boundary_before = function(intervals, position)
  for index = #intervals, 1, -1 do
    local interval = intervals[index]
    if interval.base_end == position and interval.base_end > interval.base_start then
      return interval.pane_end
    end
  end
  return map_boundary(intervals, position)
end

local map_direct_span = function(pair, start_position, end_position)
  local low = 1
  local high = #pair.spans
  while low < high do
    local middle = math.floor((low + high) / 2)
    if pair.spans[middle].base_end < end_position then
      low = middle + 1
    else
      high = middle
    end
  end

  local interval = pair.spans[low]
  if interval and interval.base_start <= start_position and interval.base_end >= end_position then
    return project_boundary(start_position, interval.base_start, interval.base_end, interval.pane_start, interval.pane_end),
      project_boundary(end_position, interval.base_start, interval.base_end, interval.pane_start, interval.pane_end)
  end
  return map_boundary(pair.intervals, start_position), map_boundary_before(pair.intervals, end_position)
end

local map_composed_span = function(mapping, start_position, end_position)
  if start_position == end_position then
    local mapped = map_boundary(mapping.intervals, start_position)
    return mapped, mapped
  end
  return map_direct_span(mapping, start_position, end_position)
end

local is_unchanged_span = function(mapping, start_position, end_position)
  if end_position == start_position then
    if mapping.insertions[start_position] then
      return false
    end
    for _, interval in ipairs(mapping.intervals) do
      if interval.changed and interval.base_start <= start_position and start_position < interval.base_end then
        return false
      end
    end
    return true
  end
  if end_position < start_position then
    return false
  end

  local position = start_position
  for _, interval in ipairs(mapping.intervals) do
    if interval.base_end > position then
      local base_count = interval.base_end - interval.base_start
      local pane_count = interval.pane_end - interval.pane_start
      if interval.base_start > position or interval.changed or base_count ~= pane_count then
        return false
      end
      position = math.min(end_position, interval.base_end)
      if position >= end_position then
        return true
      end
    end
  end
  return false
end

local map_span

local select_alignment_source = function(pair, start_position, end_position, preferred)
  local selected = nil
  local selected_start = -1
  local selected_end = -1
  for _, source in ipairs(pair.alignment_sources or {}) do
    local source_start, source_end = map_span(source.pair, start_position, end_position)
    if is_unchanged_span(source.mapping, source_start, source_end) then
      local result_start, result_end = map_composed_span(source.mapping, source_start, source_end)
      local later = result_start > selected_start or (result_start == selected_start and result_end > selected_end)
      local same = result_start == selected_start and result_end == selected_end
      if later or not selected or (same and (not preferred or source == preferred)) then
        selected = source
        selected_start = result_start
        selected_end = result_end
      end
    end
  end
  return selected
end

map_span = function(pair, start_position, end_position)
  local selected = pair.source_selections and pair.source_selections[start_position] or select_alignment_source(pair, start_position, end_position)
  if not selected then
    return map_direct_span(pair, start_position, end_position)
  end
  local source_start, source_end = map_span(selected.pair, start_position, end_position)
  return map_composed_span(selected.mapping, source_start, source_end)
end

local map_pair_boundary = function(pair, position, source)
  if not source then
    return map_boundary(pair.intervals, position)
  end
  local source_position = map_pair_boundary(source.pair, position)
  return map_boundary(source.mapping.intervals, source_position)
end

local map_pane_boundary = function(intervals, position)
  for _, interval in ipairs(intervals) do
    if interval.pane_start == position and interval.pane_end > position then
      return interval.base_start
    end
  end
  for _, interval in ipairs(intervals) do
    if interval.pane_start < position and interval.pane_end > position then
      return project_boundary(position, interval.pane_start, interval.pane_end, interval.base_start, interval.base_end)
    end
  end
  for index = #intervals, 1, -1 do
    local interval = intervals[index]
    if interval.pane_end == position and interval.pane_end > interval.pane_start then
      return interval.base_end
    end
  end
  return 0
end

local index_pair = function(pair)
  pair.spans = {}
  pair.insertions = {}
  for _, interval in ipairs(pair.intervals) do
    if interval.base_end > interval.base_start then
      pair.spans[#pair.spans + 1] = interval
    elseif interval.pane_end > interval.pane_start then
      local insertion = pair.insertions[interval.base_start]
      pair.insertions[interval.base_start] = {
        start_row = insertion and math.min(insertion.start_row, interval.pane_start) or interval.pane_start,
        end_row = insertion and math.max(insertion.end_row, interval.pane_end) or interval.pane_end,
      }
    end
  end
  return pair
end

local map_source_insertions = function(source, mapping)
  local insertions = {}
  for source_position, range in pairs(mapping.insertions) do
    local base_position = map_pane_boundary(source.intervals, source_position)
    if map_pair_boundary(source, base_position) == source_position then
      insertions[base_position] = range
    end
  end
  return insertions
end

local attach_alignment_sources = function(pair_models)
  local pairs_by_side = {}
  for _, pair in ipairs(pair_models) do
    pairs_by_side[pair.side] = pair
  end
  for _, pair in ipairs(pair_models) do
    local sources = {}
    for _, source_config in ipairs(pair.alignment_sources or {}) do
      local source = pairs_by_side[source_config.side]
      if source then
        local mapping = index_pair({ intervals = build_pair(source.line_count, pair.line_count, source.lines, source_config.diff) })
        sources[#sources + 1] = { pair = source, mapping = mapping, insertions = map_source_insertions(source, mapping) }
      end
    end
    pair.alignment_sources = #sources > 0 and sources or nil
  end
end

local collect_boundaries = function(pair_models, base_count)
  local unique = { [0] = true, [base_count] = true }
  for _, pair in ipairs(pair_models) do
    for _, interval in ipairs(pair.intervals) do
      unique[interval.base_start] = true
      unique[interval.base_end] = true
    end
    for _, source in ipairs(pair.alignment_sources or {}) do
      for boundary in pairs(source.insertions) do
        unique[boundary] = true
      end
      for _, interval in ipairs(source.mapping.intervals) do
        local start_boundary = map_pane_boundary(source.pair.intervals, interval.base_start)
        local end_boundary = map_pane_boundary(source.pair.intervals, interval.base_end)
        if map_pair_boundary(source.pair, start_boundary) == interval.base_start then
          unique[start_boundary] = true
        end
        if map_pair_boundary(source.pair, end_boundary) == interval.base_end then
          unique[end_boundary] = true
        end
      end
    end
    for _, move in ipairs((pair.diff and pair.diff.moves) or {}) do
      unique[move.original.start_line - 1] = true
      unique[map_pane_boundary(pair.intervals, move.modified.start_line - 1)] = true
    end
  end

  local boundaries = {}
  for boundary in pairs(unique) do
    boundaries[#boundaries + 1] = boundary
  end
  table.sort(boundaries)
  return boundaries
end

local build_source_selections = function(pair_models, boundaries)
  for _, pair in ipairs(pair_models) do
    pair.source_selections = {}
    local preferred = nil
    for index = 1, #boundaries - 1 do
      local base_start = boundaries[index]
      local base_end = boundaries[index + 1]
      local selected = select_alignment_source(pair, base_start, base_end, preferred)
      pair.source_selections[base_start] = selected
      preferred = selected or preferred
    end
  end
end

local get_insertion = function(pair, boundary, next_boundary, previous_boundary)
  local source = next_boundary and pair.source_selections[boundary] or nil
  if not source and previous_boundary then
    source = pair.source_selections[previous_boundary]
  end
  local source_range = source and source.insertions[boundary] or nil
  if source_range then
    return source_range, source
  end
  if source then
    return nil, source
  end
  return pair.insertions[boundary], nil
end

local build_ranges = function(pair_models, base_start, base_end, insertion, next_boundary, previous_boundary)
  local ranges = {}
  for _, pair in ipairs(pair_models) do
    local range = nil
    local source = nil
    if insertion then
      range, source = get_insertion(pair, base_start, next_boundary, previous_boundary)
    end
    if range then
      ranges[pair.side] = range
    elseif insertion then
      local mapped = map_pair_boundary(pair, base_start, source)
      ranges[pair.side] = { start_row = mapped, end_row = mapped }
    else
      local mapped_start, mapped_end = map_span(pair, base_start, base_end)
      ranges[pair.side] = { start_row = mapped_start, end_row = mapped_end }
    end
  end
  return ranges
end

local complete_interval_ranges = function(intervals, pair_models)
  local complete = {}
  local positions = {}
  for _, pair in ipairs(pair_models) do
    positions[pair.side] = 0
  end

  for _, interval in ipairs(intervals) do
    local gap = { ranges = {} }
    local has_gap = false
    for _, pair in ipairs(pair_models) do
      local side = pair.side
      local next_position = interval.ranges[side].start_row
      gap.ranges[side] = { start_row = positions[side], end_row = next_position }
      has_gap = has_gap or next_position > positions[side]
    end
    if has_gap then
      complete[#complete + 1] = gap
    end
    complete[#complete + 1] = interval
    for _, pair in ipairs(pair_models) do
      positions[pair.side] = interval.ranges[pair.side].end_row
    end
  end

  local tail = { ranges = {} }
  local has_tail = false
  for _, pair in ipairs(pair_models) do
    tail.ranges[pair.side] = { start_row = positions[pair.side], end_row = pair.line_count }
    has_tail = has_tail or positions[pair.side] < pair.line_count
  end
  if has_tail then
    complete[#complete + 1] = tail
  end
  return complete
end

local add_leading_row = function(intervals, side, row)
  for _, interval in ipairs(intervals) do
    local range = interval.ranges[side]
    if range and range.start_row == row and range.end_row > row then
      interval.leading_rows = interval.leading_rows or {}
      interval.leading_rows[side] = (interval.leading_rows[side] or 0) + 1
      return
    end
  end
end

function M.build(opts)
  local pair_models = {}
  for _, pane in ipairs(opts.panes) do
    pair_models[#pair_models + 1] = index_pair({
      side = pane.side,
      diff = pane.diff,
      lines = pane.lines,
      line_count = pane.line_count,
      alignment_sources = pane.alignment_sources,
      intervals = build_pair(opts.base_count, pane.line_count, opts.base_lines, pane.diff),
    })
  end
  attach_alignment_sources(pair_models)

  local boundaries = collect_boundaries(pair_models, opts.base_count)
  build_source_selections(pair_models, boundaries)
  local intervals = {}
  for index, boundary in ipairs(boundaries) do
    local next_boundary = boundaries[index + 1]
    local previous_boundary = boundaries[index - 1]
    local has_insertion = false
    for _, pair in ipairs(pair_models) do
      local range = get_insertion(pair, boundary, next_boundary, previous_boundary)
      has_insertion = has_insertion or range ~= nil
    end
    if has_insertion then
      intervals[#intervals + 1] = {
        ranges = build_ranges(pair_models, boundary, boundary, true, next_boundary, previous_boundary),
      }
    end

    if next_boundary and next_boundary > boundary then
      intervals[#intervals + 1] = { ranges = build_ranges(pair_models, boundary, next_boundary, false) }
    end
  end

  intervals = complete_interval_ranges(intervals, pair_models)
  for _, pair in ipairs(pair_models) do
    for _, move in ipairs((pair.diff and pair.diff.moves) or {}) do
      if opts.base_side then
        add_leading_row(intervals, opts.base_side, move.original.start_line - 1)
      end
      add_leading_row(intervals, pair.side, move.modified.start_line - 1)
    end
  end
  return intervals
end

return M
