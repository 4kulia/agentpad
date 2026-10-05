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
