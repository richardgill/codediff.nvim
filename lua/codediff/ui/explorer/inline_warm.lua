local M = {}

local config = require("codediff.config")
local git = require("codediff.core.git")
local inline_worker = require("codediff.core.inline_worker")
local lifecycle = require("codediff.ui.lifecycle")
local refresh = require("codediff.ui.explorer.refresh")

local split_file = function(contents)
  local lines = vim.split(contents, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  for index, line in ipairs(lines) do
    lines[index] = line:gsub("\r$", "")
  end
  return lines
end

local read_worktree = function(path, callback)
  local bufnr = vim.fn.bufnr(path, false)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    callback(nil, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    return
  end

  vim.uv.fs_open(path, "r", 438, function(open_err, fd)
    if open_err then
      return vim.schedule(function()
        callback(open_err)
      end)
    end
    vim.uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err then
        vim.uv.fs_close(fd)
        return vim.schedule(function()
          callback(stat_err)
        end)
      end
      vim.uv.fs_read(fd, stat.size, 0, function(read_err, contents)
        vim.uv.fs_close(fd)
        vim.schedule(function()
          callback(read_err, read_err and nil or split_file(contents))
        end)
      end)
    end)
  end)
end

local read_revision = function(revision, root, path, callback)
  if revision:match("^:[0-3]$") then
    git.get_file_content(revision, root, path, callback)
    return
  end
  git.resolve_revision(revision, root, function(err, oid)
    if err then
      callback(err)
      return
    end
    git.get_file_content(oid, root, path, callback)
  end)
end

local has_staged_version = function(explorer, path)
  for _, file in ipairs((explorer.status_result or {}).staged or {}) do
    if file.path == path then
      return true
    end
  end
  return false
end

local comparison = function(explorer, file)
  if file.status == "??" or file.status == "A" or file.status == "D" or file.group == "conflicts" then
    return nil
  end

  local eligibility = config.options.diff.inline_cache.eligibility
  local path = file.path
  local old_path = file.old_path or path
  if not explorer.git_root then
    if not eligibility.worktree then
      return nil
    end
    return {
      original = { path = explorer.dir1 .. "/" .. old_path },
      modified = { path = explorer.dir2 .. "/" .. path },
    }
  end
  if explorer.base_revision and explorer.target_revision and explorer.target_revision ~= "WORKING" then
    if not eligibility.revisions then
      return nil
    end
    return {
      original = { revision = explorer.base_revision, path = old_path },
      modified = { revision = explorer.target_revision, path = path },
    }
  end
  if explorer.base_revision then
    if not eligibility.revisions or not eligibility.worktree then
      return nil
    end
    return {
      original = { revision = explorer.base_revision, path = old_path },
      modified = { path = explorer.git_root .. "/" .. path },
    }
  end
  if file.group == "staged" then
    if not eligibility.index or not eligibility.revisions then
      return nil
    end
    return {
      original = { revision = "HEAD", path = old_path },
      modified = { revision = ":0", path = path },
    }
  end
  local index_original = has_staged_version(explorer, path)
  if not eligibility.worktree or (index_original and not eligibility.index) or (not index_original and not eligibility.revisions) then
    return nil
  end
  return {
    original = { revision = index_original and ":0" or "HEAD", path = old_path },
    modified = { path = explorer.git_root .. "/" .. path },
  }
end

local read_side = function(explorer, side, callback)
  if side.revision then
    read_revision(side.revision, explorer.git_root, side.path, callback)
  else
    read_worktree(side.path, callback)
  end
end

local prepare = function(explorer, file, generation)
  local pair = comparison(explorer, file)
  if not pair then
    return
  end

  local values = {}
  local remaining = 2
  local failed = false
  local complete
  complete = function(name, err, lines)
    if vim.in_fast_event() then
      vim.schedule(function()
        complete(name, err, lines)
      end)
      return
    end
    if failed or explorer._inline_warm_generation ~= generation then
      return
    end
    if err then
      failed = true
      return
    end
    values[name] = lines
    remaining = remaining - 1
    if remaining > 0 then
      return
    end

    local diff_options = config.options.diff
    inline_worker.compute({
      original_lines = values.original,
      modified_lines = values.modified,
      options = {
        max_computation_time_ms = diff_options.max_computation_time_ms,
        ignore_trim_whitespace = diff_options.ignore_trim_whitespace,
        compute_moves = diff_options.compute_moves,
        line_matcher = diff_options.line_matcher,
      },
      filetype = vim.filetype.match({ filename = file.path }) or "",
      kind = "warm",
      callback = function() end,
    })
  end

  read_side(explorer, pair.original, function(err, lines)
    complete("original", err, lines)
  end)
  read_side(explorer, pair.modified, function(err, lines)
    complete("modified", err, lines)
  end)
end

local candidates = function(explorer, selected)
  local options = config.options.diff.inline_cache
  local files = refresh.get_all_files(explorer.tree)
  local selected_index
  for index, file in ipairs(files) do
    if file.data.path == selected.path and file.data.group == selected.group then
      selected_index = index
    end
  end
  if not selected_index then
    return {}
  end

  local result = {}
  local seen = {}
  local add = function(index)
    if not config.options.diff.cycle_next_file and (index < 1 or index > #files) then
      return
    end
    local wrapped = (index - 1) % #files + 1
    local file = files[wrapped]
    local key = file.data.group .. "\0" .. file.data.path
    if not seen[key] and wrapped ~= selected_index then
      seen[key] = true
      result[#result + 1] = file.data
    end
  end
  for distance = 1, options.forward do
    add(selected_index + distance)
  end
  for distance = 1, options.backward do
    add(selected_index - distance)
  end
  return result
end

function M.selection_changed(explorer, selected)
  local options = config.options.diff.inline_cache
  if options.enabled == false then
    return
  end
  local session = lifecycle.get_session(explorer.tabpage)
  if not session or session.layout ~= "inline" then
    return
  end

  explorer._inline_warm_generation = (explorer._inline_warm_generation or 0) + 1
  local generation = explorer._inline_warm_generation
  vim.defer_fn(function()
    if explorer._inline_warm_generation ~= generation or not vim.api.nvim_tabpage_is_valid(explorer.tabpage) then
      return
    end
    for _, file in ipairs(candidates(explorer, selected)) do
      prepare(explorer, file, generation)
    end
  end, options.dwell_ms)
end

return M
