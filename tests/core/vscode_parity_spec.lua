local diff = require("codediff.core.diff")
local line_matchers = require("codediff.line_matchers")

local copy_lines = function(lines)
  local copy = {}
  for index, line in ipairs(lines) do
    copy[index] = line
  end
  return copy
end

local normalize_diff = function(result)
  local changes = {}
  for index, change in ipairs(result.changes) do
    changes[index] = {
      original = change.original,
      modified = change.modified,
      inner_changes = change.inner_changes,
    }
  end

  return {
    changes = changes,
    moves = result.moves,
    hit_timeout = result.hit_timeout,
  }
end

local assert_native_parity = function(original, modified, options, message)
  local native_options = vim.tbl_extend("force", { max_computation_time_ms = 60000 }, options or {})
  local lua_options = vim.tbl_extend("force", native_options, { line_matcher = line_matchers.vscode })
  local native_result = diff._compute_native_diff(original, modified, native_options)
  local lua_result = diff.compute_diff(original, modified, lua_options)

  assert.same(normalize_diff(native_result), normalize_diff(lua_result), message)
end

local generated_case = function(index)
  local original = {}
  local line_count = index % 8 + 1
  for line = 1, line_count do
    original[line] = string.format("local value_%d_%d = source_%d + %d", index, line, line * 3, index + line)
  end

  local modified = copy_lines(original)
  if index % 2 == 0 then
    local line = index % #modified + 1
    modified[line] = string.format("local renamed_%d = source_%d + %d", index, line * 5, index)
  end
  if index % 3 == 0 then
    local line = index % (#modified + 1) + 1
    table.insert(modified, line, string.format("local inserted_%d = %d", index, index))
  end
  if index % 5 == 0 and #modified > 1 then
    table.remove(modified, index % #modified + 1)
  end
  if index % 7 == 0 then
    local line = index % #modified + 1
    modified[line] = "  " .. modified[line] .. "  "
  end
  if index % 11 == 0 and #modified > 1 then
    local line = index % (#modified - 1) + 1
    modified[line] = modified[line] .. modified[line + 1]
    table.remove(modified, line + 1)
  end

  return original, modified
end

describe("VS Code matcher native parity", function()
  local test_cases = {
    {
      name = "empty inputs",
      original = {},
      modified = {},
    },
    {
      name = "empty Neovim buffer insertion",
      original = { "" },
      modified = { "content" },
    },
    {
      name = "empty Neovim buffer deletion",
      original = { "content" },
      modified = { "" },
    },
    {
      name = "pure insertion",
      original = { "before", "after" },
      modified = { "before", "added", "after" },
    },
    {
      name = "pure deletion",
      original = { "before", "removed", "after" },
      modified = { "before", "after" },
    },
    {
      name = "replacement",
      original = { "local old_name = 1" },
      modified = { "local new_name = 1" },
    },
    {
      name = "line split",
      original = { "local result = prefix .. value" },
      modified = { "local result = prefix", "  .. value" },
    },
    {
      name = "line merge",
      original = { "local result = prefix", "  .. value" },
      modified = { "local result = prefix .. value" },
    },
    {
      name = "multiple line merges",
      original = { "one", "two", "three", "four" },
      modified = { "onetwo", "threefour" },
    },
    {
      name = "adjacent whitespace and line changes",
      original = { "keep", "value", "removed", "after" },
      modified = { "keep", "  value  ", "after" },
    },
    {
      name = "unicode changes",
      original = { "local café = '😀'" },
      modified = { "local cafe = '😃'" },
    },
    {
      name = "ignored whitespace",
      original = { "  value" },
      modified = { "    value  " },
      options = { ignore_trim_whitespace = true },
    },
    {
      name = "subword refinement",
      original = { "local oldValueName = 1" },
      modified = { "local newValueName = 1" },
      options = { extend_to_subwords = true },
    },
    {
      name = "moved code",
      original = { "function foo()", "  return 1", "end", "", "function bar()", "  return 2", "end" },
      modified = { "function bar()", "  return 2", "end", "", "function foo()", "  return 1", "end" },
      options = { compute_moves = true },
    },
  }

  for _, test_case in ipairs(test_cases) do
    it("matches native output for " .. test_case.name, function()
      assert_native_parity(test_case.original, test_case.modified, test_case.options)
    end)
  end

  it("matches native output for deterministic generated edits", function()
    for index = 1, 100 do
      local original, modified = generated_case(index)
      assert_native_parity(original, modified, nil, "generated case " .. index)
    end
  end)
end)
