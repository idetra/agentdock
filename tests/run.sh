#!/usr/bin/env bash
# Test runner for agentdock. Uses temporary directories so nothing touches ~/.claude.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
REAL_REPO_ROOT="$REPO_ROOT"
FIXTURES="$SELF_DIR/fixtures"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }

assert_file_exists() {
  local file="$1"
  local label="${2:-$file}"
  if [ -f "$file" ]; then
    pass "$label exists"
  else
    fail "$label does not exist"
  fi
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local label="${3:-contains: $pattern}"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label  (in: $file)"
  fi
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  local label="${3:-not contains: $pattern}"
  if ! grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label  (in: $file)"
  fi
}

assert_files_equal() {
  local a="$1"
  local b="$2"
  local label="${3:-files equal}"
  if cmp -s "$a" "$b" 2>/dev/null; then
    pass "$label"
  else
    fail "$label  ($a vs $b)"
  fi
}

assert_json_key() {
  local file="$1"
  local jq_expr="$2"
  local expected="$3"
  local label="${4:-json: $jq_expr == $expected}"
  local actual
  actual="$(jq -r "$jq_expr" "$file" 2>/dev/null || echo "__jq_error__")"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label  (got: $actual)"
  fi
}

# setup_test_adapter <tmp_dir>: create a test adapter at tmp_dir/adapters/claude
setup_test_adapter() {
  local tmp="$1"

  # Repo structure
  mkdir -p "$tmp/adapters/claude/base"
  mkdir -p "$tmp/adapters/claude/personal"
  mkdir -p "$tmp/lib"
  mkdir -p "$tmp/scripts"
  mkdir -p "$tmp/live"

  # Copy lib and scripts from real repo
  find "$REAL_REPO_ROOT/lib" -maxdepth 1 -name "*.sh" -exec cp {} "$tmp/lib/" \;
  find "$REAL_REPO_ROOT/lib" -maxdepth 1 -name "*.jq" -exec cp {} "$tmp/lib/" \;
  find "$REAL_REPO_ROOT/scripts" -maxdepth 1 -name "*.sh" -exec cp {} "$tmp/scripts/" \;
  cp "$REAL_REPO_ROOT/agentdock" "$tmp/agentdock"
  chmod +x "$tmp/agentdock"
  find "$tmp/scripts" -maxdepth 1 -name "*.sh" -exec chmod +x {} \;

  # Minimal manifest
  cat > "$tmp/adapters/claude/manifest.json" <<'EOF'
{
  "tool": "claude",
  "display_name": "Claude Code (test)",
  "target_dir": "__LIVE__",
  "target_dir_env_override": "AGENTDOCK_TEST_LIVE",
  "categories": {
    "memory": {
      "type": "sentinel",
      "files": ["CLAUDE.md"],
      "sentinel_start": "# --- agentdock personal config start ---",
      "sentinel_end": "# --- agentdock personal config end ---"
    },
    "settings": {
      "type": "merge",
      "files": ["settings.json"]
    },
    "skills": {
      "type": "copy",
      "files": ["skills/**"]
    }
  }
}
EOF

  # Copy fixture base and personal
  cp "$FIXTURES/base/CLAUDE.md"       "$tmp/adapters/claude/base/CLAUDE.md"
  cp "$FIXTURES/base/settings.json"   "$tmp/adapters/claude/base/settings.json"
  cp "$FIXTURES/personal/CLAUDE.md"   "$tmp/adapters/claude/personal/CLAUDE.md"
  cp "$FIXTURES/personal/settings.snippet.json" \
                                      "$tmp/adapters/claude/personal/settings.snippet.json"
  mkdir -p "$tmp/adapters/claude/personal/skills"
  cp "$FIXTURES/personal/skills/my-skill.md" \
                                      "$tmp/adapters/claude/personal/skills/my-skill.md"

  export AGENTDOCK_TEST_LIVE="$tmp/live"
  export REPO_ROOT="$tmp"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_apply_sentinel() {
  printf '\n[apply: sentinel]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --only memory

  assert_file_exists "$tmp/live/CLAUDE.md" "CLAUDE.md created"
  assert_file_contains "$tmp/live/CLAUDE.md" "Company Rules" "base content present"
  assert_file_contains "$tmp/live/CLAUDE.md" "My Personal Preferences" "personal content injected"
  assert_file_contains "$tmp/live/CLAUDE.md" \
    "# --- agentdock personal config start ---" "sentinel start present"
  assert_file_contains "$tmp/live/CLAUDE.md" \
    "# --- agentdock personal config end ---" "sentinel end present"

  rm -rf "$tmp"
}

test_apply_merge() {
  printf '\n[apply: merge]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --only settings

  assert_file_exists "$tmp/live/settings.json" "settings.json created"
  assert_json_key "$tmp/live/settings.json" '.theme' "light" "personal theme wins"
  assert_json_key "$tmp/live/settings.json" \
    '[.permissions.allow[] | select(. == "Bash(git:*)")] | length' "1" "base permission kept"
  assert_json_key "$tmp/live/settings.json" \
    '[.permissions.allow[] | select(. == "Bash(pnpm:*)")] | length' "1" "personal permission added"

  rm -rf "$tmp"
}

test_apply_copy() {
  printf '\n[apply: copy]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --only skills

  assert_file_exists "$tmp/live/skills/my-skill.md" "personal skill copied"
  assert_file_contains "$tmp/live/skills/my-skill.md" "my-skill" "skill content correct"

  rm -rf "$tmp"
}

test_apply_dry_run() {
  printf '\n[apply: dry-run]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --dry-run 2>/dev/null || true

  if [ ! -f "$tmp/live/CLAUDE.md" ]; then
    pass "dry-run: CLAUDE.md not written"
  else
    fail "dry-run: CLAUDE.md was written (should not be)"
  fi

  rm -rf "$tmp"
}

test_capture_sentinel() {
  printf '\n[capture: sentinel]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  # First apply, then modify live, then capture
  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --only memory

  # Simulate user editing the sentinel block in live
  cat > "$tmp/live/CLAUDE.md" <<'ENDOFFILE'
# Company Rules

These are the company-wide AI coding assistant guidelines.

Always follow the style guide. Write tests. Keep PRs small.

# --- agentdock personal config start ---
## My Updated Preferences

I now prefer vim over emacs.
# --- agentdock personal config end ---
ENDOFFILE

  # Remove existing personal file to test extraction
  rm -f "$tmp/adapters/claude/personal/CLAUDE.md"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/capture.sh" claude --no-color --only memory

  assert_file_exists "$tmp/adapters/claude/personal/CLAUDE.md" "personal CLAUDE.md created"
  assert_file_contains "$tmp/adapters/claude/personal/CLAUDE.md" \
    "Updated Preferences" "updated content captured"
  assert_file_not_contains "$tmp/adapters/claude/personal/CLAUDE.md" \
    "# --- agentdock" "sentinel markers stripped"

  rm -rf "$tmp"
}

test_capture_merge() {
  printf '\n[capture: merge]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  # Create a live settings.json that has extra personal keys
  mkdir -p "$tmp/live"
  cat > "$tmp/live/settings.json" <<'ENDOFFILE'
{
  "permissions": {
    "allow": ["Bash(git:*)", "Bash(npm:*)", "Bash(docker:*)"],
    "deny": []
  },
  "theme": "dark",
  "customKey": "myValue"
}
ENDOFFILE

  rm -f "$tmp/adapters/claude/personal/settings.snippet.json"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/capture.sh" claude --no-color --only settings

  assert_file_exists "$tmp/adapters/claude/personal/settings.snippet.json" "snippet created"
  assert_json_key "$tmp/adapters/claude/personal/settings.snippet.json" \
    '.customKey' "myValue" "personal-only key captured"

  rm -rf "$tmp"
}

test_remove_sentinel() {
  printf '\n[remove: sentinel]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --only memory

  assert_file_contains "$tmp/live/CLAUDE.md" "My Personal Preferences" "personal present before remove"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/remove.sh" claude --no-color --only memory

  assert_file_exists "$tmp/live/CLAUDE.md" "CLAUDE.md still exists after remove"
  assert_file_contains "$tmp/live/CLAUDE.md" "Company Rules" "base content preserved"
  assert_file_not_contains "$tmp/live/CLAUDE.md" "My Personal Preferences" "personal content removed"

  rm -rf "$tmp"
}

test_remove_copy() {
  printf '\n[remove: copy]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --only skills

  assert_file_exists "$tmp/live/skills/my-skill.md" "skill present before remove"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/remove.sh" claude --no-color --only skills

  if [ ! -f "$tmp/live/skills/my-skill.md" ]; then
    pass "personal-only skill removed from live"
  else
    fail "personal-only skill still in live after remove"
  fi

  rm -rf "$tmp"
}

test_idempotent_apply() {
  printf '\n[apply: idempotent]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --no-backup

  local hash1
  hash1="$(md5 -q "$tmp/live/CLAUDE.md" 2>/dev/null || md5sum "$tmp/live/CLAUDE.md" | cut -d' ' -f1)"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --no-backup

  local hash2
  hash2="$(md5 -q "$tmp/live/CLAUDE.md" 2>/dev/null || md5sum "$tmp/live/CLAUDE.md" | cut -d' ' -f1)"

  if [ "$hash1" = "$hash2" ]; then
    pass "apply is idempotent"
  else
    fail "apply is not idempotent (CLAUDE.md changed on second run)"
  fi

  rm -rf "$tmp"
}

test_status_sentinel_no_base_no_drift() {
  # Regression: when a sentinel category has no base file, apply just copies
  # personal verbatim (no sentinel wrapping). status used to falsely report
  # drift because it constructed an expected file wrapped in sentinel markers.
  printf '\n[status: sentinel with no base file reports sync, not drift]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  rm -f "$tmp/adapters/claude/base/CLAUDE.md"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --only memory --no-backup

  local status_output
  status_output="$(REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/status.sh" claude --no-color --only memory 2>&1)"

  if echo "$status_output" | grep -q "drift"; then
    fail "status falsely reports drift (no base, personal == live)"
  else
    pass "status: no drift reported when personal matches live (no base)"
  fi

  if echo "$status_output" | grep -qE '✓.*CLAUDE\.md'; then
    pass "status: CLAUDE.md reported as in sync"
  else
    fail "status: CLAUDE.md not reported as in sync"
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required to run tests."; exit 1; }

# Detect platform for reporting
case "$(uname -s 2>/dev/null)" in
  Darwin)       PLATFORM="macOS" ;;
  Linux)        PLATFORM="Linux" ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM="Windows (Git Bash)" ;;
  *)            PLATFORM="Unknown ($(uname -s 2>/dev/null))" ;;
esac
printf 'Running agentdock tests on %s...\n' "$PLATFORM"

# Core functionality tests
printf '\n=== Core tests ===\n'
test_apply_sentinel
test_apply_merge
test_apply_copy
test_apply_dry_run
test_capture_sentinel
test_capture_merge
test_remove_sentinel
test_remove_copy
test_idempotent_apply
test_status_sentinel_no_base_no_drift

# Platform compatibility tests
printf '\n=== Platform tests ===\n'
# shellcheck source=tests/platform.sh
. "$SELF_DIR/platform.sh"
test_crlf_base_sentinel
test_crlf_sentinel_extract
test_crlf_sentinel_remove
test_spaces_in_live_path
test_spaces_in_personal_path
test_no_color_env_var
test_no_color_flag
test_piped_output_no_ansi
test_invocation_from_different_cwd
test_symlink_invocation
test_symlink_script_invocation
test_jq_missing_error
test_empty_base_dir
test_empty_personal_dir
test_only_skip_mutual_exclusion
test_dry_run_no_side_effects
test_interactive_non_tty

printf '\n'
printf '%b%d passed%b  ' "\033[32m" "$PASS" "\033[0m"
printf '%b%d failed%b\n' "\033[31m" "$FAIL" "\033[0m"

[ "$FAIL" -eq 0 ]
