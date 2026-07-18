local core = require("codediff.ui.core")
local diff = require("codediff.core.diff")
local lifecycle = require("codediff.ui.lifecycle")
local lifecycle_state = require("codediff.ui.lifecycle.state")
local wrap_alignment = require("codediff.ui.wrap_alignment")
local view = require("codediff.ui.view")

local original_lines = {
  "ANCHOR_001",
  "short original",
  "ANCHOR_002",
  "shared " .. string.rep("long unchanged content ", 8),
  "ANCHOR_003",
  "ANCHOR_004",
}

local modified_lines = {
  "ANCHOR_001",
  string.rep("long modified content ", 10),
  "ANCHOR_002",
  original_lines[4],
  "ANCHOR_003",
  string.rep("inserted content ", 8),
  "ANCHOR_004",
}

local create_buffer = function(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local create_pair = function(shared_buf, modified_buf, original_width, lines_diff, options)
  vim.cmd("tabnew")
  local original_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(original_win, shared_buf)
  vim.cmd("vsplit")
  local modified_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(modified_win, modified_buf)
  vim.api.nvim_win_set_width(original_win, original_width)
  for name, value in pairs(options.original) do
    vim.wo[original_win][name] = value
  end
  for name, value in pairs(options.modified) do
    vim.wo[modified_win][name] = value
  end

  core.render_diff(shared_buf, modified_buf, original_lines, modified_lines, lines_diff, { skip_fillers = true })
  local stats = wrap_alignment.apply({
    original_win = original_win,
    modified_win = modified_win,
    original_buf = shared_buf,
    modified_buf = modified_buf,
    lines_diff = lines_diff,
  })
  return {
    tabpage = vim.api.nvim_get_current_tabpage(),
    original_win = original_win,
    modified_win = modified_win,
    original_buf = shared_buf,
    modified_buf = modified_buf,
    stats = stats,
    options = options,
  }
end

local register_pair = function(pair, index, lines_diff)
  lifecycle.create_session(
    pair.tabpage,
    "standalone",
    nil,
    "shared-" .. index,
    "modified-" .. index,
    "WORKING",
    "WORKING",
    pair.original_buf,
    pair.modified_buf,
    pair.original_win,
    pair.modified_win,
    lines_diff
  )
end

local assert_pair_aligned = function(pair)
  local anchors = { { 1, 1 }, { 3, 3 }, { 5, 5 }, { 6, 7 } }
  for _, anchor in ipairs(anchors) do
    local original_height = vim.api.nvim_win_text_height(pair.original_win, { end_row = anchor[1] - 1, end_vcol = 0 }).all
    local modified_height = vim.api.nvim_win_text_height(pair.modified_win, { end_row = anchor[2] - 1, end_vcol = 0 }).all
    assert.equal(original_height, modified_height)
  end
  assert.is_not_nil(vim.w[pair.original_win].codediff_wrap_alignment)
  assert.is_not_nil(vim.w[pair.modified_win].codediff_wrap_alignment)
end

local assert_options = function(win, options)
  for name, value in pairs(options) do
    assert.equal(value, vim.wo[win][name])
  end
end

local wait_for_alignment = function(tabpage)
  return vim.wait(3000, function()
    local session = lifecycle.get_session(tabpage)
    return session and not session.suspended and vim.w[session.original_win].codediff_wrap_alignment ~= nil and vim.w[session.modified_win].codediff_wrap_alignment ~= nil
  end, 20)
end

local edit_and_wait = function(session, text)
  local stats = vim.w[session.original_win].codediff_wrap_alignment
  local rebuild_count = stats and stats.rebuild_count or 0
  vim.api.nvim_buf_set_lines(session.modified_bufnr, 1, 2, false, { text })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = session.modified_bufnr, modeline = false })
  return vim.wait(1000, function()
    local updated = vim.w[session.original_win].codediff_wrap_alignment
    return updated and updated.rebuild_reason == "edit" and updated.rebuild_count > rebuild_count
  end, 20)
end

describe("wrapped full-session namespace ownership", function()
  before_each(function()
    vim.o.columns = 200
    vim.o.lines = 35
    require("codediff").setup({ diff = { wrap = true } })
    require("codediff.ui.highlights").setup()
  end)

  after_each(function()
    lifecycle.cleanup_all()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    require("codediff").setup({ diff = { wrap = false } })
  end)

  it("isolates shared-buffer padding through resize, suspend, resume, and cleanup", function()
    if not wrap_alignment.is_supported() then
      pending("wrapped alignment is unavailable")
      return
    end

    local shared_buf = create_buffer(original_lines)
    local modified_buf_1 = create_buffer(modified_lines)
    local modified_buf_2 = create_buffer(modified_lines)
    local lines_diff = diff.compute_diff(original_lines, modified_lines, { compute_moves = false })
    local pair_1 = create_pair(shared_buf, modified_buf_1, 45, lines_diff, {
      original = { wrap = false, scrollbind = true, smoothscroll = true },
      modified = { wrap = false, scrollbind = false, smoothscroll = false },
    })
    local pair_2 = create_pair(shared_buf, modified_buf_2, 75, lines_diff, {
      original = { wrap = false, scrollbind = true, smoothscroll = false },
      modified = { wrap = true, scrollbind = false, smoothscroll = false },
    })

    vim.cmd("tabnew")
    local ordinary_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(ordinary_win, shared_buf)
    vim.cmd("vsplit")
    local control_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(control_win, create_buffer(original_lines))
    vim.wo[ordinary_win].wrap = true
    vim.wo[control_win].wrap = true

    register_pair(pair_1, 1, lines_diff)
    register_pair(pair_2, 2, lines_diff)
    assert_pair_aligned(pair_1)
    assert_pair_aligned(pair_2)
    assert.equal(vim.api.nvim_win_text_height(control_win, {}).all, vim.api.nvim_win_text_height(ordinary_win, {}).all)

    vim.api.nvim_win_set_width(pair_1.original_win, 60)
    wrap_alignment.rebuild(pair_1.tabpage, nil, "resize-test")
    assert_pair_aligned(pair_1)
    assert_pair_aligned(pair_2)

    lifecycle_state.suspend_diff(pair_1.tabpage)
    assert.is_nil(vim.w[pair_1.original_win].codediff_wrap_alignment)
    assert_pair_aligned(pair_2)
    assert.equal(vim.api.nvim_win_text_height(control_win, {}).all, vim.api.nvim_win_text_height(ordinary_win, {}).all)

    lifecycle_state.resume_diff(pair_1.tabpage)
    assert_pair_aligned(pair_1)
    assert_pair_aligned(pair_2)

    lifecycle.cleanup(pair_1.tabpage)
    assert_options(pair_1.original_win, pair_1.options.original)
    assert_options(pair_1.modified_win, pair_1.options.modified)
    assert_pair_aligned(pair_2)
    assert.equal(vim.api.nvim_win_text_height(control_win, {}).all, vim.api.nvim_win_text_height(ordinary_win, {}).all)

    lifecycle.cleanup(pair_2.tabpage)
    assert_options(pair_2.original_win, pair_2.options.original)
    assert_options(pair_2.modified_win, pair_2.options.modified)
  end)

  it("keeps real shared-file sessions isolated across tab lifecycle events", function()
    if not wrap_alignment.is_supported() then
      pending("wrapped alignment is unavailable")
      return
    end

    local original_path = vim.fn.tempname()
    local modified_path = vim.fn.tempname()
    vim.fn.writefile(original_lines, original_path)
    vim.fn.writefile(modified_lines, modified_path)
    local session_config = {
      mode = "standalone",
      git_root = nil,
      original_path = original_path,
      modified_path = modified_path,
      original_revision = nil,
      modified_revision = nil,
    }

    view.create(session_config)
    local tab_1 = vim.api.nvim_get_current_tabpage()
    assert.is_true(wait_for_alignment(tab_1))
    local session_1 = lifecycle.get_session(tab_1)
    vim.api.nvim_win_set_width(session_1.original_win, 45)
    wrap_alignment.rebuild(tab_1, nil, "session-1-resize")
    assert_pair_aligned({ original_win = session_1.original_win, modified_win = session_1.modified_win })

    view.create(session_config)
    local tab_2 = vim.api.nvim_get_current_tabpage()
    assert.is_true(wait_for_alignment(tab_2))
    local session_2 = lifecycle.get_session(tab_2)
    assert.equal(session_1.original_bufnr, session_2.original_bufnr)
    assert.equal(session_1.modified_bufnr, session_2.modified_bufnr)
    assert.is_true(session_1.suspended)
    assert.is_nil(vim.w[session_1.original_win].codediff_wrap_alignment)

    vim.api.nvim_set_current_tabpage(tab_1)
    assert.is_true(wait_for_alignment(tab_1))
    assert.is_true(lifecycle.get_session(tab_2).suspended)
    assert_pair_aligned({ original_win = session_1.original_win, modified_win = session_1.modified_win })

    vim.api.nvim_set_current_tabpage(tab_2)
    assert.is_true(wait_for_alignment(tab_2))
    assert.is_true(view.toggle_layout(tab_2))
    assert.equal("inline", lifecycle.get_session(tab_2).layout)
    assert.is_true(view.toggle_layout(tab_2))
    assert.is_true(wait_for_alignment(tab_2))
    session_2 = lifecycle.get_session(tab_2)
    assert_pair_aligned({ original_win = session_2.original_win, modified_win = session_2.modified_win })
    assert.is_true(lifecycle.get_session(tab_1).suspended)
    assert.is_nil(vim.w[session_1.original_win].codediff_wrap_alignment)

    vim.api.nvim_set_current_win(session_2.modified_win)
    vim.cmd("belowright vsplit")
    local ordinary_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(ordinary_win, session_2.original_bufnr)
    vim.wo[ordinary_win].wrap = true
    wrap_alignment.rebuild(tab_2, nil, "ordinary-window-resize")
    local shared_height = vim.api.nvim_win_text_height(ordinary_win, {}).all
    vim.api.nvim_win_set_buf(ordinary_win, create_buffer(original_lines))
    local control_height = vim.api.nvim_win_text_height(ordinary_win, {}).all
    vim.api.nvim_win_set_buf(ordinary_win, session_2.original_bufnr)
    assert.equal(control_height, shared_height)
    assert.is_nil(vim.w[ordinary_win].codediff_wrap_alignment)
    assert_pair_aligned({ original_win = session_2.original_win, modified_win = session_2.modified_win })
    assert.equal(tab_2, lifecycle.find_tabpage_by_buffer(session_2.modified_bufnr))
    assert.is_true(edit_and_wait(session_2, string.rep("active shared session ", 12)))
    assert_pair_aligned({ original_win = session_2.original_win, modified_win = session_2.modified_win })

    lifecycle.cleanup(tab_1)
    assert.is_nil(lifecycle.get_session(tab_1))
    assert_pair_aligned({ original_win = session_2.original_win, modified_win = session_2.modified_win })
    assert.equal(control_height, vim.api.nvim_win_text_height(ordinary_win, {}).all)

    assert.is_true(edit_and_wait(session_2, string.rep("updated shared session ", 12)))
    assert_pair_aligned({ original_win = session_2.original_win, modified_win = session_2.modified_win })

    lifecycle.cleanup(tab_2)
    vim.fn.delete(original_path)
    vim.fn.delete(modified_path)
  end)
end)
