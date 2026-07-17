See AGENTS.md for project conventions.



## Fork stack branch

This branch is the source of truth for the generated public `main` branch. Keep `main` as the repository's default branch. Do not add plugin implementation commits here or edit `main` directly.

- `stack.lock` pins the exact upstream commit, patch order, origin PR metadata, and expected output hashes.
- `patches/` contains the complete resolved patch series. Conflict resolutions must be exported here; `git rerere` is only a local convenience.
- Run `scripts/fork-stack rebuild` after changing the lock or patches. It must reconstruct the expected commit and tree from a clean worktree.
- Before restacking, remove patches whose PRs are now upstream from the ordered list, their manifest sections, and `patches/`. If application reports an empty or already-applied patch, abort, remove it, and restart.
- Update upstream with `scripts/fork-stack restack <sha>`. Resolve conflicts in the reported worktree, run `scripts/fork-stack continue` until complete, then run `scripts/fork-stack finish`.
- `finish` rewrites the resolved patches and lock, rebuilds from scratch, and runs the configured tests. Review those generated changes before committing.
- Publish only with `scripts/fork-stack publish snapshot-YYYYMMDD.N`. It atomically updates public `main`, pushes the immutable tag, and creates a GitHub Release containing the pinned install SHA.
- Never move or delete a published snapshot tag. Never bypass a failed strict rebuild with three-way application.
