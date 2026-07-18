local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local layout = require("codediff.ui.layout")
local config = require("codediff.config")
local explorer_view = require("codediff.ui.explorer")
local history_view = require("codediff.ui.history")
local wrap_alignment = require("codediff.ui.wrap_alignment")

local rerender_current = function(tabpage, session)
  if session.mode == "explorer" then
    return explorer_view.rerender_current(lifecycle.get_explorer(tabpage))
  end
  if session.mode == "history" then
    return history_view.rerender_current(lifecycle.get_explorer(tabpage))
  end
  return true
end

local function normalize_inline_layout(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not vim.api.nvim_buf_is_valid(session.original_bufnr) or not vim.api.nvim_buf_is_valid(session.modified_bufnr) then
    return false
  end

  lifecycle.update_layout(tabpage, "inline")
  session.single_pane = nil

  local original_win = session.original_win
  local modified_win = session.modified_win
  wrap_alignment.clear_window(original_win)
  wrap_alignment.clear_window(modified_win)
  local keep_win = (modified_win and vim.api.nvim_win_is_valid(modified_win) and modified_win) or (original_win and vim.api.nvim_win_is_valid(original_win) and original_win)

  if not keep_win then
    return false
  end

  session.original_win = keep_win
  session.modified_win = keep_win
  wrap_alignment.capture_window(tabpage, "modified", keep_win)
  vim.wo[keep_win].wrap = require("codediff.config").options.diff.wrap == true and vim.fn.has("nvim-0.13") == 1

  local close_win = nil
  if original_win and modified_win and original_win ~= modified_win then
    close_win = keep_win == modified_win and original_win or modified_win
  end

  if close_win and vim.api.nvim_win_is_valid(close_win) then
    session.inline_saved_original_bufhidden = vim.bo[session.original_bufnr].bufhidden
    vim.bo[session.original_bufnr].bufhidden = "hide"
    vim.api.nvim_set_current_win(keep_win)
    pcall(vim.api.nvim_win_close, close_win, true)
  end

  local original_lines = vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false)
  local modified_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
  local lines_diff = require("codediff.core.diff").compute_diff(original_lines, modified_lines, {
    max_computation_time_ms = config.options.diff.max_computation_time_ms,
    ignore_trim_whitespace = config.options.diff.ignore_trim_whitespace,
    compute_moves = config.options.diff.compute_moves,
  })
  if not lines_diff then
    return false
  end

  require("codediff.ui.inline").render_inline_diff(session.modified_bufnr, lines_diff, original_lines, modified_lines)
  lifecycle.update_diff_result(tabpage, lines_diff)
  layout.arrange(tabpage)
  require("codediff.ui.view.keymaps").setup_all_keymaps(tabpage, session.original_bufnr, session.modified_bufnr, session.mode == "explorer")
  vim.api.nvim_set_current_win(keep_win)
  return true
end

local function normalize_side_by_side_layout(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  local modified_win = (session.modified_win and vim.api.nvim_win_is_valid(session.modified_win) and session.modified_win)
    or (session.original_win and vim.api.nvim_win_is_valid(session.original_win) and session.original_win)
  if not modified_win or not vim.api.nvim_buf_is_valid(session.original_bufnr) or not vim.api.nvim_buf_is_valid(session.modified_bufnr) then
    return false
  end

  lifecycle.update_layout(tabpage, "side-by-side")
  wrap_alignment.restore_window(modified_win)
  vim.api.nvim_set_current_win(modified_win)
  local split_cmd = config.options.diff.original_position == "right" and "rightbelow vsplit" or "leftabove vsplit"
  vim.cmd(split_cmd)
  local original_win = vim.api.nvim_get_current_win()
  wrap_alignment.capture_window(tabpage, "original", original_win)
  wrap_alignment.capture_window(tabpage, "modified", modified_win)
  vim.api.nvim_win_set_buf(original_win, session.original_bufnr)
  vim.api.nvim_win_set_buf(modified_win, session.modified_bufnr)
  if session.inline_saved_original_bufhidden ~= nil then
    vim.bo[session.original_bufnr].bufhidden = session.inline_saved_original_bufhidden
    session.inline_saved_original_bufhidden = nil
  end

  session.original_win = original_win
  session.modified_win = modified_win
  session.single_pane = nil
  vim.w[original_win].codediff_restore = 1
  vim.w[modified_win].codediff_restore = 1
  layout.arrange(tabpage)

  require("codediff.ui.inline").clear(session.modified_bufnr)
  local original_lines = vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false)
  local modified_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
  local is_original_virtual = session.original_revision ~= nil and session.original_revision ~= "WORKING"
  local is_modified_virtual = session.modified_revision ~= nil and session.modified_revision ~= "WORKING"
  local lines_diff = require("codediff.ui.view.render").compute_and_render(
    session.original_bufnr,
    session.modified_bufnr,
    original_lines,
    modified_lines,
    is_original_virtual,
    is_modified_virtual,
    original_win,
    modified_win,
    false
  )
  if not lines_diff then
    return false
  end

  lifecycle.update_diff_result(tabpage, lines_diff)
  require("codediff.ui.view.keymaps").setup_all_keymaps(tabpage, session.original_bufnr, session.modified_bufnr, session.mode == "explorer")
  vim.api.nvim_set_current_win(modified_win)
  return true
end

function M.toggle(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  if session.result_win and vim.api.nvim_win_is_valid(session.result_win) then
    vim.notify("Cannot toggle layout in conflict mode", vim.log.levels.WARN)
    return false
  end

  local target_layout = session.layout == "inline" and "side-by-side" or "inline"
  local normalize = target_layout == "inline" and normalize_inline_layout or normalize_side_by_side_layout

  -- Disable compact mode before changing layout (window IDs will change)
  local compact = require("codediff.ui.view.compact")
  local was_compact = session.compact_mode
  if was_compact then
    compact.disable(tabpage)
  end

  session.layout_transition = true
  local normalized = normalize(tabpage)
  if normalized then
    layout.arrange(tabpage)
    if session.mode == "explorer" or session.mode == "history" then
      if session.inline_saved_original_bufhidden ~= nil and vim.api.nvim_buf_is_valid(session.original_bufnr) then
        vim.bo[session.original_bufnr].bufhidden = session.inline_saved_original_bufhidden
        session.inline_saved_original_bufhidden = nil
      end
      lifecycle.update_diff_result(tabpage, nil)
      normalized = rerender_current(tabpage, session)
    end
  end

  -- Re-enable compact mode in new layout
  if normalized and was_compact then
    compact.enable(tabpage)
  end

  vim.schedule(function()
    local current_session = lifecycle.get_session(tabpage)
    if current_session then
      current_session.layout_transition = nil
    end
  end)
  return normalized
end

return M
