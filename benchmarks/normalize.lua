local M = {}

local append_range = function(parts, label, range)
  parts[#parts + 1] = string.format("%s:%d:%d:%d:%d", label, range.start_line, range.start_col or 0, range.end_line, range.end_col or 0)
end

local append_line_mapping = function(parts, mapping)
  append_range(parts, "lo", mapping.original)
  append_range(parts, "lm", mapping.modified)
  for _, inner in ipairs(mapping.inner_changes or {}) do
    append_range(parts, "lio", inner.original)
    append_range(parts, "lim", inner.modified)
  end
end

function M.hash_lines_diff(result)
  local parts = { result.hit_timeout and "timeout:1" or "timeout:0" }
  for _, change in ipairs(result.changes or {}) do
    append_range(parts, "co", change.original)
    append_range(parts, "cm", change.modified)
    for _, inner in ipairs(change.inner_changes or {}) do
      append_range(parts, "io", inner.original)
      append_range(parts, "im", inner.modified)
    end
    for _, mapping in ipairs(change.line_mappings or {}) do
      append_line_mapping(parts, mapping)
    end
  end
  for _, move in ipairs(result.moves or {}) do
    append_range(parts, "mo", move.original)
    append_range(parts, "mm", move.modified)
  end
  return vim.fn.sha256(table.concat(parts, "|"))
end

return M
