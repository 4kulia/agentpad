# Claude accounts over SSH

An agent profile started in an SSH workspace runs on the workspace's server, including profiles using Main account. Main account uses Claude's own login on that server. Named accounts use an explicitly installed token stored on that server. Local profile launches continue to use the macOS Keychain and local account preflight.

## Manage a host

Open Settings → Claude accounts and select a named account. The SSH hosts list comes from SSH workspaces in the open windows. Status and Remove can reuse the workspace's SSH connection; Install and Update use a dedicated connection. Status is checked for that destination; no persistent per-host receipt store is maintained.

- **Installed:** the remote revision matches the locally saved token revision. This confirms storage, not successful authentication with Claude.
- **Not installed:** the remote account record is missing.
- **Out of date:** the remote revision differs from the locally saved revision.
- **Install failed:** the operation failed; the row and failure popup show a safe, classified reason. Raw remote output is not displayed.

Install, Update and Retry require an explicit popup action. Update replaces the previous record atomically. Remove requires a destructive confirmation. Refresh status / Check again rereads the remote revision. Dismissing a popup never approves its action. A blocked launch can open installation and optionally start that agent after success.

If an SSH operation fails, its remote outcome can be uncertain. The host row keeps Check again and Remove available alongside Retry, so you can inspect or delete a possibly stored record without sending the token again.

Replacing a token locally persists a new random UUID revision in the existing account settings archive before changing the Keychain credential. A failed metadata save leaves the credential untouched. Once the revision is saved, interruption or a credential write failure can leave the old, new, or missing credential, but previously installed host records remain out of date. If the credential write fails, AgentPad attempts to restore the previous credential and reports restoration failure explicitly; it retains the new revision even when restoration succeeds. Replacement does not send a token to any host. Older archives without a revision use the account UUID as their initial revision; the next token replacement generates a new one.

## Remote storage and transport

Each account uses `~/.agentpad/claude-accounts/<account-uuid>.credential`. The record has two lines: the non-secret revision UUID, then the token. Missing directories are created with mode `0700`; existing `.agentpad` and `claude-accounts` directories must be owned by the remote user, mode `0700`, and not symlinks. Each directory is entered physically and its ownership, mode and inode rechecked. All record operations then use relative paths in that pinned directory. Installation runs under `umask 077`, exclusively creates a mode `0600` temporary file, writes through that same open descriptor, and renames within the directory after validation. Status reads only the first line.

Install and Update send the token once through SSH stdin with PTY allocation disabled. They use `ControlMaster=no` and `ControlPath=none`, so they neither join nor create a shared master, including one configured in the user's SSH config. The local SSH child and remote credential shell disable core dumps before reading credential bytes. The token is absent from the SSH argv, SSH process environment, terminal input and application logs. Launches, status checks and Remove do not read or transfer the local token and can retain connection multiplexing. They send identifiers only; launch reads the remote token in its guarded shell. Installation requires authentication for the dedicated connection in batch mode; it cannot borrow an interactive master's authentication. No test request to Claude is made during installation.

## Launch

Named-account launch checks the remote revision before starting the terminal process. Missing, outdated or unreadable records produce a blocked tab with Install/Update and Manage account actions. AgentPad does not silently fall back to Main account.

If the remote record disappears or changes after preflight, the launch guard reports refusal through the existing launch-exit marker. AgentPad terminates that terminal and returns the tab to the blocked state with recovery actions. “Install and start” starts only while the original blocked tab, profile, account and host still match the confirmation; otherwise installation finishes without changing the tab.

The existing `agentpad-ssh` path starts the agent after the server's shell initialization. A fresh non-login shell with tracing disabled reads the named record, verifies the selected revision again, clears competing authentication/provider variables, and assigns `CLAUDE_CODE_OAUTH_TOKEN` directly to the agent's exec environment. The token is never inserted into a command argument. The cleanup uses the local account policy's variable list, including `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, inherited OAuth tokens, `apiKeyHelper`, and `CLAUDE_CODE_USE_*`; `BASH_ENV` and `ENV` are removed before the fresh shell.

Remote preflight is environment cleanup only. AgentPad does not inspect Claude settings files on the server or install an account checker/helper binary there. Remote Claude settings can therefore still affect Claude's behavior. The remote agent executable must already be installed. Existing SSH behavior does not forward local conversation IDs to the server.

Opening a local conversation from a profile's history selects a local workspace, preserving that conversation's local resume ID. It does not start a local process inside an SSH workspace or attempt to resume a local transcript on the server.

## Security and lifetime

Only install on a host you trust. File permissions protect against other ordinary users; root, same-user programs and backups can access a persistent plaintext token. Removing the remote record does not revoke the token with Claude, erase backups or remove it from a running process. Running sessions keep their launch environment until restarted. Update the host before starting a new session after a local token replacement.

Tests use in-memory credentials and a fake SSH runner. Record scripts are exercised against temporary fixture directories, never a real SSH host.
