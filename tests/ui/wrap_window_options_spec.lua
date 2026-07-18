local wrap_alignment = require("codediff.ui.wrap_alignment")

local create_panes = function()
  vim.cmd("tabnew")
  local modified_win = vim.api.nvim_get_current_win()
  local modified_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false, { "same" })
  vim.api.nvim_win_set_buf(modified_win, modified_buf)
  vim.cmd("leftabove vsplit")
  local original_win = vim.api.nvim_get_current_win()
  local original_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, { "same" })
  vim.api.nvim_win_set_buf(original_win, original_buf)
  return vim.api.nvim_get_current_tabpage(), original_win, modified_win, original_buf, modified_buf
end

local set_options = function(win, options)
  for name, value in pairs(options) do
    vim.wo[win][name] = value
  end
end

local assert_options = function(win, options)
  for name, value in pairs(options) do
    assert.equal(value, vim.wo[win][name])
  end
end

describe("wrapped window option ownership", function()
  before_each(function()
    require("codediff").setup({ diff = { wrap = true } })
  end)

  after_each(function()
    if vim.fn.tabpagenr("$") > 1 then
      vim.cmd("tabclose!")
    end
    require("codediff").setup({ diff = { wrap = false } })
  end)

  it("restores pane options after alignment is cleared", function()
    local tabpage, original_win, modified_win, original_buf, modified_buf = create_panes()
    local original_options = { wrap = false, scrollbind = true, smoothscroll = true, cursorbind = true }
    local modified_options = { wrap = true, scrollbind = false, smoothscroll = true, cursorbind = false }
    set_options(original_win, original_options)
    set_options(modified_win, modified_options)
    wrap_alignment.capture_window(tabpage, "original", original_win)
    wrap_alignment.capture_window(tabpage, "modified", modified_win)

    wrap_alignment.apply({
      original_win = original_win,
      modified_win = modified_win,
      original_buf = original_buf,
      modified_buf = modified_buf,
      lines_diff = { changes = {}, moves = {} },
    })

    assert_options(original_win, { wrap = true, scrollbind = false, smoothscroll = true, cursorbind = false })
    assert_options(modified_win, { wrap = true, scrollbind = false, smoothscroll = true, cursorbind = false })
    wrap_alignment.clear_window(original_win)
    wrap_alignment.clear_window(modified_win)
    assert_options(original_win, original_options)
    assert_options(modified_win, modified_options)
    wrap_alignment.release_session(tabpage)
  end)

  it("retains the original profile across temporary policies", function()
    local tabpage, _, modified_win = create_panes()
    local original_options = { wrap = false, scrollbind = true, smoothscroll = true, cursorbind = true }
    set_options(modified_win, original_options)
    wrap_alignment.capture_window(tabpage, "modified", modified_win)
    set_options(modified_win, { wrap = true, scrollbind = false, smoothscroll = false })
    wrap_alignment.clear_window(modified_win)

    set_options(modified_win, { wrap = true, scrollbind = false, smoothscroll = false })
    wrap_alignment.capture_window(tabpage, "modified", modified_win)
    wrap_alignment.release_session(tabpage)

    assert_options(modified_win, original_options)
  end)

  it("restores options during lifecycle cleanup", function()
    local tabpage, original_win, modified_win, original_buf, modified_buf = create_panes()
    local original_options = { wrap = false, scrollbind = true, smoothscroll = true, cursorbind = true }
    local modified_options = { wrap = true, scrollbind = false, smoothscroll = true, cursorbind = false }
    set_options(original_win, original_options)
    set_options(modified_win, modified_options)
    wrap_alignment.capture_window(tabpage, "original", original_win)
    wrap_alignment.capture_window(tabpage, "modified", modified_win)
    set_options(original_win, { wrap = true, scrollbind = false, smoothscroll = false })
    set_options(modified_win, { wrap = true, scrollbind = false, smoothscroll = false })
    local lifecycle = require("codediff.ui.lifecycle")
    lifecycle.create_session(
      tabpage,
      "standalone",
      nil,
      "original",
      "modified",
      "WORKING",
      "WORKING",
      original_buf,
      modified_buf,
      original_win,
      modified_win,
      { changes = {}, moves = {} }
    )

    lifecycle.cleanup(tabpage)

    assert_options(original_win, original_options)
    assert_options(modified_win, modified_options)
  end)
end)
