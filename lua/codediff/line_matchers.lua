local M = {}

-- Inspired by CPython difflib.Differ._fancy_replace: https://github.com/python/cpython/blob/1736526023a3e616d1530815880bb3b28e3433c3/Lib/difflib.py#L896-L988
local DEFAULT_THRESHOLD = 0.75
local SEARCH_WINDOW = 10

local function lcs_length(left, right)
  local previous = {}
  for right_index = 0, #right do
    previous[right_index] = 0
  end

  for left_index = 1, #left do
    local current = { [0] = 0 }
    local left_char = left:sub(left_index, left_index)
    for right_index = 1, #right do
      if left_char == right:sub(right_index, right_index) then
        current[right_index] = previous[right_index - 1] + 1
      else
        current[right_index] = math.max(previous[right_index], current[right_index - 1])
      end
    end
    previous = current
  end

  return previous[#right]
end

local function similarity_score(left, right)
  if left == right then
    return 1
  end
  if #left == 0 or #right == 0 then
    return 0
  end
  return 2 * lcs_length(left, right) / (#left + #right)
end

local function find_best_pair(context, range, threshold)
  local best

  for original_index = range.original_start, range.original_end do
    local expected_modified = range.modified_start + original_index - range.original_start
    local modified_start = math.max(range.modified_start, expected_modified - SEARCH_WINDOW)
    local modified_end = math.min(range.modified_end, expected_modified + SEARCH_WINDOW)

    for modified_index = modified_start, modified_end do
      local score = similarity_score(context.original_lines[original_index], context.modified_lines[modified_index])
      if score >= threshold and (not best or score > best.score) then
        best = {
          original_index = original_index,
          modified_index = modified_index,
          score = score,
        }
      end
    end
  end

  return best
end

local function collect_similar_pairs(context, range, threshold, pairs)
  if range.original_start > range.original_end or range.modified_start > range.modified_end then
    return
  end

  local best = find_best_pair(context, range, threshold)
  if not best then
    return
  end

  collect_similar_pairs(context, {
    original_start = range.original_start,
    original_end = best.original_index - 1,
    modified_start = range.modified_start,
    modified_end = best.modified_index - 1,
  }, threshold, pairs)

  pairs[#pairs + 1] = {
    original_index = best.original_index,
    modified_index = best.modified_index,
  }

  collect_similar_pairs(context, {
    original_start = best.original_index + 1,
    original_end = range.original_end,
    modified_start = best.modified_index + 1,
    modified_end = range.modified_end,
  }, threshold, pairs)
end

-- Pair similar original and modified lines in order using an optional similarity threshold.
-- Example: left = "local old_name = 1", right = "local new_name = 1" gives 0.83.
function M.similarity(context, options)
  local threshold = options and options.threshold or DEFAULT_THRESHOLD
  local pairs = {}

  collect_similar_pairs(context, {
    original_start = 1,
    original_end = #context.original_lines,
    modified_start = 1,
    modified_end = #context.modified_lines,
  }, threshold, pairs)

  return pairs
end

-- Pair original and modified lines by position only when both sides have equal line counts (GitHub-style).
-- Example: left = { "line1", "line2" }, right = { "line3", "line4" } pairs 1:1 and 2:2.
-- Example: left = { "line1" }, right = { "line2", "line3" } returns no pairs.
function M.equal_line_count(context)
  if #context.original_lines ~= #context.modified_lines then
    return {}
  end

  local pairs = {}
  for index = 1, #context.original_lines do
    pairs[index] = {
      original_index = index,
      modified_index = index,
    }
  end
  return pairs
end

function M.none(_context)
  return {}
end

return M
