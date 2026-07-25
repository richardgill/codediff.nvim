-- vscode-diff main API
local M = {}

-- Configuration setup
function M.setup(opts)
  local config = require("codediff.config")
  config.setup(opts)

  local render = require("codediff.ui")
  render.setup_highlights()
end

function M.render_aligned_modified_virtual_lines(opts)
  return require("codediff.ui.move").render_aligned_modified_virtual_lines(opts)
end

function M.get_diff_context(bufnr)
  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage = lifecycle.find_tabpage_by_buffer(bufnr)
  local session = tabpage and lifecycle.get_session(tabpage)
  if not session then
    return nil
  end

  local side = session.original_bufnr == bufnr and "original" or session.modified_bufnr == bufnr and "modified" or nil
  if not side then
    return nil
  end

  local ref = side == "original" and session.original or session.modified
  return {
    tabpage = tabpage,
    side = side,
    git_root = session.git_root,
    path = ref and ref.absolute or nil,
  }
end

-- Navigate to next hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.next_hunk()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.next_hunk()
end

-- Navigate to previous hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.prev_hunk()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.prev_hunk()
end

-- Navigate to next file in explorer/history mode
-- In single-file history mode, navigates to next commit instead
-- Returns true if navigation succeeded, false otherwise
function M.next_file()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.next_file()
end

-- Navigate to previous file in explorer/history mode
-- In single-file history mode, navigates to previous commit instead
-- Returns true if navigation succeeded, false otherwise
function M.prev_file()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.prev_file()
end

return M
