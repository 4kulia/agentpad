# AgentPad

**Every coding-agent session and its files in one macOS window.**

If you run several Claude Code or Codex sessions at once, they end up scattered across terminal tabs, and finding the one that is waiting for you turns into a search. AgentPad puts them in one place: every live session, wherever it was started; every past conversation, ready to resume; and the selected session's files right beside the terminal.

AgentPad is a fork of [kooky](https://github.com/iAmCorey/kooky) by Corey Chiu, a native terminal for AI coding built on SwiftUI and [libghostty](https://github.com/ghostty-org/ghostty). It keeps everything kooky does and adds a session hub, a file manager and a file preview.

> Screenshots are coming.

## Layout

Three panes, all collapsible:

- **Files** on the left: the selected session's folder.
- **Terminal** in the middle, with a read-only file preview docked underneath.
- **Sessions** on the right: one list of everything that is running or recently ran.

## Sessions

- **One list for all sessions.** It shows agent tabs inside AgentPad, live Claude Code sessions running in other terminals (Terminal.app, iTerm2 and others), and recent conversations from disk.
- **Grouped by what they need from you:** *Needs you*, *Running*, *Idle*, *Recent*. Each row shows the conversation title, its folder and how long it has been in that state. You can switch to grouping by project and search by title or path.
- **Sessions in other terminals.** Click one to bring its Terminal.app or iTerm2 tab to the front. **Move Here** closes an idle session in its terminal and resumes the same conversation in an AgentPad tab, so nothing in the conversation is lost. **Show Files** points the file tree at that session's folder.
- **Attention:**
  - a Dock badge counts the sessions waiting for you;
  - <kbd>⌘</kbd><kbd>⇧</kbd><kbd>U</kbd> cycles through them;
  - notifications name the session and the reason it is waiting, and clicking one takes you there.
- **Resume any past conversation** of a supported agent in a new tab, in its original folder.

### Supported agents

| Agent | Command | Waiting dot | Tool pill | Session history |
| --- | --- | :---: | :---: | :---: |
| Claude Code | `claude` | ✓ | ✓ | ✓ |
| Codex | `codex` | ✓ | ✗ | ✓ |
| Gemini CLI | `gemini` | ✓ | ✗ | ✓ |
| OpenCode | `opencode` | ✓ | ✗ | ✓ |
| Amp | `amp` | ✓ | ✗ | ✗ |
| Cursor CLI | `cursor-agent` | ✓ | ✗ | ✓ |
| Copilot CLI | `copilot` | ✓ | ✗ | ✓ |
| Grok Build | `grok` | ✗ | ✗ | ✓ |
| Antigravity CLI | `agy` | ✓ | ✗ | ✗ |
| Kimi Code | `kimi` | ✓ | ✗ | ✓ |
| Pi | `pi` | ✓ | ✓ | ✓ |
| Oh My Pi | `omp` | ✓ | ✓ | ✓ |
| Reasonix | `reasonix` | ✓ | ✓ | ✓ |
| Kiro CLI | `kiro-cli` | ✗ | ✗ | ✓ |
| Droid | `droid` | ✓ | ✗ | ✓ |

- **Waiting dot:** the agent stopped and needs an answer, including a pending tool approval.
- **Tool pill:** shows the tool running right now.
- **Session history:** past conversations can be browsed and resumed.

Sessions running in *other* terminals are detected for Claude Code only for now.

## Files

- **File tree** of the session's folder. It updates live as the agent creates, changes or deletes files, and shows git line counts on changed files.
- **Copy, Cut and Paste** through the system clipboard, so they work with Finder in both directions.
- **New File, New Folder, Rename, Duplicate.**
- **Move to Trash.** Nothing is ever deleted outright.
- **Name clashes** ask whether to *Keep Both*, *Replace* or *Skip*, with *Apply to all* for batches. Replace is staged: if anything fails, the original stays where it was.
- **Drag and drop.** Within the tree it moves, from Finder it copies. Dragging a file onto the terminal inserts its path.
- **Find a file by name** in the session's folder. Tooling folders such as `.git` and `node_modules` are skipped.
- **Show or hide dotfiles**, and **Quick Look** any file.

## Preview

Click a file to preview it under the terminal. Drag the divider to resize the preview, or close it with ✕. Editing stays in your editor, one click away with **Open**.

- **Code and text:** syntax highlighting, line numbers, find with <kbd>⌘</kbd><kbd>F</kbd>.
- **Markdown:** rendered, with a toggle to the source. JavaScript is off, images load only from inside the project, and links never launch local files.
- **Everything else** goes through Quick Look: images, PDF, office documents, audio and video.
- **Live reload:** the preview follows the file as the agent rewrites it.
- **Large files:** text files over 5 MB show their first 5 MB.

## Team work

*In progress: team work moves to an AgentPad server. Connecting and publishing agents work today; calls to colleagues come back once the server delivers them. Team settings of AgentPad 1.0.x (direct pairing) are not carried over: set them up again.*

Team work goes through an AgentPad server your team shares:

1. **Team → Connect to a Server…**: the server's address and your email; enter the code the server mails you.
2. **Team → Team…** shows the connection and anything that needs you; **Team → Disconnect from the Server…** turns team work off.

Let your colleague's agents ask yours:

- **Team → Published Agents… → Publish Agent…**: a name, what to ask it about, a project folder, and its rights — *Read*, *Read and git* (a repository's top folder), or *Edit*. Files with secrets (`.env`, keys) are excluded from reading by default.
- Or right-click a Claude Code session in the right panel → **Publish to Team ▸ Publish…**, and publish the session itself (each call works on a copy of its conversation, which stays untouched; the agent disappears when the conversation is deleted), a fresh agent in its folder, or both.

An agent can be given more folders than its project (a second checkout, a shared knowledge repository). While it works, it can also ask for another folder: the request appears in the Team tab and the right panel with **Allow Once**, **Always** (added to the agent for good) and **Deny**, and the conversation goes on with the folder once allowed.

Every call shows up at the top of the right panel with its full text. Nothing runs until the owner clicks **Allow**; then Claude Code runs in the agent's folder with those rights only — the owner's own Claude Code settings and MCP servers are not used — and the answer goes back. The **Team** tab in the left sidebar lists the calls received and sent, with their state and answers, and Allow / Decline / Stop / Cancel; **Watch** opens a tab that shows, live, what the agent working on a call does, and **Continue…** opens its conversation for you to carry on.

Calling a colleague's agent:

- **From a Claude Code session in AgentPad**, just ask: "ask Masha's backend agent how auth works in her branch". While connected to a server, every new session gets the tools `team_agents`, `team_ask`, `team_check` and `team_cancel` (an MCP server passed at launch; your configuration is not changed). `team_ask` asks for your permission, since it sends text to another person.
- **From the command line**, for any other agent: `agentpad-cli team agents`, `agentpad-cli team ask backend@masha "How does auth work in your branch?"` (`--thread <id>` continues the conversation).

AgentPad connects only to the server you chose, over HTTPS; the sign-in is kept in the macOS keychain. Disconnecting closes the connection. Published agents and calls live in `~/Library/Application Support/agentpad/team-server/`, the connection in `…/agentpad/chat/`; the `team/` folder of 1.0.x is no longer used and can be deleted.

## Where the data comes from

AgentPad reads what the agents already write; it doesn't install hooks into your configuration.

| What | Source |
| --- | --- |
| Live Claude Code sessions in other terminals | `~/.claude/sessions/<pid>.json`, falling back to `claude agents --json` |
| Past conversations | each agent's own session store, e.g. `~/.claude/projects`, `~/.codex/sessions` |
| Status of AgentPad's own agent tabs | hooks passed per launch with `claude --settings`. Your `~/.claude/settings.json` is never modified |

Claude Code's session files are an internal format. AgentPad treats them defensively, ignoring unknown fields and dropping records it can't verify. Before **Move Here** signals a process, it checks that the process is still the same Claude Code instance that was listed, so a reused PID is never hit.

## Privacy

There is no telemetry, and no accounts or sync unless you connect to a team server. Conversations and files stay on your Mac. AgentPad makes no network requests on its own, with two exceptions:

- **Updates.** Once a day, and when you choose **Check for Updates…**, AgentPad reads the list of releases (`appcast.xml`) from this repository's latest GitHub release. Nothing about you or your Mac is sent.
- **Team work**, while connected, talks to the AgentPad server you connected to (see above), and to nothing else.

## Install

Download the latest `AgentPad-v….dmg` from [Releases](https://github.com/4kulia/agentpad/releases), open it and drag AgentPad to Applications. It needs macOS 14.5 or later on Apple Silicon.

Releases from 1.0.5 on are signed with a Developer ID and notarized by Apple, so they open like any other app.

**AgentPad → Check for Updates…** shows what is new and installs the update in place: AgentPad quits, updates itself and relaunches, keeping its macOS permissions. Versions 1.0.4 and older can only point you to the new DMG; install 1.0.5 by hand once. If one of those older, unsigned versions does not open, allow it in System Settings → Privacy & Security → **Open Anyway**.

### Build from source

Requirements:

- macOS 14.5 or later on Apple Silicon;
- Xcode 26 or later (Swift 6.2).

```sh
git clone https://github.com/4kulia/agentpad.git
cd agentpad
./scripts/setup-libghostty.sh        # one time: fetch the libghostty xcframework
./scripts/build-app.sh               # writes dist/AgentPad.app
cp -R dist/AgentPad.app /Applications
```

On first use, macOS asks for a few permissions, each when it is first needed:

- notifications;
- control of Terminal or iTerm2, to bring a session's tab to the front;
- access to protected folders.

AgentPad runs alongside an installed kooky. It uses its own bundle id (`com.4kulia.agentpad`), its own settings (`~/.agentpad/settings.json`) and its own support folder (`~/Library/Application Support/agentpad`).

## Develop

```sh
swift build
swift run                            # dev build
swift test                           # 1100+ unit tests
```

AgentPad's own code lives in `Sources/AgentPadKit/AgentPad/`. Changes to files inherited from kooky are kept to small hooks marked `AgentPad:`. The `main` branch tracks upstream kooky; development happens on `agentpad`. Upstream's name is replaced throughout by `scripts/rebrand.py`, which is re-applied to each upstream update before it is merged, so the rename itself never conflicts.

## Command line

`agentpad-cli` drives a running AgentPad: open tabs, run commands, resume conversations, list, focus or close tabs.

```sh
agentpad-cli open --cwd ~/project --agent claude-code     # new tab running an agent
agentpad-cli open --cwd ~/project -e "npm run dev"        # new tab running a command
agentpad-cli resume --agent codex --id <conversation-id>  # reopen a conversation
agentpad-cli list --json                                  # windows → workspaces → tabs, with ids
agentpad-cli focus --tab <session-uuid>
agentpad-cli status                                       # exit code 1 when AgentPad isn't running
```

The binary ships inside the app. AgentPad refreshes a stable copy at `~/Library/Application Support/agentpad/bin/agentpad-cli` on every launch. Deep links use the `agentpad://` scheme:

```
agentpad://resume?agent=<agent-id>&id=<conversation-id>&cwd=<abs-path>
```

## Credits

AgentPad is built on [kooky](https://github.com/iAmCorey/kooky) by [Corey Chiu](https://coreychiu.com). The terminal itself is [Ghostty](https://ghostty.org)'s engine. Thank you both.

## License

MIT — see [LICENSE](LICENSE). Bundled third-party assets keep their upstream licenses; see [NOTICE.md](NOTICE.md).
