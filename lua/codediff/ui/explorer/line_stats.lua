local M = {}

local HIGHLIGHTS = {
  text = "CodeDiffExplorerStat",
  files = "CodeDiffExplorerStatFiles",
  insertions = "CodeDiffExplorerStatInsertions",
  deletions = "CodeDiffExplorerStatDeletions",
  binary = "CodeDiffExplorerStatBinary",
}

local function add_highlights(segments, default_highlight)
  local highlighted = {}
  for _, segment in ipairs(segments) do
    highlighted[#highlighted + 1] = {
      text = segment.text,
      hl = segment.kind and HIGHLIGHTS[segment.kind] or default_highlight,
    }
  end
  return highlighted
end

-- Returns highlighted parts, e.g. { { text = "+12", hl = "CodeDiffExplorerStatInsertions" } }.
function M.build_file_segments(stats, line_stats_options)
  if not stats then
    return {}
  end
  return add_highlights(line_stats_options.file_format(stats), "Normal")
end

function M.build_group_segments(files, line_stats_options)
  return add_highlights(line_stats_options.group_format(M.sum_text_stats(files)), "CodeDiffExplorerTreeGroup")
end

-- Joins highlighted parts into plain text for labels, e.g. "+12 -4".
function M.text(segments)
  local parts = {}
  for _, segment in ipairs(segments) do
    parts[#parts + 1] = segment.text
  end
  return table.concat(parts)
end

-- Sums text-file stats, e.g. +10/-2 and +3/-1 sum to: +13/-3.
function M.sum_text_stats(files)
  local total = { files_changed = #files, insertions = 0, deletions = 0 }
  for _, file in ipairs(files) do
    local stats = file.line_stats
    if stats and not stats.binary then
      total.insertions = total.insertions + (stats.insertions or 0)
      total.deletions = total.deletions + (stats.deletions or 0)
    end
  end
  return total
end

return M
