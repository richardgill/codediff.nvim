local M = {}

-- Wraps styled segments in a fixed or priority-truncatable layout region.
local function region(segments, options)
  return vim.tbl_extend("force", { segments = segments }, options or {})
end

-- Appends a highlighted stat with a separating space when needed.
local function append_stat(segments, text, hl)
  if #segments > 0 then
    segments[#segments + 1] = { text = " ", hl = "Normal" }
  end
  segments[#segments + 1] = { text = text, hl = hl }
end

-- Formats Git stats as semantic segments, for example `+12 -4` or `3 files +12 -4`.
local function stat_segments(stats, include_files)
  if not stats then
    return {}
  end
  if stats.binary then
    return { { text = "bin", hl = "CodeDiffExplorerStatBinary" } }
  end

  local segments = {}
  if include_files then
    append_stat(segments, tostring(stats.files_changed) .. " files", "CodeDiffExplorerStatFiles")
  end
  if (stats.insertions or 0) > 0 then
    append_stat(segments, "+" .. stats.insertions, "CodeDiffExplorerStatInsertions")
  end
  if (stats.deletions or 0) > 0 then
    append_stat(segments, "-" .. stats.deletions, "CodeDiffExplorerStatDeletions")
  end
  return segments
end

-- Builds the fixed file-line prefix from its indentation and optional icon.
local function file_prefix(ctx)
  local segments = { { text = ctx.indent, hl = ctx.indent_hl } }
  if ctx.icon ~= "" then
    segments[#segments + 1] = { text = ctx.icon, hl = ctx.icon_hl }
    segments[#segments + 1] = { text = " ", hl = "Normal" }
  end
  return segments
end

-- Formats a file line as truncatable path content followed by right-aligned stats and status.
function M.file(ctx)
  local left = {
    region(file_prefix(ctx)),
    region({ { text = ctx.filename, hl = "Normal" } }, { truncate_priority = 2 }),
  }
  if ctx.directory ~= "" then
    left[#left + 1] = region({
      { text = " ", hl = "Normal" },
      { text = ctx.directory, hl = "ExplorerDirectorySmall" },
    }, { truncate_priority = 1 })
  end

  local right = {}
  local stats = stat_segments(ctx.stats, false)
  if #stats > 0 then
    stats[#stats + 1] = { text = " ", hl = "Normal" }
    right[#right + 1] = region(stats, { truncate_priority = 3 })
  end
  right[#right + 1] = region({
    { text = ctx.status, hl = ctx.status_hl },
    { text = string.rep(" ", ctx.status_right_margin), hl = "Normal" },
  })

  return { left = left, right = right, min_gap = 2 }
end

-- Formats a folder line from its fixed indentation/icon prefix and truncatable name.
function M.folder(ctx)
  local prefix = { { text = ctx.indent, hl = ctx.indent_hl } }
  if ctx.icon ~= "" then
    prefix[#prefix + 1] = { text = ctx.icon, hl = ctx.icon_hl }
    prefix[#prefix + 1] = { text = " ", hl = "Normal" }
  end
  return {
    left = {
      region(prefix),
      region({ { text = ctx.name, hl = "Directory" } }, { truncate_priority = 1 }),
    },
    right = {},
    min_gap = 2,
  }
end

-- Formats a group heading with its file count and optional aggregate Git stats.
function M.group(ctx)
  local summary = {
    { text = " (", hl = "CodeDiffExplorerTreeGroup" },
    { text = tostring(ctx.file_count), hl = ctx.stats and "CodeDiffExplorerStatFiles" or "CodeDiffExplorerTreeGroup" },
  }
  if ctx.stats and ctx.stats.insertions > 0 then
    summary[#summary + 1] = { text = " · ", hl = "CodeDiffExplorerTreeGroup" }
    summary[#summary + 1] = { text = "+" .. ctx.stats.insertions, hl = "CodeDiffExplorerStatInsertions" }
  end
  if ctx.stats and ctx.stats.deletions > 0 then
    summary[#summary + 1] = { text = ctx.stats.insertions > 0 and " " or " · ", hl = "CodeDiffExplorerTreeGroup" }
    summary[#summary + 1] = { text = "-" .. ctx.stats.deletions, hl = "CodeDiffExplorerStatDeletions" }
  end
  summary[#summary + 1] = { text = ")", hl = "CodeDiffExplorerTreeGroup" }

  return {
    left = {
      region({ { text = " ", hl = "CodeDiffExplorerTreeGroup" } }),
      region({ { text = ctx.label, hl = "CodeDiffExplorerTreeGroup" } }, { truncate_priority = 2 }),
      region(summary, { truncate_priority = 1 }),
    },
    right = {},
    min_gap = 2,
  }
end

return M
