local core = require("codediff.ui.core")
local diff = require("codediff.core.diff")
local lifecycle = require("codediff.ui.lifecycle")
local wrap_alignment = require("codediff.ui.wrap_alignment")

local create_session = function()
  local original_lines = {
    "ANCHOR_001",
    "original " .. string.rep("wide content ", 12),
    "日本語 😀 é\tlist",
    "folded context one",
    "folded context two",
    "ANCHOR_002",
    "tail " .. string.rep("content ", 10),
    "ANCHOR_003",
  }
  local modified_lines = {
    "ANCHOR_001",
    "modified short",
    "日本語 😀 é\tlist changed",
    "folded context one",
    "folded context two",
    "ANCHOR_002",
    "tail short",
    "ANCHOR_003",
  }
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

  local lines_diff = diff.compute_diff(original_lines, modified_lines, { compute_moves = false })
  core.render_diff(original_buf, modified_buf, original_lines, modified_lines, lines_diff, { skip_fillers = true })
  local tabpage = vim.api.nvim_get_current_tabpage()
  lifecycle.create_session(tabpage, "standalone", nil, "original", "modified", "WORKING", "WORKING", original_buf, modified_buf, original_win, modified_win, lines_diff)
  wrap_alignment.apply({
    original_win = original_win,
    modified_win = modified_win,
    original_buf = original_buf,
    modified_buf = modified_buf,
    lines_diff = lines_diff,
  })
  return {
    tabpage = tabpage,
    original_win = original_win,
    modified_win = modified_win,
    original_buf = original_buf,
    modified_buf = modified_buf,
  }
end

local wait_for_reason = function(win, reason, previous_count)
  return vim.wait(2000, function()
    local stats = vim.w[win].codediff_wrap_alignment
    return stats and stats.rebuild_reason == reason and (not previous_count or stats.rebuild_count > previous_count)
  end, 20)
end

local anchor_rows = function(buf)
  local rows = {}
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find("ANCHOR_", 1, true) then
      rows[#rows + 1] = row
    end
  end
  return rows
end

local assert_aligned = function(session)
  local original_rows = anchor_rows(session.original_buf)
  local modified_rows = anchor_rows(session.modified_buf)
  for index, original_row in ipairs(original_rows) do
    local modified_row = modified_rows[index]
    local original_fold = vim.api.nvim_win_call(session.original_win, function()
      return vim.fn.foldclosed(original_row)
    end)
    local modified_fold = vim.api.nvim_win_call(session.modified_win, function()
      return vim.fn.foldclosed(modified_row)
    end)
    if original_fold < 0 and modified_fold < 0 then
      local original_height = vim.api.nvim_win_text_height(session.original_win, { end_row = original_row - 1, end_vcol = 0 }).all
      local modified_height = vim.api.nvim_win_text_height(session.modified_win, { end_row = modified_row - 1, end_vcol = 0 }).all
      assert.equal(original_height, modified_height)
    end
  end
end

describe("wrapped display invalidation", function()
  before_each(function()
    require("codediff").setup({ diff = { wrap = true } })
  end)

  after_each(function()
    lifecycle.cleanup_all()
    if vim.fn.tabpagenr("$") > 1 then
      vim.cmd("tabclose!")
    end
    require("codediff").setup({ diff = { wrap = false } })
  end)

  it("rebuilds after rendering option changes", function()
    local session = create_session()
    vim.wait(100)
    vim.api.nvim_win_call(session.original_win, function()
      vim.cmd("setlocal linebreak breakindent number")
      vim.wo.showbreak = ">>"
      vim.wo.numberwidth = 6
      vim.wo.list = true
      vim.wo.listchars = "tab:>-"
      vim.wo.foldcolumn = "1"
      vim.wo.statuscolumn = "%l "
      vim.api.nvim_exec_autocmds("OptionSet", { pattern = "linebreak", modeline = false })
    end)
    assert.is_true(wait_for_reason(session.original_win, "display-option"))
    assert_aligned(session)
  end)

  it("rebuilds after global width and conceal changes", function()
    local session = create_session()
    local original_ambiwidth = vim.o.ambiwidth
    local original_listchars = vim.o.listchars
    vim.o.listchars = "tab:>-,trail:-"
    vim.o.ambiwidth = original_ambiwidth == "single" and "double" or "single"
    vim.api.nvim_exec_autocmds("OptionSet", { pattern = "ambiwidth", modeline = false })
    assert.is_true(wait_for_reason(session.original_win, "display-option"))
    assert_aligned(session)

    local rebuild_count = vim.w[session.original_win].codediff_wrap_alignment.rebuild_count
    vim.api.nvim_win_call(session.original_win, function()
      vim.wo.conceallevel = 2
      vim.wo.concealcursor = "n"
      vim.api.nvim_exec_autocmds("ModeChanged", { modeline = false })
    end)
    assert.is_true(wait_for_reason(session.original_win, "conceal", rebuild_count))
    assert_aligned(session)
    vim.o.ambiwidth = original_ambiwidth
    vim.o.listchars = original_listchars
  end)

  it("rebuilds after diagnostic display changes", function()
    local session = create_session()
    local namespace = vim.api.nvim_create_namespace("codediff-wrap-invalidation-test")
    vim.diagnostic.set(namespace, session.modified_buf, {
      { lnum = 1, col = 0, message = "diagnostic", severity = vim.diagnostic.severity.ERROR },
    }, { signs = true, virtual_text = true })

    assert.is_true(wait_for_reason(session.original_win, "diagnostic"))
    assert_aligned(session)
    vim.diagnostic.reset(namespace, session.modified_buf)
  end)

  it("supports explicit invalidation for external decorations", function()
    local session = create_session()
    local namespace = vim.api.nvim_create_namespace("codediff-wrap-external-decoration-test")
    vim.api.nvim_buf_set_extmark(session.modified_buf, namespace, 1, 0, {
      virt_text = { { string.rep(" virtual text", 10), "Normal" } },
      virt_text_pos = "inline",
    })

    assert.is_true(require("codediff").invalidate_alignment(session.tabpage, "external-decoration"))
    assert.is_true(wait_for_reason(session.original_win, "external-decoration"))
    assert_aligned(session)
  end)

  it("realigns after explicitly invalidated arbitrary folds", function()
    local session = create_session()
    vim.api.nvim_win_call(session.original_win, function()
      vim.wo.foldmethod = "manual"
      vim.cmd("2,5fold")
    end)

    assert.is_true(require("codediff").invalidate_alignment(session.tabpage, "fold"))
    assert.is_true(wait_for_reason(session.original_win, "fold"))
    assert.equal(
      2,
      vim.api.nvim_win_call(session.original_win, function()
        return vim.fn.foldclosed(2)
      end)
    )
    assert_aligned(session)

    vim.api.nvim_win_call(session.original_win, function()
      vim.api.nvim_win_set_cursor(session.original_win, { 2, 0 })
      vim.cmd("normal! zo")
    end)
    local rebuild_count = vim.w[session.original_win].codediff_wrap_alignment.rebuild_count
    assert.is_true(require("codediff").invalidate_alignment(session.tabpage, "fold"))
    assert.is_true(wait_for_reason(session.original_win, "fold", rebuild_count))
    assert_aligned(session)

    vim.api.nvim_win_call(session.original_win, function()
      vim.cmd("6,8fold")
    end)
    rebuild_count = vim.w[session.original_win].codediff_wrap_alignment.rebuild_count
    assert.is_true(require("codediff").invalidate_alignment(session.tabpage, "fold"))
    assert.is_true(wait_for_reason(session.original_win, "fold", rebuild_count))
    assert.equal(vim.api.nvim_win_text_height(session.original_win, {}).all, vim.api.nvim_win_text_height(session.modified_win, {}).all)
  end)
end)
