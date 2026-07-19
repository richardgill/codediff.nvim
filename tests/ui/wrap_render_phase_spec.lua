local render = require("codediff.ui.view.render")
local wrap_alignment = require("codediff.ui.wrap_alignment")

local make_lines = function()
  local lines = {}
  for index = 1, 60 do
    lines[index] = string.format("line %02d %s", index, string.rep("content ", index % 4))
  end
  return lines
end

local create_panes = function(original_lines, modified_lines)
  vim.cmd("tabnew")
  local modified_win = vim.api.nvim_get_current_win()
  local modified_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false, modified_lines)
  vim.api.nvim_win_set_buf(modified_win, modified_buf)
  vim.cmd("leftabove vsplit")
  local original_win = vim.api.nvim_get_current_win()
  local original_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, original_lines)
  vim.api.nvim_win_set_buf(original_win, original_buf)
  vim.api.nvim_win_set_width(original_win, 32)
  return original_win, modified_win, original_buf, modified_buf
end

local set_view = function(win)
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_cursor(win, { 30, 0 })
    vim.fn.winrestview({ topline = 20 })
  end)
end

local get_view = function(win)
  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end

local get_offset = function(win)
  local view = get_view(win)
  return vim.api.nvim_win_text_height(win, { end_row = view.topline - 1, end_vcol = 0 }).all - view.topfill
end

describe("wrapped post-decoration render phase", function()
  before_each(function()
    require("codediff").setup({ diff = { wrap = true } })
    wrap_alignment.reset_metrics()
  end)

  after_each(function()
    if vim.fn.tabpagenr("$") > 1 then
      vim.cmd("tabclose!")
    end
    require("codediff").setup({ diff = { wrap = false } })
  end)

  it("measures final decorations before restoring aligned views", function()
    if not wrap_alignment.is_supported() then
      pending("wrapped alignment is unavailable")
      return
    end

    local original_lines = make_lines()
    local modified_lines = vim.deepcopy(original_lines)
    original_lines[5] = string.rep("original wrapping ", 12)
    modified_lines[5] = "short"
    local original_win, modified_win, original_buf, modified_buf = create_panes(original_lines, modified_lines)

    render.compute_and_render(original_buf, modified_buf, original_lines, modified_lines, false, false, original_win, modified_win, false)
    set_view(original_win)
    set_view(modified_win)
    local original_before = get_view(original_win)
    local modified_before = get_view(modified_win)

    modified_lines[5] = string.rep("modified wrapping ", 18)
    vim.api.nvim_buf_set_lines(modified_buf, 4, 5, false, { modified_lines[5] })
    render.compute_and_render(original_buf, modified_buf, original_lines, modified_lines, false, false, original_win, modified_win, false)

    local original_after = get_view(original_win)
    local modified_after = get_view(modified_win)
    assert.equal(original_before.topline, original_after.topline)
    assert.equal(modified_before.topline, modified_after.topline)
    assert.equal(get_offset(original_win), get_offset(modified_win))
    local stats = vim.w[original_win].codediff_wrap_alignment
    assert.is_not_nil(stats)
    assert.is_true(stats.cache_hits > 0)
    assert.is_true(stats.measurements < stats.measurement_requests)
    assert.equal(0, stats.plan_cache_hits)
    assert.equal(2, stats.rebuild_count)
    assert.equal("render", stats.rebuild_reason)

    render.compute_and_render(original_buf, modified_buf, original_lines, modified_lines, false, false, original_win, modified_win, false)

    local cached_stats = vim.w[original_win].codediff_wrap_alignment
    assert.equal(1, cached_stats.plan_cache_hits)
    assert.is_true(cached_stats.layer_entries_reused > 0)
    assert.equal(3, cached_stats.rebuild_count)
    assert.equal(3, wrap_alignment.get_metrics().rebuild_count)
  end)
end)
