local config = require("codediff.config")
local line_stats = require("codediff.ui.explorer.line_stats")
local nodes = require("codediff.ui.explorer.nodes")
local tree = require("codediff.ui.explorer.tree")

local reset_config = function()
  config.options = vim.deepcopy(config.defaults)
end

describe("Explorer line stats", function()
  before_each(function()
    reset_config()
  end)

  after_each(function()
    reset_config()
  end)

  it("is disabled with safe defaults", function()
    local options = config.options.explorer.line_stats
    assert.is_false(options.enabled)
    assert.is_true(options.group_totals)
    assert.is_false(options.count_untracked)
    assert.equals(1024 * 1024, options.max_untracked_bytes)
    assert.is_nil(options.format)
  end)

  it("formats text, binary, unavailable, and zero stats", function()
    local options = config.options.explorer.line_stats
    assert.equals("+3 -2", line_stats.text({ insertions = 3, deletions = 2 }, options))
    assert.equals("+3", line_stats.text({ insertions = 3, deletions = 0 }, options))
    assert.equals("", line_stats.text({ insertions = 0, deletions = 0 }, options))
    assert.equals("bin", line_stats.text({ binary = true }, options))
    assert.equals("", line_stats.text(nil, options))
  end)

  it("supports a custom formatter", function()
    local options = config.options.explorer.line_stats
    options.format = function(stats)
      if stats.binary then
        return "binary"
      end
      return string.format("%d added, %d removed", stats.insertions, stats.deletions)
    end

    assert.equals("3 added, 2 removed", line_stats.text({ insertions = 3, deletions = 2, binary = false }, options))
    assert.equals("binary", line_stats.text({ insertions = 0, deletions = 0, binary = true }, options))

    options.enabled = true
    local files = { { path = "changed.lua", status = "M", line_stats = { insertions = 3, deletions = 2, binary = false } } }
    local root = tree.create_tree_data({ unstaged = files, staged = {}, conflicts = {} }, "/repo", nil, false, { unstaged = true, staged = false })[1]
    assert.equals("Changes (1 · 3 added, 2 removed)", root.text)
  end)

  it("renders per-file stats and visible group totals", function()
    config.options.explorer.line_stats.enabled = true
    local files = {
      { path = "added.lua", status = "A", line_stats = { insertions = 20, deletions = 0 } },
      { path = "changed.lua", status = "M", line_stats = { insertions = 22, deletions = 8 } },
      { path = "image.png", status = "M", line_stats = { binary = true } },
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
      { path = "a-very-long-filename-that-needs-truncation.lua", status = "??", line_stats = { insertions = 4, deletions = 0 } },
    }
    local node = nodes.create_file_nodes(files, "/repo", "unstaged")[1]
    local content = nodes.prepare_node(node, 40, nil, nil):content()

    assert.matches("a%-very%-long%-filename.*%.%.%.%s+%+4 %?%? %s*$", content)
    assert.equals(40, vim.fn.strdisplaywidth(content))
  end)

  it("can hide group totals", function()
    config.options.explorer.line_stats.enabled = true
    config.options.explorer.line_stats.group_totals = false
    local files = { { path = "changed.lua", status = "M", line_stats = { insertions = 2, deletions = 1 } } }
    local root = tree.create_tree_data({ unstaged = files, staged = {}, conflicts = {} }, "/repo", nil, false, { unstaged = true, staged = false })[1]
    assert.equals("Changes (1)", root.text)
  end)
end)
