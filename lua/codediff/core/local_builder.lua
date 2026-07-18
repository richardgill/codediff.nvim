local M = {}

local ffi = require("ffi")
local path_util = require("codediff.core.path")
local version = require("codediff.version")

local build_id

local get_lib_ext = function()
  if ffi.os == "Windows" then
    return "dll"
  end
  if ffi.os == "OSX" then
    return "dylib"
  end
  return "so"
end

local read_file = function(path)
  local file = io.open(path, "rb")
  if not file then
    return ""
  end
  local content = file:read("*a")
  file:close()
  return content
end

local get_source_files = function()
  local root = path_util.get_plugin_root()
  local native_root = root .. "/libvscode-diff"
  local patterns = {
    root .. "/build.sh",
    root .. "/build.cmd",
    native_root .. "/*.c",
    native_root .. "/*.def",
    native_root .. "/include/*",
    native_root .. "/src/*",
    native_root .. "/vendor/*",
  }
  local files = {}
  for _, pattern in ipairs(patterns) do
    vim.list_extend(files, vim.fn.glob(pattern, false, true))
  end
  table.sort(files)
  return files
end

local get_build_id = function()
  if build_id then
    return build_id
  end
  local root = path_util.get_plugin_root()
  local parts = {}
  for _, path in ipairs(get_source_files()) do
    if vim.fn.filereadable(path) == 1 then
      parts[#parts + 1] = path:sub(#root + 1)
      parts[#parts + 1] = read_file(path)
    end
  end
  build_id = version.VERSION .. "-" .. vim.fn.sha256(table.concat(parts)):sub(1, 12)
  return build_id
end

local get_install_dir = function()
  return vim.fn.stdpath("cache") .. "/codediff/native/" .. get_build_id()
end

local get_manual_lib_path = function()
  return path_util.get_plugin_root() .. "/libvscode_diff." .. get_lib_ext()
end

local get_cached_lib_path = function()
  return get_install_dir() .. "/libvscode_diff_" .. version.VERSION .. "." .. get_lib_ext()
end

local find_compiler = function()
  local configured = vim.env.CC
  if configured and configured ~= "" then
    local command = configured:match("^%s*(%S+)")
    if command and vim.fn.executable(command) == 1 then
      return command
    end
    return nil, "Configured C compiler is not executable: " .. configured
  end

  local candidates = ffi.os == "Windows" and { "cl.exe", "clang.exe", "gcc.exe" } or { "cc", "gcc", "clang" }
  for _, command in ipairs(candidates) do
    if vim.fn.executable(command) == 1 then
      return command
    end
  end

  if ffi.os == "Windows" then
    return nil, "No C compiler found. Install Visual Studio Build Tools, Clang, or MinGW-w64, then retry :CodeDiff install."
  end
  return nil, "No C compiler found. Install cc, GCC, or Clang, then retry :CodeDiff install."
end

local run_build = function(output_path, build_dir)
  local root = path_util.get_plugin_root()
  local command
  if ffi.os == "Windows" then
    command = { "cmd.exe", "/d", "/c", root .. "/build.cmd", output_path, build_dir }
  else
    command = { root .. "/build.sh", output_path, build_dir }
  end

  if vim.system then
    return vim.system(command, { text = true }):wait()
  end

  local output = vim.fn.system(command)
  return { code = vim.v.shell_error, stdout = output, stderr = "" }
end

local notify_error = function(message, silent)
  if not silent then
    vim.notify(message, vim.log.levels.ERROR)
  end
  return false, message
end

function M.get_install_dir()
  if vim.env.VSCODE_DIFF_NO_AUTO_INSTALL then
    return path_util.get_plugin_root()
  end
  return get_install_dir()
end

function M.get_lib_path()
  local manual_path = get_manual_lib_path()
  if vim.env.VSCODE_DIFF_NO_AUTO_INSTALL and vim.fn.filereadable(manual_path) == 1 then
    return manual_path
  end
  return get_cached_lib_path()
end

function M.install(opts)
  opts = opts or {}
  local lib_path = get_cached_lib_path()
  if not opts.force and vim.fn.filereadable(lib_path) == 1 then
    return true
  end

  local _, compiler_error = find_compiler()
  if compiler_error then
    return notify_error(compiler_error, opts.silent)
  end

  local install_dir = get_install_dir()
  local build_dir = install_dir .. "/build"
  vim.fn.mkdir(build_dir, "p")
  local temp_path = lib_path .. ".tmp"
  os.remove(temp_path)

  if not opts.silent then
    vim.notify("Building libvscode-diff locally...", vim.log.levels.INFO)
  end
  local result = run_build(temp_path, build_dir)
  if result.code ~= 0 then
    os.remove(temp_path)
    local output = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
    return notify_error("Failed to build libvscode-diff locally:\n" .. output, opts.silent)
  end

  os.remove(lib_path)
  if not os.rename(temp_path, lib_path) then
    os.remove(temp_path)
    return notify_error("Failed to install locally built library at: " .. lib_path, opts.silent)
  end

  if not opts.silent then
    vim.notify("Built libvscode-diff at: " .. lib_path, vim.log.levels.INFO)
  end
  return true
end

function M.is_installed()
  return vim.fn.filereadable(M.get_lib_path()) == 1
end

function M.get_installed_version()
  return M.is_installed() and version.VERSION or nil
end

function M.needs_update()
  return not M.is_installed()
end

return M
