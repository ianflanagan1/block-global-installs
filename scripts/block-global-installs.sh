#!/bin/bash
# PreToolUse hook for Bash, Edit, Write and MultiEdit. It blocks commands that install software
# globally on this machine: tools belong in a project's devbox.json (devbox add) or global devbox
# (devbox global add). It also blocks changes to the Go toolchain pin, and to the checksum and
# flag settings beside it, that go-ianf-strict-baseline writes into a project's devbox.json: a command that
# sets or unsets them, go env -w/-u, go get toolchain@/go@, and edits of devbox.json that change them.
# Exit 2 blocks the tool call and shows stderr to Claude. Without jq it can't read the
# call, so it lets it through with a visible error (exit 1) rather than block every call.

jq=$(command -v jq || echo /usr/bin/jq)
if [ ! -x "$jq" ]; then
    echo "block-global-installs: jq not found, so global installs and the Go toolchain pin are not being checked" >&2
    exit 1
fi

input=$(cat)
field() { printf '%s' "$input" | "$jq" --raw-output "$1"; }

# The settings go-ianf-strict-baseline pins in devbox.json, as a whole word.
PIN_VAR='(^|[^[:alnum:]_])(GOTOOLCHAIN|GOSUMDB|GONOSUMDB|GONOSUMCHECK|GOPRIVATE|GOINSECURE|GOFLAGS)([^[:alnum:]_]|$)'

block_pin() {
    echo "Blocked: $1 would change or override the Go toolchain pin or the checksum and flag settings beside it. The Go toolchain is pinned by go-ianf-strict-baseline: bump go-ianf-strict-baseline and run \`go tool go-ianf-strict-baseline write\`, or ask the user." >&2
    exit 2
}

# pin_lines text: the lines of text that set a pinned setting, trimmed and without a trailing comma.
pin_lines() {
    printf '%s\n' "$1" | grep --extended-regexp "$PIN_VAR" \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]*,?[[:space:]]*$//' | sort
}

tool=$(field '.tool_name // empty')
case $tool in
    Edit | MultiEdit | Write)
        file=$(field '.tool_input.file_path // empty')
        [ "$(basename -- "$file")" = devbox.json ] || exit 0
        if [ "$tool" = Write ]; then
            before=$(cat -- "$file" 2>/dev/null)
            after=$(field '.tool_input.content // empty')
        else
            before=$(field '[.tool_input.old_string // empty, (.tool_input.edits // [])[].old_string] | join("\n")')
            after=$(field '[.tool_input.new_string // empty, (.tool_input.edits // [])[].new_string] | join("\n")')
        fi
        [ "$(pin_lines "$before")" = "$(pin_lines "$after")" ] || block_pin "this edit of devbox.json"
        exit 0
        ;;
esac

cmd=$(field '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

# Start of a command word: line start or a non-name character (so /opt/homebrew/bin/brew still matches).
B='(^|[^[:alnum:]_.-])'
END='([[:space:]]|$)'

block() {
    echo "Blocked: $1 can install software globally. Add it to the project's devbox.json (devbox add <pkg>) or global devbox (devbox global add <pkg>), and ask the user before doing either." >&2
    exit 2
}

# Checks that need the pipe intact.
if printf '%s' "$cmd" | grep --extended-regexp --quiet "${B}(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|fi)?sh${END}"; then
    block "piping a download into a shell"
fi
if printf '%s' "$cmd" | grep --extended-regexp --quiet "${B}(ba|z)?sh[[:space:]]+-c[[:space:]]+[\"']?\\\$\((curl|wget)"; then
    block "running a downloaded script"
fi

# A pip install is project-local when it targets a virtualenv or runs inside devbox.
pip_is_local=false
if printf '%s' "$cmd" | grep --extended-regexp --quiet '(devbox (run|shell)|\.venv/|venv/bin/|uv pip|poetry |pipenv )'; then
    pip_is_local=true
fi

# A shell edit of devbox.json counts when the command names a pinned setting or a Go release.
mentions_pin=false
if printf '%s' "$cmd" | grep --extended-regexp --quiet "${PIN_VAR}|go1\.[0-9]"; then
    mentions_pin=true
fi

while IFS= read -r seg; do
    matches() { printf '%s' "$seg" | grep --extended-regexp --quiet "$1"; }

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

    matches "${B}(GOTOOLCHAIN|GOSUMDB|GONOSUMDB|GONOSUMCHECK|GOPRIVATE|GOINSECURE|GOFLAGS)=" && block_pin "setting a Go toolchain, checksum or flag variable"
    if matches "${B}(unset|env[[:space:]].*(-u|--unset)|go[[:space:]]+env[[:space:]].*-[wu])${END}" && matches "$PIN_VAR"; then
        block_pin "unsetting a Go toolchain, checksum or flag variable, or go env -w/-u of one,"
    fi
    matches "${B}go[[:space:]]+get[[:space:]](.*[[:space:]])?(toolchain|go)@" && block_pin "go get of a toolchain or go version"
    if [ "$mentions_pin" = true ] \
        && matches "(>[[:space:]]*[^[:space:]]*|${B}(tee|sponge|mv|cp)[[:space:]].*|${B}(sed|perl)[[:space:]](.*[[:space:]])?(-[[:alpha:]]*i|--in-place).*)devbox\.json"; then
        block_pin "a shell edit of devbox.json"
    fi
done < <(printf '%s\n' "$cmd" | tr ';&|' '\n')

exit 0
