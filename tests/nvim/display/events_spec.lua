local display = require("codediff.nvim.display")

local subscriptions = {}

local create_windows = function()
  local lines = {}
  for index = 1, 200 do
    lines[index] = string.format("line %03d %s", index, string.rep("wrapped content ", index % 6))
  end

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
  vim.api.nvim_win_set_width(source_win, 30)
  vim.api.nvim_win_set_width(target_win, 48)
  vim.wo[source_win].wrap = true
  vim.wo[target_win].wrap = true
  return source_win, target_win, source_buf, target_buf
end

local observe = function(opts)
  local subscription = display.observe(opts)
  subscriptions[#subscriptions + 1] = subscription
  return subscription
end

local set_topline = function(win, topline)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { topline, 0 })
  vim.cmd("normal! zt")
end

local redraw = function(win)
  vim.cmd("redraw")
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win), modeline = false })
end

local wait_for = function(predicate)
  return vim.wait(1000, predicate, 10)
end

local close_tab = function()
  for _, subscription in ipairs(subscriptions) do
    display.unobserve(subscription)
  end
  subscriptions = {}
  if vim.fn.tabpagenr("$") > 1 then
    vim.cmd("tabclose!")
  end
end

describe("display event normalization", function()
  after_each(close_tab)

  it("coalesces scrolling onto the final settled source offset", function()
    local source_win = create_windows()
    local calls = {}
    observe({
      wins = { source_win },
      on_scroll = function(win, offset)
        calls[#calls + 1] = { win = win, offset = offset }
      end,
      on_invalidate = function() end,
    })

    set_topline(source_win, 10)
    redraw(source_win)
    set_topline(source_win, 40)

    assert.equal(0, #calls)
    assert.is_true(wait_for(function()
      return #calls == 1
    end))
    assert.equal(source_win, calls[1].win)
    assert.equal(display.get_offset(source_win), calls[1].offset)
  end)

  it("suppresses scroll events produced by non-notifying offset updates", function()
    local source_win, target_win = create_windows()
    local calls = {}
    observe({
      wins = { target_win },
      on_scroll = function(win, offset)
        calls[#calls + 1] = { win = win, offset = offset }
      end,
      on_invalidate = function() end,
    })

    set_topline(source_win, 120)
    vim.api.nvim_win_set_cursor(target_win, { 1, 0 })
    local source_offset = display.get_offset(source_win)
    display.set_offset(target_win, source_offset, { notify = false })
    assert.equal(source_offset, display.get_offset(target_win))
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(target_win))
    redraw(target_win)
    vim.wait(100)
    assert.equal(0, #calls)

    set_topline(target_win, 80)
    redraw(target_win)
    assert.is_true(wait_for(function()
      return #calls == 1
    end))
    assert.equal(target_win, calls[1].win)
    assert.equal(display.get_offset(target_win), calls[1].offset)
  end)

  it("synchronizes a real mouse scroll into inactive wrapped filler without notifying", function()
    local source_win, target_win, _, target_buf = create_windows()
    local filler = {}
    for index = 1, 10 do
      filler[index] = { { "filler " .. index } }
    end
    local ns = vim.api.nvim_create_namespace("CodeDiffDisplayInactiveMouse")
    vim.api.nvim_buf_set_extmark(target_buf, ns, 0, 0, { virt_lines = filler })
    vim.wo[source_win].smoothscroll = true
    vim.wo[target_win].smoothscroll = true
    vim.api.nvim_set_current_win(source_win)
    vim.api.nvim_win_set_cursor(target_win, { 200, 0 })
    display.set_offset(target_win, 0)
    vim.cmd("redraw")

    local source_calls = 0
    local target_calls = 0
    local subscription
    subscription = observe({
      wins = { source_win, target_win },
      on_scroll = function(win, offset)
        if win == source_win then
          source_calls = source_calls + 1
          display.synchronize(subscription, win, offset)
          vim.schedule(function()
            redraw(target_win)
          end)
        else
          target_calls = target_calls + 1
        end
      end,
      on_invalidate = function() end,
    })

    local position = vim.fn.win_screenpos(vim.fn.win_id2win(source_win))
    local mouse = vim.keycode(string.format("<ScrollWheelDown><%d,%d>", position[2] + 2, position[1] + 2))
    vim.fn.feedkeys(mouse:rep(3), "xt")
    redraw(source_win)

    local synced = wait_for(function()
      local source_offset = display.get_offset(source_win)
      return source_calls == 1 and source_offset > 1 and source_offset < 11 and display.get_offset(target_win) == source_offset
    end)
    assert.is_true(
      synced,
      vim.inspect({
        position = position,
        source_calls = source_calls,
        source_offset = display.get_offset(source_win),
        target_calls = target_calls,
        target_offset = display.get_offset(target_win),
      })
    )
    vim.wait(100)
    assert.same({ 200, 0 }, vim.api.nvim_win_get_cursor(target_win))
    assert.equal(0, target_calls)
  end)

  it("aligns the current partner when an inactive pane is scrolled", function()
    local source_win, target_win = create_windows()
    vim.api.nvim_set_current_win(target_win)
    vim.api.nvim_win_set_cursor(target_win, { 1, 0 })
    local source_calls = 0
    local target_calls = 0
    local subscription
    subscription = observe({
      wins = { source_win, target_win },
      on_scroll = function(win, offset)
        if win == source_win then
          source_calls = source_calls + 1
          display.synchronize(subscription, win, offset)
        else
          target_calls = target_calls + 1
        end
      end,
      on_invalidate = function() end,
    })

    vim.api.nvim_win_call(source_win, function()
      vim.api.nvim_win_set_cursor(source_win, { 80, 0 })
      vim.cmd("normal! zt")
    end)
    redraw(source_win)

    assert.is_true(wait_for(function()
      local source_offset = display.get_offset(source_win)
      return source_calls == 1 and source_offset > 10 and display.get_offset(target_win) == source_offset
    end))
    vim.wait(100)
    assert.equal(target_win, vim.api.nvim_get_current_win())
    assert.is_true(vim.api.nvim_win_get_cursor(target_win)[1] > 1)
    assert.equal(0, target_calls)
  end)

  it("expires suppression when an offset update produces no scroll event", function()
    local _, target_win = create_windows()
    local calls = {}
    observe({
      wins = { target_win },
      on_scroll = function(win, offset)
        calls[#calls + 1] = { win = win, offset = offset }
      end,
      on_invalidate = function() end,
    })

    display.set_offset(target_win, display.get_offset(target_win), { notify = false })
    vim.wait(20)
    set_topline(target_win, 80)
    redraw(target_win)

    assert.is_true(wait_for(function()
      return #calls == 1
    end))
    assert.equal(target_win, calls[1].win)
  end)

  it("keeps independent subscriptions isolated through cleanup", function()
    local source_win, target_win = create_windows()
    local source_calls = 0
    local target_calls = 0
    local source_subscription = observe({
      wins = { source_win },
      on_scroll = function()
        source_calls = source_calls + 1
      end,
      on_invalidate = function() end,
    })
    local target_subscription = observe({
      wins = { target_win },
      on_scroll = function()
        target_calls = target_calls + 1
      end,
      on_invalidate = function() end,
    })

    set_topline(source_win, 20)
    redraw(source_win)
    assert.is_true(wait_for(function()
      return source_calls == 1
    end))
    assert.equal(0, target_calls)

    set_topline(target_win, 30)
    redraw(target_win)
    assert.is_true(wait_for(function()
      return target_calls == 1
    end))
    assert.equal(1, source_calls)

    display.unobserve(target_subscription)
    set_topline(target_win, 50)
    redraw(target_win)
    vim.wait(100)
    assert.equal(1, target_calls)

    set_topline(source_win, 70)
    redraw(source_win)
    display.unobserve(source_subscription)
    vim.wait(100)
    assert.equal(1, source_calls)
  end)

  it("normalizes and scopes display invalidations", function()
    local source_win, _, source_buf, target_buf = create_windows()
    local reasons = {}
    observe({
      wins = { source_win },
      on_scroll = function() end,
      on_invalidate = function(reason)
        reasons[#reasons + 1] = reason
      end,
    })

    vim.api.nvim_exec_autocmds("DiagnosticChanged", { buffer = target_buf, modeline = false })
    assert.same({}, reasons)

    vim.api.nvim_win_call(source_win, function()
      vim.api.nvim_exec_autocmds("OptionSet", { pattern = "linebreak", modeline = false })
    end)
    vim.api.nvim_exec_autocmds("DiagnosticChanged", { buffer = source_buf, modeline = false })

    vim.wo[source_win].conceallevel = 2
    vim.wo[source_win].concealcursor = "n"
    vim.api.nvim_set_current_win(source_win)
    vim.api.nvim_exec_autocmds("ModeChanged", { modeline = false })
    vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
    vim.api.nvim_exec_autocmds("OptionSet", { pattern = "ambiwidth", modeline = false })

    assert.same({ "display-option", "diagnostic", "conceal", "resize", "display-option" }, reasons)
  end)
end)
