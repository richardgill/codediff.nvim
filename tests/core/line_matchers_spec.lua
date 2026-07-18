local diff = require("codediff.core.diff")
local line_matchers = require("codediff.line_matchers")

local context = {
  original_lines = { "one", "two" },
  modified_lines = { "ONE", "TWO" },
  original_start_line = 4,
  modified_start_line = 7,
}

describe("Line matchers", function()
  local equal_line_count_cases = {
    {
      name = "pairs equal line counts by position",
      context = context,
      expected = {
        { original_index = 1, modified_index = 1 },
        { original_index = 2, modified_index = 2 },
      },
    },
    {
      name = "does not pair unequal line counts",
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
      { { original_index = 1, modified_index = 1 } },
      line_matchers.similarity(similar_context, {
        threshold = 0.6,
      })
    )
  end)

  it("returns ordered similarity pairs and leaves unrelated lines unpaired", function()
    local pairs = line_matchers.similarity({
      original_lines = { "local old_name = 1", "removed without match", "print(old_name)" },
      modified_lines = { "local new_name = 1", "print(new_name)", "unrelated insertion" },
    })

    assert.same({
      { original_index = 1, modified_index = 1 },
      { original_index = 3, modified_index = 2 },
    }, pairs)
  end)

  it("passes changed block context to a custom matcher", function()
    local received_context
    local result = diff.compute_diff({ "before", "old value", "deleted" }, { "before", "new value", "inserted" }, {
      line_matcher = function(matcher_context)
        received_context = matcher_context
        return { { original_index = 1, modified_index = 1 } }
      end,
    })

    assert.same({ "old value", "deleted" }, received_context.original_lines)
    assert.same({ "new value", "inserted" }, received_context.modified_lines)
    assert.equal(2, received_context.original_start_line)
    assert.equal(2, received_context.modified_start_line)
    assert.same({ { original_line = 2, modified_line = 2 } }, result.changes[1].line_pairs)
    assert.is_true(#result.changes[1].inner_changes > 0)
  end)

  it("omits character changes when matching is disabled", function()
    local result = diff.compute_diff({ "old value" }, { "new value" }, {
      line_matcher = line_matchers.none,
    })

    assert.same({}, result.changes[1].line_pairs)
    assert.same({}, result.changes[1].inner_changes)
  end)
end)
