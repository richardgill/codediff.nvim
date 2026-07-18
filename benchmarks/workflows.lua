dofile("benchmarks/bootstrap.lua")

vim.cmd("runtime plugin/codediff.lua")
require("codediff").setup({
  diff = {
    layout = "side-by-side",
    cycle_hunks_across_files = false,
  },
})

local lifecycle = require("codediff.ui.lifecycle")
local harness = dofile("benchmarks/harness.lua")
local fixture
local base_tabpage
local original_cwd = vim.fn.getcwd()

local git = function(arguments)
  local command = { "git", "-C", fixture.dir }
  vim.list_extend(command, arguments)
  local output = vim.fn.system(command)
  assert(vim.v.shell_error == 0, table.concat(command, " ") .. " failed: " .. output)
end

local make_file_lines = function(file_index, changed)
  local lines = {}
  for line = 1, 1200 do
    local value = changed and line % 120 == 0 and "modified" or "original"
    lines[line] = string.format("file %02d line %04d %s", file_index, line, value)
  end
  return lines
end

local create_fixture = function()
  fixture = {
    dir = vim.fn.tempname(),
    file_count = 8,
  }
  vim.fn.mkdir(fixture.dir, "p")
  git({ "init", "-q" })
  git({ "config", "user.email", "benchmark@example.com" })
  git({ "config", "user.name", "CodeDiff Benchmark" })

  for index = 1, fixture.file_count do
    local path = string.format("%s/file-%02d.txt", fixture.dir, index)
    vim.fn.writefile(make_file_lines(index, false), path)
  end
  vim.fn.writefile({ "neutral" }, fixture.dir .. "/neutral.txt")
  git({ "add", "." })
  git({ "commit", "-qm", "initial" })

  for index = 1, fixture.file_count do
    local path = string.format("%s/file-%02d.txt", fixture.dir, index)
    vim.fn.writefile(make_file_lines(index, true), path)
  end
end

local reset_to_base_tab = function()
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    if tabpage ~= base_tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
      vim.api.nvim_set_current_tabpage(tabpage)
      vim.cmd("tabclose")
    end
  end
  vim.api.nvim_set_current_tabpage(base_tabpage)
  vim.cmd("edit " .. vim.fn.fnameescape(fixture.dir .. "/file-01.txt"))
  vim.fn.chdir(fixture.dir)
end

local get_ready_view = function(tabpage, previous_path)
  local explorer = lifecycle.get_explorer(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not explorer or not session or not session.stored_diff_result then
    return nil
  end
  if previous_path and explorer.current_file_path == previous_path then
    return nil
  end
  if not explorer.current_file_path or not session.modified_path then
    return nil
  end
  if not session.modified_path:find(explorer.current_file_path, 1, true) then
    return nil
  end
  if not session.modified_win or not vim.api.nvim_win_is_valid(session.modified_win) then
    return nil
  end
  if not session.stored_diff_result.changes or #session.stored_diff_result.changes == 0 then
    return nil
  end
  return {
    tabpage = tabpage,
    explorer = explorer,
    session = session,
  }
end

local wait_for_view = function(tabpage, previous_path)
  local view
  local ready = vim.wait(8000, function()
    if tabpage then
      view = get_ready_view(tabpage, previous_path)
      return view ~= nil
    end
    for _, candidate in ipairs(vim.api.nvim_list_tabpages()) do
      view = get_ready_view(candidate, previous_path)
      if view then
        return true
      end
    end
    return false
  end, 1)
  return {
    ready = ready,
    view = view,
  }
end

local run_open = function()
  vim.cmd("CodeDiff")
  return wait_for_view(nil)
end

local current_view = function()
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    local view = get_ready_view(tabpage)
    if view then
      return view
    end
  end

  reset_to_base_tab()
  local result = run_open()
  assert(result.ready and result.view, "CodeDiff did not render")
  return result.view
end

local focus_modified = function(view)
  vim.api.nvim_set_current_tabpage(view.tabpage)
  assert(
    vim.wait(2000, function()
      return lifecycle.is_suspended(view.tabpage) == false
    end, 1),
    "CodeDiff view did not resume"
  )
  vim.api.nvim_set_current_win(view.session.modified_win)
end

local get_action = function(bufnr, lhs)
  local callback = vim.api.nvim_buf_call(bufnr, function()
    local mapping = vim.fn.maparg(lhs, "n", false, true)
    return mapping and mapping.callback or nil
  end)
  if type(callback) == "function" then
    return callback
  end
  error("missing CodeDiff keymap: " .. lhs)
end

local validate_rendered_view = function(result)
  assert(result.ready and result.view, "CodeDiff view did not render")
end

local setup_next_file = function()
  local view = current_view()
  focus_modified(view)
  return {
    action = get_action(view.session.modified_bufnr, "]f"),
    tabpage = view.tabpage,
    previous_path = view.explorer.current_file_path,
  }
end

local run_next_file = function(context)
  context.action()
  return wait_for_view(context.tabpage, context.previous_path)
end

local setup_gf = function()
  local view = current_view()
  local base_window = vim.api.nvim_tabpage_get_win(base_tabpage)
  vim.api.nvim_win_call(base_window, function()
    vim.cmd("edit " .. vim.fn.fnameescape(fixture.dir .. "/neutral.txt"))
  end)
  focus_modified(view)
  vim.api.nvim_win_set_cursor(view.session.modified_win, { 600, 0 })
  return {
    action = get_action(view.session.modified_bufnr, "gf"),
    diff_tabpage = view.tabpage,
    expected_line = 600,
    target_path = fixture.dir .. "/" .. view.explorer.current_file_path,
  }
end

local run_gf = function(context)
  context.action()
  return {
    line = vim.api.nvim_win_get_cursor(0)[1],
    path = vim.api.nvim_buf_get_name(0),
    tabpage = vim.api.nvim_get_current_tabpage(),
  }
end

local validate_gf = function(result, context)
  assert(result.tabpage ~= context.diff_tabpage, "gf did not leave the diff tab")
  assert(result.path == context.target_path, "gf did not open the working-tree file")
  assert(result.line == context.expected_line, "gf did not preserve the cursor")
end

local setup_next_hunk = function()
  local view = current_view()
  focus_modified(view)
  local changes = view.session.stored_diff_result.changes
  vim.api.nvim_win_set_cursor(view.session.modified_win, { 1, 0 })
  return {
    action = get_action(view.session.modified_bufnr, "]c"),
    expected_line = changes[1].modified.start_line,
  }
end

local run_next_hunk = function(context)
  context.action()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local validate_next_hunk = function(result, context)
  assert(result == context.expected_line, "next hunk did not move the cursor")
end

local cases = {
  {
    name = "open-to-render",
    setup = reset_to_base_tab,
    run = run_open,
    validate = validate_rendered_view,
  },
  {
    name = "next-file-to-render",
    setup = setup_next_file,
    run = run_next_file,
    validate = validate_rendered_view,
  },
  {
    name = "gf-to-buffer",
    setup = setup_gf,
    run = run_gf,
    validate = validate_gf,
  },
  {
    name = "next-hunk-to-cursor",
    setup = setup_next_hunk,
    run = run_next_hunk,
    validate = validate_next_hunk,
  },
}

local setup_suite = function()
  create_fixture()
  vim.fn.chdir(fixture.dir)
  vim.cmd("edit " .. vim.fn.fnameescape(fixture.dir .. "/file-01.txt"))
  base_tabpage = vim.api.nvim_get_current_tabpage()
end

local print_result = function(case, stats)
  print(string.format("%-22s %8.3fms %8.3fms %8.3fms %8.3f .. %8.3fms", case.name, stats.median, stats.p95, stats.mad, stats.min, stats.max))
end

local main = function()
  harness.run({
    script = "benchmarks/workflows.lua",
    suite_name = "workflow",
    usage = "usage: scripts/benchmark.sh workflows [--list | benchmark-name]",
    title = "CodeDiff workflow benchmarks",
    description = "Neovim is already running. Fixture setup and validation are outside timed sections.",
    header = string.format("%-22s %10s %10s %10s %19s", "benchmark", "median", "p95", "MAD", "min .. max"),
    cases = cases,
    setup = setup_suite,
    print_result = print_result,
  })
end

local ok, err = xpcall(main, debug.traceback)
pcall(lifecycle.cleanup_all)
if fixture then
  vim.fn.chdir(original_cwd)
  vim.fn.delete(fixture.dir, "rf")
end
if not ok then
  io.stderr:write("Workflow benchmark error: " .. tostring(err) .. "\n")
  os.exit(1)
end
vim.cmd("qall!")
