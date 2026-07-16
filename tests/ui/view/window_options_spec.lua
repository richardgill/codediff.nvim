local config = require("codediff.config")
local welcome = require("codediff.ui.welcome")
local window_options = require("codediff.ui.view.window_options")

local function create_window()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufnr)
  return win, bufnr
end

local function close_extra_windows()
  local current = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= current and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
end

describe("Diff window options", function()
  before_each(function()
    config.options.diff.window_options = nil
  end)

  after_each(function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      window_options.restore(win)
    end
    config.options.diff.window_options = nil
    if welcome.is_welcome_buffer(vim.api.nvim_get_current_buf()) then
      vim.cmd("enew")
    end
    close_extra_windows()
  end)

  it("rejects static window option tables", function()
    assert.has_error(function()
      config.setup({ diff = { window_options = { signcolumn = "no" } } })
    end, "codediff: diff.window_options must be a function")
  end)

  it("applies returned options and provides the pane context", function()
    local win = vim.api.nvim_get_current_win()
    local original_signcolumn = vim.wo[win].signcolumn
    local context
    config.options.diff.window_options = function(ctx)
      context = ctx
      return { signcolumn = "no", number = false }
    end

    window_options.apply(win, "original", "side-by-side")

    assert.equals(win, context.win)
    assert.equals(vim.api.nvim_win_get_buf(win), context.buf)
    assert.equals(vim.api.nvim_get_current_tabpage(), context.tabpage)
    assert.equals("original", context.role)
    assert.equals("side-by-side", context.view)
    assert.equals("no", vim.wo[win].signcolumn)
    assert.is_false(vim.wo[win].number)

    window_options.restore(win)
    assert.equals(original_signcolumn, vim.wo[win].signcolumn)
  end)

  it("restores options omitted after a role change", function()
    local win = vim.api.nvim_get_current_win()
    local original_signcolumn = vim.wo[win].signcolumn
    config.options.diff.window_options = function(ctx)
      if ctx.role == "original" then
        return { signcolumn = "no" }
      end
      return {}
    end

    window_options.apply(win, "original", "side-by-side")
    assert.equals("no", vim.wo[win].signcolumn)

    window_options.apply(win, "result", "conflict")
    assert.equals(original_signcolumn, vim.wo[win].signcolumn)
  end)

  it("reports invalid option values and restores the previous value", function()
    local win = vim.api.nvim_get_current_win()
    local original_signcolumn = vim.wo[win].signcolumn
    local value = "no"
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message)
      table.insert(notifications, message)
    end

    local ok, err = pcall(function()
      config.options.diff.window_options = function()
        return { signcolumn = value }
      end
      window_options.apply(win, "original", "side-by-side")
      value = "invalid"
      window_options.apply(win, "original", "side-by-side")
    end)
    vim.notify = original_notify

    assert.is_true(ok, err)
    assert.equals(original_signcolumn, vim.wo[win].signcolumn)
    assert.is_true(#notifications > 0)
  end)

  it("assigns side-by-side, inline, and conflict roles", function()
    local original_win = vim.api.nvim_get_current_win()
    local modified_win = create_window()
    local seen = {}
    config.options.diff.window_options = function(ctx)
      seen[ctx.role] = ctx.view
      return { signcolumn = "no" }
    end

    local session = {
      original_path = "old.lua",
      modified_path = "new.lua",
      original_win = original_win,
      modified_win = modified_win,
      layout = "side-by-side",
    }
    window_options.apply_session(session)
    assert.equals("side-by-side", seen.original)
    assert.equals("side-by-side", seen.modified)

    seen = {}
    session.original_win = modified_win
    session.layout = "inline"
    window_options.apply_session(session)
    assert.equals("inline", seen.inline)
    assert.is_nil(seen.original)
    assert.is_nil(seen.modified)

    local result_win = create_window()
    seen = {}
    session.original_win = original_win
    session.modified_win = modified_win
    session.result_win = result_win
    session.layout = "side-by-side"
    window_options.apply_session(session)
    assert.equals("conflict", seen.original)
    assert.equals("conflict", seen.modified)
    assert.equals("conflict", seen.result)
  end)

  it("does not invoke the callback for placeholder or welcome panes", function()
    local win = vim.api.nvim_get_current_win()
    local calls = 0
    config.options.diff.window_options = function()
      calls = calls + 1
      return { signcolumn = "yes:1" }
    end

    window_options.apply_session({
      original_path = "",
      modified_path = "",
      original_win = win,
      modified_win = win,
      layout = "inline",
    })
    assert.equals(0, calls)

    local welcome_buf = welcome.create_buffer(80, 24)
    vim.api.nvim_win_set_buf(win, welcome_buf)
    window_options.apply(win, "inline", "inline")
    assert.equals(0, calls)
  end)
end)

describe("Diff window options integration", function()
  local paths = {}

  before_each(function()
    paths = { vim.fn.tempname() .. ".lua", vim.fn.tempname() .. ".lua" }
    vim.fn.writefile({ "local value = 1" }, paths[1])
    vim.fn.writefile({ "local value = 2" }, paths[2])
  end)

  after_each(function()
    config.options.diff.window_options = nil
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    for _, path in ipairs(paths) do
      vim.fn.delete(path)
    end
  end)

  it("reapplies role-specific options across layout changes", function()
    local seen = {}
    require("codediff").setup({
      diff = {
        layout = "side-by-side",
        window_options = function(ctx)
          seen[ctx.role] = (seen[ctx.role] or 0) + 1
          local values = {
            original = "no",
            modified = "yes:1",
            inline = "yes:2",
          }
          return { signcolumn = values[ctx.role] or "auto" }
        end,
      },
    })

    local ready = false
    require("codediff.ui.view").create(
      {
        mode = "standalone",
        original_path = paths[1],
        modified_path = paths[2],
      },
      nil,
      function()
        ready = true
      end
    )

    assert.is_true(vim.wait(5000, function()
      return ready
    end, 20))

    local tabpage = vim.api.nvim_get_current_tabpage()
    local lifecycle = require("codediff.ui.lifecycle")
    local session = lifecycle.get_session(tabpage)
    assert.equals("no", vim.wo[session.original_win].signcolumn)
    assert.equals("yes:1", vim.wo[session.modified_win].signcolumn)
    assert.is_true(seen.original > 0)
    assert.is_true(seen.modified > 0)

    assert.is_true(require("codediff.ui.view").toggle_layout(tabpage))
    assert.is_true(vim.wait(5000, function()
      session = lifecycle.get_session(tabpage)
      return session and session.layout == "inline" and seen.inline and vim.wo[session.modified_win].signcolumn == "yes:2"
    end, 20))

    assert.is_true(require("codediff.ui.view").toggle_layout(tabpage))
    assert.is_true(vim.wait(5000, function()
      session = lifecycle.get_session(tabpage)
      return session
        and session.layout == "side-by-side"
        and session.original_win ~= session.modified_win
        and vim.wo[session.original_win].signcolumn == "no"
        and vim.wo[session.modified_win].signcolumn == "yes:1"
    end, 20))
  end)
end)
