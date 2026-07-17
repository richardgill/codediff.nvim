local M = {}

local compat = require("codediff.core.compat")

local function is_empty(range)
  return range.start_line == range.end_line and range.start_col == range.end_col
end

local function to_byte_col(line, utf16_col)
  if utf16_col <= 1 then
    return utf16_col - 1
  end

  local ok, byte_col = pcall(compat.str_byteindex_utf16, line, utf16_col - 1)
  return ok and byte_col or utf16_col - 1
end

local function split_range(range, lines)
  if is_empty(range) then
    return {}
  end

  local segments = {}
  for line = range.start_line, math.min(range.end_line, #lines) do
    local text = lines[line]
    local start_col = line == range.start_line and to_byte_col(text, range.start_col) or 0
    local end_col = line == range.end_line and to_byte_col(text, range.end_col) or #text
    start_col = math.max(0, math.min(start_col, #text))
    end_col = math.max(0, math.min(end_col, #text))

    if end_col > start_col then
      table.insert(segments, {
        line = line,
        start_col = start_col,
        end_col = end_col,
        full_line = start_col == 0 and end_col == #text,
      })
    end
  end
  return segments
end

local function find_matched_segments(segments, counterparts)
  local lengths = {}
  for i = #segments, 1, -1 do
    lengths[i] = {}
    for j = #counterparts, 1, -1 do
      lengths[i][j] = segments[i].full_line == counterparts[j].full_line and 1 + ((lengths[i + 1] and lengths[i + 1][j + 1]) or 0)
        or math.max((lengths[i + 1] and lengths[i + 1][j]) or 0, lengths[i][j + 1] or 0)
    end
  end

  local matched = {}
  local i, j = 1, 1
  while i <= #segments and j <= #counterparts do
    if segments[i].full_line == counterparts[j].full_line then
      matched[i] = true
      i = i + 1
      j = j + 1
    elseif ((lengths[i + 1] and lengths[i + 1][j]) or 0) >= (lengths[i][j + 1] or 0) then
      i = i + 1
    else
      j = j + 1
    end
  end
  return matched
end

function M.to_line_segments(range, counterpart, lines, counterpart_lines)
  local segments = split_range(range, lines)
  local matched = find_matched_segments(segments, split_range(counterpart, counterpart_lines))

  for index, segment in ipairs(segments) do
    segment.line_text = segment.full_line and not matched[index]
    segment.full_line = nil
  end
  return segments
end

return M
