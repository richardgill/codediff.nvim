local async_diff = require("codediff.core.async_diff")
local diff = require("codediff.core.diff")

local make_large_lines = function(prefix)
  local lines = {}
  for index = 1, 300 do
    lines[index] = string.format("%s %03d %s", prefix, index, string.rep("content ", 8))
  end
  return lines
end

local compute_async = function(original, modified, options, owner)
  local result
  local callback_error
  local done = false
  local queued, queue_error = diff.compute_diff_async({
    original_lines = original,
    modified_lines = modified,
    options = options,
    owner = owner,
    callback = function(value, err)
      result = value
      callback_error = err
      done = true
    end,
  })
  assert.is_true(queued, queue_error)
  assert.is_true(
    vim.wait(10000, function()
      return done
    end, 1),
    "async diff did not complete"
  )
  assert.is_nil(callback_error)
  return result
end

describe("Async diff", function()
  before_each(function()
    async_diff.reset_metrics()
  end)

  it("matches synchronous results", function()
    local original = { "alpha", "shared", "old value", "omega" }
    local modified = { "alpha", "inserted", "shared", "new value", "omega" }
    local options = { compute_moves = true, line_matcher = { strategy = "vscode" } }

    assert.same(diff.compute_diff(original, modified, options), compute_async(original, modified, options))
    assert.same(diff.compute_diff({}, {}), compute_async({}, {}))
  end)

  it("delivers only the latest result for an owner", function()
    local delivered = {}
    local owner = {}
    assert(diff.compute_diff_async({
      original_lines = { "first" },
      modified_lines = { "stale" },
      owner = owner,
      callback = function()
        delivered[#delivered + 1] = "stale"
      end,
    }))
    local latest = compute_async({ "second" }, { "latest" }, {}, owner)

    vim.wait(100)
    assert.is_not_nil(latest)
    assert.same({}, delivered)
  end)

  it("coalesces rapid requests for one owner", function()
    local original = make_large_lines("original")
    local owner = {}
    local delivered = {}
    local done = false

    for index = 1, 5 do
      local request_index = index
      assert(diff.compute_diff_async({
        original_lines = original,
        modified_lines = make_large_lines("modified-" .. request_index),
        owner = owner,
        callback = function(_, err)
          delivered[#delivered + 1] = { index = request_index, err = err }
          done = request_index == 5
        end,
      }))
    end

    local queued_stats = async_diff.get_metrics()
    assert.equal(1, queued_stats.worker_queued)
    assert.equal(4, queued_stats.coalesced)
    assert.is_true(
      vim.wait(10000, function()
        return done
      end, 1),
      "coalesced diff did not complete"
    )
    assert.same({ { index = 5 } }, delivered)
    assert.equal(2, async_diff.get_metrics().worker_queued)
  end)

  it("runs requests for distinct owners concurrently", function()
    local completed = {}
    local errors = {}
    local original = make_large_lines("original")

    for index = 1, 2 do
      local request_index = index
      assert(diff.compute_diff_async({
        original_lines = original,
        modified_lines = make_large_lines("owner-" .. request_index),
        owner = {},
        callback = function(_, err)
          completed[#completed + 1] = request_index
          errors[#errors + 1] = err
        end,
      }))
    end

    assert.equal(2, async_diff.get_metrics().worker_queued)
    assert.is_true(
      vim.wait(10000, function()
        return #completed == 2
      end, 1),
      "concurrent diffs did not complete"
    )
    table.sort(completed)
    assert.same({ 1, 2 }, completed)
    assert.same({}, errors)
  end)

  it("keeps the main loop responsive during worker computation", function()
    local timer_fired = false
    local callback_saw_timer = false
    local done = false
    vim.defer_fn(function()
      timer_fired = true
    end, 0)

    assert(diff.compute_diff_async({
      original_lines = make_large_lines("responsive-original"),
      modified_lines = make_large_lines("responsive-modified"),
      callback = function(_, err)
        assert.is_nil(err)
        callback_saw_timer = timer_fired
        done = true
      end,
    }))

    assert.is_false(done)
    assert.is_true(
      vim.wait(10000, function()
        return done
      end, 1),
      "responsive diff did not complete"
    )
    assert.is_true(callback_saw_timer)
  end)

  it("returns worker failures with a traceback", function()
    local callback_error
    assert(async_diff.compute({
      original_lines = { "before" },
      modified_lines = { "after" },
      options = {},
      callback = function(_, err)
        callback_error = err
      end,
      library_path = "/codediff/missing-library",
      ffi_definitions = "",
    }))

    assert.is_true(
      vim.wait(10000, function()
        return callback_error ~= nil
      end, 1),
      "worker error was not delivered"
    )
    assert.matches("missing%-library", callback_error)
    assert.matches("stack traceback", callback_error)
  end)

  it("suppresses callbacks during shutdown", function()
    local called = false
    assert(diff.compute_diff_async({
      original_lines = { "before" },
      modified_lines = { "after" },
      callback = function()
        called = true
      end,
    }))
    async_diff.shutdown()

    vim.wait(100)
    assert.is_false(called)
    local queued, err = diff.compute_diff_async({
      original_lines = { "before" },
      modified_lines = { "after" },
      callback = function() end,
    })
    assert.is_nil(queued)
    assert.matches("shutting down", err)
  end)
end)
