local model = require("codediff.ui.wrap_alignment_model")

local make_diff = function(change)
  return { changes = change and { change } or {}, moves = {} }
end

local make_change = function(original_end, modified_end, inner_changes)
  return {
    original = { start_line = 1, end_line = original_end },
    modified = { start_line = 1, end_line = modified_end },
    inner_changes = inner_changes or {},
  }
end

local line_change = function(original_start, original_end, modified_start, modified_end)
  return {
    original = { start_line = original_start, end_line = original_end },
    modified = { start_line = modified_start, end_line = modified_end },
    inner_changes = {},
  }
end

local get_boundaries = function(intervals, side)
  local boundaries = { intervals[1].ranges[side].start_row }
  for _, interval in ipairs(intervals) do
    boundaries[#boundaries + 1] = interval.ranges[side].end_row
  end
  return boundaries
end

describe("wrapped alignment model", function()
  it("projects coarse n-ary mappings to the nearest line boundary", function()
    local base_lines = { "one", "two", "three", "four", "five", "six" }
    local intervals = model.build({
      base_count = #base_lines,
      base_lines = base_lines,
      panes = {
        { side = "base", line_count = 6 },
        { side = "expanded", line_count = 7, diff = make_diff(make_change(7, 8)) },
        { side = "contracted", line_count = 5, diff = make_diff(make_change(7, 6)) },
      },
    })

    assert.are.same({ 0, 1, 2, 3, 4, 5, 6 }, get_boundaries(intervals, "base"))
    assert.are.same({ 0, 1, 2, 4, 5, 6, 7 }, get_boundaries(intervals, "expanded"))
    assert.are.same({ 0, 1, 2, 3, 3, 4, 5 }, get_boundaries(intervals, "contracted"))
  end)

  it("combines overlapping conflict shapes on one base coordinate", function()
    local base_lines = { "one", "two", "three", "four", "five", "six" }
    local intervals = model.build({
      base_count = #base_lines,
      base_lines = base_lines,
      panes = {
        { side = "result", line_count = 6 },
        {
          side = "expanded",
          line_count = 7,
          diff = make_diff({
            original = { start_line = 1, end_line = 5 },
            modified = { start_line = 1, end_line = 6 },
            inner_changes = {},
          }),
        },
        {
          side = "contracted",
          line_count = 5,
          diff = make_diff({
            original = { start_line = 3, end_line = 7 },
            modified = { start_line = 3, end_line = 6 },
            inner_changes = {},
          }),
        },
      },
    })

    assert.are.same({ 0, 1, 2, 3, 4, 5, 6 }, get_boundaries(intervals, "result"))
    assert.are.same({ 0, 1, 3, 4, 5, 6, 7 }, get_boundaries(intervals, "expanded"))
    assert.are.same({ 0, 1, 2, 3, 4, 4, 5 }, get_boundaries(intervals, "contracted"))
  end)

  it("retains inner line mappings inside a large changed hunk", function()
    local base_lines = { "alpha", "bravo", "charlie", "delta", "echo" }
    local inner_changes = {
      {
        original = { start_line = 1, start_col = 2, end_line = 1, end_col = 3 },
        modified = { start_line = 1, start_col = 2, end_line = 1, end_col = 3 },
      },
      {
        original = { start_line = 3, start_col = 2, end_line = 3, end_col = 4 },
        modified = { start_line = 4, start_col = 2, end_line = 4, end_col = 4 },
      },
    }
    local intervals = model.build({
      base_count = #base_lines,
      base_lines = base_lines,
      panes = {
        { side = "base", line_count = 5 },
        { side = "pane", line_count = 6, diff = make_diff(make_change(6, 7, inner_changes)) },
      },
    })

    assert.equal(3, intervals[2].ranges.pane.end_row)
    assert.equal(3, intervals[3].ranges.pane.start_row)
  end)

  it("preserves source anchors when an edited result has a coarse base mapping", function()
    local base_lines = { "one", "two", "three", "four", "five", "six" }
    local source_to_result = make_diff({
      original = { start_line = 4, end_line = 4 },
      modified = { start_line = 4, end_line = 6 },
      inner_changes = {},
    })
    local intervals = model.build({
      base_count = #base_lines,
      base_lines = base_lines,
      panes = {
        { side = "base", line_count = 6 },
        { side = "source", lines = base_lines, line_count = 6 },
        {
          side = "result",
          line_count = 8,
          diff = make_diff(make_change(7, 9)),
          alignment_sources = { { side = "source", diff = source_to_result } },
        },
      },
    })

    assert.are.same({ 0, 1, 2, 3, 3, 4, 5, 6 }, get_boundaries(intervals, "source"))
    assert.are.same({ 0, 1, 2, 3, 5, 6, 7, 8 }, get_boundaries(intervals, "result"))
  end)

  it("aligns concatenated accepted blocks to the later source region", function()
    local base_lines = { "head", "base one", "base two", "tail" }
    local incoming_lines = { "head", "incoming one", "incoming two", "tail" }
    local current_lines = { "head", "current one", "current two", "tail" }
    local test_cases = {
      {
        lines = { "head", "incoming one", "incoming two", "current one", "current two", "tail" },
        selected_side = "current",
        sources = {
          { side = "incoming", diff = make_diff(line_change(4, 4, 4, 6)) },
          { side = "current", diff = make_diff(line_change(2, 2, 2, 4)) },
        },
      },
      {
        lines = { "head", "current one", "current two", "incoming one", "incoming two", "tail" },
        selected_side = "incoming",
        sources = {
          { side = "incoming", diff = make_diff(line_change(2, 2, 2, 4)) },
          { side = "current", diff = make_diff(line_change(4, 4, 4, 6)) },
        },
      },
    }

    for _, test_case in ipairs(test_cases) do
      local intervals = model.build({
        base_count = #base_lines,
        base_lines = base_lines,
        panes = {
          { side = "base", lines = base_lines, line_count = #base_lines },
          {
            side = "incoming",
            lines = incoming_lines,
            line_count = #incoming_lines,
            diff = make_diff(line_change(2, 4, 2, 4)),
          },
          {
            side = "current",
            lines = current_lines,
            line_count = #current_lines,
            diff = make_diff(line_change(2, 4, 2, 4)),
          },
          {
            side = "result",
            lines = test_case.lines,
            line_count = #test_case.lines,
            diff = make_diff(line_change(2, 4, 2, 6)),
            alignment_sources = test_case.sources,
          },
        },
      })

      assert.are.same({ start_row = 1, end_row = 3 }, intervals[2].ranges.result)
      assert.are.same({ start_row = 1, end_row = 1 }, intervals[2].ranges[test_case.selected_side])
      assert.are.same({ start_row = 3, end_row = 4 }, intervals[3].ranges.result)
      assert.are.same({ start_row = 1, end_row = 2 }, intervals[3].ranges[test_case.selected_side])
      assert.are.same({ start_row = 4, end_row = 5 }, intervals[4].ranges.result)
      assert.are.same({ start_row = 2, end_row = 3 }, intervals[4].ranges[test_case.selected_side])
    end
  end)

  it("composes result alignment from different sources by region", function()
    local base_lines = { "head", "base one", "middle", "base two", "tail" }
    local incoming_lines = { "head", "incoming one a", "incoming one b", "middle", "incoming two", "tail" }
    local current_lines = { "head", "current one", "middle", "current two a", "current two b", "tail" }
    local result_lines = { "head", "incoming one a", "incoming one b", "middle", "current two a", "current two b", "tail" }
    local incoming_diff = {
      changes = { line_change(2, 3, 2, 4), line_change(4, 5, 5, 6) },
      moves = {},
    }
    local current_diff = {
      changes = { line_change(2, 3, 2, 3), line_change(4, 5, 4, 6) },
      moves = {},
    }
    local result_diff = {
      changes = { line_change(2, 3, 2, 4), line_change(4, 5, 5, 7) },
      moves = {},
    }
    local intervals = model.build({
      base_count = #base_lines,
      base_lines = base_lines,
      panes = {
        { side = "base", lines = base_lines, line_count = #base_lines },
        { side = "incoming", lines = incoming_lines, line_count = #incoming_lines, diff = incoming_diff },
        { side = "current", lines = current_lines, line_count = #current_lines, diff = current_diff },
        {
          side = "result",
          lines = result_lines,
          line_count = #result_lines,
          diff = result_diff,
          alignment_sources = {
            { side = "incoming", diff = make_diff(line_change(5, 6, 5, 7)) },
            { side = "current", diff = make_diff(line_change(2, 3, 2, 4)) },
          },
        },
      },
    })

    local first_region = nil
    local second_region = nil
    for _, interval in ipairs(intervals) do
      if interval.ranges.base.start_row == 1 and interval.ranges.base.end_row == 2 then
        first_region = interval
      elseif interval.ranges.base.start_row == 3 and interval.ranges.base.end_row == 4 then
        second_region = interval
      end
    end
    assert.are.same({ start_row = 1, end_row = 3 }, first_region.ranges.result)
    assert.are.same({ start_row = 4, end_row = 6 }, second_region.ranges.result)
  end)

  it("keeps move annotations on both semantic boundaries", function()
    local base_lines = { "one", "two", "three", "four", "five", "six" }
    local pane_diff = make_diff(make_change(7, 8))
    pane_diff.moves = {
      {
        original = { start_line = 4, end_line = 5 },
        modified = { start_line = 5, end_line = 6 },
      },
    }
    local intervals = model.build({
      base_count = #base_lines,
      base_lines = base_lines,
      base_side = "base",
      panes = {
        { side = "base", line_count = 6 },
        { side = "pane", line_count = 7, diff = pane_diff },
      },
    })

    assert.equal(1, intervals[4].leading_rows.base)
    assert.equal(1, intervals[4].leading_rows.pane)
  end)
end)
