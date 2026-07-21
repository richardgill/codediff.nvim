local relative_path_module = assert(loadfile("./lua/codediff/core/path.lua"))()
local loaded_path_module = package.loaded["codediff.core.path"]
package.loaded["codediff.core.path"] = relative_path_module
local relative_version_module = assert(loadfile("./lua/codediff/version.lua"))()
package.loaded["codediff.core.path"] = loaded_path_module

local expected_root = vim.fn.fnamemodify("./lua/codediff/core/path.lua", ":p:h:h:h:h")

describe("Plugin path resolution", function()
  it("resolves an absolute plugin root from a relative module source", function()
    assert.equals(expected_root, relative_path_module.get_plugin_root())
  end)

  it("loads VERSION when the version module source is relative", function()
    local version_file = assert(io.open(expected_root .. "/VERSION", "r"))
    local expected_version = version_file:read("*line")
    version_file:close()

    assert.equals(expected_version, relative_version_module.VERSION)
  end)
end)
