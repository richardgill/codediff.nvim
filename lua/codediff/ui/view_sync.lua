local M = {}

local display = require("codediff.nvim.display")
local sessions = {}

local function valid_windows(windows)
  return vim.tbl_filter(vim.api.nvim_win_is_valid, windows)
end

function M.is_supported()
  return display.is_viewport_supported()
end

function M.clear(tabpage)
  local state = sessions[tabpage]
  if not state then
    return
  end
  display.unobserve(state.subscription)
  sessions[tabpage] = nil
end

function M.setup(tabpage, windows, source_win)
  if not tabpage then
    return false
  end
  M.clear(tabpage)
  local wins = valid_windows(windows)
  if not M.is_supported() or #wins < 2 then
    return false
  end
  for _, win in ipairs(wins) do
    vim.wo[win].scrollbind = false
  end
  local state = {}
  state.subscription = display.observe({
    wins = wins,
    on_scroll = function(source_win, offset)
      display.synchronize(state.subscription, source_win, offset)
    end,
    on_invalidate = function() end,
  })
  sessions[tabpage] = state
  if source_win then
    M.sync_from(tabpage, source_win)
  end
  return true
end

function M.sync_from(tabpage, source_win)
  local state = sessions[tabpage]
  if not state then
    return nil
  end
  return display.synchronize(state.subscription, source_win)
end

return M
