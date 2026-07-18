local wrap_alignment = require("codediff.ui.wrap_alignment")

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
  vim.api.nvim_win_set_width(original_win, 28)
  vim.api.nvim_win_set_width(modified_win, 46)
  return vim.api.nvim_get_current_tabpage(), original_win, modified_win, original_buf, modified_buf
end

local get_text_width = function(win)
  local info = vim.fn.getwininfo(win)[1]
  return info.width - info.textoff
end

local get_view = function(win)
  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end

local get_offset = function(win)
  local view = get_view(win)
  local prefix = vim.api.nvim_win_text_height(win, { end_row = view.topline - 1, end_vcol = 0 }).all
  local skipped = view.skipcol > 0
      and vim.api.nvim_win_text_height(win, {
        start_row = view.topline - 1,
        start_vcol = 0,
        end_row = view.topline - 1,
        end_vcol = view.skipcol,
      }).all
    or 0
  return prefix - view.topfill + skipped
end

local set_skipped_rows = function(win, rows)
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 1, skipcol = get_text_width(win) * rows })
  end)
end

describe("wrapped smooth scrolling", function()
  before_each(function()
    require("codediff").setup({ diff = { wrap = true } })
  end)

  after_each(function()
    if vim.fn.tabpagenr("$") > 1 then
      vim.cmd("tabclose!")
    end
    require("codediff").setup({ diff = { wrap = false } })
  end)

  it("maps partially visible wrapped lines across unequal pane widths", function()
    if not wrap_alignment.is_supported() then
      pending("wrapped alignment is unavailable")
      return
    end

    local lines = { string.rep("wrapped content ", 20), "second line", "third line" }
    local tabpage, original_win, modified_win, original_buf, modified_buf = create_panes(lines, lines)
    vim.wo[original_win].smoothscroll = true
    vim.wo[modified_win].smoothscroll = false

    wrap_alignment.apply({
      original_win = original_win,
      modified_win = modified_win,
      original_buf = original_buf,
      modified_buf = modified_buf,
      lines_diff = { changes = {}, moves = {} },
    })

    assert.is_true(vim.wo[original_win].smoothscroll)
    assert.is_true(vim.wo[modified_win].smoothscroll)
    set_skipped_rows(original_win, 1)
    wrap_alignment.sync_from(tabpage, original_win)

    local original_view = get_view(original_win)
    local modified_view = get_view(modified_win)
    assert.equal(1, original_view.topline)
    assert.equal(1, modified_view.topline)
    assert.is_true(original_view.skipcol > 0)
    assert.is_true(modified_view.skipcol > 0)
    assert.is_true(original_view.skipcol ~= modified_view.skipcol)
    assert.equal(get_offset(original_win), get_offset(modified_win))

    set_skipped_rows(modified_win, 2)
    wrap_alignment.sync_from(tabpage, modified_win)
    assert.equal(get_offset(modified_win), get_offset(original_win))

    wrap_alignment.clear_window(original_win)
    wrap_alignment.clear_window(modified_win)
    assert.is_true(vim.wo[original_win].smoothscroll)
    assert.is_false(vim.wo[modified_win].smoothscroll)
    wrap_alignment.release_session(tabpage)
  end)

  it("maps a partial long line to compensation rows on the shorter side", function()
    if not wrap_alignment.is_supported() then
      pending("wrapped alignment is unavailable")
      return
    end

    local original_lines = { string.rep("original wrapping ", 20), "second line", "third line" }
    local modified_lines = { "short", "second line", "third line" }
    local tabpage, original_win, modified_win, original_buf, modified_buf = create_panes(original_lines, modified_lines)
    vim.wo[original_win].smoothscroll = true

    wrap_alignment.apply({
      original_win = original_win,
      modified_win = modified_win,
      original_buf = original_buf,
      modified_buf = modified_buf,
      lines_diff = {
        changes = {
          {
            original = { start_line = 1, end_line = 2 },
            modified = { start_line = 1, end_line = 2 },
            inner_changes = {},
          },
        },
        moves = {},
      },
    })

    set_skipped_rows(original_win, 1)
    wrap_alignment.sync_from(tabpage, original_win)

    local modified_view = get_view(modified_win)
    assert.equal(2, modified_view.topline)
    assert.equal(0, modified_view.skipcol)
    assert.is_true(modified_view.topfill > 0)
    assert.equal(get_offset(original_win), get_offset(modified_win))

    wrap_alignment.clear_window(original_win)
    wrap_alignment.clear_window(modified_win)
    wrap_alignment.release_session(tabpage)
  end)

  it("defers window-scroll synchronization until the source view settles", function()
    if not wrap_alignment.is_supported() then
      pending("wrapped alignment is unavailable")
      return
    end

    local original_lines = {}
    local modified_lines = {}
    for index = 1, 80 do
      original_lines[index] = string.format("line %02d %s", index, string.rep("original content ", index % 5))
      modified_lines[index] = string.format("line %02d %s", index, string.rep("modified content ", index % 3))
    end
    local tabpage, original_win, modified_win, original_buf, modified_buf = create_panes(original_lines, modified_lines)
    local lines_diff = require("codediff.core.diff").compute_diff(original_lines, modified_lines, { compute_moves = false })

    wrap_alignment.apply({
      original_win = original_win,
      modified_win = modified_win,
      original_buf = original_buf,
      modified_buf = modified_buf,
      lines_diff = lines_diff,
    })

    vim.api.nvim_win_call(modified_win, function()
      vim.fn.winrestview({ topline = 6 })
    end)
    wrap_alignment.schedule_sync_from(tabpage, modified_win)
    vim.api.nvim_win_call(modified_win, function()
      vim.fn.winrestview({ topline = 12 })
    end)

    local synced = vim.wait(1000, function()
      local modified_offset = get_offset(modified_win)
      return modified_offset > 0 and modified_offset == get_offset(original_win)
    end, 20)
    assert.is_true(synced, string.format("offsets should settle: %d/%d", get_offset(original_win), get_offset(modified_win)))

    wrap_alignment.clear_window(original_win)
    wrap_alignment.clear_window(modified_win)
    wrap_alignment.release_session(tabpage)
  end)
end)
