local M = {}

local viewport = require("codediff.nvim.display.viewport")

local subscriptions = {}
local suppressed_offsets = {}
local event_group = nil
local display_option_names = {
  "ambiwidth",
  "breakindent",
  "breakindentopt",
  "concealcursor",
  "conceallevel",
  "display",
  "foldcolumn",
  "linebreak",
  "list",
  "listchars",
  "number",
  "numberwidth",
  "relativenumber",
  "showbreak",
  "signcolumn",
  "statuscolumn",
  "tabstop",
  "vartabstop",
}
local fold_option_names = { "foldenable", "foldexpr", "foldlevel", "foldmethod", "foldminlines", "foldtext" }
local global_display_options = { ambiwidth = true, display = true }

local to_set = function(values)
  local result = {}
  for _, value in ipairs(values) do
    result[value] = true
  end
  return result
end

local is_vertical_change = function(change)
  if not change or change.width ~= 0 or change.height ~= 0 then
    return false
  end
  return (change.topline or 0) ~= 0 or (change.topfill or 0) ~= 0 or (change.skipcol or 0) ~= 0
end

local get_scrolled_win = function(args)
  local current_win = vim.api.nvim_get_current_win()
  local matched_win = tonumber(args.match)
  if is_vertical_change(vim.v.event[tostring(current_win)]) then
    return current_win
  end
  if matched_win and is_vertical_change(vim.v.event[tostring(matched_win)]) then
    return matched_win
  end
  for key, change in pairs(vim.v.event) do
    local win = tonumber(key)
    if win and is_vertical_change(change) then
      return win
    end
  end
  if matched_win and vim.tbl_isempty(vim.v.event) then
    return matched_win
  end
  return nil
end

local is_suppressed = function(win)
  local suppression = suppressed_offsets[win]
  if not suppression then
    return false
  end
  suppressed_offsets[win] = nil
  return viewport.get_offset(win) == suppression.offset
end

local schedule_scroll = function(subscription, state, win)
  state.pending_win = win
  if state.scroll_scheduled then
    return
  end
  state.scroll_scheduled = true
  vim.schedule(function()
    state.scroll_scheduled = false
    local source_win = state.pending_win
    state.pending_win = nil
    if subscriptions[subscription] ~= state or not source_win or not state.wins[source_win] then
      return
    end
    local offset = viewport.get_offset(source_win)
    if offset ~= nil then
      state.on_scroll(source_win, offset)
    end
  end)
end

local handle_winscrolled = function(args)
  local win = get_scrolled_win(args)
  if not win or is_suppressed(win) then
    return
  end
  for subscription, state in pairs(subscriptions) do
    if state.wins[win] then
      schedule_scroll(subscription, state, win)
    end
  end
end

local observes_scope = function(state, scope)
  if scope.all then
    return true
  end
  for _, win in ipairs(scope.wins or {}) do
    if state.wins[win] then
      return true
    end
  end
  for win in pairs(state.wins) do
    if vim.api.nvim_win_is_valid(win) and vim.tbl_contains(scope.bufs or {}, vim.api.nvim_win_get_buf(win)) then
      return true
    end
  end
  return false
end

local emit_invalidation = function(reason, scope)
  for _, state in pairs(subscriptions) do
    if observes_scope(state, scope) then
      state.on_invalidate(reason)
    end
  end
end

local handle_option_set = function(args)
  local name = args.match
  local reason = vim.tbl_contains(fold_option_names, name) and "fold" or "display-option"
  if global_display_options[name] then
    emit_invalidation(reason, { all = true })
    return
  end
  emit_invalidation(reason, { wins = { vim.api.nvim_get_current_win() }, bufs = { args.buf } })
end

local setup_autocmds = function()
  if event_group then
    return
  end
  event_group = vim.api.nvim_create_augroup("CodeDiffDisplayEvents", { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", { group = event_group, callback = handle_winscrolled })
  vim.api.nvim_create_autocmd("WinResized", {
    group = event_group,
    callback = function()
      local wins = vim.v.event.windows or {}
      emit_invalidation("resize", #wins > 0 and { wins = wins } or { all = true })
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = event_group,
    pattern = vim.list_extend(vim.deepcopy(display_option_names), fold_option_names),
    callback = handle_option_set,
  })
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = event_group,
    callback = function(args)
      emit_invalidation("diagnostic", { bufs = { args.buf } })
    end,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = event_group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.wo[win].conceallevel > 0 and vim.wo[win].concealcursor ~= "" then
        emit_invalidation("conceal", { wins = { win } })
      end
    end,
  })
end

local clear_autocmds = function()
  if next(subscriptions) or not event_group then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_id, event_group)
  event_group = nil
  suppressed_offsets = {}
end

function M.observe(opts)
  vim.validate("opts", opts, "table")
  vim.validate("opts.wins", opts.wins, "table")
  vim.validate("opts.on_scroll", opts.on_scroll, "function")
  vim.validate("opts.on_invalidate", opts.on_invalidate, "function")
  local subscription = {}
  subscriptions[subscription] = {
    wins = to_set(opts.wins),
    ordered_wins = vim.deepcopy(opts.wins),
    on_scroll = opts.on_scroll,
    on_invalidate = opts.on_invalidate,
  }
  setup_autocmds()
  return subscription
end

function M.unobserve(subscription)
  if not subscriptions[subscription] then
    return
  end
  subscriptions[subscription] = nil
  clear_autocmds()
end

local synchronize

local schedule_reconciliation = function(subscription, state, source_win)
  if state.reconcile_scheduled then
    return
  end
  state.reconcile_scheduled = true
  vim.schedule(function()
    state.reconcile_scheduled = false
    if subscriptions[subscription] ~= state or not state.wins[source_win] then
      return
    end
    local offset = viewport.get_offset(source_win)
    for _, win in ipairs(state.ordered_wins) do
      if offset and viewport.get_offset(win) ~= offset then
        synchronize(subscription, state, source_win, offset, true)
        return
      end
    end
  end)
end

synchronize = function(subscription, state, source_win, offset, force_cursor)
  local target_offset = offset
  for _ = 1, #state.ordered_wins + 1 do
    local next_offset = target_offset
    for _, win in ipairs(state.ordered_wins) do
      local applied_offset = win == source_win and target_offset == offset and viewport.get_offset(win)
        or M.set_offset(win, target_offset, {
          notify = false,
          preserve_cursor = not force_cursor and target_offset == offset,
        })
      next_offset = math.max(next_offset, applied_offset or next_offset)
    end
    if next_offset == target_offset then
      if not force_cursor then
        schedule_reconciliation(subscription, state, source_win)
      end
      return target_offset
    end
    target_offset = next_offset
  end
  for _, win in ipairs(state.ordered_wins) do
    M.set_offset(win, target_offset, { notify = false, preserve_cursor = false })
  end
  if not force_cursor then
    schedule_reconciliation(subscription, state, source_win)
  end
  return target_offset
end

function M.synchronize(subscription, source_win, offset)
  local state = subscriptions[subscription]
  if not state or not state.wins[source_win] then
    return nil
  end
  offset = offset or viewport.get_offset(source_win)
  if offset == nil then
    return nil
  end
  return synchronize(subscription, state, source_win, offset, false)
end

function M.set_offset(win, offset, opts)
  local applied_offset = viewport.set_offset(win, offset, opts)
  if not applied_offset or not (opts and opts.notify == false) then
    return applied_offset
  end
  local suppression = { offset = applied_offset }
  suppressed_offsets[win] = suppression
  vim.defer_fn(function()
    if suppressed_offsets[win] == suppression then
      suppressed_offsets[win] = nil
    end
  end, 0)
  return applied_offset
end

return M
