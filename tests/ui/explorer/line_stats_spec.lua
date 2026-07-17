local config = require("codediff.config")
local line_stats = require("codediff.ui.explorer.line_stats")
local nodes = require("codediff.ui.explorer.nodes")
local tree = require("codediff.ui.explorer.tree")

local reset_config = function()
  config.options = vim.deepcopy(config.defaults)
end

local get_segment = function(segments, text)
  for _, segment in ipairs(segments) do
    if segment.text == text then
      return segment
    end
  end
end

describe("Explorer line stats", function()
  before_each(function()
    reset_config()
  end)

  after_each(function()
    reset_config()
  end)

  it("is disabled with formatter defaults", function()
    local options = config.options.explorer.line_stats
    assert.is_false(options.enabled)
    assert.is_true(options.group_totals)
    assert.is_false(options.count_untracked)
    assert.equals(1024 * 1024, options.max_untracked_bytes)
    assert.is_function(options.file_format)
    assert.is_function(options.group_format)
  end)

  it("formats default file and group segments with semantic highlights", function()
    local options = config.options.explorer.line_stats
    local file_segments = line_stats.build_file_segments({ insertions = 3, deletions = 2, binary = false }, options)
    assert.equals("+3 -2", line_stats.text(file_segments))
    assert.equals("CodeDiffExplorerStatInsertions", get_segment(file_segments, "+3").hl)
    assert.equals("Normal", get_segment(file_segments, " ").hl)
    assert.equals("CodeDiffExplorerStatDeletions", get_segment(file_segments, "-2").hl)

    assert.equals("+3", line_stats.text(line_stats.build_file_segments({ insertions = 3, deletions = 0, binary = false }, options)))
    assert.equals("-2", line_stats.text(line_stats.build_file_segments({ insertions = 0, deletions = 2, binary = false }, options)))
    assert.equals("", line_stats.text(line_stats.build_file_segments({ insertions = 0, deletions = 0, binary = false }, options)))
    assert.equals("bin", line_stats.text(line_stats.build_file_segments({ insertions = 0, deletions = 0, binary = true }, options)))
    assert.equals("", line_stats.text(line_stats.build_file_segments(nil, options)))

    local files = {
      { line_stats = { insertions = 3, deletions = 2, binary = false } },
      { line_stats = { insertions = 0, deletions = 0, binary = true } },
      {},
    }
    local group_segments = line_stats.build_group_segments(files, options)
    assert.equals("3 · +3 -2", line_stats.text(group_segments))
    assert.equals("CodeDiffExplorerStatFiles", get_segment(group_segments, "3").hl)
    assert.equals("CodeDiffExplorerTreeGroup", get_segment(group_segments, " · ").hl)

    local deleted_file = { { line_stats = { insertions = 0, deletions = 2, binary = false } } }
    assert.equals("1 · -2", line_stats.text(line_stats.build_group_segments(deleted_file, options)))
  end)

  it("supports separate semantic file and group formatters", function()
    local options = config.options.explorer.line_stats
    local received_group_stats
    options.file_format = function(stats)
      if stats.binary then
        return { { text = "binary", kind = "binary" } }
      end
      return {
        { text = stats.insertions .. " added", kind = "insertions" },
        { text = ", " },
        { text = stats.deletions .. " removed", kind = "deletions" },
        { text = " reviewed", kind = "text" },
      }
    end
    options.group_format = function(stats)
      received_group_stats = stats
      return {
        { text = stats.files_changed .. " files", kind = "files" },
        { text = " · " },
        { text = stats.insertions .. " added", kind = "insertions" },
        { text = " · " },
        { text = stats.deletions .. " removed", kind = "deletions" },
      }
    end
    options.enabled = true

    local files = {
      { path = "changed.lua", status = "M", line_stats = { insertions = 3, deletions = 2, binary = false } },
      { path = "image.png", status = "M", line_stats = { insertions = 0, deletions = 0, binary = true } },
    }
    local root = tree.create_tree_data({ unstaged = files, staged = {}, conflicts = {} }, "/repo", nil, false, { unstaged = true, staged = false })[1]
    assert.equals("Changes (2 files · 3 added · 2 removed)", root.text)
    assert.same({ files_changed = 2, insertions = 3, deletions = 2 }, received_group_stats)

    local group_line = nodes.prepare_node(root, 50, nil, nil)
    assert.equals("CodeDiffExplorerStatFiles", get_segment(group_line._segments, "2 files").hl)
    assert.equals("CodeDiffExplorerStatInsertions", get_segment(group_line._segments, "3 added").hl)
    assert.equals("CodeDiffExplorerStatDeletions", get_segment(group_line._segments, "2 removed").hl)

    local file_node = nodes.create_file_nodes(files, "/repo", "unstaged")[1]
    local file_line = nodes.prepare_node(file_node, 60, nil, nil)
    assert.equals("CodeDiffExplorerStatInsertions", get_segment(file_line._segments, "3 added").hl)
    assert.equals("CodeDiffExplorerStatDeletions", get_segment(file_line._segments, "2 removed").hl)
    assert.equals("CodeDiffExplorerStat", get_segment(file_line._segments, " reviewed").hl)
  end)

  it("renders per-file stats and visible group totals", function()
    config.options.explorer.line_stats.enabled = true
    local files = {
      { path = "added.lua", status = "A", line_stats = { insertions = 20, deletions = 0, binary = false } },
      { path = "changed.lua", status = "M", line_stats = { insertions = 22, deletions = 8, binary = false } },
      { path = "image.png", status = "M", line_stats = { insertions = 0, deletions = 0, binary = true } },
    }
    local root = tree.create_tree_data({ unstaged = files, staged = {}, conflicts = {} }, "/repo", nil, false, { unstaged = true, staged = false })[1]
    assert.equals("Changes (3 · +42 -8)", root.text)

    local node = nodes.create_file_nodes(files, "/repo", "unstaged")[2]
    local content = nodes.prepare_node(node, 50, nil, nil):content()
    assert.matches("changed%.lua%s+%+22 %-8 M%s*$", content)
  end)

  it("keeps stats and status visible for long filenames", function()
    config.options.explorer.line_stats.enabled = true
    local files = {
      { path = "a-very-long-filename-that-needs-truncation.lua", status = "??", line_stats = { insertions = 4, deletions = 0, binary = false } },
    }
    local node = nodes.create_file_nodes(files, "/repo", "unstaged")[1]
    local content = nodes.prepare_node(node, 40, nil, nil):content()

    assert.matches("a%-very%-long%-filename.*%.%.%.%s+%+4 %?%? %s*$", content)
    assert.equals(40, vim.fn.strdisplaywidth(content))
  end)

  it("can hide group totals", function()
    config.options.explorer.line_stats.enabled = true
    config.options.explorer.line_stats.group_totals = false
    local files = { { path = "changed.lua", status = "M", line_stats = { insertions = 2, deletions = 1, binary = false } } }
    local root = tree.create_tree_data({ unstaged = files, staged = {}, conflicts = {} }, "/repo", nil, false, { unstaged = true, staged = false })[1]
    assert.equals("Changes (1)", root.text)
    assert.same({ { text = "1", hl = "CodeDiffExplorerTreeGroup" } }, root.data.stat_segments)
  end)
end)
