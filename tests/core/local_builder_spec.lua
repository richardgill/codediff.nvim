local builder = require("codediff.core.local_builder")

describe("Local native builder", function()
  local original_cc
  local original_no_auto_install
  local original_executable

  before_each(function()
    original_cc = vim.env.CC
    original_no_auto_install = vim.env.VSCODE_DIFF_NO_AUTO_INSTALL
    original_executable = vim.fn.executable
  end)

  after_each(function()
    vim.env.CC = original_cc
    vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = original_no_auto_install
    vim.fn.executable = original_executable
  end)

  it("uses a source-addressed cache path", function()
    vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = nil
    local install_dir = builder.get_install_dir()

    assert.is_truthy(install_dir:find(vim.fn.stdpath("cache"), 1, true))
    assert.is_truthy(install_dir:match("/codediff/native/%d+%.%d+%.%d+%-[%da-f]+$"))
    assert.is_truthy(builder.get_lib_path():find(install_dir, 1, true))
  end)

  it("reports how to install a compiler", function()
    vim.env.CC = nil
    vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = nil
    vim.fn.executable = function()
      return 0
    end

    local success, err = builder.install({ force = true, silent = true })

    assert.is_false(success)
    assert.is_truthy(err:match("No C compiler found"))
    assert.is_truthy(err:match("retry :CodeDiff install"))
  end)
end)
