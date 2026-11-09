# Native timeline foundation (W01)

`ChatTimelineView` remains the shared channel/DM feed/thread entry point. Its
single internal `implementation` selection defaults to `.legacy`. The legacy
view owns its original scroll, focus, notification and reading lifecycle. The
wrapper never mounts a second renderer or publishes visibility itself.

The `.native` case accepts an injected view factory. W01 uses this slot for
isolated test probes; W02 supplies the native table representable. Product
callers do not opt in. It is not a preference, capability or environment flag.
The selector and legacy branch are removed together only after the migration's
parity and performance gates.

`ChatTimelineSnapshotHost` evaluates model, metadata, service, catalog and style
dependencies within SwiftUI observation. `ChatTimelineAdapter` copies them into
value inputs. It does not start reading visits or publish viewport facts.
`ChatTimelineSnapshotBuilder` holds only the latest input/snapshot and the cached
`ChatFeedLayout` projection; unchanged messages, unread boundary and calendar do
not repeat sorting/grouping.

All snapshot fields are values. Row identity is conversation plus semantic kind;
decorations never enter `messageIDs`. Server message revision is independent of
presentation `contentRevision` and `layoutRevision`. Selection, avatar/preview
completion, time visibility and color changes repaint without resetting text
layout. Content, grouping, metadata, edit, name and metric changes invalidate
layout. Width remains a W02 layout-cache input, not a row identity.

Navigation commands retain monotonic request tokens. A controller consumes each
token once, including a pending reveal when its message arrives. To repeat the
same explicit command, call `builder.request` after an initial snapshot; requests
coalesce by kind and are discarded when conversation or presentation epoch
changes. No command is inferred from row materialization. Message aliases are
supplied explicitly by the domain when an ID is replaced, never matched by text.

`ChatTimelineActions` resolves current messages and permissions on every call.
It rejects an obsolete pane, service/store binding or invalidated adapter.
Models retain edit lifetime, drafts, authorization and read semantics. Native
geometry/focus, cells, popup anchors, media tasks and editor hosting belong to
later units; W01 introduces no storage or subscriptions for them.
