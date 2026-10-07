# Live server tests

These tests are opt-in and need a deployment you operate. Run one live scenario
at a time, with `swift test -j 1 --filter <test name>` and its existing
`AGENTPAD_LIVE_*` scenario flag. Ordinary test runs do not contact the deployment.

Both live chat test classes require these environment variables before any
network request. Missing or blank variables skip the tests with `XCTSkip`.

| Variable | Value |
| --- | --- |
| `AGENTPAD_LIVE_HOST` | SSH alias for the test deployment. |
| `AGENTPAD_LIVE_OPERATOR` | Remote command prefix for privileged organization creation. The test appends `create-org --name <E2E name> --owner <email>` as positional arguments. |
| `AGENTPAD_LIVE_ISSUE_CODE_OPERATOR` | Remote command prefix for code issuance. The test appends `issue-code <email>` as positional arguments. |
| `AGENTPAD_LIVE_EMAIL` | Email template with exactly one `{id}` in the local part and an `e2e-` marker, for example `tester+e2e-{id}@example.com`. Use a mailbox/domain you control. |

Command prefixes are trusted operator configuration. Each can name a remote
wrapper (for example `/opt/agentpad/bin/test-operator`) or define a shell function
and end with its name. They run in Bash on the remote host, supplied through SSH
stdin. Arguments are shell-quoted and passed through `"$@"`; host-side credential
handling belongs in the wrapper or function. Do not enable shell tracing or print
credentials. Standard error is discarded and failures never include operator
output. Keep private deployment configuration outside the repository.

Generated addresses replace `{id}` with the scenario, run timestamp, and client
suffix. Explicit addresses in `AGENTPAD_LIVE_SIGNIN` and
`AGENTPAD_LIVE_FEED_A` / `AGENTPAD_LIVE_FEED_B` must also match the template and
belong to the intended E2E organization. `AGENTPAD_LIVE_FEED_ORG` selects that
organization. `AGENTPAD_LIVE_CODES` still supports manually supplied code files;
it does not remove the shared configuration requirement.

The default API server remains `https://agentpad.rabbitshat.ai`.

Real Claude execution also requires `AGENTPAD_LIVE_CLAUDE_CONFIG_DIR` to point
to an operator-prepared, authenticated directory: either the dedicated
`$HOME/.agentpad-live-claude` profile or a directory named `agentpad-e2e-claude-*`
inside the system temporary directory (or `/private/tmp`). Temporary profiles
require an empty `agentpad-e2e-ready` marker, placed only after preparation.
The persistent profile must already exist and must not resolve to a personal
profile through a symlink; explicitly supplying its dedicated path opts it in.
The tests never copy credentials or inspect the personal Claude profile. Missing
configuration skips the real run before organization creation or execution.

`AGENTPAD_LIVE_CLAUDE_EXECUTABLE` optionally selects the native Claude binary for
these isolated tests; otherwise they locate the default installation. D4/Y2
currently assert version `2.1.289`. Select an installed binary of that version
if the default has updated: an unprobed version waits for local owner approval.
An explicit path never falls back to a different installation, and the normal
native-file and version checks still apply.

`IsolatedClaudeFixture` supplies a temporary project, HOME and AgentPad profile,
passes `HOME`, `CFFIXED_USER_HOME` and `CLAUDE_CONFIG_DIR` explicitly to both the version probe and executor, and points
all session-history reads and copies at that configuration's `projects` directory.
It uses an in-memory version-approval store. Removing a fixture removes only its
own temporary project/profile; the operator-owned authenticated test configuration
is retained for later scenarios. The production environment allowlist does not
inherit `CLAUDE_CONFIG_DIR` or authentication variables from the caller.
The isolated profile's `projects` directory must not be a symlink. Server-only
ChatLive scenarios (including F5/F6 stand-ins) refuse unconfigured execution;
their TeamCalls history roots also stay in the temporary test directory.
No existing personal sessions are read or deleted.

UX1 live checks require a deployment advertising `chat.channel_ux1` and
`chat.session_tools`. After deployment, verify feed/thread routing, local self
consent versus a second Mac, trust enable/revoke, stop versus late completion,
and all three MCP tools from real ordinary tabs. Include a forged hook UUID from
a genuine second tab: it must keep that tab's signature, never take the first
tab's published author. Also verify unknown-ACK retry, the rolling server quota,
and that the operator's personal session history is unchanged.
