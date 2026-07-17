local M = {}

local HIGHLIGHTS = {
  custom = "CodeDiffExplorerStat",
  insertions = "CodeDiffExplorerStatInsertions",
  deletions = "CodeDiffExplorerStatDeletions",
  binary = "CodeDiffExplorerStatBinary",
}

-- Returns highlighted parts, e.g. { { text = "+12", hl = "CodeDiffExplorerStatInsertions" } }.
function M.build_segments(stats, line_stats_options)
  if not stats then
    return {}
  end
  local formatter = line_stats_options.format
  if formatter then
    local text = formatter(stats)
    return text and text ~= "" and { { text = text, hl = HIGHLIGHTS.custom } } or {}
  end
  if stats.binary then
    return { { text = "bin", hl = HIGHLIGHTS.binary } }
  end

  local segments = {}
  local insertions = stats.insertions or 0
  local deletions = stats.deletions or 0
  if insertions > 0 then
    segments[#segments + 1] = { text = "+" .. insertions, hl = HIGHLIGHTS.insertions }
  end
  if deletions > 0 then
    segments[#segments + 1] = { text = "-" .. deletions, hl = HIGHLIGHTS.deletions }
  end
  return segments
end

-- Joins highlighted parts into plain text for labels, e.g. "+12 -4".
function M.text(stats, line_stats_options)
  local parts = {}
  for _, segment in ipairs(M.build_segments(stats, line_stats_options)) do
    parts[#parts + 1] = segment.text
  end
  return table.concat(parts, " ")
end

-- Sums text-file stats, e.g. +10/-2 and +3/-1 sum to: +13/-3; returns nil when none are available.
function M.sum_text_stats(files)
  local total = { insertions = 0, deletions = 0, binary = false }
  local has_text_stats = false
  for _, file in ipairs(files) do
    local stats = file.line_stats
    if stats and not stats.binary then
      total.insertions = total.insertions + (stats.insertions or 0)
      total.deletions = total.deletions + (stats.deletions or 0)
      has_text_stats = true
    end
  end
  return has_text_stats and total or nil
end

return M
