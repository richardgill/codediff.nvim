local M = {}

local alignment_model = require("codediff.ui.wrap_alignment_model")
local alignment_renderer = require("codediff.ui.wrap_alignment_renderer")
local display = require("codediff.nvim.display")

local groups_by_win = {}
local scheduled_rebuilds = {}
local plan_caches = {}
local option_profiles = {}
local option_owners = {}
local fold_tracking = {}
local owned_option_names = { "wrap", "scrollbind", "smoothscroll", "cursorbind" }

local read_owned_options = function(win)
  local options = {}
  for _, name in ipairs(owned_option_names) do
    options[name] = vim.wo[win][name]
  end
  return options
end

local apply_owned_options = function(win, options)
  if not options or not vim.api.nvim_win_is_valid(win) then
    return
  end
  for _, name in ipairs(owned_option_names) do
    vim.wo[win][name] = options[name]
  end
end

local elapsed_ms = function(started_at)
  return (vim.uv.hrtime() - started_at) / 1000000
end

local get_plan_fingerprint = function(lines_diff)
  return vim.json.encode({ changes = lines_diff.changes or {}, moves = lines_diff.moves or {} })
end

local get_two_pane_plan = function(opts)
  local original_tick = vim.api.nvim_buf_get_changedtick(opts.original_buf)
  local modified_tick = vim.api.nvim_buf_get_changedtick(opts.modified_buf)
  local fingerprint = get_plan_fingerprint(opts.lines_diff)
  local cached = plan_caches[opts.original_win]
  if
    cached
    and cached.original_buf == opts.original_buf
    and cached.modified_buf == opts.modified_buf
    and cached.original_tick == original_tick
    and cached.modified_tick == modified_tick
    and cached.fingerprint == fingerprint
  then
    return cached.intervals, 1, cached
  end

  local intervals = alignment_model.build({
    base_count = opts.panes[1].line_count,
    base_lines = opts.original_lines,
    base_side = "original",
    panes = opts.panes,
  })
  local entry = {
    original_buf = opts.original_buf,
    modified_buf = opts.modified_buf,
    original_tick = original_tick,
    modified_tick = modified_tick,
    fingerprint = fingerprint,
    intervals = intervals,
  }
  plan_caches[opts.original_win] = entry
  return intervals, 0, entry
end

local is_valid_pane = function(pane)
  return pane.win and pane.buf and vim.api.nvim_win_is_valid(pane.win) and vim.api.nvim_buf_is_valid(pane.buf) and vim.api.nvim_win_get_buf(pane.win) == pane.buf
end

local unobserve_group = function(group)
  if not group then
    return
  end
  display.unobserve(group.subscription)
  group.subscription = nil
  for _, pane in ipairs(group.panes) do
    if groups_by_win[pane.win] == group then
      groups_by_win[pane.win] = nil
    end
  end
end

local observe_group = function(group)
  local wins = {}
  for _, pane in ipairs(group.panes) do
    wins[#wins + 1] = pane.win
  end
  group.subscription = display.observe({
    wins = wins,
    on_scroll = function(source_win, offset)
      display.synchronize(group.subscription, source_win, offset)
    end,
    on_invalidate = function(reason)
      if reason == "resize" then
        M.schedule_rebuild(group.tabpage, reason)
      else
        M.invalidate(group.tabpage, reason)
      end
    end,
  })
end

local set_group = function(tabpage, panes)
  local previous_groups = {}
  for _, pane in ipairs(panes) do
    local group = groups_by_win[pane.win]
    if group then
      previous_groups[group] = true
    end
  end
  for group in pairs(previous_groups) do
    unobserve_group(group)
  end

  local group = { tabpage = tabpage, panes = panes }
  for _, pane in ipairs(panes) do
    groups_by_win[pane.win] = group
  end
  observe_group(group)
end

local apply_plan = function(opts)
  opts.started_at = opts.started_at or vim.uv.hrtime()
  if not M.is_supported() then
    vim.notify_once("[codediff] wrapped alignment requires Neovim 0.12+", vim.log.levels.WARN)
    return nil
  end

  local prepare_started_at = vim.uv.hrtime()
  local smoothscroll = false
  for _, pane in ipairs(opts.panes) do
    if not is_valid_pane(pane) then
      return nil
    end
    M.capture_window(opts.tabpage, pane.side, pane.win)
    local profile = option_profiles[opts.tabpage] and option_profiles[opts.tabpage][pane.side]
    smoothscroll = smoothscroll or (profile and profile.smoothscroll) or false
  end
  for _, pane in ipairs(opts.panes) do
    vim.wo[pane.win].wrap = true
    vim.wo[pane.win].scrollbind = false
    vim.wo[pane.win].smoothscroll = smoothscroll
    vim.wo[pane.win].cursorbind = false
  end

  local session = require("codediff.ui.lifecycle").get_session(opts.tabpage)
  local stats = alignment_renderer.apply(vim.tbl_extend("force", opts, {
    compact_mode = session and session.compact_mode,
    fold_tracking = fold_tracking[opts.tabpage],
    prepare_started_at = prepare_started_at,
  }))
  set_group(opts.tabpage, opts.panes)
  for _, pane in ipairs(opts.panes) do
    vim.w[pane.win].codediff_wrap_alignment = stats
  end
  return stats
end

function M.is_supported()
  return display.is_supported()
end

function M.is_enabled()
  return require("codediff.config").options.diff.wrap == true and M.is_supported()
end

function M.capture_window(tabpage, side, win)
  if not tabpage or not side or not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  option_profiles[tabpage] = option_profiles[tabpage] or {}
  option_profiles[tabpage][side] = option_profiles[tabpage][side] or read_owned_options(win)
  option_owners[win] = { tabpage = tabpage, side = side }
end

function M.restore_window(win, release)
  local owner = win and option_owners[win] or nil
  if not owner then
    return
  end
  local profiles = option_profiles[owner.tabpage]
  apply_owned_options(win, profiles and profiles[owner.side])
  if release then
    option_owners[win] = nil
  end
end

function M.release_session(tabpage)
  local session_groups = {}
  for _, group in pairs(groups_by_win) do
    if group.tabpage == tabpage then
      session_groups[group] = true
    end
  end
  for group in pairs(session_groups) do
    unobserve_group(group)
  end
  local owned_windows = {}
  for win, owner in pairs(option_owners) do
    if owner.tabpage == tabpage then
      owned_windows[#owned_windows + 1] = win
    end
  end
  for _, win in ipairs(owned_windows) do
    M.restore_window(win, true)
  end
  option_profiles[tabpage] = nil
  fold_tracking[tabpage] = nil
end

function M.capture_views(wins)
  local current_win = vim.api.nvim_get_current_win()
  local captured = { panes = {} }
  for _, win in ipairs(wins) do
    local anchor = display.capture(win)
    if anchor then
      captured.panes[#captured.panes + 1] = { win = win, anchor = anchor }
      if win == current_win then
        captured.source_win = win
      end
    end
  end
  return captured
end

function M.apply(opts)
  local started_at = vim.uv.hrtime()
  local original_lines = vim.api.nvim_buf_get_lines(opts.original_buf, 0, -1, false)
  local panes = {
    {
      side = "original",
      win = opts.original_win,
      buf = opts.original_buf,
      line_count = vim.api.nvim_buf_line_count(opts.original_buf),
      lines = original_lines,
    },
    {
      side = "modified",
      win = opts.modified_win,
      buf = opts.modified_buf,
      line_count = vim.api.nvim_buf_line_count(opts.modified_buf),
      lines = vim.api.nvim_buf_get_lines(opts.modified_buf, 0, -1, false),
      diff = opts.lines_diff,
    },
  }
  local plan_started_at = vim.uv.hrtime()
  local intervals, plan_cache_hits, plan_token = get_two_pane_plan({
    original_win = opts.original_win,
    original_buf = opts.original_buf,
    modified_buf = opts.modified_buf,
    original_lines = original_lines,
    lines_diff = opts.lines_diff,
    panes = panes,
  })
  return apply_plan({
    tabpage = vim.api.nvim_win_get_tabpage(opts.original_win),
    panes = panes,
    intervals = intervals,
    reason = opts.reason,
    started_at = started_at,
    plan_ms = elapsed_ms(plan_started_at),
    plan_cache_hits = plan_cache_hits,
    plan_token = plan_token,
  })
end

local align_result_to_sources = function(panes, diff, diff_options)
  local result = panes[#panes]
  local sources = {}
  for index = 1, #panes - 1 do
    local candidate = panes[index]
    local candidate_diff = diff.compute_diff(candidate.lines, result.lines, diff_options)
    if not candidate_diff.hit_timeout then
      sources[#sources + 1] = { side = candidate.side, diff = candidate_diff }
    end
  end
  result.alignment_sources = sources
end

function M.apply_conflict(tabpage, reason)
  local started_at = vim.uv.hrtime()
  local session = require("codediff.ui.lifecycle").get_session(tabpage)
  local panes = session
      and {
        { side = "original", win = session.original_win, buf = session.original_bufnr },
        { side = "modified", win = session.modified_win, buf = session.modified_bufnr },
        { side = "result", win = session.result_win, buf = session.result_bufnr },
      }
    or {}
  if #panes ~= 3 or not session.merge_base_lines then
    return nil
  end
  for _, pane in ipairs(panes) do
    if not is_valid_pane(pane) then
      return nil
    end
    pane.lines = vim.api.nvim_buf_get_lines(pane.buf, 0, -1, false)
    pane.line_count = vim.api.nvim_buf_line_count(pane.buf)
  end

  local config = require("codediff.config")
  local diff = require("codediff.core.diff")
  local diff_options = {
    max_computation_time_ms = config.options.diff.max_computation_time_ms,
    ignore_trim_whitespace = config.options.diff.ignore_trim_whitespace,
    compute_moves = false,
  }
  for _, pane in ipairs(panes) do
    pane.diff = diff.compute_diff(session.merge_base_lines, pane.lines, diff_options)
    if not pane.diff then
      return nil
    end
  end
  align_result_to_sources(panes, diff, diff_options)

  local plan_started_at = vim.uv.hrtime()
  local intervals = alignment_model.build({
    base_count = #session.merge_base_lines,
    base_lines = session.merge_base_lines,
    panes = panes,
  })
  return apply_plan({
    tabpage = tabpage,
    panes = panes,
    intervals = intervals,
    reason = reason,
    started_at = started_at,
    plan_ms = elapsed_ms(plan_started_at),
  })
end

function M.sync_from(tabpage, source_win)
  local group = groups_by_win[source_win]
  if not group or group.tabpage ~= tabpage then
    return
  end
  display.synchronize(group.subscription, source_win)
end

local finish_views = function(stats, tabpage, saved_views, defer_sync)
  local started_at = vim.uv.hrtime()
  for _, pane in ipairs((saved_views and saved_views.panes) or {}) do
    display.restore(pane.win, pane.anchor)
  end
  if not defer_sync then
    local source_win = saved_views and saved_views.source_win or nil
    if source_win then
      M.sync_from(tabpage, source_win)
    end
  end
  if stats then
    stats.timings.view_sync_ms = elapsed_ms(started_at)
    stats.timings.total_ms = stats.timings.total_ms + stats.timings.view_sync_ms
    for win, group in pairs(groups_by_win) do
      if group.tabpage == tabpage and vim.api.nvim_win_is_valid(win) then
        vim.w[win].codediff_wrap_alignment = stats
      end
    end
  end
  return stats
end

function M.finish_two_pane(opts)
  local stats = M.apply(opts)
  local tabpage = opts.tabpage or vim.api.nvim_win_get_tabpage(opts.modified_win)
  return finish_views(stats, tabpage, opts.saved_views, opts.defer_sync)
end

function M.finish_conflict(opts)
  local stats = M.apply_conflict(opts.tabpage, opts.reason)
  return finish_views(stats, opts.tabpage, opts.saved_views, opts.defer_sync)
end

function M.clear_window(win)
  if not win then
    return
  end
  alignment_renderer.clear_window(win)
  local group = groups_by_win[win]
  for _, pane in ipairs((group and group.panes) or {}) do
    plan_caches[pane.win] = nil
  end
  unobserve_group(group)
  plan_caches[win] = nil
  if vim.api.nvim_win_is_valid(win) then
    vim.w[win].codediff_wrap_alignment = nil
  end
  M.restore_window(win)
end

function M.get_metrics()
  return alignment_renderer.get_metrics()
end

function M.reset_metrics()
  alignment_renderer.reset_metrics()
end

function M.invalidate(tabpage, reason)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  if not M.is_enabled() then
    return false
  end
  local found = false
  for win, group in pairs(groups_by_win) do
    if group.tabpage == tabpage then
      found = true
      alignment_renderer.invalidate_window(win)
    end
  end
  if not found then
    return false
  end
  if reason == "fold" then
    fold_tracking[tabpage] = true
  end
  M.schedule_rebuild(tabpage, reason or "external-display")
  return true
end

function M.schedule_rebuild(tabpage, reason)
  if scheduled_rebuilds[tabpage] then
    return
  end
  scheduled_rebuilds[tabpage] = reason or "scheduled"
  vim.schedule(function()
    local rebuild_reason = scheduled_rebuilds[tabpage]
    scheduled_rebuilds[tabpage] = nil
    M.rebuild(tabpage, nil, rebuild_reason)
  end)
end

function M.rebuild(tabpage, saved_views, reason)
  if not M.is_enabled() then
    return nil
  end
  local session = require("codediff.ui.lifecycle").get_session(tabpage)
  if not session or session.layout ~= "side-by-side" or session.single_pane then
    return nil
  end
  local panes = {
    { win = session.original_win, buf = session.original_bufnr },
    { win = session.modified_win, buf = session.modified_bufnr },
  }
  for _, pane in ipairs(panes) do
    if not is_valid_pane(pane) then
      return nil
    end
  end

  saved_views = saved_views or M.capture_views({ session.original_win, session.modified_win, session.result_win })
  vim.wo[session.original_win].scrollbind = false
  vim.wo[session.modified_win].scrollbind = false

  if session.result_win and vim.api.nvim_win_is_valid(session.result_win) then
    return M.finish_conflict({ tabpage = tabpage, saved_views = saved_views, reason = reason or "rebuild" })
  end
  if not session.stored_diff_result then
    return nil
  end
  return M.finish_two_pane({
    tabpage = tabpage,
    original_win = session.original_win,
    modified_win = session.modified_win,
    original_buf = session.original_bufnr,
    modified_buf = session.modified_bufnr,
    lines_diff = session.stored_diff_result,
    saved_views = saved_views,
    reason = reason or "rebuild",
  })
end

return M
