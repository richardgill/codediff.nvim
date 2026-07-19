# Test Suite

Integration tests for codediff.nvim using [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

## Test Coverage

### ✅ FFI Integration (ffi_integration_spec.lua)
C ↔ Lua boundary validation:
- Data structure conversion
- Memory management (no leaks)
- Edge cases (empty diffs, large files)

**10 tests**

### ✅ Git Integration (git_integration_spec.lua)
Git operations and async handling:
- Repository detection
- Async callbacks
- Error handling for invalid revisions
- Path calculation
- LRU cache validation

**9 tests**

### ✅ Installer (installer_spec.lua)
Automatic binary installation and version management:
- Module API validation
- VERSION loading from version.lua
- Library path construction
- Version detection from filenames
- Update necessity logic
- Platform-specific extension handling

**10 tests**

### ✅ Auto-scroll (autoscroll_spec.lua)
Diff view scrolling behavior:
- Scroll to first change
- Window centering
- Scroll sync activation

**5 tests**

### ✅ Semantic Tokens (render/semantic_tokens_spec.lua)
LSP integration and rendering:
- Module compatibility checks
- Virtual file URL handling
- Namespace management

**12 tests**

### ✅ Rendered Display Facade (`nvim/display/`)
Window-renderer compatibility coverage (42 cases):
- Opaque viewport capture, restoration, and rendered offsets
- Settled scroll and display-invalidation events
- Batch renderer measurements, opaque layout contexts, decoration/layer exclusion, signatures, folds, and dynamic gutters
- Window-local layer isolation at differing widths, ordinary shared-buffer windows, concurrent ownership, re-scoping, declarative extmark-ID reuse/update/removal, buffer replacement, invalid windows, capability failure, and ordered teardown
- Architecture enforcement for the display facade and main wrapping modules
- Unwrapped multi-pane synchronization through a 60-row virtual filler block on Neovim 0.12 and nightly

Wrapping session ownership remains covered in `ui/wrap_session_ownership_spec.lua`, including shared buffers, ordinary-window isolation, window replacement, suspend/resume, and cleanup.

## Running Tests

### All tests:
```bash
./tests/run_plenary_tests.sh
```

### Individual spec:
```bash
nvim --headless --noplugin -u tests/init.lua \
  -c "lua require('plenary.test_harness').test_file('tests/nvim/display/layer_spec.lua', { minimal_init = '$PWD/tests/init.lua' })"
```

## Test Philosophy

Focus on **integration points** that C tests cannot validate:
- FFI boundary integrity
- Lua async operations
- System integration (git)
- UI behavior (scrolling, rendering)

**Total: 46 tests** across 5 spec files using industry-standard plenary.nvim framework.

## What's NOT Covered

❌ **Diff algorithm** - Validated by C tests in `c-diff-core/tests/` (3,490 lines)
❌ **Visual correctness** - Manual testing required
