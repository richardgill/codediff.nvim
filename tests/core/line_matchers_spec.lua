local diff = require("codediff.core.diff")
local line_matchers = require("codediff.line_matchers")

local context = {
  original_lines = { "one", "two" },
  modified_lines = { "ONE", "TWO" },
  original_start_line = 4,
  modified_start_line = 7,
}

local one_line_mapping = function(original_index, modified_index)
  return {
    original = { start_index = original_index, end_index = original_index + 1 },
    modified = { start_index = modified_index, end_index = modified_index + 1 },
  }
end

local compute_with_mappings = function(mappings)
  return diff.compute_diff({ "original one", "original two" }, { "modified one", "modified two" }, {
    line_matcher = function()
      return mappings
    end,
  })
end

describe("Line matchers", function()
  local equal_line_count_cases = {
    {
      name = "maps equal line counts by position",
      context = context,
      expected = {
        one_line_mapping(1, 1),
        one_line_mapping(2, 2),
      },
    },
    {
      name = "does not map unequal line counts",
      context = {
        original_lines = { "one" },
        modified_lines = { "ONE", "extra" },
      },
      expected = {},
    },
  }

  for _, test_case in ipairs(equal_line_count_cases) do
    it(test_case.name, function()
      assert.same(test_case.expected, line_matchers.equal_line_count(test_case.context))
    end)
  end

  it("uses a configurable similarity threshold", function()
    local similar_context = {
      original_lines = { "cat" },
      modified_lines = { "cut" },
    }

    assert.same({}, line_matchers.similarity(similar_context))
    assert.same(
      { one_line_mapping(1, 1) },
      line_matchers.similarity(similar_context, {
        threshold = 0.6,
      })
    )
  end)

  it("returns ordered similarity mappings and leaves unrelated lines unmapped", function()
    local mappings = line_matchers.similarity({
      original_lines = { "local old_name = 1", "removed without match", "print(old_name)" },
      modified_lines = { "local new_name = 1", "print(new_name)", "unrelated insertion" },
    })

    assert.same({
      one_line_mapping(1, 1),
      one_line_mapping(3, 2),
    }, mappings)
  end)

  it("passes changed block context to a custom matcher", function()
    local received_context
    local result = diff.compute_diff({ "before", "old value", "deleted" }, { "before", "new value", "inserted" }, {
      line_matcher = function(matcher_context)
        received_context = matcher_context
        return { one_line_mapping(1, 1) }
      end,
    })

    assert.same({ "old value", "deleted" }, received_context.original_lines)
    assert.same({ "new value", "inserted" }, received_context.modified_lines)
    assert.equal(2, received_context.original_start_line)
    assert.equal(2, received_context.modified_start_line)
    assert.same({ start_line = 2, end_line = 3 }, result.changes[1].line_mappings[1].original)
    assert.same({ start_line = 2, end_line = 3 }, result.changes[1].line_mappings[1].modified)
    assert.is_true(#result.changes[1].inner_changes > 0)
  end)

  it("refines a one-to-many line mapping", function()
    local result = diff.compute_diff({ "before", "local result = prefix .. value", "after" }, { "before", "local result = prefix", "  .. value", "after" }, {
      line_matcher = function()
        return {
          {
            original = { start_index = 1, end_index = 2 },
            modified = { start_index = 1, end_index = 3 },
          },
        }
      end,
    })

    local mapping = result.changes[1].line_mappings[1]
    assert.same({ start_line = 2, end_line = 3 }, mapping.original)
    assert.same({ start_line = 2, end_line = 4 }, mapping.modified)
    assert.is_true(#mapping.inner_changes > 0)
  end)

  it("refines a many-to-one line mapping", function()
    local result = diff.compute_diff({ "before", "local result = prefix", "  .. value", "after" }, { "before", "local result = prefix .. value", "after" }, {
      line_matcher = function()
        return {
          {
            original = { start_index = 1, end_index = 3 },
            modified = { start_index = 1, end_index = 2 },
          },
        }
      end,
    })

    local mapping = result.changes[1].line_mappings[1]
    assert.same({ start_line = 2, end_line = 4 }, mapping.original)
    assert.same({ start_line = 2, end_line = 3 }, mapping.modified)
    assert.is_true(#mapping.inner_changes > 0)
  end)

  local pure_change_cases = {
    {
      name = "allows a custom matcher to map a pure insertion",
      original = { "before", "after" },
      modified = { "before", "added", "after" },
      mapping = {
        original = { start_index = 1, end_index = 1 },
        modified = { start_index = 1, end_index = 2 },
      },
      expected_context = { original = {}, modified = { "added" } },
      expected_original = { start_line = 2, end_line = 2 },
      expected_modified = { start_line = 2, end_line = 3 },
    },
    {
      name = "allows a custom matcher to map a pure deletion",
      original = { "before", "removed", "after" },
      modified = { "before", "after" },
      mapping = {
        original = { start_index = 1, end_index = 2 },
        modified = { start_index = 1, end_index = 1 },
      },
      expected_context = { original = { "removed" }, modified = {} },
      expected_original = { start_line = 2, end_line = 3 },
      expected_modified = { start_line = 2, end_line = 2 },
    },
  }

  for _, test_case in ipairs(pure_change_cases) do
    it(test_case.name, function()
      local received_context
      local result = diff.compute_diff(test_case.original, test_case.modified, {
        line_matcher = function(matcher_context)
          received_context = matcher_context
          return { test_case.mapping }
        end,
      })

      assert.same(test_case.expected_context.original, received_context.original_lines)
      assert.same(test_case.expected_context.modified, received_context.modified_lines)
      assert.same(test_case.expected_original, result.changes[1].line_mappings[1].original)
      assert.same(test_case.expected_modified, result.changes[1].line_mappings[1].modified)
    end)
  end

  it("omits character changes when matching is disabled", function()
    local result = diff.compute_diff({ "old value" }, { "new value" }, {
      line_matcher = line_matchers.none,
    })

    assert.same({}, result.changes[1].line_mappings)
    assert.same({}, result.changes[1].inner_changes)
  end)

  local invalid_mapping_cases = {
    {
      name = "rejects reversed ranges",
      mappings = {
        {
          original = { start_index = 2, end_index = 1 },
          modified = { start_index = 1, end_index = 2 },
        },
      },
      error_pattern = "out of bounds",
    },
    {
      name = "rejects out-of-bounds ranges",
      mappings = {
        {
          original = { start_index = 1, end_index = 4 },
          modified = { start_index = 1, end_index = 2 },
        },
      },
      error_pattern = "out of bounds",
    },
    {
      name = "rejects mappings empty on both sides",
      mappings = {
        {
          original = { start_index = 1, end_index = 1 },
          modified = { start_index = 1, end_index = 1 },
        },
      },
      error_pattern = "cannot be empty on both sides",
    },
    {
      name = "rejects crossing mappings",
      mappings = {
        one_line_mapping(1, 2),
        one_line_mapping(2, 1),
      },
      error_pattern = "ordered and non%-overlapping",
    },
  }

  for _, test_case in ipairs(invalid_mapping_cases) do
    it(test_case.name, function()
      local success, error_message = pcall(compute_with_mappings, test_case.mappings)
      assert.is_false(success)
      assert.matches(test_case.error_pattern, error_message)
    end)
  end
end)
