-- Test: ui/inline.lua - Inline diff rendering logic
-- Tests for single-buffer inline diff with virtual line overlays

local inline = require("codediff.ui.inline")
local highlights = require("codediff.ui.highlights")
local diff = require("codediff.core.diff")

describe("Inline Diff Rendering", function()
  before_each(function()
    highlights.setup()
  end)

  -- Test 1: Added lines get highlight extmarks
  it("highlights added lines on modified buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "line 1", "line 2" }
    local modified = { "line 1", "line 2", "line 3" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    -- Added line should have highlight extmark
    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })
    local has_insert_hl = false
    local has_insert_text = false
    local has_char_insert = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.hl_group == "CodeDiffLineInsert" then
        has_insert_hl = true
      elseif details.hl_group == "CodeDiffLineInsertText" then
        has_insert_text = true
      elseif details.hl_group == "CodeDiffCharInsert" then
        has_char_insert = true
      end
    end
    assert.is_true(has_insert_hl, "Added line should have CodeDiffLineInsert highlight")
    assert.is_true(has_insert_text, "Added text should have CodeDiffLineInsertText highlight")
    assert.is_false(has_char_insert, "Added line should not have CodeDiffCharInsert highlight")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 2: Deleted lines appear as virtual lines
  it("shows deleted lines as virtual lines", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "line 1", "line 2", "line 3" }
    local modified = { "line 1", "line 3" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    -- Should have virt_lines extmark
    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })
    local has_virt_lines = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines and #details.virt_lines > 0 then
        has_virt_lines = true
        -- Check that virtual line contains the deleted text
        local virt_text = details.virt_lines[1][1][1]
        assert.equals("line 2", virt_text, "Virtual line should contain deleted text")
        break
      end
    end
    assert.is_true(has_virt_lines, "Deleted line should appear as virtual line")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 3: Modified lines get both virtual lines and highlights
  it("renders modified lines with both delete virt_lines and insert highlights", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "line 1", "old content", "line 3" }
    local modified = { "line 1", "new content", "line 3" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })

    local has_virt_lines = false
    local has_insert_hl = false

    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines and #details.virt_lines > 0 then
        has_virt_lines = true
      end
      if details.hl_group == "CodeDiffLineInsert" then
        has_insert_hl = true
      end
    end

    assert.is_true(has_virt_lines, "Modified line should have virtual line showing original")
    assert.is_true(has_insert_hl, "Modified line should have insert highlight")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 4: Character-level highlights on modified buffer
  it("applies character-level highlights for inner changes", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "hello world" }
    local modified = { "hello earth", "added line" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })

    local has_char_insert = false
    local has_insert_text = false
    local has_char_insert_on_added_line = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.hl_group == "CodeDiffCharInsert" then
        has_char_insert = true
        has_char_insert_on_added_line = has_char_insert_on_added_line or mark[2] == 1
      elseif details.hl_group == "CodeDiffLineInsertText" and mark[2] == 1 then
        has_insert_text = true
      end
    end

    assert.is_true(has_char_insert, "Should have character-level insert highlight")
    assert.is_true(has_insert_text, "Added EOF line should have inserted-line text highlight")
    assert.is_false(has_char_insert_on_added_line, "Added EOF line should not have character highlight")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 5: Clear removes all decorations
  it("clear() removes all inline decorations", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "line 1", "line 2" }
    local modified = { "line 1", "changed", "line 3" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    -- Verify marks exist
    local marks_before = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, {})
    assert.is_true(#marks_before > 0, "Should have extmarks before clear")

    -- Clear
    inline.clear(buf)

    local marks_after = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, {})
    assert.equals(0, #marks_after, "Should have no extmarks after clear")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 6: No changes produces no decorations
  it("identical content produces no decorations", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local content = { "line 1", "line 2", "line 3" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)

    local lines_diff = diff.compute_diff(content, content)
    inline.render_inline_diff(buf, lines_diff, content, content)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, {})
    assert.equals(0, #marks, "Identical content should produce no extmarks")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 7: Multiple hunks
  it("renders multiple hunks correctly", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "aaa", "bbb", "ccc", "ddd", "eee" }
    local modified = { "aaa", "BBB", "ccc", "DDD", "eee" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })

    -- Should have at least 2 sets of changes (virt_lines + highlights for each hunk)
    local virt_line_count = 0
    local hl_count = 0
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines then
        virt_line_count = virt_line_count + 1
      end
      if details.hl_group == "CodeDiffLineInsert" then
        hl_count = hl_count + 1
      end
    end

    assert.is_true(virt_line_count >= 2, "Should have virtual lines for at least 2 hunks")
    assert.is_true(hl_count >= 2, "Should have insert highlights for at least 2 hunks")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 8: Pure deletion at end of file
  it("handles complete deletion at end of file", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "line 1", "line 2", "line 3" }
    local modified = { "line 1" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })
    local has_virt_lines = false
    local has_delete_text = false
    local has_char_delete = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines and #details.virt_lines > 0 then
        has_virt_lines = true
        for _, virt_line in ipairs(details.virt_lines) do
          for _, chunk in ipairs(virt_line) do
            if chunk[2] == "CodeDiffLineDeleteText" then
              has_delete_text = true
            elseif chunk[2] == "CodeDiffCharDelete" then
              has_char_delete = true
            end
          end
        end
      end
    end

    assert.is_true(has_virt_lines, "Complete deletion should show virtual lines")
    assert.is_true(has_delete_text, "Complete deletion should have CodeDiffLineDeleteText chunks")
    assert.is_false(has_char_delete, "Complete deletion should not have CodeDiffCharDelete chunks")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 9: Character-level highlights within virtual lines
  it("virtual lines contain char-level delete highlights as separate chunks", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "hello world", "deleted line" }
    local modified = { "hello earth" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })

    local found_char_delete_in_virt = false
    local found_delete_text_in_virt = false
    local found_char_delete_on_deleted_line = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines then
        for line_index, virt_line in ipairs(details.virt_lines) do
          for _, chunk in ipairs(virt_line) do
            if chunk[2] == "CodeDiffCharDelete" then
              found_char_delete_in_virt = true
              found_char_delete_on_deleted_line = found_char_delete_on_deleted_line or line_index == 2
            elseif chunk[2] == "CodeDiffLineDeleteText" and line_index == 2 then
              found_delete_text_in_virt = true
            end
          end
        end
      end
    end

    assert.is_true(found_char_delete_in_virt, "Virtual lines should contain CodeDiffCharDelete chunks for changed characters")
    assert.is_true(found_delete_text_in_virt, "Deleted EOF line should have deleted-line text chunks")
    assert.is_false(found_char_delete_on_deleted_line, "Deleted EOF line should not have character chunks")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 10: Re-render clears previous decorations
  it("re-rendering clears previous decorations first", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "line 1", "line 2" }
    local modified = { "line 1", "line 2", "line 3" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks_first = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, {})
    local count_first = #marks_first

    -- Re-render same diff
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks_second = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, {})
    assert.equals(count_first, #marks_second, "Re-render should produce same number of extmarks (not doubled)")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
