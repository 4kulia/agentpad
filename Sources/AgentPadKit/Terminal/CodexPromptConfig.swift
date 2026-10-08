/// Runs in the tab's live shell, where HOME, cwd and Codex's argv are known.
/// Python's standard TOML parser is optional: no parser (Python < 3.11), an
/// unreadable/invalid layer or an unsupported configuration means no override.
/// Never approximate TOML with regexes or promote untrusted project settings
/// into a trusted CLI override.
enum CodexPromptConfig {
    static let resolverScript = #"""
    import json
    import os
    from pathlib import Path
    import re
    import sys
    import tomllib

    def skip():
        sys.exit(1)

    def read_config(path):
        try:
            with path.open("rb") as source:
                return tomllib.load(source)
        except FileNotFoundError:
            # A dangling symlink is not a missing, optional config.
            if any(p.is_symlink() and not p.exists() for p in (path, *path.parents)):
                skip()
            return {}

    def checked(layer):
        # Profile resolution and alternate instruction files are deliberately
        # left to Codex. Custom roots/trust overrides need its own resolver too.
        if any(key in layer for key in (
            "profile", "model_instructions_file", "experimental_instructions_file",
            "project_root_markers",
        )):
            skip()
        if "developer_instructions" in layer and not isinstance(layer["developer_instructions"], str):
            skip()
        return layer

    def resolve():
        prompt = tomllib.loads(os.environ["AGENTPAD_AGENT_PROMPT_CODEX_CONFIG"])["developer_instructions"]
        if not isinstance(prompt, str) or not prompt:
            skip()
        home = Path(os.environ["HOME"])
        if not home.is_absolute():
            skip()
        home = home.resolve(strict=True)
        codex_home = home / ".codex"
        if "CODEX_HOME" in os.environ and Path(os.environ["CODEX_HOME"]).resolve() != codex_home.resolve():
            skip()
        # Managed defaults cannot be reconstructed from these local layers.
        if (codex_home / "managed_config.toml").exists():
            skip()

        cwd = Path.cwd()
        explicit_cwd = False
        resuming = False
        overrides = []
        positional = False
        args = iter(sys.argv[1:])
        value_options = {
            "-c", "--config", "-C", "--cd", "-m", "--model", "-s", "--sandbox",
            "-a", "--ask-for-approval", "-i", "--image", "--add-dir", "--enable",
            "--disable", "--local-provider",
        }
        switches = {
            "--search", "--oss", "--full-auto", "--dangerously-bypass-approvals-and-sandbox",
            "--no-alt-screen", "--last", "--all",
        }
        commands = {
            "exec", "e", "review", "login", "logout", "mcp", "mcp-server", "plugin",
            "app-server", "remote-control", "app", "completion", "update", "doctor",
            "sandbox", "debug", "apply", "a", "cloud", "exec-server", "features",
            "help", "agents", "queue", "archive", "delete", "migrate-rollouts", "unarchive",
        }
        for arg in args:
            if arg == "--":
                break
            if not arg.startswith("-"):
                if not positional and arg in commands:
                    skip()
                if not positional and arg in ("resume", "fork"):
                    resuming = True
                positional = True
                continue
            if arg in switches:
                continue
            option, separator, value = arg.partition("=")
            if arg.startswith("-") and not arg.startswith("--") and len(arg) > 2:
                option, separator, value = arg[:2], "=", arg[2:].removeprefix("=")
            # Includes every profile spelling, remote launches, help/version,
            # and unknown flags whose effect or arity we cannot safely infer.
            if option not in value_options:
                skip()
            if not separator:
                value = next(args)
            if value == "--":
                skip()
            if option in ("-C", "--cd"):
                cwd = Path(value)
                explicit_cwd = True
            elif option in ("-c", "--config"):
                key, equals, raw = value.partition("=")
                key = key.strip()
                if not equals or not re.fullmatch(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*", key):
                    skip()
                parsed = tomllib.loads("value = " + raw)
                if set(parsed) != {"value"}:
                    skip()
                top = key.split(".")[0]
                if top in ("profile", "profiles", "projects", "project_root_markers",
                           "model_instructions_file", "experimental_instructions_file"):
                    skip()
                if top == "developer_instructions":
                    if key != top or not isinstance(parsed["value"], str):
                        skip()
                    overrides.append(parsed["value"])

        # Resume/fork can switch to the saved session's cwd after startup.
        # Only an explicit --cd makes its project config knowable here.
        if resuming and not explicit_cwd:
            skip()
        cwd = cwd.resolve(strict=True)
        if not cwd.is_dir():
            skip()
        effective = checked(read_config(Path("/etc/codex/config.toml")))
        user_path = codex_home / "config.toml"
        effective.update(checked(read_config(user_path)))

        # Default Codex project boundary: nearest .git directory or worktree
        # pointer. Without a marker, ancestor configs make the scope ambiguous.
        directories = []
        for parent in (cwd, *cwd.parents):
            directories.append(parent)
            if (parent / ".git").exists():
                break
        else:
            for parent in directories[1:]:
                candidate = parent / ".codex/config.toml"
                if candidate != user_path and read_config(candidate):
                    skip()
            directories = [cwd]

        projects = effective.get("projects", {})
        trust = projects.get(str(cwd), projects.get(str(directories[-1]), {})).get("trust_level")
        for parent in reversed(directories):
            path = parent / ".codex/config.toml"
            if path == user_path:
                continue
            layer = checked(read_config(path))
            if layer:
                # Trust may still be awaiting Codex's interactive confirmation.
                # In that case let Codex decide without our CLI override.
                if trust != "trusted":
                    skip()
                effective.update(layer)

        existing = overrides[-1] if overrides else effective.get("developer_instructions", "")
        combined = existing + "\n\n" + prompt if existing else prompt
        # JSON's basic-string escapes are TOML-compatible, except surrogate
        # pairs and unescaped DEL. Preserve Unicode and escape DEL explicitly.
        encoded = json.dumps(combined, ensure_ascii=False).replace("\x7f", "\\u007f")
        sys.stdout.write("developer_instructions=" + encoded)

    try:
        resolve()
    except Exception:
        # Do not print config contents, environment values or parser errors.
        skip()
    """#
}
