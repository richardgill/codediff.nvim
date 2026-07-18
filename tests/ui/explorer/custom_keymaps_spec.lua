local Tree = require("codediff.ui.lib.tree")
local Line = require("codediff.ui.lib.line")
local config = require("codediff.config")
local keymaps = require("codediff.ui.explorer.keymaps")
local refresh = require("codediff.ui.explorer.refresh")

local original_refresh = refresh.refresh

local reset_config = function()
  config.options = vim.deepcopy(config.defaults)
end

local render_line = function(reviewed, node)
  local line = Line()
  line:append(node.data.type == "group" and "Changes" or (reviewed and "✓ file.lua" or "file.lua"), "Normal")
  return line
end

describe("Explorer custom keymaps", function()
  before_each(function()
    reset_config()
    refresh.refresh = original_refresh
  end)

  after_each(function()
    refresh.refresh = original_refresh
    reset_config()
  end)

  it("passes a consistent entry context and redraws without rebuilding the tree", function()
    local previous_bufnr = vim.api.nvim_get_current_buf()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, bufnr)

    local reviewed = false
    local received
    local file = { path = "file.lua", status = "M", line_stats = { insertions = 4, deletions = 2, binary = false } }
    local file_node = Tree.Node({
      text = file.path,
      data = {
        path = file.path,
        status = file.status,
        group = "unstaged",
        line_stats = file.line_stats,
      },
    })
    local group_node = Tree.Node({
      text = "Changes",
      data = {
        type = "group",
        name = "unstaged",
        label = "Changes",
        file_count = 1,
        files = { file },
      },
    }, { file_node })
    local tree = Tree({
      bufnr = bufnr,
      nodes = { group_node },
      prepare_node = function(node)
        return render_line(reviewed, node)
      end,
    })
    group_node:expand()
    tree:render()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local explorer = {
      bufnr = bufnr,
      winid = vim.api.nvim_get_current_win(),
      tabpage = vim.api.nvim_get_current_tabpage(),
      split = { bufnr = bufnr },
      tree = tree,
    }
    config.options.keymaps.explorer.custom = {
      {
        key = "m",
        desc = "Toggle reviewed",
        callback = function(ctx)
          received = ctx
          reviewed = not reviewed
          ctx.redraw()
        end,
      },
    }
    keymaps.setup(explorer)

    local mapping = vim.fn.maparg("m", "n", false, true)
    assert.equals("Toggle reviewed", mapping.desc)
    mapping.callback()

    assert.same({
      kind = "file",
      path = "file.lua",
      group = "unstaged",
      status = "M",
      stats = { insertions = 4, deletions = 2, binary = false },
    }, received.entry)
    assert.equals("✓ file.lua", vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1])
    assert.is_true(group_node:is_expanded())
    assert.equals(file_node, tree:get_node(file_node:get_id()))

    local refresh_calls = 0
    refresh.refresh = function(value)
      assert.equals(explorer, value)
      refresh_calls = refresh_calls + 1
    end
    received.refresh()
    assert.equals(1, refresh_calls)

    vim.api.nvim_win_set_buf(0, previous_bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    assert.has_no.errors(received.redraw)
    assert.has_no.errors(received.refresh)
    assert.equals(1, refresh_calls)
  end)
end)
