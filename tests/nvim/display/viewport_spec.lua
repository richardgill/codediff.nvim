local display = require("codediff.nvim.display")
local viewport = require("codediff.nvim.display.viewport")

local create_windows = function(lines)
  vim.cmd("tabnew")
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(source_win, source_buf)
  vim.cmd("vsplit")
  local target_win = vim.api.nvim_get_current_win()
  local target_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(target_win, target_buf)
  vim.api.nvim_win_set_width(source_win, 28)
  vim.api.nvim_win_set_width(target_win, 46)
  for _, win in ipairs({ source_win, target_win }) do
    vim.wo[win].wrap = true
    vim.wo[win].smoothscroll = true
  end
  return source_win, target_win
end

local get_offset = function(win)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
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

local close_tab = function()
  if vim.fn.tabpagenr("$") > 1 then
    vim.cmd("tabclose!")
  end
end

describe("display viewport characterization", function()
  after_each(close_tab)

  it("captures and restores cursor and partial wrapped view", function()
    local lines = { string.rep("wrapped source content ", 30), "second", "third" }
    local source_win, target_win = create_windows(lines)
    vim.api.nvim_win_call(source_win, function()
      vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
      vim.fn.winrestview({ topline = 1, skipcol = 56 })
    end)
    vim.api.nvim_set_current_win(source_win)

    local anchor = display.capture(source_win)
    local expected_view = vim.api.nvim_win_call(source_win, vim.fn.winsaveview)
    vim.api.nvim_win_call(source_win, function()
      vim.api.nvim_win_set_cursor(source_win, { 3, 0 })
      vim.fn.winrestview({ topline = 2, skipcol = 0 })
    end)
    display.restore(source_win, anchor)

    local restored = vim.api.nvim_win_call(source_win, vim.fn.winsaveview)
    assert.equal(expected_view.topline, restored.topline)
    assert.equal(expected_view.skipcol, restored.skipcol)
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(source_win))
    assert.same({}, anchor)
  end)

  it("maps rendered offsets from an inactive source with the target cursor far below", function()
    local lines = { string.rep("wrapped source content ", 30) }
    for index = 2, 200 do
      lines[index] = string.format("line %03d", index)
    end
    local source_win, target_win = create_windows(lines)
    vim.api.nvim_win_call(source_win, function()
      vim.fn.winrestview({ topline = 1, skipcol = 56 })
    end)
    vim.api.nvim_win_set_cursor(target_win, { 200, 0 })
    vim.api.nvim_set_current_win(source_win)

    local offset = display.get_offset(source_win)
    local source_view = vim.api.nvim_win_call(source_win, vim.fn.winsaveview)
    viewport.reset_metrics()
    display.set_offset(target_win, offset)
    vim.cmd("redraw")

    local metrics = viewport.get_metrics()
    assert.equal(1, metrics.direct_count)
    assert.equal(0, metrics.fallback_count)
    assert.is_true(metrics.direct_text_height_calls <= 7)
    local target_view = vim.api.nvim_win_call(target_win, vim.fn.winsaveview)
    assert.is_true(source_view.skipcol > 0)
    assert.is_true(target_view.skipcol > 0)
    assert.is_true(source_view.skipcol ~= target_view.skipcol)
    assert.equal(offset, get_offset(target_win))
    assert.same({ 200, 0 }, vim.api.nvim_win_get_cursor(target_win))
  end)

  it("maps a wrapped offset onto an inactive target with its cursor far above", function()
    local lines = {}
    for index = 1, 200 do
      lines[index] = string.rep("wrapped content ", 15)
    end
    local source_win, target_win = create_windows(lines)
    vim.api.nvim_set_current_win(source_win)
    display.set_offset(source_win, 121, { preserve_cursor = false })
    vim.api.nvim_win_set_cursor(target_win, { 1, 0 })

    display.set_offset(target_win, display.get_offset(source_win))
    vim.cmd("redraw")

    local target_view = vim.api.nvim_win_call(target_win, vim.fn.winsaveview)
    assert.equal(121, get_offset(target_win))
    assert.is_true(target_view.skipcol > 0)
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(target_win))
  end)

  it("represents zero before virtual filler above the first line", function()
    local _, target_win = create_windows({ "first", "second", "third" })
    local target_buf = vim.api.nvim_win_get_buf(target_win)
    local ns = vim.api.nvim_create_namespace("CodeDiffDisplayViewportBofCharacterization")
    vim.api.nvim_buf_set_extmark(target_buf, ns, 0, 0, {
      virt_lines = { { { "filler one" } }, { { "filler two" } } },
      virt_lines_above = true,
    })
    vim.cmd("redraw")

    viewport.reset_metrics()
    display.set_offset(target_win, 0)

    local metrics = viewport.get_metrics()
    local target_view = vim.api.nvim_win_call(target_win, vim.fn.winsaveview)
    assert.equal(1, metrics.direct_count)
    assert.equal(1, metrics.direct_text_height_calls)
    assert.equal(1, target_view.topline)
    assert.equal(2, target_view.topfill)
    assert.equal(0, get_offset(target_win))
  end)

  it("represents an offset inside virtual filler with topfill", function()
    local lines = { string.rep("wrapped source content ", 30), "second", "third" }
    local source_win, target_win = create_windows(lines)
    local target_buf = vim.api.nvim_win_get_buf(target_win)
    vim.api.nvim_buf_set_lines(target_buf, 0, 1, false, { "short" })
    local ns = vim.api.nvim_create_namespace("CodeDiffDisplayViewportCharacterization")
    vim.api.nvim_buf_set_extmark(target_buf, ns, 0, 0, {
      virt_lines = { { { "filler one" } }, { { "filler two" } }, { { "filler three" } } },
    })
    vim.cmd("redraw")
    vim.api.nvim_win_call(source_win, function()
      vim.fn.winrestview({ topline = 1, skipcol = 28 })
    end)

    viewport.reset_metrics()
    display.set_offset(target_win, display.get_offset(source_win))

    local metrics = viewport.get_metrics()
    local target_view = vim.api.nvim_win_call(target_win, vim.fn.winsaveview)
    assert.equal(0, metrics.direct_count)
    assert.equal(1, metrics.fallback_count)
    assert.is_true(metrics.fallback_text_height_calls > 3)
    assert.equal(0, target_view.skipcol)
    assert.is_true(target_view.topfill > 0)
    assert.equal(get_offset(source_win), get_offset(target_win))
  end)

  it("returns the nearest representable offset when virtual filler cannot fill the viewport", function()
    local _, target_win = create_windows({ "first", string.rep("wrapped target content ", 20), "third" })
    local target_buf = vim.api.nvim_win_get_buf(target_win)
    local virtual_lines = {}
    for index = 1, 12 do
      virtual_lines[index] = { { "filler " .. index } }
    end
    vim.api.nvim_buf_set_extmark(target_buf, vim.api.nvim_create_namespace("CodeDiffDisplayViewportClamp"), 0, 0, {
      virt_lines = virtual_lines,
    })
    vim.api.nvim_win_set_height(target_win, 8)
    vim.api.nvim_win_set_cursor(target_win, { 1, 0 })
    vim.cmd("redraw")

    local applied_offset = display.set_offset(target_win, 3)
    vim.cmd("redraw")

    assert.is_true(applied_offset > 3)
    assert.equal(applied_offset, display.get_offset(target_win))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(target_win))
  end)

  it("preserves a far cursor when an inactive target starts inside virtual filler", function()
    local lines = {}
    for index = 1, 200 do
      lines[index] = string.format("line %03d", index)
    end
    local source_win, target_win = create_windows(lines)
    local target_buf = vim.api.nvim_win_get_buf(target_win)
    local ns = vim.api.nvim_create_namespace("CodeDiffDisplayViewportFarCursorFiller")
    vim.api.nvim_buf_set_extmark(target_buf, ns, 99, 0, {
      virt_lines = { { { "filler one" } }, { { "filler two" } }, { { "filler three" } } },
    })
    vim.cmd("redraw")
    vim.api.nvim_win_set_cursor(target_win, { 200, 0 })
    vim.api.nvim_set_current_win(source_win)

    display.set_offset(target_win, 102)
    vim.cmd("redraw")

    local target_view = vim.api.nvim_win_call(target_win, vim.fn.winsaveview)
    assert.equal(102, get_offset(target_win))
    assert.is_true(target_view.topfill > 0)
    assert.same({ 200, 0 }, vim.api.nvim_win_get_cursor(target_win))
  end)

  it("produces the fallback view when a bounded endpoint is ambiguous", function()
    local lines = { string.rep("wrapped source content ", 30), "second", "third" }
    local source_win, target_win = create_windows(lines)
    vim.api.nvim_win_call(source_win, function()
      vim.fn.winrestview({ topline = 1, skipcol = 56 })
    end)
    local offset = display.get_offset(source_win)

    viewport.reset_metrics()
    display.set_offset(target_win, offset)
    local direct_view = vim.api.nvim_win_call(target_win, vim.fn.winsaveview)
    local direct_calls = viewport.get_metrics().direct_text_height_calls

    vim.api.nvim_win_call(target_win, function()
      vim.fn.winrestview({ topline = 2, skipcol = 0 })
    end)
    local text_height = vim.api.nvim_win_text_height
    vim.api.nvim_win_text_height = function(win, opts)
      local result = text_height(win, opts)
      if opts.max_height then
        result.end_vcol = -1
      end
      return result
    end
    viewport.reset_metrics()
    local ok, error_message = pcall(display.set_offset, target_win, offset)
    vim.api.nvim_win_text_height = text_height
    assert.is_true(ok, error_message)

    local metrics = viewport.get_metrics()
    local fallback_view = vim.api.nvim_win_call(target_win, vim.fn.winsaveview)
    assert.equal(0, metrics.direct_count)
    assert.equal(1, metrics.fallback_count)
    assert.is_true(metrics.fallback_text_height_calls > direct_calls)
    assert.same({ direct_view.topline, direct_view.topfill, direct_view.skipcol }, {
      fallback_view.topline,
      fallback_view.topfill,
      fallback_view.skipcol,
    })
  end)

  it("falls back for a closed-fold endpoint", function()
    local lines = {}
    for index = 1, 20 do
      lines[index] = string.format("line %02d", index)
    end
    local _, target_win = create_windows(lines)
    vim.api.nvim_win_call(target_win, function()
      vim.wo.foldmethod = "manual"
      vim.cmd("2,6fold")
    end)
    vim.cmd("redraw")

    viewport.reset_metrics()
    display.set_offset(target_win, 2)

    local metrics = viewport.get_metrics()
    assert.equal(0, metrics.direct_count)
    assert.equal(1, metrics.fallback_count)
  end)

  it("keeps direct and fallback resolution equivalent across rendered row types", function()
    local lines = {
      string.rep("first wrapped words ", 12),
      "fold start",
      "folded tabs:\tone\ttwo",
      "fold end",
      "Unicode 日本語 Καλημέρα 🙂🙂🙂",
      string.rep("last wrapped words ", 15),
    }
    local _, target_win = create_windows(lines)
    local target_buf = vim.api.nvim_win_get_buf(target_win)
    local ns = vim.api.nvim_create_namespace("CodeDiffDisplayViewportParity")
    vim.api.nvim_buf_set_extmark(target_buf, ns, 0, 0, {
      virt_lines = { { { "above one" } }, { { "above two" } } },
      virt_lines_above = true,
    })
    vim.api.nvim_buf_set_extmark(target_buf, ns, 0, 0, {
      virt_lines = { { { "after first one" } }, { { "after first two" } } },
    })
    vim.api.nvim_win_call(target_win, function()
      vim.wo.linebreak = true
      vim.wo.breakindent = true
      vim.wo.showbreak = "> "
      vim.wo.foldmethod = "manual"
      vim.cmd("2,4fold")
    end)
    vim.cmd("redraw")

    local total = vim.api.nvim_win_text_height(target_win, {}).all
    local text_height = vim.api.nvim_win_text_height
    for offset = 0, total + 2 do
      display.set_offset(target_win, offset)
      local direct_view = vim.api.nvim_win_call(target_win, vim.fn.winsaveview)
      local direct_offset = display.get_offset(target_win)

      vim.api.nvim_win_text_height = function(win, opts)
        local result = text_height(win, opts)
        if opts.max_height then
          result.end_vcol = -1
        end
        return result
      end
      local ok, error_message = pcall(display.set_offset, target_win, offset)
      vim.api.nvim_win_text_height = text_height
      assert.is_true(ok, error_message)

      local fallback_view = vim.api.nvim_win_call(target_win, vim.fn.winsaveview)
      assert.same({ direct_view.topline, direct_view.topfill, direct_view.skipcol }, {
        fallback_view.topline,
        fallback_view.topfill,
        fallback_view.skipcol,
      })
      assert.equal(direct_offset, display.get_offset(target_win))
    end
  end)

  it("ignores invalid windows and unknown anchors", function()
    local _, target_win = create_windows({ "first", "second" })
    local before = vim.api.nvim_win_call(target_win, vim.fn.winsaveview)

    assert.is_nil(display.capture(nil))
    assert.is_nil(display.get_offset(nil))
    assert.has_no.errors(function()
      display.restore(target_win, {})
      display.set_offset(nil, 10)
    end)

    local after = vim.api.nvim_win_call(target_win, vim.fn.winsaveview)
    assert.same(before, after)
  end)
end)
