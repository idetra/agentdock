# agentdock

A portable personal-overlay system for the configuration directories of agentic coding tools (Claude Code, Codex, Gemini CLI, Cursor, and others). Maintain your personal preferences in a private git repo and apply them on top of any base config distributed by your company, then capture changes back from any machine.

The mental model is kustomize-style overlays for AI agent config.

**License summary.** agentdock is open source under Apache 2.0 with a Commons Clause restriction. You can use it freely for any purpose including internal company use. You may not sell it, offer it as a hosted service, or commercialize it without a separate commercial license. See `LICENSE` and `COMMERCIAL_LICENSE.md`.

---

## Quickstart

Your personal config is sensitive, so you want it in a **private** repo. Do not click "Fork": GitHub will not let you change a fork's visibility later.

Click **"Use this template"** on [github.com/idetra/agentdock](https://github.com/idetra/agentdock) and choose private. That creates a brand-new private repo with no fork relationship.

**First machine** (the one where your `~/.claude/` already has the setup you want to keep):

```bash
git clone git@github.com:<you>/agentdock.git ~/agentdock
cd ~/agentdock
git remote add upstream git@github.com:idetra/agentdock.git
./agentdock claude capture     # pull ~/.claude/ into adapters/claude/personal/
git add -A && git commit -m "capture" && git push
```

**Any other machine** (where you want that setup deployed):

```bash
git clone git@github.com:<you>/agentdock.git ~/agentdock
cd ~/agentdock
git remote add upstream git@github.com:idetra/agentdock.git
./agentdock claude apply       # write adapters/claude/personal/ into ~/.claude/
```

Day-to-day:

- `git pull upstream main` picks up template updates from idetra/agentdock.
- `git pull origin main` and `git push origin main` sync your personal config between your machines.

No installer. `apply` creates `~/.claude/` if needed and backs up anything it overwrites.

---

## The verb model

**apply** reads `adapters/<tool>/base/` and `adapters/<tool>/personal/`, merges them per the manifest, and writes the result to the live config directory. Backs up anything it overwrites to `<file>.bak`.

**capture** reads the live config directory, diffs it against `adapters/<tool>/base/`, and writes the personal delta to `adapters/<tool>/personal/`. Additive only by default (use `--prune` to also remove deleted items).

**remove** re-applies only `adapters/<tool>/base/` to the live config directory, stripping all personal contributions. Use `--keep-added` to leave standalone personal files in place.

**status** shows a color-coded overview of every tracked item: what's in sync, what's drifted, what's pending, and what needs attention.

**diff** shows a line-by-line content diff for one item with explicit hints on how to resolve it.

---

## Status output

```
Status: agentdock claude -> /Users/you/.claude

[memory]
✓  CLAUDE.md
✓  rules/company-rules.md

[settings]
~  settings.json  (drift: live differs from base+personal)

[skills]
+  skills/my-formatter.md  (pending apply)
?  skills/old-tool.md      (uncaptured)

Summary:
  ✓    2 in sync
  +    1 pending apply       run 'apply' to deploy
  ~    1 drift               run 'capture' to record, or 'apply' to overwrite
  ?    1 uncaptured          run 'capture' to keep, or 'apply' to discard
```

State icons (always present even without color):

| Symbol | Meaning |
|--------|---------|
| `✓` gray | from base, present and unchanged |
| `✓` green | from personal, currently on machine |
| `+` bright green | in personal, not yet on machine |
| `-` red | expected on machine but absent |
| `~` yellow | machine differs from base+personal merge |
| `?` yellow | on machine, not in base or personal |
| `⚠` magenta | same value in both base and personal |

---

## Three injection types

### 1. Sentinel blocks (markdown files)

Personal content is embedded inside a base file between sentinel comment lines:

```markdown
# --- agentdock personal config start ---
(your personal content here)
# --- agentdock personal config end ---
```

Used for `CLAUDE.md` and `rules/*.md`. The personal content for these files lives in `personal/<filename>` (just the block content, without the sentinel lines themselves).

### 2. Deep-merge (settings.json)

Personal additions live in `personal/settings.snippet.json`. On apply, agentdock deep-merges base and snippet: objects are merged recursively, arrays are concatenated, scalars favor the snippet. On capture, the inverse: structural diff between live and base is written to the snippet.

### 3. Additive copy (skills, agents, commands)

For files that exist only in personal or only in base. Apply copies them to the live directory; capture copies live files not present in base to personal; remove deletes personal-only files from live.

---

## Adding a new tool adapter

1. Create `adapters/<toolname>/manifest.json` (copy from `adapters/claude/manifest.json` and edit).
2. Create `adapters/<toolname>/base/` and `adapters/<toolname>/personal/` (can be empty).
3. Run `agentdock list` to verify the adapter appears.
4. Run `agentdock <toolname> apply`.

The manifest schema:

```json
{
  "tool": "mytool",
  "display_name": "My Tool",
  "target_dir": "~/.mytool",
  "target_dir_env_override": "MYTOOL_CONFIG_DIR",
  "categories": {
    "memory": {
      "type": "sentinel",
      "files": ["RULES.md"],
      "sentinel_start": "# --- agentdock personal config start ---",
      "sentinel_end": "# --- agentdock personal config end ---"
    },
    "settings": { "type": "merge", "files": ["config.json"] },
    "plugins": { "type": "copy", "files": ["plugins/**"] }
  }
}
```

Category types: `sentinel` (markdown injection), `merge` (JSON deep-merge), `copy` (additive file copy).

---

## Company mode (submodule recipe)

This is a recipe, not a built-in feature.

A company can publish a base config as a git repo. Engineers fork the agentdock template, add the company base as a git submodule at `adapters/claude/base/`, and keep their personal overrides in `adapters/claude/personal/`.

```bash
# One-time setup (inside your private agentdock fork):
git submodule add git@github.com:mycompany/claude-base.git adapters/claude/base

# Pull company updates:
git submodule update --remote adapters/claude/base
git add adapters/claude/base
git commit -m "update company base"

# Re-apply to pick up the new base plus your personal overlay:
./agentdock claude apply
```

This way company updates never overwrite your personal settings; agentdock merges them.

---

## Dependencies

- **bash** 3.2 or later (macOS ships with 3.2; Linux typically has 4+)
- **jq** 1.6 or later (required; install with `brew install jq` or `apt install jq`)
- **sed**, **awk**, **find**, **cp**, **mv**, **diff** (POSIX standard, available everywhere)
- **git** (assumed since the repo is git-distributed)

---

## Cross-platform notes

agentdock works on:

- macOS (Terminal, iTerm2, and any POSIX shell)
- Linux (any distro with bash 3.2+ and jq)
- Windows via Git Bash or WSL (WSL gives a more complete environment)

Windows users should use Git Bash or WSL. PowerShell and cmd.exe are not supported.

---

## CLI reference

```
agentdock                              show help, list adapters
agentdock list                         list configured adapters
agentdock <tool>                       show help for that adapter
agentdock <tool> apply [paths...]      repo -> machine
agentdock <tool> capture [paths...]    machine -> repo
agentdock <tool> remove [paths...]     restore live to base only
agentdock <tool> status                color-coded overview
agentdock <tool> diff <path>           detailed diff for one item

Global options (all verbs):
  -h, --help
  -v, --verbose
  -q, --quiet
  -n, --dry-run
  -i, --interactive
  --only <categories>    comma-separated whitelist (e.g. memory,skills)
  --skip <categories>    comma-separated blacklist
  --no-color             disable ANSI colors (also: set NO_COLOR env var)

apply options:
  --no-backup            skip writing .bak files
  --force                overwrite without prompting
  --from <dir>           use a different source than personal/

capture options:
  --review               open git diff in pager after writing
  --prune                also remove from personal/ items not in live
  --tidy                 remove from personal/ anything identical to base

remove options:
  --restore-backup       prefer .bak files over re-applying base
  --keep-added           keep standalone personal-only files in live

status options:
  -c, --show-contents    print each tracked file's live contents inline
```
