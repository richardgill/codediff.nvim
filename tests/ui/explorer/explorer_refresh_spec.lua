local h = dofile("tests/helpers.lua")

h.ensure_plugin_loaded()

-- Search recursively because collapsed directory descendants are absent from rendered lines.
local function find_in_node(tree, node, predicate)
  if predicate(node) then
    return node
  end
  for _, child_id in ipairs(node:get_child_ids()) do
    local child = tree:get_node(child_id)
    if child then
      local found = find_in_node(tree, child, predicate)
      if found then
        return found
      end
    end
  end
end

-- Search every root status group and stop at the first matching node.
local function find_node(tree, predicate)
  for _, node in ipairs(tree:get_nodes()) do
    local found = find_in_node(tree, node, predicate)
    if found then
      return found
    end
  end
end

-- Match both path and group so duplicate staged and unstaged directories stay distinct.
local function find_directory(explorer, path, group)
  return find_node(explorer.tree, function(node)
    return node.data.type == "directory" and node.data.dir_path == path and node.data.group == group
  end)
end

-- Find a root status group independently of whether it is currently expanded.
local function find_group(explorer, name)
  return find_node(explorer.tree, function(node)
    return node.data.type == "group" and node.data.name == name
  end)
end

-- Open a real explorer and wait for its initial async Git status and file selection.
local function open_explorer(repo)
  vim.cmd("edit " .. vim.fn.fnameescape(repo.path("src/a/one.txt")))
  vim.cmd("CodeDiff")

  local lifecycle = require("codediff.ui.lifecycle")
  local explorer
  local ready = vim.wait(6000, function()
    explorer = lifecycle.get_explorer(vim.api.nvim_get_current_tabpage())
    return explorer and explorer.current_file_path ~= nil and find_directory(explorer, "src/a", "unstaged") ~= nil
  end, 50)
  assert.is_true(ready, "Explorer should render the nested working-tree changes")
  return explorer
end

describe("Explorer refresh tree state", function()
  local repo

  before_each(function()
    -- Isolate lifecycle state and enable the tree behavior exercised by this regression.
    require("codediff.ui.lifecycle").cleanup_all()
    require("codediff").setup({
      explorer = {
        auto_refresh = true,
        flatten_dirs = true,
        view_mode = "tree",
      },
    })

    -- Two changed files produce one flattened node: Changes → src/a → {one.txt, two.txt}.
    repo = h.create_temp_git_repo()
    repo.write_file("src/a/one.txt", { "one" })
    repo.write_file("src/a/two.txt", { "two" })
    repo.git("add .")
    repo.git("commit -m initial")
    repo.write_file("src/a/one.txt", { "one changed" })
    repo.write_file("src/a/two.txt", { "two changed" })
  end)

  after_each(function()
    -- Stop watchers before removing the temporary repository they observe.
    require("codediff.ui.lifecycle").cleanup_all()
    vim.cmd("tabnew")
    vim.cmd("tabonly")
    if repo then
      repo.cleanup()
    end
  end)

  it("preserves a collapsed directory when an index change rebuilds flattened paths", function()
    local explorer = open_explorer(repo)
    local selected_path = explorer.current_file_path
    local selected_group = explorer.current_file_group
    local original_directory = find_directory(explorer, "src/a", "unstaged")
    original_directory:collapse()
    explorer.tree:render()

    -- Adding src/b changes src/a into src → {a, b}; add/reset makes the Git watcher run.
    repo.write_file("src/b/new.txt", { "new" })
    repo.git("add src/b/new.txt")
    repo.git("reset HEAD src/b/new.txt")

    -- A different node object proves a rebuild occurred, not merely another render.
    local rebuilt = vim.wait(6000, function()
      local existing = find_directory(explorer, "src/a", "unstaged")
      local added = find_directory(explorer, "src/b", "unstaged")
      return existing and existing ~= original_directory and not existing:is_expanded() and added
    end, 50)
    assert.is_true(rebuilt, "Git watcher should preserve the collapsed directory after rebuilding")
    -- The existing directory keeps its collapse, while the genuinely new directory uses defaults.
    assert.is_true(find_directory(explorer, "src/b", "unstaged"):is_expanded())
    -- Refresh must not disturb the file currently displayed in the diff panes.
    assert.equals(selected_path, explorer.current_file_path)
    assert.equals(selected_group, explorer.current_file_group)
  end)

  it("preserves independent group and directory state on manual and async refreshes", function()
    local explorer = open_explorer(repo)
    local unstaged_directory = find_directory(explorer, "src/a", "unstaged")
    unstaged_directory:collapse()

    -- Staging one file creates Changes → src/a/two.txt and Staged → src/a/one.txt.
    repo.git("add src/a/one.txt")
    local duplicated = vim.wait(6000, function()
      local current_unstaged = find_directory(explorer, "src/a", "unstaged")
      local current_staged = find_directory(explorer, "src/a", "staged")
      return current_unstaged and current_unstaged ~= unstaged_directory and current_staged ~= nil
    end, 50)
    assert.is_true(duplicated, "Index refresh should show the path in both status groups")

    -- Group-qualified keys preserve the old unstaged fold without folding the new staged node.
    local current_unstaged = find_directory(explorer, "src/a", "unstaged")
    local current_staged = find_directory(explorer, "src/a", "staged")
    assert.is_false(current_unstaged:is_expanded())
    assert.is_true(current_staged:is_expanded())

    local refresh = require("codediff.ui.explorer.refresh")
    -- Collapse after starting the async request to verify state is captured at rebuild time.
    refresh.refresh(explorer)
    current_staged:collapse()
    local captured_latest_state = vim.wait(6000, function()
      local rebuilt = find_directory(explorer, "src/a", "staged")
      return rebuilt and rebuilt ~= current_staged
    end, 50)
    assert.is_true(captured_latest_state, "Manual refresh should rebuild the tree")
    assert.is_false(find_directory(explorer, "src/a", "staged"):is_expanded())

    -- Remove the last unstaged path and verify the surviving empty group keeps its fold.
    local unstaged_group = find_group(explorer, "unstaged")
    unstaged_group:collapse()
    repo.git("checkout -- src/a/two.txt")
    refresh.refresh(explorer)
    local removed = vim.wait(6000, function()
      return find_directory(explorer, "src/a", "unstaged") == nil
    end, 50)
    assert.is_true(removed, "Manual refresh should remove clean working-tree paths")
    assert.is_false(find_group(explorer, "unstaged"):is_expanded())
  end)
end)
