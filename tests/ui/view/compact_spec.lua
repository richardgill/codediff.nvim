-- Tests for codediff.ui.view.compact (#344).
-- Focus:
--   * compute_visible_lines: pure, deterministic — fully unit-testable.
--   * enable/disable round-trip: fold settings save+restore exactly.
--   * toggle idempotence.
--   * Module-level visible_lines_by_win is populated on enable, cleared on disable.

local compact = require("codediff.ui.view.compact")
local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local diff = require("codediff.core.diff")
local highlights = require("codediff.ui.highlights")

local function get_temp_path(name)
  local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local dir = is_win and (vim.fn.getenv("TEMP") or "C:\\Windows\\Temp") or "/tmp"
  local sep = is_win and "\\" or "/"
  return dir .. sep .. name
end

-- Build a real codediff diff session whose left/right buffers contain the
-- given line arrays, returning (tabpage, session, left_path, right_path).
local function create_session(original, modified)
  local left = get_temp_path("compact_spec_left.txt")
  local right = get_temp_path("compact_spec_right.txt")
  vim.fn.writefile(original, left)
  vim.fn.writefile(modified, right)

  local ready = false
  view.create({
    mode = "standalone",
    git_root = nil,
    original_path = left,
    modified_path = right,
    original_revision = nil,
    modified_revision = nil,
  }, "", function() ready = true end)

  local tabpage = vim.api.nvim_get_current_tabpage()

  -- view.create for real files schedules its render asynchronously; wait
  -- for the on_ready callback OR the session to gain windows.
  vim.wait(5000, function()
    if ready then return true end
    local s = lifecycle.get_session(tabpage)
    return s ~= nil and s.original_win ~= nil and s.modified_win ~= nil
  end, 20)

  return tabpage, lifecycle.get_session(tabpage), left, right
end

describe("compact mode (#344)", function()
  before_each(function()
    require("codediff").setup({
      diff = { layout = "side-by-side", compact_context_lines = 3 },
    })
    highlights.setup()
  end)

  after_each(function()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
  end)

  -- =====================================================================
  -- compute_visible_lines: pure function tests
  -- =====================================================================

  describe("compute_visible_lines", function()
    local function make_change(orig_start, orig_end, mod_start, mod_end)
      return {
        original = { start_line = orig_start, end_line = orig_end },
        modified = { start_line = mod_start, end_line = mod_end },
      }
    end

    it("returns empty set when there are no changes", function()
      local visible = compact.compute_visible_lines({}, "original", 100, 3)
      assert.same({}, visible)
    end)

    it("includes hunk lines plus N context lines on each side", function()
      -- One hunk at lines 10-13 (exclusive end), context = 3
      -- Expected visible: 7..15 (3 before line 10, the 3 hunk lines, 3 after line 12)
      local changes = { make_change(10, 13, 10, 13) }
      local visible = compact.compute_visible_lines(changes, "original", 100, 3)
      for l = 7, 15 do
        assert.is_true(visible[l], "line " .. l .. " should be visible")
      end
      assert.is_nil(visible[6], "line 6 should be folded")
      assert.is_nil(visible[16], "line 16 should be folded")
    end)

    it("clamps context to buffer bounds at the top", function()
      -- Hunk at line 1, context = 3 — can't go below line 1.
      local changes = { make_change(1, 2, 1, 2) }
      local visible = compact.compute_visible_lines(changes, "original", 100, 3)
      assert.is_true(visible[1])
      assert.is_true(visible[4])
      assert.is_nil(visible[5])
    end)

    it("clamps context to buffer bounds at the bottom", function()
      -- Hunk at last line of 10-line buffer.
      local changes = { make_change(10, 11, 10, 11) }
      local visible = compact.compute_visible_lines(changes, "original", 10, 3)
      assert.is_true(visible[10])
      assert.is_true(visible[7])
      assert.is_nil(visible[11], "buffer only has 10 lines")
    end)

    it("treats zero-width ranges (pure insertion/deletion) as a one-line anchor", function()
      -- Zero-width range at line 5 — gets treated as the one-line slice [5,6).
      -- With context=2: visible = max(1, 5-2)..min(N, 6-1+2) = 3..7.
      local changes = { make_change(5, 5, 5, 8) }
      local visible = compact.compute_visible_lines(changes, "original", 100, 2)
      for l = 3, 7 do
        assert.is_true(visible[l], "line " .. l .. " should be visible")
      end
      assert.is_nil(visible[2])
      assert.is_nil(visible[8])
    end)

    it("merges overlapping hunks' visible ranges via set union", function()
      -- Two adjacent hunks whose context windows overlap.
      local changes = {
        make_change(10, 11, 10, 11),
        make_change(13, 14, 13, 14),
      }
      local visible = compact.compute_visible_lines(changes, "original", 100, 3)
      -- First: 7..13, second: 10..16. Union: 7..16.
      for l = 7, 16 do
        assert.is_true(visible[l], "line " .. l .. " should be visible")
      end
      assert.is_nil(visible[6])
      assert.is_nil(visible[17])
    end)

    it("uses the requested side (original vs modified) for line ranges", function()
      -- Pure insertion: original range zero-width at line 5, modified at lines 10-13.
      local changes = { make_change(5, 5, 10, 13) }

      local orig_visible = compact.compute_visible_lines(changes, "original", 100, 2)
      local mod_visible = compact.compute_visible_lines(changes, "modified", 100, 2)

      -- Original side: anchor at 5, ±2 context → 3..6.
      assert.is_true(orig_visible[5])
      assert.is_true(orig_visible[3])
      assert.is_nil(orig_visible[10])

      -- Modified side: hunk 10..12, ±2 context → 8..14.
      assert.is_true(mod_visible[10])
      assert.is_true(mod_visible[14])
      assert.is_nil(mod_visible[5])
    end)

    it("supports zero context (only the hunk lines visible)", function()
      local changes = { make_change(10, 13, 10, 13) }
      local visible = compact.compute_visible_lines(changes, "original", 100, 0)
      assert.is_true(visible[10])
      assert.is_true(visible[12])
      assert.is_nil(visible[9])
      assert.is_nil(visible[13])
    end)
  end)

  -- =====================================================================
  -- enable / disable round-trip
  -- =====================================================================

  describe("enable/disable round-trip on a real session", function()
    it("returns false when there is no session", function()
      -- Use a tabpage id that doesn't have a session attached.
      assert.is_false(compact.enable(9999))
    end)

    it("enable sets foldmethod=expr; disable restores prior fold settings", function()
      local original = {}
      local modified = {}
      for i = 1, 30 do
        original[i] = "line " .. i
        modified[i] = "line " .. i
      end
      modified[15] = "line 15 CHANGED"

      local tabpage, session = create_session(original, modified)
      assert.is_not_nil(session.stored_diff_result, "diff must be computed for compact mode to act")
      assert.is_not_nil(session.original_win, "session must have original_win")
      assert.is_not_nil(session.modified_win, "session must have modified_win")

      -- Snapshot the pre-compact fold settings on both panes.
      local pre = {}
      for _, win in ipairs({ session.original_win, session.modified_win }) do
        pre[win] = {
          foldmethod = vim.wo[win].foldmethod,
          foldexpr = vim.wo[win].foldexpr,
          foldlevel = vim.wo[win].foldlevel,
          foldminlines = vim.wo[win].foldminlines,
          foldenable = vim.wo[win].foldenable,
          foldtext = vim.wo[win].foldtext,
        }
      end

      assert.is_true(compact.enable(tabpage))
      assert.is_true(session.compact_mode)
      for _, win in ipairs({ session.original_win, session.modified_win }) do
        assert.equal("expr", vim.wo[win].foldmethod)
        assert.is_true(vim.wo[win].foldexpr:find("compact", 1, true) ~= nil,
          "foldexpr should reference the compact module")
        assert.is_true(vim.wo[win].foldenable)
      end

      assert.is_true(compact.disable(tabpage))
      assert.is_false(session.compact_mode == true,
        "session.compact_mode should be cleared on disable")

      -- Every pre-compact fold setting must be restored exactly.
      for _, win in ipairs({ session.original_win, session.modified_win }) do
        for opt, expected in pairs(pre[win]) do
          assert.equal(expected, vim.wo[win][opt],
            opt .. " should be restored on disable (win " .. win .. ")")
        end
      end
    end)

    it("toggle alternates enable and disable", function()
      local original = {}
      local modified = {}
      for i = 1, 20 do
        original[i] = "L" .. i
        modified[i] = "L" .. i
      end
      modified[10] = "L10 changed"

      local tabpage, session = create_session(original, modified)

      assert.is_true(compact.toggle(tabpage))
      assert.is_true(session.compact_mode)
      assert.is_true(compact.toggle(tabpage))
      assert.is_false(session.compact_mode == true)
      assert.is_true(compact.toggle(tabpage))
      assert.is_true(session.compact_mode)
    end)

    it("enable is idempotent (second call is a no-op success)", function()
      local original, modified = { "a", "b", "c" }, { "a", "B", "c" }
      local tabpage, session = create_session(original, modified)

      assert.is_true(compact.enable(tabpage))
      local saved_state_first = session.compact_saved_fold_state
      -- Second call should still return true without overwriting saved state.
      assert.is_true(compact.enable(tabpage))
      assert.equal(saved_state_first, session.compact_saved_fold_state,
        "second enable must not overwrite the saved fold state")
    end)

    it("returns false when there are no changes to compact", function()
      -- Identical files → no hunks.
      local lines = { "a", "b", "c" }
      local tabpage, session = create_session(lines, lines)
      assert.equal(0, #(session.stored_diff_result.changes or {}),
        "sanity: identical files should produce zero changes")
      assert.is_false(compact.enable(tabpage))
      assert.is_not.equal(true, session.compact_mode)
    end)
  end)
end)
