local M = {}

local parent_channel

local traceback = function(err)
  return debug.traceback(tostring(err), 2)
end

function M.setup(channel)
  parent_channel = channel
end

function M.compute(request_id, args)
  local ok, result = xpcall(function()
    local diff = require("codediff.core.diff")
    local inline = require("codediff.ui.inline")
    return {
      lines_diff = diff.compute_diff(args.original_lines, args.modified_lines, args.options),
      syntax_hls = inline.compute_syntax_highlights(args.original_lines, args.filetype),
    }
  end, traceback)

  local payload = ok and vim.mpack.encode(result) or tostring(result)
  vim.rpcnotify(parent_channel, "nvim_exec_lua", "return require('codediff.core.inline_worker')._complete(...)", {
    request_id,
    ok,
    payload,
  })
end

return M
