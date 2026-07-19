local config = require("codediff.config")
local git = require("codediff.core.git")
local inline_warm = require("codediff.ui.explorer.inline_warm")
local inline_worker = require("codediff.core.inline_worker")
local lifecycle = require("codediff.ui.lifecycle")
local refresh = require("codediff.ui.explorer.refresh")

local original_get_all_files = refresh.get_all_files
local original_get_session = lifecycle.get_session
local original_resolve_revision = git.resolve_revision
local original_get_file_content = git.get_file_content
local original_compute = inline_worker.compute

describe("Inline explorer warming", function()
  after_each(function()
    refresh.get_all_files = original_get_all_files
    lifecycle.get_session = original_get_session
    git.resolve_revision = original_resolve_revision
    git.get_file_content = original_get_file_content
    inline_worker.compute = original_compute
    config.options.diff.inline_cache.dwell_ms = 100
  end)

  it("warms the next visible tracked worktree comparison", function()
    local requested
    local explorer = {
      tabpage = vim.api.nvim_get_current_tabpage(),
      git_root = "/repo",
      status_result = { staged = {}, unstaged = {}, conflicts = {} },
      tree = {},
    }
    local selected = { path = "a.lua", group = "unstaged", status = "M" }
    local adjacent = { path = "b.lua", group = "unstaged", status = "M" }
    local modified = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(modified, "/repo/b.lua")
    vim.api.nvim_buf_set_lines(modified, 0, -1, false, { "local value = 2" })

    config.options.diff.inline_cache.dwell_ms = 0
    refresh.get_all_files = function()
      return { { data = selected }, { data = adjacent } }
    end
    lifecycle.get_session = function()
      return { layout = "inline" }
    end
    git.resolve_revision = function(_, _, callback)
      callback(nil, "head-oid")
    end
    git.get_file_content = function(_, _, _, callback)
      callback(nil, { "local value = 1" })
    end
    inline_worker.compute = function(args)
      requested = args
      return true
    end

    inline_warm.selection_changed(explorer, selected)
    assert.is_true(vim.wait(1000, function()
      return requested ~= nil
    end, 10))
    assert.same({ "local value = 1" }, requested.original_lines)
    assert.same({ "local value = 2" }, requested.modified_lines)
    assert.equal("lua", requested.filetype)

    vim.api.nvim_buf_delete(modified, { force = true })
  end)
end)
