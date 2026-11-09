# Native timeline infrastructure (W02)

The product still defaults to the legacy timeline. A fixture opts in through the
existing `ChatTimelineView.implementation` factory and returns
`NativeChatTimelineRepresentable(snapshot:)`. This mounts one view-based,
single-column `NSTableView`, with native shell cells and no row hosting views.
The shell is an infrastructure fixture: exact markdown, structural decoration,
actions, attachments, metadata, scrolling policy and reading lifecycle remain
the later ordered units in the approved migration specification. Its captures
are not visual-parity or benchmark evidence.

`NativeChatTimelineCoordinator` owns the ordered payloads, ID index and current
row plans. `ChatTimelineDifference` describes sequential removals, insertions and
moves. Each data-source mutation precedes its corresponding AppKit call within
one zero-duration update group. Final payloads and height invalidations are
installed in that transaction. Existing cells are configured directly; full
reload is limited to initial mount and conversation/presentation-epoch reset.
Reentrant updates coalesce to the newest request and run after the transaction.

Preparation uses immutable snapshots and a ticket carrying conversation,
presentation epoch, snapshot generation, exact pixel-normalized width and a
monotonic request serial. Both preparation and commit reject superseded tickets;
commit also rejects replay. Disposal invalidates tickets and clears retained
data. Measurement is currently synchronous on the main actor, with isolated
undisplayed TextKit objects and background layout disabled. No worker queue or
synchronous worker join has been introduced. This API fences future delayed
preparation without assuming that shared AppKit objects are thread-safe.

`ChatTimelineRowLayoutPlan` is the only frame/height representation. The delegate
returns its height and the cell lays out its header/body from its rectangles.
The exact table width is normalized to backing pixels once; the plan derives
the actual content width after feed/thread insets and the avatar gutter.
There are no width buckets, hidden measurement cells, downloads or model calls.

Each controller owns two LRU caches keyed by scoped row ID, presentation epoch,
normalized width/scale and the appropriate content or layout revision. Defaults
are 512 entries and 4 MiB of accounted attributed-content cost; 512 entries and
256 KiB of accounted layout cost. Oversized entries are not retained. Removal
and pane reset purge obsolete IDs/epochs; disposal empties both. The coordinator
also retains one compact final plan per row in the current snapshot, needed for
exact table heights; it does not retain old-width plans or attributed content
outside those caches. The byte figures are deterministic accounting budgets,
not measurements of allocator overhead or process RSS.

Shell reuse identifiers describe structure. Each binding contains row ID,
presentation epoch, content revision and reuse generation. Rebinding cancels
cell-owned work and clears selection, menu, tooltip, accessibility and tracking
state. A same-text repaint preserves characters, text storage and native
selection; attribute changes update attributes in place. Delayed cell work must
present its binding token before applying. User operations and active editor
lifetime remain outside reusable shells.

The W01 attachment follow-up is closed by projecting raw server limits to
`limitsAvailable`. Non-geometric numeric changes no longer change row revisions
or cache keys, including messages with files. Capability/availability changes
and file geometry still invalidate. Real offline adapter coverage and cache
coverage exercise this distinction without credentials or network integration.

Validation uses `scripts/test-quiet.py`; W02 capture output is opt-in through
`AGENTPAD_CHAT_NATIVE_W02_CAPTURE`. Tests cover the four seam mounts, actual
insert/delete/move/reconfigure transactions, native reuse, selection and stale
completion fences, exact width/layout agreement, cache eviction and pagination.
The product's existing legacy tests remain on their original mount.
