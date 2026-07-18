dofile("benchmarks/bootstrap.lua")

local core = require("codediff.ui.core")
local diff = require("codediff.core.diff")
local fixture_data = dofile("benchmarks/fixtures.lua")
local harness = dofile("benchmarks/harness.lua")
local highlights = require("codediff.ui.highlights")
local fixtures = {
  sparse = fixture_data.by_name["sparse-edits"],
  dense = fixture_data.by_name["dense-edits"],
  full_rewrite = fixture_data.by_name["full-rewrite"],
  large_insertion = fixture_data.by_name["large-insertion"],
}

local count_extmarks = function(fixture)
  local buffers = { fixture.original_buf, fixture.modified_buf }
  local namespaces = { highlights.ns_highlight, highlights.ns_filler }
  local count = 0
  for _, bufnr in ipairs(buffers) do
    for _, namespace in ipairs(namespaces) do
      count = count + #vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})
    end
  end
  return count
end

local clear_render = function(fixture)
  for _, bufnr in ipairs({ fixture.original_buf, fixture.modified_buf }) do
    vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns_highlight, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns_filler, 0, -1)
  end
end

local render = function(fixture)
  return core.render_diff(fixture.original_buf, fixture.modified_buf, fixture.original, fixture.modified, fixture.lines_diff)
end

local prepare_fixture = function(fixture)
  fixture.original_buf = vim.api.nvim_create_buf(false, true)
  fixture.modified_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fixture.original_buf, 0, -1, false, fixture.original)
  vim.api.nvim_buf_set_lines(fixture.modified_buf, 0, -1, false, fixture.modified)
  fixture.lines_diff = diff.compute_diff(fixture.original, fixture.modified, fixture_data.diff_options)
  assert(fixture.lines_diff.hit_timeout == false, "fixture diff timed out")
  assert(#fixture.lines_diff.changes == fixture.expected_changes, "unexpected fixture change count")

  local result = render(fixture)
  fixture.expected_extmarks = count_extmarks(fixture)
  fixture.expected_fillers = result.left_fillers + result.right_fillers
end

local setup_suite = function()
  highlights.setup()
end

local setup_case = function(case)
  if not case.fixture.lines_diff then
    prepare_fixture(case.fixture)
  end
  clear_render(case.fixture)
  if case.rerender then
    render(case.fixture)
  end
  return case.fixture
end

local run = function(_, fixture)
  return render(fixture)
end

local validate = function(case, result, fixture)
  assert(count_extmarks(fixture) == fixture.expected_extmarks, case.name .. ": unexpected extmark count")
  assert(result.left_fillers + result.right_fillers == fixture.expected_fillers, case.name .. ": unexpected filler count")
end

local cases = {
  {
    name = "sparse-rerender",
    fixture = fixtures.sparse,
    rerender = true,
  },
  {
    name = "dense-first-render",
    fixture = fixtures.dense,
  },
  {
    name = "dense-rerender",
    fixture = fixtures.dense,
    rerender = true,
  },
  {
    name = "full-rewrite-rerender",
    fixture = fixtures.full_rewrite,
    rerender = true,
  },
  {
    name = "large-insertion-rerender",
    fixture = fixtures.large_insertion,
    rerender = true,
  },
}

local print_result = function(case, stats)
  local fixture = case.fixture
  local line_count = string.format("%d -> %d", #fixture.original, #fixture.modified)
  print(
    string.format(
      "%-26s %13s %8d %9d %8d %8.3fms %8.3fms %8.3fms %8.3f .. %8.3fms",
      case.name,
      line_count,
      fixture.expected_changes,
      fixture.expected_extmarks,
      fixture.expected_fillers,
      stats.median,
      stats.p95,
      stats.mad,
      stats.min,
      stats.max
    )
  )
end

local cleanup = function()
  for _, fixture in pairs(fixtures) do
    for _, bufnr in ipairs({ fixture.original_buf, fixture.modified_buf }) do
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end
end

local main = function()
  harness.run({
    script = "benchmarks/render.lua",
    suite_name = "render",
    usage = "usage: scripts/benchmark.sh render [--list | benchmark-name]",
    title = "CodeDiff side-by-side rendering benchmarks",
    description = "Diff computation, buffer setup, and validation are outside timed sections. Lower is better.",
    header = string.format("%-26s %13s %8s %9s %8s %10s %10s %10s %19s", "benchmark", "lines", "changes", "extmarks", "fillers", "median", "p95", "MAD", "min .. max"),
    cases = cases,
    setup = setup_suite,
    setup_case = setup_case,
    run = run,
    validate = validate,
    print_result = print_result,
  })
end

local ok, err = xpcall(main, debug.traceback)
cleanup()
if not ok then
  io.stderr:write("Rendering benchmark error: " .. tostring(err) .. "\n")
  os.exit(1)
end
vim.cmd("quit")
