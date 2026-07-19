local display = require("codediff.nvim.display")

local original_namespace_set = vim.api.nvim__ns_set
local original_clear_namespace = vim.api.nvim_buf_clear_namespace
local original_set_extmark = vim.api.nvim_buf_set_extmark
local original_del_extmark = vim.api.nvim_buf_del_extmark

local create_shared_windows = function()
  vim.cmd("tabnew")
  local left = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "one " .. string.rep("abcdefghij ", 10),
    "two",
    "three",
  })
  vim.api.nvim_win_set_buf(left, buf)
  vim.cmd("vsplit")
  local middle = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(middle, buf)
  vim.cmd("vsplit")
  local ordinary = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(ordinary, buf)
  vim.api.nvim_win_set_width(left, 24)
  vim.api.nvim_win_set_width(middle, 36)
  for _, win in ipairs({ left, middle, ordinary }) do
    vim.wo[win].wrap = true
  end
  return buf, left, middle, ordinary
end

local entry = function(key, boundary_row, count)
  return { key = key, boundary_row = boundary_row, count = count }
end

local get_height = function(win)
  vim.cmd("redraw")
  return vim.api.nvim_win_text_height(win, {}).all
end

local get_mark_identities = function(buf)
  local identities = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    identities[#identities + 1] = string.format("%d:%d", mark[4].ns_id, mark[1])
  end
  table.sort(identities)
  return identities
end

local close_tab = function()
  if vim.fn.tabpagenr("$") > 1 then
    vim.cmd("tabclose!")
  end
end

local require_layers = function()
  if not display.is_supported() then
    pending("window-scoped namespaces are unavailable")
    return false
  end
  return true
end

describe("display window-local layers", function()
  after_each(function()
    vim.api.nvim__ns_set = original_namespace_set
    vim.api.nvim_buf_clear_namespace = original_clear_namespace
    vim.api.nvim_buf_set_extmark = original_set_extmark
    vim.api.nvim_buf_del_extmark = original_del_extmark
    close_tab()
  end)

  it("isolates differing-width concurrent layers from an ordinary shared-buffer window", function()
    if not require_layers() then
      return
    end

    local buf, left, middle, ordinary = create_shared_windows()
    local natural = {
      left = get_height(left),
      middle = get_height(middle),
      ordinary = get_height(ordinary),
    }
    assert.are_not.equal(vim.api.nvim_win_get_width(left), vim.api.nvim_win_get_width(middle))

    local left_layer = display.create_layer(left)
    local middle_layer = display.create_layer(middle)
    display.set_layer(left_layer, buf, { entry("left", 1, 1) })
    display.set_layer(middle_layer, buf, { entry("middle", 1, 2) })

    assert.equal(natural.left + 1, get_height(left))
    assert.equal(natural.middle + 2, get_height(middle))
    assert.equal(natural.ordinary, get_height(ordinary))

    display.destroy_layer(left_layer)
    assert.equal(natural.left, get_height(left))
    assert.equal(natural.middle + 2, get_height(middle))
    display.destroy_layer(middle_layer)
    assert.equal(natural.middle, get_height(middle))
  end)

  it("reuses extmark IDs and updates, removes, clears, and restores entries", function()
    if not require_layers() then
      return
    end

    local buf, left = create_shared_windows()
    local layer = display.create_layer(left)
    local initial = display.set_layer(layer, buf, {
      entry("first", 1, 1),
      entry("second", 2, 2),
    })
    local initial_marks = get_mark_identities(buf)
    assert.same({ removed = 0, reused = 0, updated = 2 }, initial)
    assert.equal(2, #initial_marks)

    local reused = display.set_layer(layer, buf, {
      entry("first", 1, 1),
      entry("second", 2, 2),
    })
    assert.same({ removed = 0, reused = 2, updated = 0 }, reused)
    assert.same(initial_marks, get_mark_identities(buf))

    local changed = display.set_layer(layer, buf, { entry("first", 1, 2) })
    local changed_marks = get_mark_identities(buf)
    assert.same({ removed = 1, reused = 0, updated = 1 }, changed)
    assert.equal(1, #changed_marks)
    assert.is_true(vim.tbl_contains(initial_marks, changed_marks[1]))

    assert.equal(1, display.clear_layer(layer))
    assert.same({}, get_mark_identities(buf))
    assert.same({ removed = 0, reused = 0, updated = 1 }, display.set_layer(layer, buf, { entry("restored", 1, 1) }))
    display.destroy_layer(layer)
  end)

  it("keeps large unchanged declarative updates on the reuse path", function()
    if not require_layers() then
      return
    end

    local buf, left = create_shared_windows()
    local layer = display.create_layer(left)
    local entries = {}
    for index = 1, 1000 do
      entries[index] = entry(index, 1, 1)
    end
    display.set_layer(layer, buf, entries)

    local renderer_calls = 0
    vim.api.nvim_buf_set_extmark = function(...)
      renderer_calls = renderer_calls + 1
      return original_set_extmark(...)
    end
    vim.api.nvim_buf_del_extmark = function(...)
      renderer_calls = renderer_calls + 1
      return original_del_extmark(...)
    end
    local reused = display.set_layer(layer, buf, entries)

    assert.same({ removed = 0, reused = 1000, updated = 0 }, reused)
    assert.equal(0, renderer_calls)
    display.destroy_layer(layer)
  end)

  it("cleans the old buffer before replacing it", function()
    if not require_layers() then
      return
    end

    local old_buf, left = create_shared_windows()
    local new_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, { "new one", "new two" })
    local layer = display.create_layer(left)
    display.set_layer(layer, old_buf, { entry("padding", 1, 1) })

    local moved = display.set_layer(layer, new_buf, { entry("padding", 1, 2) })
    assert.same({ removed = 1, reused = 0, updated = 1 }, moved)
    assert.same({}, get_mark_identities(old_buf))
    assert.equal(1, #get_mark_identities(new_buf))

    vim.api.nvim_win_set_buf(left, new_buf)
    assert.equal(4, get_height(left))
    display.destroy_layer(layer)
    assert.same({}, get_mark_identities(new_buf))
  end)

  it("reapplies window scope on every declarative update", function()
    if not require_layers() then
      return
    end

    local buf, left = create_shared_windows()
    local layer = display.create_layer(left)
    local scoped_wins = {}
    vim.api.nvim__ns_set = function(namespace, opts)
      scoped_wins[#scoped_wins + 1] = vim.deepcopy(opts.wins)
      return original_namespace_set(namespace, opts)
    end

    display.set_layer(layer, buf, { entry("padding", 1, 1) })
    display.set_layer(layer, buf, { entry("padding", 1, 1) })
    vim.api.nvim__ns_set = original_namespace_set

    assert.same({ { left }, { left } }, scoped_wins)
    display.destroy_layer(layer)
  end)

  it("allows only one live namespace owner per window", function()
    if not require_layers() then
      return
    end

    local _, left = create_shared_windows()
    local layer = display.create_layer(left)
    assert.is_false(pcall(display.create_layer, left))
    display.destroy_layer(layer)

    local replacement = display.create_layer(left)
    display.destroy_layer(replacement)
  end)

  it("rejects invalid windows without losing clear and destroy cleanup", function()
    if not require_layers() then
      return
    end

    local buf, left = create_shared_windows()
    local layer = display.create_layer(left)
    display.set_layer(layer, buf, { entry("padding", 1, 1) })
    vim.api.nvim_win_close(left, true)

    assert.is_false(pcall(display.set_layer, layer, buf, { entry("padding", 1, 2) }))
    assert.equal(1, display.clear_layer(layer))
    assert.same({}, get_mark_identities(buf))
    display.destroy_layer(layer)
    assert.is_false(pcall(display.set_layer, layer, buf, {}))
    assert.is_false(pcall(display.create_layer, left))
  end)

  it("reports absent and failing scoped-namespace capability without registering an owner", function()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim__ns_set = nil
    assert.is_false(display.is_supported())
    assert.is_false(pcall(display.create_layer, win))

    vim.api.nvim__ns_set = function()
      error("scope failed")
    end
    assert.is_false(pcall(display.create_layer, win))

    vim.api.nvim__ns_set = original_namespace_set
    if vim.fn.has("nvim-0.12") == 1 and type(vim.api.nvim_win_text_height) == "function" then
      local layer = display.create_layer(win)
      display.destroy_layer(layer)
    end
  end)

  it("clears buffer marks before scope and token teardown", function()
    if not require_layers() then
      return
    end

    local buf, left = create_shared_windows()
    local layer = display.create_layer(left)
    display.set_layer(layer, buf, { entry("padding", 1, 1) })
    local calls = {}
    vim.api.nvim_buf_clear_namespace = function(...)
      calls[#calls + 1] = "clear"
      return original_clear_namespace(...)
    end
    vim.api.nvim__ns_set = function(namespace, opts)
      calls[#calls + 1] = "scope:" .. #opts.wins
      return original_namespace_set(namespace, opts)
    end

    display.destroy_layer(layer)
    vim.api.nvim_buf_clear_namespace = original_clear_namespace
    vim.api.nvim__ns_set = original_namespace_set

    assert.same({ "clear", "scope:0" }, calls)
    assert.same({}, get_mark_identities(buf))
    assert.is_false(pcall(display.set_layer, layer, buf, {}))
    display.destroy_layer(layer)
    assert.same({ "clear", "scope:0" }, calls)
  end)
end)
