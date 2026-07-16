See AGENTS.md for project conventions.

On first use, create symlinks so Claude Code discovers existing skills and agents:
```
mkdir -p .claude/skills/nvim-e2e-workflow .claude/skills/codediff-developer
ln -sf ../../.github/skills/nvim-e2e-workflow/SKILL.md .claude/skills/nvim-e2e-workflow/SKILL.md
ln -sf ../../.github/agents/codediff-developer.agent.md .claude/skills/codediff-developer/SKILL.md
```

## Richard patch stack

The `richard` branch carries these patches above `origin/main`, oldest first:

1. [`5cea7a6` — explorer `gf` opens in the previous tab](https://github.com/esmuellert/codediff.nvim/pull/321)
2. [`ee9443a` — include zero-hunk files in cross-file cycling](https://github.com/esmuellert/codediff.nvim/pull/438)
3. [`2b2f488` — keep Neovim open when closing the last diff tab](https://github.com/esmuellert/codediff.nvim/pull/440)
4. [`aa4964f` — hide the native tabline in CodeDiff views](https://github.com/esmuellert/codediff.nvim/pull/441)
5. [`5d90f3f` — highlight added and deleted single-file views](https://github.com/esmuellert/codediff.nvim/pull/442)
6. [`9e94576` — preserve explorer tree state across refreshes](https://github.com/esmuellert/codediff.nvim/pull/443)
7. [`353297d` — distinguish modified lines from insertions](https://github.com/esmuellert/codediff.nvim/pull/324)
8. [`c3acc61` — make filler text configurable](https://github.com/esmuellert/codediff.nvim/pull/444)
9. [`a082372` — add per-pane window options callback](https://github.com/esmuellert/codediff.nvim/pull/445)

Update this list whenever a patch is stacked, dropped, or replaced after an upstream merge.
