#!/bin/bash
# PreToolUse hook for Bash: blocks commands that install software globally on this machine.
# Tools belong in a project's devbox.json (devbox add) or global devbox (devbox global add).
# Exit 2 blocks the tool call and shows stderr to Claude. Without jq it can't read the
# command, so it lets the call through with a visible error (exit 1) rather than block every command.

jq=$(command -v jq || echo /usr/bin/jq)
if [ ! -x "$jq" ]; then
    echo "block-global-installs: jq not found, so global installs are not being checked" >&2
    exit 1
fi

cmd=$("$jq" -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

# Start of a command word: line start or a non-name character (so /opt/homebrew/bin/brew still matches).
B='(^|[^[:alnum:]_.-])'
END='([[:space:]]|$)'

block() {
    echo "Blocked: $1 can install software globally. Add it to the project's devbox.json (devbox add <pkg>) or global devbox (devbox global add <pkg>), and ask the user before doing either." >&2
    exit 2
}

# Checks that need the pipe intact.
if printf '%s' "$cmd" | grep -Eq "${B}(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|fi)?sh${END}"; then
    block "piping a download into a shell"
fi
if printf '%s' "$cmd" | grep -Eq "${B}(ba|z)?sh[[:space:]]+-c[[:space:]]+[\"']?\\\$\((curl|wget)"; then
    block "running a downloaded script"
fi

# A pip install is project-local when it targets a virtualenv or runs inside devbox.
pip_is_local=false
if printf '%s' "$cmd" | grep -Eq '(devbox (run|shell)|\.venv/|venv/bin/|uv pip|poetry |pipenv )'; then
    pip_is_local=true
fi

while IFS= read -r seg; do
    matches() { printf '%s' "$seg" | grep -Eq "$1"; }

    matches "${B}sudo${END}" && block "sudo"
    matches "${B}brew[[:space:]]+(install|reinstall|upgrade|tap|link|bundle)${END}" && block "brew"
    matches "${B}port[[:space:]]+install${END}" && block "MacPorts"
    matches "${B}mas[[:space:]]+(install|upgrade)${END}" && block "mas"
    matches "${B}(installer[[:space:]].*-pkg|softwareupdate[[:space:]].*(-i|--install))${END}" && block "a macOS installer"
    matches "${B}(nix-env[[:space:]]+(-i|--install|-iA)|nix[[:space:]]+profile[[:space:]]+(install|add))${END}" && block "nix profile"
    if matches "${B}(npm|pnpm|bun)[[:space:]]" && matches "[[:space:]](-g|--global)${END}" \
        && matches "[[:space:]](install|i|add|link|update|upgrade)${END}"; then
        block "a global npm/pnpm/bun package"
    fi
    matches "${B}yarn[[:space:]]+global[[:space:]]+(add|upgrade)${END}" && block "yarn global"
    matches "${B}pipx[[:space:]]+install${END}" && block "pipx"
    matches "${B}uv[[:space:]]+tool[[:space:]]+install${END}" && block "uv tool"
    if [ "$pip_is_local" = false ] \
        && matches "${B}(pip[0-9.]*|python[0-9.]*[[:space:]]+-m[[:space:]]+pip)[[:space:]]+install${END}"; then
        block "pip outside a virtualenv"
    fi
    matches "${B}cargo[[:space:]]+install${END}" && block "cargo install"
    matches "${B}go[[:space:]]+install${END}" && block "go install"
    matches "${B}gem[[:space:]]+install${END}" && block "gem install"
    matches "${B}composer[[:space:]]+global[[:space:]]+(require|install|update)${END}" && block "composer global"
done < <(printf '%s\n' "$cmd" | tr ';&|' '\n')

exit 0
