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

local make_dense_block = function(block_size, changed)
  return make_lines(1000, "dense block", function(index)
    local in_block = index > 400 and index <= 400 + block_size
    return changed and in_block and make_line("dense replacement", index) or make_line("dense block", index)
  end)
end

local make_interleaved = function(modified)
  local lines = {}
  for index = 1, 100 do
    local prefix = modified and "new entry" or "old entry"
    lines[#lines + 1] = make_line(prefix, index)
    if modified and index % 5 == 0 then
      lines[#lines + 1] = make_line("interleaved insertion", index)
    end
  end
  return lines
end

local make_sparse_blocks = function(changed)
  return make_lines(5000, "sparse blocks", function(index)
    return changed and index % 50 == 0 and make_line("sparse replacement", index) or make_line("sparse blocks", index)
  end)
end

local load_pinned_file = function(revision, path)
  local lines = vim.fn.systemlist({ "git", "show", revision .. ":" .. path })
  assert(vim.v.shell_error == 0, string.format("cannot load pinned fixture %s:%s", revision, path))
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
    name = "pure-insertion-1000",
    original = { "" },
    modified = make_lines(1000, "pure insertion"),
    expected_changes = 1,
  },
  {
    name = "pure-deletion-1000",
    original = make_lines(1000, "pure deletion"),
    modified = { "" },
    expected_changes = 1,
  },
  {
    name = "dense-block-50",
    original = make_dense_block(50, false),
    modified = make_dense_block(50, true),
    expected_changes = 1,
  },
  {
    name = "dense-block-200",
    original = make_dense_block(200, false),
    modified = make_dense_block(200, true),
    expected_changes = 1,
  },
  {
    name = "interleaved-100x120",
    original = make_interleaved(false),
    modified = make_interleaved(true),
    expected_changes = 1,
  },
  {
    name = "sparse-100-blocks",
    original = make_sparse_blocks(false),
    modified = make_sparse_blocks(true),
    expected_changes = 100,
  },
  {
    name = "real-lua-navigation",
    original = load_pinned_file("52c3dd434f6ddb428ea671334ab9774ac46a7787^", "lua/codediff/ui/view/navigation.lua"),
    modified = load_pinned_file("52c3dd434f6ddb428ea671334ab9774ac46a7787", "lua/codediff/ui/view/navigation.lua"),
    expected_changes = 3,
  },
  {
    name = "real-docs-index",
    original = load_pinned_file("0bc4a59da4c082b0e844e12121bece3de3f83748^", "docs/README.md"),
    modified = load_pinned_file("0bc4a59da4c082b0e844e12121bece3de3f83748", "docs/README.md"),
    expected_changes = 4,
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
