import Foundation

enum ShellCommandIntegration {
    static let keySequence = "\u{18}\u{1F}"
    static let titlePrefix = "agentpad-shell-control:"

    enum Event: String { case available, finished }

    static func parseTitle(_ title: String) -> (event: Event, pid: pid_t)? {
        guard title.hasPrefix(titlePrefix) else { return nil }
        let parts = title.dropFirst(titlePrefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let event = Event(rawValue: String(parts[0])),
              let pid = pid_t(parts[1]), pid > 0 else { return nil }
        return (event, pid)
    }

    // The key invokes an editor widget; its helper fetches the command over
    // the hook socket, never from stdin. Keystrokes remain queued for the
    // editor while the widget runs, so they cannot become part of an eval.
    static let zsh = #"""
    _agentpad_unset_proxy() { unset "$@"; }
    _agentpad_shell_control_available() { printf '\e]2;agentpad-shell-control:available:%s\a' "$$"; }
    _agentpad_shell_control_status() { return "$1"; }
    _agentpad_shell_control() {
        local _agentpad_control_text _agentpad_control_hook _agentpad_control_status
        local _agentpad_control_buffer=$BUFFER _agentpad_control_cursor=$CURSOR
        if _agentpad_control_text=$("$AGENTPAD_HOOK_BIN" shell-command "$$" </dev/null) && [[ -n "$_agentpad_control_text" ]]; then
            zle -I
            eval "$_agentpad_control_text"
            _agentpad_control_status=$?
            # Rebuild cached prompts (vcs_info / Starship / p10k) before
            # repainting. Skip our own prompt/command markers: the draft
            # was not submitted and this is not a new command boundary.
            for _agentpad_control_hook in precmd "${precmd_functions[@]}"; do
                [[ $_agentpad_control_hook == _agentpad_* || $_agentpad_control_hook == __agentpad_* ]] && continue
                (( ${+functions[$_agentpad_control_hook]} )) || continue
                _agentpad_shell_control_status "$_agentpad_control_status"
                "$_agentpad_control_hook" || break
            done
            _agentpad_env_status
            _agentpad_osc7_pwd
            BUFFER=$_agentpad_control_buffer
            CURSOR=$_agentpad_control_cursor
            zle reset-prompt
        fi
        printf '\e]2;agentpad-shell-control:finished:%s\a' "$$"
    }
    zle -N _agentpad_shell_control
    for _agentpad_keymap in main emacs viins vicmd; do
        bindkey -M "$_agentpad_keymap" '^X^_' _agentpad_shell_control
    done
    unset _agentpad_keymap
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _agentpad_shell_control_available
    """#

    static let bash = #"""
    _agentpad_unset_proxy() { unset "$@"; }
    _agentpad_shell_control_available() { printf '\e]2;agentpad-shell-control:available:%s\a' "$$"; }
    _agentpad_shell_control() {
        local _agentpad_control_text
        if _agentpad_control_text=$("$AGENTPAD_HOOK_BIN" shell-command "$$" </dev/null) && [[ -n "$_agentpad_control_text" ]]; then
            printf '\n'
            eval "$_agentpad_control_text"
            _agentpad_env_status
            _agentpad_osc7_pwd
        fi
        # Bash 3.2 caches Readline's expanded prompt during bind -x. Keep
        # the draft intact; its next normal prompt refreshes PS1 as usual.
        printf '\e]2;agentpad-shell-control:finished:%s\a' "$$"
    }
    for _agentpad_keymap in emacs-standard vi-insert vi-command; do
        bind -m "$_agentpad_keymap" -x '"\C-x\C-_":_agentpad_shell_control'
    done
    unset _agentpad_keymap
    """#

    static let fish = #"""
    function _agentpad_unset_proxy
        for _agentpad_proxy in $argv
            set -eg $_agentpad_proxy
            # An exported empty global masks an exported universal value in
            # child processes; an unexported global still leaks the universal.
            # Keep the persistent value intact for other terminals.
            if set -qU $_agentpad_proxy
                set -gx $_agentpad_proxy ''
            end
        end
    end
    function __agentpad_shell_control
        set -l _agentpad_control_text ("$AGENTPAD_HOOK_BIN" shell-command $fish_pid </dev/null)
        if test -n "$_agentpad_control_text"
            printf '\n'
            eval $_agentpad_control_text
            __agentpad_env_status
            __agentpad_prompt
            commandline -f repaint
        end
        printf '\e]2;agentpad-shell-control:finished:%s\a' $fish_pid
    end
    function __agentpad_shell_control_available --on-event fish_prompt
        bind -M default \cx\c_ __agentpad_shell_control
        bind -M insert \cx\c_ __agentpad_shell_control
        printf '\e]2;agentpad-shell-control:available:%s\a' $fish_pid
    end
    """#
}
