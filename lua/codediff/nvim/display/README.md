# CodeDiff rendered-display facade

This package is the boundary between CodeDiff and Neovim's rendered-window behavior. Callers own window groups, buffer ranges, compensation counts, cache policy, and rebuild decisions. This package owns viewport representation, renderer-backed measurement, event timing, and window-local virtual rows.

Renderer workarounds stay here. Callers must not inspect saved-view dictionaries, `topfill`, `skipcol`, rendering signatures, extmark details, namespace identifiers, raw scroll deltas, or experimental namespace APIs.

## Contract

`require("codediff.nvim.display")` exposes:

```lua
is_viewport_supported() -> boolean
is_supported() -> boolean
capture(win) -> CodeDiffDisplayAnchor?
restore(win, anchor)
get_offset(win) -> integer?
set_offset(win, offset, { preserve_cursor?: boolean, notify?: boolean }?) -> integer?
observe({ wins, on_scroll, on_invalidate }) -> CodeDiffDisplaySubscription
unobserve(subscription)
synchronize(subscription, source_win, offset?) -> integer?
measure_ranges(win, ranges) -> integer[]
measurement_context(win, { exclude_layer?: CodeDiffDisplayLayer }?) -> CodeDiffDisplayMeasurementContext
closed_folds(win, rows) -> table<integer, integer>
create_layer(win) -> CodeDiffDisplayLayer
set_layer(layer, buf, entries) -> { removed: integer, reused: integer, updated: integer }
clear_layer(layer) -> integer
destroy_layer(layer)
```

`is_viewport_supported()` requires Neovim 0.12 and `nvim_win_text_height()`. `is_supported()` additionally requires window-scoped namespace support for alignment layers.

### Anchors and offsets

`CodeDiffDisplayAnchor` is opaque. `capture()` records the cursor and viewport of a valid window. `restore()` replays that state and ignores invalid windows or unknown anchors. An anchor may be restored only to a compatible rendered window.

An absolute rendered offset is the number of display rows before the first visible row. It includes wrapped text, folds, virtual rows, native diff filler, and facade layers. Zero is the beginning of the rendered stream. `get_offset()` returns `nil` for an invalid window. `set_offset()` clamps negative values to zero and returns the offset Neovim actually accepted.

`set_offset()` preserves the target cursor unless `preserve_cursor = false`. In an inactive target, the preserved cursor may remain before or after the restored viewport; cursor and viewport fields are restored atomically so Neovim does not independently scroll back to the cursor. Neovim requires the active window's cursor to remain visible, so an active partner cursor outside the requested viewport is clamped to the nearest visible line. If Neovim rejects a requested position inside virtual filler or a partial wrapped line, the facade selects the nearest later representable offset and Neovim may move the cursor to the following line. Group owners reconcile every pane to the returned offset. `notify = false` suppresses the matching observer event caused by that update. Cursors are never bound to corresponding semantic lines.

### Observers

`CodeDiffDisplaySubscription` is opaque and owns callbacks for one window set:

- `on_scroll(win, offset)` runs on the next event-loop turn after a vertical scroll has settled and coalesced.
- `on_invalidate(reason)` runs only when the normalized invalidation affects an observed window or its buffer.
- `unobserve()` is required during owner teardown. Pending callbacks become no-ops, and removing the final subscription removes package autocmds.

A non-notifying update suppresses only its matching generated event. Its suppression record remains through the next redraw opportunity, then expires when no event occurs, so a no-op update cannot consume a later user scroll. `synchronize()` applies one common representable offset across an observed window set and performs one scheduled post-redraw reconciliation when Neovim clamps a target viewport.

Normalized invalidations cover resize, relevant window/buffer/global options, diagnostics, and conceal-mode changes. Decorations and fold changes without a stable Neovim event require explicit invalidation by the caller.

### Measurements

`measure_ranges()` accepts zero-based, end-exclusive buffer ranges, preserves request order, and returns zero for empty ranges without issuing a renderer call. Every non-empty range is measured by one scalar `nvim_win_text_height()` call in the requested window. Arithmetic wrapping is not used. Layout operations reject invalid window handles.

`CodeDiffDisplayMeasurementContext` is opaque and exposes only:

```lua
context:has_same_signature(other) -> boolean
context:height_decorated_rows() -> table<integer, boolean>
context:has_active_conceal() -> boolean
```

The signature includes actual width, effective gutter width, wrapping and continuation options, columns, conceal, tab settings, `ambiwidth`, and `display`. Decoration inspection is lazy. `height_decorated_rows()` returns a detached zero-based row set for virtual lines, virtual text, and conceal. `exclude_layer` omits only the supplied facade layer from that inspection.

`closed_folds()` queries only valid requested rows in the target window. Values are zero-based exclusive fold ends.

### Layers

`CodeDiffDisplayLayer` is opaque and belongs to the window passed to `create_layer()`. A window may have only one live layer, and therefore one padding namespace; owners must destroy it before creating a replacement. Entries passed to `set_layer()` are the complete desired state:

```lua
{
  key = any,
  boundary_row = integer,
  count = integer,
  above = boolean?,
  anchor_row = integer?,
}
```

Rows are zero-based. Keys are required and unique within an update; they preserve entry identity across updates. Equal entries are reused, changed entries are updated, omitted entries are removed, and non-positive counts are ignored. Aggregate lifecycle counts are returned; extmark and namespace identifiers never leave the package.

`set_layer()` validates the owning window, reapplies window scope, and clears the old buffer before moving ownership. `clear_layer()` removes entries, returns the number removed, and retains the layer for reuse while its window remains valid; clearing and destroying remain safe after window invalidation. `destroy_layer()` clears buffer marks before removing scope, invalidates the token, and is required during owner teardown. Independent layers remain isolated when their windows display the same buffer.

## Viewport semantics

A viewport can begin in wrapped text, virtual filler before a line, a closed fold, or ordinary text. Neovim represents those states with private fields that vary with width. The facade converts them to opaque anchors or absolute rendered offsets.

`nvim_win_text_height({ max_height = ... })` is used as a guarded inverse. The resolver checks the requested bound and, when needed, its preceding bound because `end_vcol` is rounded to a rendered-row endpoint. A direct endpoint is accepted only when its prefix, partial-line height, and line boundary agree with the requested offset. Non-positive virtual columns, closed folds, filler interiors, inconsistent partial rows, and filler-bearing boundaries use measured binary searches. This preserves exact behavior where Neovim's endpoint does not identify the rendered row type.

A range beginning at a row excludes that row's leading `virt_lines_above`. Callers that model leading rendered rows must add those counts separately.

## Workaround inventory

### Filler-aware viewport get/set

- Missing API: exact absolute rendered-offset getter and setter.
- Upstream: [#16166](https://github.com/neovim/neovim/issues/16166), [#11370](https://github.com/neovim/neovim/issues/11370), and closed [#15248](https://github.com/neovim/neovim/pull/15248).
- Failure without the facade: logical line restoration drifts across unequal wrapping, filler, folds, and partial wrapped rows.
- Implementation: `viewport.lua` opaque anchors, offset conversion, guarded bounded lookup, and measured fallback.
- Protected by: inactive-cursor, wrapped-row, filler, and mouse/`WinScrolled` cases in `tests/nvim/display/viewport_spec.lua`, `tests/nvim/display/events_spec.lua`, and `tests/ui/wrap_smoothscroll_spec.lua`.
- Delete when: Neovim exposes exact filler-aware rendered-offset get/set operations.

### Ambiguous bounded inverse

- Missing API: a typed rendered endpoint that distinguishes text, folds, and filler and reports position within filler.
- Upstream: [`nvim_win_text_height({ max_height = ... })`](https://github.com/neovim/neovim/pull/32835) and Neovim's [UI2 usage](https://github.com/neovim/neovim/blob/952e59347e053a61cb621e56625c846b249236a0/runtime/lua/vim/_core/ui2/messages.lua#L118-L140).
- Failure without the guard: filler endpoints can report unusable virtual columns.
- Implementation: `viewport.lua` validates bounded endpoints and falls back when ambiguous.
- Protected by: direct, filler, fold, parity, path-selection, and call-count cases in `viewport_spec.lua`.
- Delete when: bounded lookup returns the rendered row type and exact within-row offset.

### Settled viewport observation

- Missing API: plugin-facing post-redraw viewport events.
- Upstream: internal `ui_ext_win_viewport()`, [#8539](https://github.com/neovim/neovim/issues/8539), [#19270](https://github.com/neovim/neovim/pull/19270), and [#24182](https://github.com/neovim/neovim/pull/24182).
- Failure without the shim: `WinScrolled` can expose a keyboard scroll before wrapped redraw settles.
- Implementation: `events.lua` coalesces the raw event, emits one final offset on the next event-loop turn, and reconciles observer windows after Neovim clamps an active viewport.
- Protected by: `tests/nvim/display/events_spec.lua` and `tests/ui/wrap_smoothscroll_spec.lua`.
- Delete when: plugins can subscribe to a settled viewport event carrying an exact absolute rendered offset.

### Bound scrolling

- Defective API: native `scrollbind` can oscillate inside large virtual filler blocks and counts logical/filler rows rather than wrapped display rows.
- Upstream: [#29518](https://github.com/neovim/neovim/issues/29518) and virtual-line accounting fix [#29766](https://github.com/neovim/neovim/pull/29766).
- Failure without the facade: unwrapped panes can jump between filler and the beginning of the buffer, while wrapped windows of unequal width drift.
- Implementation: `ui/view_sync.lua` and wrapped alignment callers disable native binding and apply one observed absolute offset to peer windows with non-notifying updates.
- Protected by: `tests/ui/view/view_spec.lua` and `tests/ui/wrap_smoothscroll_spec.lua`.
- Delete when: native bound scrolling accounts for virtual filler and wrapping at unequal widths without viewport oscillation.

### Renderer-backed layout inspection

- Missing API: batch height measurement and a stable generation for height-affecting display state.
- Failure without the facade: arithmetic estimates diverge on tabs, Unicode, conceal, folds, gutters, continuation options, and decorations.
- Implementation: `layout.lua` provides batch-shaped scalar measurement and opaque compatibility contexts.
- Protected by: `tests/nvim/display/layout_spec.lua` and `tests/ui/wrap_invalidation_spec.lua`.
- Delete when: Neovim provides batch measurements and a reliable height-affecting generation.

### Fold observation

- Missing API: complete fold queries plus general fold-change events.
- Upstream: [#29870](https://github.com/neovim/neovim/issues/29870), [#8538](https://github.com/neovim/neovim/issues/8538), [#19226](https://github.com/neovim/neovim/issues/19226), and closed [#24279](https://github.com/neovim/neovim/pull/24279).
- Failure without explicit invalidation: padding can remain stale after unobservable fold changes.
- Implementation: `layout.lua` provides requested fold queries; callers initiate rebuilds.
- Protected by: `layout_spec.lua` and wrapping invalidation tests.
- Delete when: Neovim emits per-window fold changes and exposes stable fold ranges.

### Window-local virtual rows

- Experimental API: `nvim__ns_set()` window scoping.
- Upstream: implementation [#28728](https://github.com/neovim/neovim/pull/28728) and stabilization [#36994](https://github.com/neovim/neovim/issues/36994).
- Failure without scoping: width-specific virtual rows leak into every window displaying a shared buffer.
- Implementation: `layer.lua` owns one scoped namespace and declarative entry set per layer.
- Protected by: `tests/nvim/display/layer_spec.lua` capability, differing-width isolation, ordinary-window, re-scope, replacement, reuse, invalid-window, and teardown cases, plus wrapping ownership integration tests.
- Delete when: namespace scoping is stable or extmarks gain stable direct window ownership.

### Display invalidation

- Missing API: one event or generation for all height-affecting decorations, signs, folds, conceal, inlay hints, gutters, and options.
- Upstream: sign-only proposal [#32185](https://github.com/neovim/neovim/issues/32185).
- Failure without normalization: cached measurements can survive rendered-height changes.
- Implementation: `events.lua` normalizes observable changes; callers explicitly invalidate unobservable providers.
- Protected by: `events_spec.lua` and wrapping invalidation tests.
- Delete when: Neovim exposes a per-window height generation and invalidation event.

## Testing and diagnostics

Run the package contract and architecture checks:

```bash
for spec in tests/nvim/display/*_spec.lua; do
  nvim --headless --noplugin -u tests/init.lua \
    -c "lua require('plenary.test_harness').test_file('$spec', { minimal_init = '$PWD/tests/init.lua' })"
done
```

Then run focused wrapping/lifecycle tests and `make test-lua`. Compatibility targets are Neovim 0.12.2 and the pinned Neovim 0.13 nightly.

Manual ownership checks:

```bash
nvim --headless -u NONE -S overlay/branch/manual-wrap-namespace.lua
nvim --headless -u NONE -S overlay/branch/manual-wrap-concurrency.lua
```

Focused viewport tests inspect only direct/fallback resolver counts and rendered-height call totals through the implementation module. Layer diagnostics expose only aggregate removed/reused/updated counts. Inspect private viewport fields, namespace data, or extmarks only within this package or its focused tests.

## Replacement rules

When an upstream capability replaces a workaround:

1. keep the facade contract stable unless caller semantics must change;
2. update the corresponding inventory entry and minimum Neovim capability;
3. keep characterization coverage for every represented viewport state;
4. rerun package, wrapping, lifecycle, shared-buffer, and cleanup tests on both target versions;
5. verify that ordinary scrolling does not trigger a full caller rebuild.

## Known limits

- External virtual text/lines, signs, enabled inlay hints, arbitrary decoration providers, and dynamic status columns without observable events require explicit invalidation.
- Arbitrary fold changes require explicit invalidation.
- GUI Unicode width behavior is not validated.
- Namespace scoping remains experimental.
- Cold measurement is approximately linear in requested ranges and remains costly for 100k-line files.
- `scrolloff`, `splitkeep`, externally managed winbars, and unusual window policy can interact with restoration.
- Complete inline virtual-line wrapping requires Neovim 0.13; multi-window rendered wrapping targets Neovim 0.12+.
