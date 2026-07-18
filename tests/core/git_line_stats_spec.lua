local git = require("codediff.core.git")
local h = dofile("tests/helpers.lua")

local get_file = function(files, path)
  for _, file in ipairs(files) do
    if file.path == path then
      return file
    end
  end
end

local await_result = function(invoke)
  local done = false
  local callback_error
  local result
  invoke(function(err, value)
    callback_error = err
    result = value
    done = true
  end)
  assert.is_true(vim.wait(3000, function()
    return done
  end, 20))
  return callback_error, result
end

local expect_result = function(invoke)
  local err, result = await_result(invoke)
  assert.is_nil(err)
  assert.is_not_nil(result)
  return result
end

local get_options = function()
  return {
    enabled = true,
    count_untracked = false,
    max_untracked_bytes = 1024 * 1024,
  }
end

local write_raw_file = function(path, contents)
  local uv = vim.uv or vim.loop
  local fd = assert(uv.fs_open(path, "w", 420))
  uv.fs_write(fd, contents, 0)
  uv.fs_close(fd)
end

local commit_all = function(repo, message)
  repo.git("add -A")
  repo.git("commit -m " .. message)
  local output = repo.git("rev-parse HEAD")
  return vim.trim(output)
end

describe("Git line stats", function()
  local repo
  local base_revision

  before_each(function()
    repo = h.create_temp_git_repo()
    repo.write_file("tracked.txt", { "one", "two" })
    repo.write_file("renamed.txt", { "same" })
    base_revision = commit_all(repo, "initial")
  end)

  after_each(function()
    repo.cleanup()
  end)

  it("adds staged, unstaged, renamed, binary, and optional untracked stats", function()
    repo.write_file("tracked.txt", { "one", "changed", "three" })
    repo.write_file("staged.txt", { "alpha", "beta" })
    write_raw_file(repo.path("binary.dat"), "binary\0content")
    repo.git("add staged.txt binary.dat")
    repo.git("mv renamed.txt moved.txt")
    repo.write_file("untracked.txt", { "first", "second" })

    local options = get_options()
    local result = expect_result(function(callback)
      git.get_status_with_line_stats(repo.dir, options, callback)
    end)

    assert.same({ insertions = 2, deletions = 1, binary = false }, get_file(result.unstaged, "tracked.txt").line_stats)
    assert.same({ insertions = 2, deletions = 0, binary = false }, get_file(result.staged, "staged.txt").line_stats)
    assert.same({ insertions = 0, deletions = 0, binary = false }, get_file(result.staged, "moved.txt").line_stats)
    assert.same({ insertions = 0, deletions = 0, binary = true }, get_file(result.staged, "binary.dat").line_stats)
    assert.is_nil(get_file(result.unstaged, "untracked.txt").line_stats)

    options.count_untracked = true
    options.max_untracked_bytes = 1
    result = expect_result(function(callback)
      git.get_status_with_line_stats(repo.dir, options, callback)
    end)
    assert.is_nil(get_file(result.unstaged, "untracked.txt").line_stats)

    options.max_untracked_bytes = 1024 * 1024
    result = expect_result(function(callback)
      git.get_status_with_line_stats(repo.dir, options, callback)
    end)
    assert.same({ insertions = 2, deletions = 0, binary = false }, get_file(result.unstaged, "untracked.txt").line_stats)
  end)

  it("adds aggregate working tree stats relative to one revision", function()
    repo.write_file("tracked.txt", { "one", "changed", "three" })
    repo.write_file("staged.txt", { "alpha", "beta" })
    repo.git("add staged.txt")
    repo.write_file("untracked.txt", { "first", "second" })

    local options = get_options()
    local result = expect_result(function(callback)
      git.get_diff_revision_with_line_stats(base_revision, repo.dir, options, callback)
    end)

    assert.same({ insertions = 2, deletions = 1, binary = false }, get_file(result.unstaged, "tracked.txt").line_stats)
    assert.same({ insertions = 2, deletions = 0, binary = false }, get_file(result.unstaged, "staged.txt").line_stats)
    assert.is_nil(get_file(result.unstaged, "untracked.txt").line_stats)

    options.count_untracked = true
    result = expect_result(function(callback)
      git.get_diff_revision_with_line_stats(base_revision, repo.dir, options, callback)
    end)
    assert.same({ insertions = 2, deletions = 0, binary = false }, get_file(result.unstaged, "untracked.txt").line_stats)
  end)

  it("adds destination path stats between two revisions", function()
    repo.write_file("tracked.txt", { "one", "changed", "three" })
    repo.git("mv renamed.txt moved.txt")
    write_raw_file(repo.path("binary.dat"), "binary\0content")
    local target_revision = commit_all(repo, "changes")

    local result = expect_result(function(callback)
      git.get_diff_revisions_with_line_stats(base_revision, target_revision, repo.dir, get_options(), callback)
    end)

    assert.same({ insertions = 2, deletions = 1, binary = false }, get_file(result.unstaged, "tracked.txt").line_stats)
    assert.same({ insertions = 0, deletions = 0, binary = false }, get_file(result.unstaged, "moved.txt").line_stats)
    assert.same({ insertions = 0, deletions = 0, binary = true }, get_file(result.unstaged, "binary.dat").line_stats)
    assert.is_nil(get_file(result.unstaged, "renamed.txt"))
  end)

  it("returns base results without stats when disabled", function()
    repo.write_file("tracked.txt", { "one", "committed", "three" })
    local target_revision = commit_all(repo, "target")
    repo.write_file("tracked.txt", { "one", "working", "three", "four" })
    local options = { enabled = false }
    local cases = {
      {
        base = function(callback)
          git.get_status(repo.dir, callback)
        end,
        with_stats = function(callback)
          git.get_status_with_line_stats(repo.dir, options, callback)
        end,
      },
      {
        base = function(callback)
          git.get_diff_revision(target_revision, repo.dir, callback)
        end,
        with_stats = function(callback)
          git.get_diff_revision_with_line_stats(target_revision, repo.dir, options, callback)
        end,
      },
      {
        base = function(callback)
          git.get_diff_revisions(base_revision, target_revision, repo.dir, callback)
        end,
        with_stats = function(callback)
          git.get_diff_revisions_with_line_stats(base_revision, target_revision, repo.dir, options, callback)
        end,
      },
    }

    for _, case in ipairs(cases) do
      assert.same(expect_result(case.base), expect_result(case.with_stats))
    end
  end)

  it("propagates invalid repository and revision errors", function()
    local options = get_options()
    local missing_revision = "missing-line-stats-revision"
    local cases = {
      function(callback)
        git.get_status_with_line_stats(repo.path("missing"), options, callback)
      end,
      function(callback)
        git.get_diff_revision_with_line_stats(missing_revision, repo.dir, options, callback)
      end,
      function(callback)
        git.get_diff_revisions_with_line_stats(base_revision, missing_revision, repo.dir, options, callback)
      end,
    }

    for _, invoke in ipairs(cases) do
      local err, result = await_result(invoke)
      assert.is_not_nil(err)
      assert.is_nil(result)
    end
  end)
end)
