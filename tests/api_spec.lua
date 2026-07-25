-- Tests for public API exports in init.lua
describe("Public API", function()
  local codediff

  before_each(function()
    codediff = require("codediff")
  end)

  describe("exports", function()
    it("exports setup function", function()
      assert.is_function(codediff.setup)
    end)

    it("exports get_diff_context function", function()
      assert.is_function(codediff.get_diff_context)
    end)

    it("exports render_aligned_modified_virtual_lines function", function()
      assert.is_function(codediff.render_aligned_modified_virtual_lines)
    end)

    it("exports next_hunk function", function()
      assert.is_function(codediff.next_hunk)
    end)

    it("exports prev_hunk function", function()
      assert.is_function(codediff.prev_hunk)
    end)

    it("exports next_file function", function()
      assert.is_function(codediff.next_file)
    end)

    it("exports prev_file function", function()
      assert.is_function(codediff.prev_file)
    end)
  end)

  describe("diff context", function()
    it("returns nil when the buffer has no diff session", function()
      assert.is_nil(codediff.get_diff_context(9999))
    end)

    it("returns the buffer's side and file context", function()
      local lifecycle = require("codediff.ui.lifecycle")
      local original_find_tabpage = lifecycle.find_tabpage_by_buffer
      local original_get_session = lifecycle.get_session
      lifecycle.find_tabpage_by_buffer = function()
        return 7
      end
      lifecycle.get_session = function()
        return {
          git_root = "/repo",
          original_bufnr = 10,
          original_path = "before.lua",
          modified_bufnr = 11,
          modified_path = "after.lua",
        }
      end

      local original = codediff.get_diff_context(10)
      local modified = codediff.get_diff_context(11)
      lifecycle.find_tabpage_by_buffer = original_find_tabpage
      lifecycle.get_session = original_get_session

      assert.are.same({ tabpage = 7, side = "original", git_root = "/repo", path = "before.lua" }, original)
      assert.are.same({ tabpage = 7, side = "modified", git_root = "/repo", path = "after.lua" }, modified)
    end)
  end)

  describe("navigation functions", function()
    it("next_hunk returns false when no diff session", function()
      local result = codediff.next_hunk()
      assert.is_false(result)
    end)

    it("prev_hunk returns false when no diff session", function()
      local result = codediff.prev_hunk()
      assert.is_false(result)
    end)

    it("next_file returns false when no explorer/history", function()
      local result = codediff.next_file()
      assert.is_false(result)
    end)

    it("prev_file returns false when no explorer/history", function()
      local result = codediff.prev_file()
      assert.is_false(result)
    end)
  end)
end)
