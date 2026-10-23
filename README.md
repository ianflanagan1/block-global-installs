# block-global-installs

A Claude Code hook that stops Claude installing software globally on your machine, so tools go into [devbox](https://www.jetify.com/devbox) instead: a project's `devbox.json` (`devbox add`) or global devbox (`devbox global add`).

## What it blocks

The `PreToolUse` hook (`scripts/block-global-installs.sh`) reads every Bash command Claude is about to run and refuses it (exit 2) when it contains:

- brew `install`/`reinstall`/`upgrade`/`tap`/`link`/`bundle`, MacPorts, `mas install`, `installer -pkg`, `softwareupdate -i`
- global npm, pnpm and bun packages (`-g`/`--global`), `yarn global add`
- `pipx install`, `uv tool install`, `cargo install`, `go install`, `gem install`, `composer global require`
- `nix-env -i`, `nix profile install`
- `pip install` outside a virtualenv (a `.venv/` path, `devbox run`, `uv pip`, poetry and pipenv count as inside one)
- a download piped into a shell (`curl … | sh`, `sh -c "$(curl …)"`)
- any `sudo`

The refusal tells Claude to use devbox and to ask you first. Project-local installs (`composer install`, `npm install` without `-g`) and read-only commands (`brew list`, `npm ls -g`) pass.

It checks each part of a chained command (`cd x && brew install y`) and full paths (`/opt/homebrew/bin/brew`). It can't tell a quoted string from a command, so `git commit -m "drop brew install"` is refused too; commit with `-F` and a message file instead.

It needs `jq`. Without it the hook lets every command through and reports an error on each one, so a missing `jq` is visible rather than silently unchecked.

It only limits Claude. Commands you run yourself are unaffected.

## Install

Clone to `~/projects/claude/block-global-installs`, then add the hook to `~/.claude/settings.json`. It runs straight from the clone, so changes to it apply from the next command:

```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "Bash",
      "hooks": [
        {
          "type": "command",
          "command": "bash \"$HOME/projects/claude/block-global-installs/scripts/block-global-installs.sh\""
        }
      ]
    }
  ]
}
```

Pair it with a rule in `~/.claude/CLAUDE.md` saying what to do instead, so Claude reaches for devbox before it hits the hook:

```markdown
## Installing software

Never install software globally on this machine. When a tool is missing, prefer the project's devbox (`devbox add <pkg>`, then `devbox run -- …`), or global devbox (`devbox global add <pkg>`) for tools used across projects. Ask me before either.
```

## Development

```sh
devbox run test   # shunit2
devbox run lint   # shellcheck
```
