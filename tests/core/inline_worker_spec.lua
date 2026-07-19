local config = require("codediff.config")
local diff = require("codediff.core.diff")
local inline = require("codediff.ui.inline")
local worker = require("codediff.core.inline_worker")

local compute = function(original, modified, filetype)
  local done = false
  local result
  local callback_error
  local cache_hit
  local queued, err = worker.compute({
    original_lines = original,
    modified_lines = modified,
    options = {},
    filetype = filetype,
    callback = function(value, value_error, hit)
      result = value
      callback_error = value_error
      cache_hit = hit
      done = true
    end,
  })
  assert.is_true(queued, err)
  assert.is_true(
    vim.wait(10000, function()
      return done
    end, 10),
    "inline worker timed out"
  )
  assert.is_nil(callback_error)
  return result, cache_hit
end

describe("Inline worker", function()
  before_each(function()
    worker.clear()
    config.options.diff.inline_cache.max_entries = 8
    config.options.diff.inline_cache.max_bytes = 32 * 1024 * 1024
  end)

  it("computes exact diff and Tree-sitter captures outside the editor process", function()
    local original = { "local value = 1", "return value" }
    local modified = { "local value = 2", "return value" }
    local result, cache_hit = compute(original, modified, "lua")

    assert.is_false(cache_hit)
    assert.same(diff.compute_diff(original, modified), result.lines_diff)
    assert.same(inline.compute_syntax_highlights(original, "lua"), result.syntax_hls)
  end)

  it("caches the combined result", function()
    local original = { "local value = 1" }
    local modified = { "local value = 2" }
    local first = compute(original, modified, "lua")
    local second, cache_hit = compute(original, modified, "lua")

    assert.is_true(cache_hit)
    assert.same(first, second)
    assert.equal(1, worker.get_metrics().entries)
  end)

  it("enforces the entry budget", function()
    config.options.diff.inline_cache.max_entries = 1
    compute({ "local first = 1" }, { "local first = 2" }, "lua")
    compute({ "local second = 1" }, { "local second = 2" }, "lua")

    local metrics = worker.get_metrics()
    assert.equal(1, metrics.entries)
    assert.is_true(metrics.evictions > 0)
  end)
end)
