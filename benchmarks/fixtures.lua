local M = {}

M.diff_options = {
  ignore_trim_whitespace = false,
  max_computation_time_ms = 5000,
  compute_moves = false,
  extend_to_subwords = false,
}

local make_line = function(prefix, index)
  return string.format("%s line %05d value %08x", prefix, index, (index * 2654435761) % 4294967296)
end

local make_lines = function(count, prefix, replacement)
  local lines = {}
  for index = 1, count do
    lines[index] = replacement and replacement(index) or make_line(prefix, index)
  end
  return lines
end

local make_long_line = function(index, changed)
  local left = string.rep(string.char(97 + (index % 20)), 4096)
  local middle = changed and "CHANGED" or "original"
  return string.format("%04d %s %s %s", index, left, middle, left)
end

local make_large_insertion = function()
  local original = make_lines(6000, "insertion")
  local modified = {}
  for index = 1, 3000 do
    table.insert(modified, original[index])
  end
  for index = 1, 1000 do
    table.insert(modified, make_line("inserted", index))
  end
  for index = 3001, #original do
    table.insert(modified, original[index])
  end
  return original, modified
end

local make_repeated_context = function(changed)
  local lines = {}
  for index = 1, 600 do
    local value = changed and index % 100 == 0 and "changed" or "value"
    vim.list_extend(lines, {
      string.format("local function item_%04d()", index),
      "  if ready then",
      "    return " .. value,
      "  end",
      "end",
    })
  end
  return lines
end

local insertion_original, insertion_modified = make_large_insertion()
M.cases = {
  {
    name = "unchanged-large",
    original = make_lines(10000, "stable"),
    expected_changes = 0,
  },
  {
    name = "sparse-edits",
    original = make_lines(8000, "sparse"),
    modified = make_lines(8000, "sparse", function(index)
      return index % 800 == 0 and make_line("sparse replacement", index) or make_line("sparse", index)
    end),
    expected_changes = 10,
  },
  {
    name = "large-insertion",
    original = insertion_original,
    modified = insertion_modified,
    expected_changes = 1,
  },
  {
    name = "repeated-context",
    original = make_repeated_context(false),
    modified = make_repeated_context(true),
    expected_changes = 6,
  },
  {
    name = "dense-edits",
    original = make_lines(3000, "dense"),
    modified = make_lines(3000, "dense", function(index)
      return index % 2 == 0 and make_line("dense replacement", index) or make_line("dense", index)
    end),
    expected_changes = 1500,
  },
  {
    name = "long-lines",
    original = make_lines(240, "long", function(index)
      return make_long_line(index, false)
    end),
    modified = make_lines(240, "long", function(index)
      return make_long_line(index, index % 20 == 0)
    end),
    expected_changes = 12,
  },
  {
    name = "unicode",
    original = make_lines(3000, "unicode", function(index)
      return string.format("行 %05d — café Ελληνικά 🚀", index)
    end),
    modified = make_lines(3000, "unicode", function(index)
      local suffix = index % 100 == 0 and "変更 🐍" or "café Ελληνικά 🚀"
      return string.format("行 %05d — %s", index, suffix)
    end),
    expected_changes = 30,
  },
  {
    name = "full-rewrite",
    original = make_lines(1000, "before"),
    modified = make_lines(1000, "after"),
    expected_changes = 1,
  },
}

M.cases[1].modified = M.cases[1].original
M.by_name = {}
for _, case in ipairs(M.cases) do
  M.by_name[case.name] = case
end

return M
