local M = {}

function M.is_supported()
  return type(vim.api.nvim__ns_set) == "function"
end

function M.create(name, win)
  local namespace = vim.api.nvim_create_namespace(name)
  M.scope(namespace, win)
  return namespace
end

function M.scope(namespace, win)
  vim.api.nvim__ns_set(namespace, { wins = { win } })
end

function M.clear_scope(namespace)
  vim.api.nvim__ns_set(namespace, { wins = {} })
end

return M
