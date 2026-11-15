# Work and personal AI profiles on macOS

How two Claude setups and two Codex setups (Desktop and CLI for each) run side by side under a work and a personal account on one Mac, and how `ccu` attributes their usage. This page is for both people and AI assistants (Claude Code, Codex).

Account emails, account and org UUIDs, the `ccu` endpoint and every token live only in the Private repository and in each tool's own state. They are never written here.

## Profile map

| Tool | Account | Launcher | State | Transcripts |
|---|---|---|---|---|
| Claude Desktop | work | `/Applications/Claude.app` | `~/Library/Application Support/Claude` | Code tab: `~/.claude/projects`. Cowork: `.../Claude/local-agent-mode-sessions` |
| Claude Desktop | personal | `~/Applications/Claude Personal.app` → `~/.local/bin/claude-app-personal` | `~/Library/Application Support/Claude-Personal` | Code tab: `~/.claude/projects` (shared). Cowork: `.../Claude-Personal/local-agent-mode-sessions` |
| Claude Code CLI | personal | `claude` | `~/.claude`, `~/.claude.json` | `~/.claude/projects` |
| Claude Code CLI | personal (spare) | `claudep` alias, `~/.local/bin/claude-personal` | `~/.claude-personal` (holds its own `.claude.json`) | `~/.claude-personal/projects` |
| Codex Desktop | work | `/Applications/ChatGPT.app` | `CODEX_HOME=~/.codex`; Electron `.../Codex` | `~/.codex/sessions`, `archived_sessions` |
| Codex Desktop | personal | `~/Applications/Codex Personal.app` → `~/.local/bin/codex-app-personal` | `CODEX_HOME=~/.codex-personal`; Electron `.../Codex-Personal` | `~/.codex-personal/sessions`, `archived_sessions` |
| Codex CLI | work | `codex` | `~/.codex` | `~/.codex/sessions` |
| Codex CLI | personal | `codexp` alias, `~/.local/bin/codex-personal` | `~/.codex-personal` | `~/.codex-personal/sessions` |

The default `claude` CLI is signed in to the **personal** account on purpose. Work Claude usage comes from Claude Desktop (work). Codex is the opposite: the default `~/.codex` is work.

`~/Library/Application Support/Claude-3p` holds only a `claude_desktop_config.json` and no sessions.

## Isolation mechanisms

| Layer | Mechanism | What it isolates |
|---|---|---|
| Claude Code CLI | `CLAUDE_CONFIG_DIR` | Whole state tree including `.claude.json` (MCP servers, trust, `oauthAccount`). Credentials go to a keychain item named `Claude Code-credentials-<hash>` per config dir. |
| Claude Desktop | Electron `--user-data-dir` | `config.json` holds the encrypted OAuth token cache. The `Claude Safe Storage` keychain item is only the AES key and is shared harmlessly. |
| Codex CLI and Desktop | `CODEX_HOME` | `auth.json`, `config.toml`, MCP, sessions, history |
| Codex Desktop window state | `--user-data-dir` + `CODEX_ELECTRON_USER_DATA_PATH` | Electron state for the second instance |

This is account and state isolation, not a security boundary. Everything runs as the same Unix user and shares TCC grants.

### Launchers

```bash
# ~/.local/bin/claude-app-personal
UDD="$HOME/Library/Application Support/Claude-Personal"
CH="$HOME/.codex-personal"
mkdir -p "$UDD"
exec /usr/bin/open -n --env CODEX_HOME="$CH" -a /Applications/Claude.app --args --user-data-dir="$UDD"

# ~/.local/bin/codex-app-personal
CH="$HOME/.codex-personal"
UDD="$HOME/Library/Application Support/Codex-Personal"
mkdir -p "$CH" "$UDD"
exec /usr/bin/open -n --env CODEX_HOME="$CH" --env CODEX_ELECTRON_USER_DATA_PATH="$UDD" \
  -a /Applications/ChatGPT.app --args --user-data-dir="$UDD"

# ~/.local/bin/claude-personal and codex-personal export CLAUDE_CONFIG_DIR / CODEX_HOME, then exec the CLI.
# ~/.zshrc
alias claudep='CLAUDE_CONFIG_DIR="$HOME/.claude-personal" claude'
alias codexp='CODEX_HOME="$HOME/.codex-personal" codex'
```

`~/Applications/Claude Personal.app` and `Codex Personal.app` are minimal bundles whose `Contents/MacOS/launch` execs the matching script (`LSUIElement` set, so only the real app shows in the Dock).

### Behaviors that are easy to get wrong

- **Both Desktop instances write Code tab transcripts to `~/.claude/projects`.** Desktop starts its embedded `claude` with `CLAUDE_CODE_ENTRYPOINT=claude-desktop` and an injected `CLAUDE_CODE_OAUTH_TOKEN`, but no `CLAUDE_CONFIG_DIR`. Both instances therefore also run the hooks in `~/.claude/settings.json`, never `~/.claude-personal/settings.json`.
- **Desktop records which account ran each Code tab session** in `claude-code-sessions/<accountUuid>/<orgUuid>/local_<id>.json`, naming the transcript's `cliSessionId`. That record is the only reliable way to split the shared folder by account.
- **Codex called from Claude Code** (Codex plugin, originator `Claude Code`) uses whatever `CODEX_HOME` the Desktop instance passes. The personal launcher sets `~/.codex-personal`; work Desktop falls back to `~/.codex`. This only applies when Claude Personal is started through its launcher.
- **Run the personal CLI from a project or `~/personal`, not from `~`.** From `~`, Claude Code treats `~/.claude/` as workspace config and pulls in the default profile's permissions and `CLAUDE.md`.
- **Codex transcripts do not record the account,** only `rate_limits.plan_type` per call (work is `team`, personal is `pro`) and an `originator` (`Codex Desktop`, `codex-tui`, `Claude Code`).

## Usage tracking with ccu

`ccu` (`~/.claude-usage/ccu.mjs`, Node 20+, 22.15+ for compressed Codex sessions) reads transcripts incrementally and uploads hourly and five-minute token buckets. Transcript text is never uploaded. Its config (`~/.claude-usage/config.json`: endpoint, token, machine name, `accounts` map) is private.

### Attribution

| Source | Account comes from |
|---|---|
| `~/.claude/projects`, entrypoint `cli` | `oauthAccount.emailAddress` in the active `.claude.json`, read at sync time |
| `~/.claude/projects`, entrypoint `claude-desktop` | The Desktop session record's account UUID, mapped to an email `ccu` has learned |
| Cowork | `emailAddress` in the Cowork session record |
| Codex | `email` claim in the `id_token` of `$CODEX_HOME/auth.json`, overridden per call by `plan:<type>` entries in `accounts` |

The `accounts` map labels each email (and `plan:pro`) as `work` or `personal`. Because the CLI and Codex are labeled at read time, a re-login between syncs mislabels that window. Already-uploaded history is never relabeled.

### Coverage

| Trigger | Environment | Covers |
|---|---|---|
| Stop hook in `~/.claude/settings.json` | default | `~/.claude/projects` (CLI + both Desktop instances), every `Claude*` Desktop folder, `~/.codex` |
| Stop hook in `~/.claude-personal/settings.json` | `CLAUDE_CONFIG_DIR=~/.claude-personal`, `CODEX_HOME=~/.codex-personal` | `~/.claude-personal/projects`, `~/.codex-personal` |
| `com.claude-usage.sync` LaunchAgent, every 900 s | default | same as default Stop hook; logs to `~/.claude-usage/sync.log` |
| `com.claude-usage.sync.personal` LaunchAgent, every 900 s | personal env as above | same as personal Stop hook; logs to `~/.claude-usage/sync.personal.log` |

Hook command shape (`--background` returns immediately and syncs in a detached process):

```bash
'/opt/homebrew/opt/node@24/bin/node' "$HOME/.claude-usage/ccu.mjs" sync --background
/usr/bin/env CODEX_HOME="$HOME/.codex-personal" CLAUDE_CONFIG_DIR="$HOME/.claude-personal" \
  '/opt/homebrew/opt/node@24/bin/node' "$HOME/.claude-usage/ccu.mjs" sync --background
```

Codex has no per-turn hook (`notify` in `config.toml` is used by Codex Computer Use), so it relies on the LaunchAgents.

Do not set `CCU_CLAUDE_DESKTOP_DIR` in the personal environment. Both environments share `~/.claude-usage/state.json`, and narrowing the Desktop folders makes each personal run delete the work instance's session records, which the next default run re-reads.

## Verification

```bash
# Which account each profile is signed in to (prints emails only, no tokens)
python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.claude.json")))["oauthAccount"]["emailAddress"])'
python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.claude-personal/.claude.json")))["oauthAccount"]["emailAddress"])'
for h in ~/.codex ~/.codex-personal; do python3 -c 'import json,sys,base64;t=json.load(open(sys.argv[1]+"/auth.json"))["tokens"]["id_token"].split(".")[1];t+="="*(-len(t)%4);j=json.loads(base64.urlsafe_b64decode(t));print(sys.argv[1],j["email"],j["https://api.openai.com/auth"]["chatgpt_plan_type"])' "$h"; done

# Both Desktop instances and whether their Claude Code children carry CODEX_HOME (names only)
pgrep -fl 'Claude.app/Contents/MacOS/Claude'
for p in $(pgrep -f 'claude-code/.*/claude.app/Contents/MacOS/claude'); do ps eww -o command= -p "$p" | tr ' ' '\n' | grep -oE '^(CLAUDE_CONFIG_DIR|CODEX_HOME)='; done

# ccu, once per environment: accounts and anything waiting to upload
node ~/.claude-usage/ccu.mjs status
CODEX_HOME=~/.codex-personal CLAUDE_CONFIG_DIR=~/.claude-personal node ~/.claude-usage/ccu.mjs status

# Scheduled jobs
launchctl print gui/$(id -u)/com.claude-usage.sync | grep -E 'state|last exit'
launchctl print gui/$(id -u)/com.claude-usage.sync.personal | grep -E 'state|last exit|CODEX_HOME|CLAUDE_CONFIG_DIR'
```

Expected `ccu status`: default shows Claude Code = personal, Codex = work; personal shows both = personal; the `desktop:` line maps one account UUID to `work` and one to `personal`.

## Teardown (personal side)

Quit the personal instances first.

```bash
launchctl bootout gui/$(id -u)/com.claude-usage.sync.personal
rm ~/Library/LaunchAgents/com.claude-usage.sync.personal.plist
rm -rf ~/Library/Application\ Support/Claude-Personal ~/Library/Application\ Support/Codex-Personal
rm -rf ~/.claude-personal ~/.codex-personal
rm -rf ~/Applications/Claude\ Personal.app ~/Applications/Codex\ Personal.app
rm -f ~/.local/bin/{claude,codex}-personal ~/.local/bin/{claude,codex}-app-personal
# remove the claudep and codexp aliases from ~/.zshrc
```
