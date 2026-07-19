local display = require("codediff.nvim.display")

local original_ambiwidth
local original_display
local original_listchars

local create_window = function(lines)
  vim.cmd("tabnew")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(win, buf)
  vim.cmd("rightbelow vsplit")
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_width(win, 32)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = false
  vim.wo[win].breakindent = false
  vim.wo[win].breakindentopt = ""
  vim.wo[win].showbreak = ""
  vim.wo[win].list = false
  vim.wo[win].listchars = ""
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].numberwidth = 4
  vim.wo[win].signcolumn = "auto"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].conceallevel = 0
  vim.wo[win].concealcursor = ""
  vim.bo[buf].tabstop = 8
  vim.bo[buf].vartabstop = ""
  return win, buf
end

local close_tab = function()
  vim.o.ambiwidth = original_ambiwidth
  vim.o.display = original_display
  vim.o.listchars = original_listchars
  if vim.fn.tabpagenr("$") > 1 then
    vim.cmd("tabclose!")
  end
end

local assert_context_changes = function(win, apply, restore, label)
  local before = display.measurement_context(win)
  apply()
  vim.cmd("redraw")
  local after = display.measurement_context(win)
  restore()
  if after:has_same_signature(before) then
    error("unchanged measurement context for " .. label)
  end
end

local assert_option_changes = function(win, options, name, value, restored_value)
  assert_context_changes(win, function()
    options[name] = value
  end, function()
    options[name] = restored_value
  end, name)
end

describe("display layout", function()
  before_each(function()
    original_ambiwidth = vim.o.ambiwidth
    original_display = vim.o.display
    original_listchars = vim.o.listchars
  end)

  after_each(close_tab)

  it("measures batches through the target window renderer", function()
    local win = create_window({ string.rep("renderer backed wrapping ", 20), "short" })
    local heights = display.measure_ranges(win, {
      { start_row = 0, end_row = 1 },
      { start_row = 1, end_row = 2 },
      { start_row = 2, end_row = 2 },
    })

    assert.is_true(heights[1] > heights[2])
    assert.equal(1, heights[2])
    assert.equal(0, heights[3])
  end)

  it("preserves scalar-loop batch order and skips empty ranges", function()
    local win = create_window({ "one", "two", "three", "four", "five" })
    local original_text_height = vim.api.nvim_win_text_height
    local calls = {}
    vim.api.nvim_win_text_height = function(called_win, opts)
      calls[#calls + 1] = { win = called_win, opts = opts }
      return { all = #calls * 10 }
    end

    local heights
    local ok, err = pcall(function()
      heights = display.measure_ranges(win, {
        { start_row = 2, end_row = 5 },
        { start_row = 3, end_row = 3 },
        { start_row = 0, end_row = 1 },
      })
    end)
    vim.api.nvim_win_text_height = original_text_height

    assert.is_true(ok, err)
    assert.same({ 10, 0, 20 }, heights)
    assert.same({
      { win = win, opts = { start_row = 2, start_vcol = 0, end_row = 4 } },
      { win = win, opts = { start_row = 0, start_vcol = 0, end_row = 0 } },
    }, calls)
  end)

  it("excludes leading virtual lines when a measured range starts on their row", function()
    local win, buf = create_window({ "first", "second", "third" })
    local ns = vim.api.nvim_create_namespace("CodeDiffDisplayLeadingRows")
    vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, {
      virt_lines = { { { "leading virtual row" } } },
      virt_lines_above = true,
    })
    vim.cmd("redraw")

    assert.equal(4, vim.api.nvim_win_text_height(win, {}).all)
    assert.equal(1, display.measure_ranges(win, { { start_row = 1, end_row = 2 } })[1])
  end)

  it("keeps signatures and decoration details behind opaque contexts", function()
    local win, buf = create_window({ "virtual line", "virtual text", "concealed", "plain" })
    local ns = vim.api.nvim_create_namespace("CodeDiffDisplayDecoratedRows")
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_lines = { { { "extra" } } } })
    vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { virt_text = { { "inline" } }, virt_text_pos = "inline" })
    vim.api.nvim_buf_set_extmark(buf, ns, 2, 0, { conceal = "x" })
    vim.api.nvim_buf_set_extmark(buf, ns, 3, 0, { sign_text = "!!" })

    local context = display.measurement_context(win)
    assert.is_nil(context.signature)
    assert.is_nil(context.decorated_rows)
    local decorated_rows = context:height_decorated_rows()
    assert.is_true(decorated_rows[0])
    assert.is_true(decorated_rows[1])
    assert.is_true(decorated_rows[2])
    assert.is_nil(decorated_rows[3])
    decorated_rows[3] = true
    assert.is_nil(context:height_decorated_rows()[3])
    assert.is_true(context:has_same_signature(display.measurement_context(win)))
  end)

  it("excludes an alignment layer from decorated-row inspection", function()
    if not display.is_supported() then
      pending("window-scoped namespaces are unavailable")
      return
    end

    local win, buf = create_window({ "one", "two", "three" })
    local alignment_layer = display.create_layer(win)
    local external_namespace = vim.api.nvim_create_namespace("CodeDiffDisplayExternalDecoration")
    display.set_layer(alignment_layer, buf, { { key = "padding", boundary_row = 1, count = 1 } })
    vim.api.nvim_buf_set_extmark(buf, external_namespace, 1, 0, { virt_text = { { "external" } }, virt_text_pos = "inline" })

    assert.is_true(display.measurement_context(win):height_decorated_rows()[0])
    local excluded_rows = display.measurement_context(win, { exclude_layer = alignment_layer }):height_decorated_rows()
    assert.is_nil(excluded_rows[0])
    assert.is_true(excluded_rows[1])
    display.destroy_layer(alignment_layer)
  end)

  it("changes contexts for renderer width and display options", function()
    local win, buf = create_window({ "one two three four five six seven eight nine ten" })
    assert_context_changes(win, function()
      vim.api.nvim_win_set_width(win, 36)
    end, function()
      vim.api.nvim_win_set_width(win, 32)
    end, "width")

    local cases = {
      { options = vim.wo[win], name = "wrap", value = false, restored_value = true },
      { options = vim.wo[win], name = "linebreak", value = true, restored_value = false },
      { options = vim.wo[win], name = "breakindent", value = true, restored_value = false },
      { options = vim.wo[win], name = "breakindentopt", value = "shift:3", restored_value = "" },
      { options = vim.wo[win], name = "showbreak", value = ">>", restored_value = "" },
      { options = vim.wo[win], name = "list", value = true, restored_value = false },
      { options = vim.wo[win], name = "listchars", value = "tab:XY", restored_value = "" },
      { options = vim.wo[win], name = "number", value = true, restored_value = false },
      { options = vim.wo[win], name = "relativenumber", value = true, restored_value = false },
      { options = vim.wo[win], name = "numberwidth", value = 6, restored_value = 4 },
      { options = vim.wo[win], name = "signcolumn", value = "yes:2", restored_value = "auto" },
      { options = vim.wo[win], name = "foldcolumn", value = "1", restored_value = "0" },
      { options = vim.wo[win], name = "statuscolumn", value = "%l ", restored_value = "" },
      { options = vim.wo[win], name = "conceallevel", value = 2, restored_value = 0 },
      { options = vim.wo[win], name = "concealcursor", value = "n", restored_value = "" },
      { options = vim.bo[buf], name = "tabstop", value = 4, restored_value = 8 },
      { options = vim.bo[buf], name = "vartabstop", value = "4,8", restored_value = "" },
    }
    for _, case in ipairs(cases) do
      assert_option_changes(win, case.options, case.name, case.value, case.restored_value)
    end

    assert_context_changes(win, function()
      vim.o.listchars = "tab:>-"
      vim.o.ambiwidth = original_ambiwidth == "single" and "double" or "single"
    end, function()
      vim.o.ambiwidth = original_ambiwidth
      vim.o.listchars = original_listchars
    end, "ambiwidth")
    assert_context_changes(win, function()
      vim.o.display = original_display == "lastline" and "uhex" or "lastline"
    end, function()
      vim.o.display = original_display
    end, "display")
  end)

  it("tracks effective dynamic gutter width", function()
    local win, buf = create_window({ "one", "two" })
    vim.wo[win].signcolumn = "auto"
    vim.cmd("redraw")
    local before = display.measurement_context(win)
    local ns = vim.api.nvim_create_namespace("CodeDiffDisplayDynamicGutter")
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { sign_text = "!!" })
    vim.cmd("redraw")

    assert.is_false(display.measurement_context(win):has_same_signature(before))
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.cmd("redraw")
    assert.is_true(display.measurement_context(win):has_same_signature(before))
  end)

  it("reports window-local closed fold ranges for requested rows", function()
    local win = create_window({ "one", "two", "three", "four", "five" })
    vim.api.nvim_win_call(win, function()
      vim.wo.foldmethod = "manual"
      vim.cmd("2,4fold")
      vim.cmd("normal! zM")
    end)

    local folds = display.closed_folds(win, { 0, 1, 2, 4, 100, -1, 1 })
    assert.is_nil(folds[0])
    assert.equal(4, folds[1])
    assert.equal(4, folds[2])
    assert.is_nil(folds[4])
  end)

  it("rejects invalid window handles across layout operations", function()
    local win = create_window({ "one", "two" })
    vim.api.nvim_win_close(win, true)

    assert.is_false(pcall(display.measure_ranges, win, { { start_row = 0, end_row = 1 } }))
    assert.is_false(pcall(display.measurement_context, win))
    assert.is_false(pcall(display.closed_folds, win, { 0 }))
  end)
end)
