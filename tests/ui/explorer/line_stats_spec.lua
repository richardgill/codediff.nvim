local config = require("codediff.config")
local line_layout = require("codediff.ui.explorer.line_layout")
local line_stats = require("codediff.ui.explorer.line_stats")
local nodes = require("codediff.ui.explorer.nodes")
local tree = require("codediff.ui.explorer.tree")

local reset_config = function()
  config.options = vim.deepcopy(config.defaults)
end

local fixed_layout = function(text, hl)
  return {
    left = { { segments = { { text = text, hl = hl } } } },
    right = {},
  }
end

describe("Explorer line formatters", function()
  before_each(function()
    reset_config()
  end)

  after_each(function()
    reset_config()
  end)

  it("is disabled with whole-line formatter defaults", function()
    local options = config.options.explorer
    assert.is_false(options.line_stats.enabled)
    assert.is_false(options.line_stats.count_untracked)
    assert.equals(1024 * 1024, options.line_stats.max_untracked_bytes)
    assert.is_function(options.formatters.file)
    assert.is_function(options.formatters.folder)
    assert.is_function(options.formatters.group)
  end)

  it("aggregates text, binary, and unavailable file stats", function()
    local stats = line_stats.sum({
      { line_stats = { insertions = 3, deletions = 2, binary = false } },
      { line_stats = { insertions = 0, deletions = 0, binary = true } },
      {},
    })
    assert.same({
      files_changed = 3,
      insertions = 3,
      deletions = 2,
      binary_files = 1,
      unavailable_files = 1,
    }, stats)
  end)

  it("renders default file stats and group totals", function()
    config.options.explorer.line_stats.enabled = true
    local files = {
      { path = "added.lua", status = "A", line_stats = { insertions = 20, deletions = 0, binary = false } },
      { path = "changed.lua", status = "M", line_stats = { insertions = 22, deletions = 8, binary = false } },
      { path = "image.png", status = "M", line_stats = { insertions = 0, deletions = 0, binary = true } },
    }
    local root = tree.create_tree_data({ unstaged = files, staged = {}, conflicts = {} }, "/repo", nil, false, { unstaged = true, staged = false })[1]
    assert.equals(" Changes (3 · +42 -8)", nodes.prepare_node(root, 50, nil, nil):content())

    local file_nodes = nodes.create_file_nodes(files, "/repo", "unstaged")
    local content = nodes.prepare_node(file_nodes[2], 50, nil, nil):content()
    assert.matches("changed%.lua%s+%+22 %-8 M%s*$", content)
    assert.equals(50, vim.fn.strdisplaywidth(content))
    assert.matches("image%.png%s+bin M%s*$", nodes.prepare_node(file_nodes[3], 50, nil, nil):content())
  end)

  it("passes complete file, folder, and group contexts", function()
    config.options.explorer.view_mode = "tree"
    config.options.explorer.flatten_dirs = false
    config.options.explorer.line_stats.enabled = true
    local contexts = {}
    config.options.explorer.formatters = {
      file = function(ctx)
        contexts.file = ctx
        return fixed_layout("file")
      end,
      folder = function(ctx)
        contexts.folder = ctx
        return fixed_layout("folder")
      end,
      group = function(ctx)
        contexts.group = ctx
        return fixed_layout("group")
      end,
    }

    local files = {
      { path = "src/one.lua", status = "M", line_stats = { insertions = 3, deletions = 2, binary = false } },
      { path = "src/two.lua", status = "A", line_stats = { insertions = 4, deletions = 0, binary = false } },
    }
    local root = tree.create_tree_data({ unstaged = files, staged = {}, conflicts = {} }, "/repo", nil, false, { unstaged = true, staged = false })[1]
    local folder = root._children[1]
    local file = folder._children[1]

    assert.equals("group", nodes.prepare_node(root, 40, nil, nil):content())
    assert.equals("folder", nodes.prepare_node(folder, 40, nil, nil):content())
    assert.equals("file", nodes.prepare_node(file, 40, nil, nil):content())
    assert.same({ files_changed = 2, insertions = 7, deletions = 2, binary_files = 0, unavailable_files = 0 }, contexts.group.stats)
    assert.same(contexts.group.stats, contexts.folder.stats)
    assert.equals(2, contexts.group.file_count)
    assert.equals(2, contexts.folder.file_count)
    assert.equals("src", contexts.folder.name)
    assert.equals("src/one.lua", contexts.file.path)
    assert.equals("one.lua", contexts.file.filename)
    assert.equals("M", contexts.file.status)
    assert.equals(1, contexts.file.file_count)

    config.options.explorer.line_stats.enabled = false
    nodes.prepare_node(root, 40, nil, nil)
    nodes.prepare_node(folder, 40, nil, nil)
    nodes.prepare_node(file, 40, nil, nil)
    assert.is_nil(contexts.group.stats)
    assert.is_nil(contexts.folder.stats)
    assert.is_nil(contexts.file.stats)
  end)

  it("truncates regions by priority and keeps status visible", function()
    local layout = {
      left = {
        { segments = { { text = "file-name.lua" } }, truncate_priority = 2 },
        { segments = { { text = " src/components" } }, truncate_priority = 1 },
      },
      right = {
        { segments = { { text = "+123 -45 " } }, truncate_priority = 3 },
        { segments = { { text = "M " } } },
      },
      min_gap = 2,
    }

    local wide = line_layout.render(layout, 30):content()
    assert.matches("file%-name%.lua %.%.%.%s+%+123 %-45 M $", wide)
    assert.equals(30, vim.fn.strdisplaywidth(wide))

    local narrow = line_layout.render(layout, 2):content()
    assert.equals("M ", narrow)
    assert.equals(2, vim.fn.strdisplaywidth(narrow))
    assert.is_true(narrow:find("+", 1, true) == nil)
  end)

  it("accepts highlight groups, hex colors, and highlight tables", function()
    local layout = {
      left = {
        { segments = {
          { text = "hex", hl = "#3fb950" },
          { text = " styled", hl = { fg = "#f00", bold = true } },
        } },
      },
      right = {},
    }
    local line = line_layout.render(layout, 40)
    local hex = vim.api.nvim_get_hl(0, { name = line._segments[1].hl, link = false })
    local styled = vim.api.nvim_get_hl(0, { name = line._segments[2].hl, link = false })
    assert.equals(0x3fb950, hex.fg)
    assert.equals(0xff0000, styled.fg)
    assert.is_true(styled.bold)

    local selected = line_layout.render(layout, 40, 0x112233)
    local selected_hex = vim.api.nvim_get_hl(0, { name = selected._segments[1].hl, link = false })
    assert.equals(0x3fb950, selected_hex.fg)
    assert.equals(0x112233, selected_hex.bg)
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
end)
