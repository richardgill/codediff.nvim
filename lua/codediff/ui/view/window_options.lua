local M = {}

local config = require("codediff.config")
local welcome = require("codediff.ui.welcome")

local restore_variable = "codediff_window_options_restore"

local function notify_error(message)
  vim.notify("[codediff] diff.window_options " .. message, vim.log.levels.ERROR)
end

local function is_valid_window(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function set_window_option(win, name, value)
  return pcall(function()
    vim.wo[win][name] = value
  end)
end

function M.restore(win)
  if not is_valid_window(win) then
    return
  end

  local restore = vim.w[win][restore_variable]
  if type(restore) ~= "table" then
    return
  end

  for name, value in pairs(restore) do
    set_window_option(win, name, value)
  end
  vim.w[win][restore_variable] = nil
end

local function evaluate(callback, context)
  local ok, options = pcall(callback, context)
  if not ok then
    notify_error("callback failed: " .. tostring(options))
    return nil
  end
  if options ~= nil and type(options) ~= "table" then
    notify_error("must return a table or nil")
    return nil
  end
  return options or {}
end

local function restore_omitted_options(win, restore, options)
  local retained = {}
  for name, value in pairs(restore) do
    if options[name] == nil then
      set_window_option(win, name, value)
    else
      retained[name] = value
    end
  end
  return retained
end

local function apply_option(win, restore, name, value)
  if type(name) ~= "string" then
    notify_error("returned a non-string option name")
    return
  end

  local ok, current = pcall(function()
    return vim.wo[win][name]
  end)
  if not ok then
    notify_error("returned an invalid window option: " .. name)
    return
  end

  if restore[name] == nil then
    restore[name] = current
  end

  local applied, err = set_window_option(win, name, value)
  if applied then
    return
  end

  notify_error("could not set " .. name .. ": " .. tostring(err))
  set_window_option(win, name, restore[name])
  restore[name] = nil
end

function M.apply(win, role, view)
  if not is_valid_window(win) then
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(win)
  if welcome.is_welcome_buffer(bufnr) then
    M.restore(win)
    return
  end

  local callback = config.options.diff.window_options
  if not callback then
    M.restore(win)
    return
  end

  local options = evaluate(callback, {
    win = win,
    buf = bufnr,
    tabpage = vim.api.nvim_win_get_tabpage(win),
    role = role,
    view = view,
  })
  if not options then
    M.restore(win)
    return
  end

  local restore = vim.w[win][restore_variable]
  if type(restore) ~= "table" then
    restore = {}
  end

  restore = restore_omitted_options(win, restore, options)
  for name, value in pairs(options) do
    apply_option(win, restore, name, value)
  end

  vim.w[win][restore_variable] = next(restore) and restore or nil
end

local function get_view(session)
  if session.result_win and is_valid_window(session.result_win) then
    return "conflict"
  end
  return session.layout == "inline" and "inline" or "side-by-side"
end

function M.apply_window(session, win)
  if not session or not is_valid_window(win) then
    return
  end
  if not session.result_win and session.original_path == "" and session.modified_path == "" then
    M.restore(win)
    return
  end

  local view = get_view(session)
  if view == "inline" and (win == session.original_win or win == session.modified_win) then
    M.apply(win, "inline", view)
  elseif win == session.result_win then
    M.apply(win, "result", view)
  elseif win == session.original_win then
    M.apply(win, "original", view)
  elseif win == session.modified_win then
    M.apply(win, "modified", view)
  end
end

function M.apply_session(session)
  if not session then
    return
  end

  local seen = {}
  for _, field in ipairs({ "original_win", "modified_win", "result_win" }) do
    local win = session[field]
    if is_valid_window(win) and not seen[win] then
      M.apply_window(session, win)
      seen[win] = true
    end
  end
end

function M.restore_session(session)
  if not session then
    return
  end

  local seen = {}
  for _, field in ipairs({ "original_win", "modified_win", "result_win" }) do
    local win = session[field]
    if is_valid_window(win) and not seen[win] then
      M.restore(win)
      seen[win] = true
    end
  end
end

return M
