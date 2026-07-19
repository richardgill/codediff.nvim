local read_source = function(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local assert_absent = function(path, source, pattern)
  assert.is_nil(source:find(pattern, 1, true), string.format("%s must not reference %s", path, pattern))
end

describe("rendered display architecture", function()
  it("keeps renderer primitives inside the display package", function()
    local primitives = { "nvim__ns_set", "nvim_win_text_height" }
    local paths = vim.fn.glob("lua/**/*.lua", false, true)
    assert.is_true(#paths > 0)
    for _, path in ipairs(paths) do
      if not path:find("^lua/codediff/nvim/display/") then
        local source = read_source(path)
        for _, primitive in ipairs(primitives) do
          assert_absent(path, source, primitive)
        end
      end
    end
  end)

  it("keeps renderer workarounds out of main wrapping modules", function()
    local forbidden = {
      "WinScrolled",
      "vim.v.event",
      "winsaveview",
      "winrestview",
      "topfill",
      "skipcol",
      "nvim_create_namespace",
      "nvim_buf_set_extmark",
      "nvim_buf_del_extmark",
      "nvim_buf_clear_namespace",
      "nvim_buf_get_extmarks",
      "codediff.nvim.display.",
    }
    local paths = vim.fn.glob("lua/codediff/ui/wrap_*.lua", false, true)
    assert.is_true(#paths > 0)
    for _, path in ipairs(paths) do
      local source = read_source(path)
      for _, pattern in ipairs(forbidden) do
        assert_absent(path, source, pattern)
      end
    end
  end)

  it("keeps layout inspection out of the alignment renderer", function()
    local path = "lua/codediff/ui/wrap_alignment_renderer.lua"
    local source = read_source(path)
    local forbidden = {
      "nvim_win_text_height",
      "nvim_buf_get_extmarks",
      "getwininfo",
      "foldclosed",
      "vim.wo",
      "vim.bo",
      "vim.o.",
    }
    for _, pattern in ipairs(forbidden) do
      assert_absent(path, source, pattern)
    end
  end)

  it("keeps window-layer primitives owned by layer.lua", function()
    local primitives = {
      "nvim__ns_set",
      "nvim_create_namespace",
      "nvim_buf_set_extmark",
      "nvim_buf_del_extmark",
      "nvim_buf_clear_namespace",
    }
    local paths = vim.fn.glob("lua/codediff/nvim/display/*.lua", false, true)
    for _, path in ipairs(paths) do
      if path ~= "lua/codediff/nvim/display/layer.lua" then
        local source = read_source(path)
        for _, primitive in ipairs(primitives) do
          assert_absent(path, source, primitive)
        end
      end
    end

    local display = require("codediff.nvim.display")
    assert.is_nil(display._owns_namespace)
    assert.is_nil(display._is_supported)
    assert.is_nil(display.get_viewport_metrics)
    assert.is_nil(display.reset_viewport_metrics)
  end)

  it("keeps the display package independent from higher-level CodeDiff modules", function()
    local forbidden = {
      'require("codediff.config',
      'require("codediff.core.',
      'require("codediff.ui.',
    }
    local paths = vim.fn.glob("lua/codediff/nvim/display/*.lua", false, true)
    assert.is_true(#paths > 0)
    for _, path in ipairs(paths) do
      local source = read_source(path)
      for _, pattern in ipairs(forbidden) do
        assert_absent(path, source, pattern)
      end
    end
  end)

  it("keeps superseded modules removed", function()
    assert.equal(0, vim.fn.filereadable("lua/codediff/ui/wrap_view_sync.lua"))
    assert.equal(0, vim.fn.filereadable("lua/codediff/nvim/window_namespace.lua"))
  end)
end)
