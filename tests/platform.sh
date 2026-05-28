#!/usr/bin/env bash
# platform.sh: tests for macOS, Linux, and Windows (Git Bash / WSL) portability.
#
# Sourced by tests/run.sh; uses the same helpers (pass/fail, assert_*, setup_test_adapter)
# and REAL_REPO_ROOT / FIXTURES already defined there.

# ---------------------------------------------------------------------------
# 1. CRLF line endings in the base file (Windows git checkout behavior)
# ---------------------------------------------------------------------------

test_crlf_base_sentinel() {
  printf '\n[CRLF: base CLAUDE.md with Windows line endings]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  # Overwrite base file with CRLF endings
  printf "# Company Rules\r\n\r\nCRLF content here.\r\n" \
    > "$tmp/adapters/claude/base/CLAUDE.md"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --only memory

  assert_file_exists "$tmp/live/CLAUDE.md" "CLAUDE.md created (CRLF base)"
  assert_file_contains "$tmp/live/CLAUDE.md" "Company Rules" "base content present (CRLF base)"
  assert_file_contains "$tmp/live/CLAUDE.md" "My Personal Preferences" \
    "personal content injected (CRLF base)"

  # Output must not contain bare CR characters (normalized to LF)
  if LC_ALL=C grep -qP '\r' "$tmp/live/CLAUDE.md" 2>/dev/null || \
     awk '/\r/ { found=1 } END { exit !found }' "$tmp/live/CLAUDE.md" 2>/dev/null; then
    fail "CRLF base: output still has CR characters"
  else
    pass "CRLF base: output normalized to LF"
  fi

  rm -rf "$tmp"
}

test_crlf_sentinel_extract() {
  printf '\n[CRLF: extract from live file with Windows line endings]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  # Create a live CLAUDE.md with CRLF that includes a sentinel block
  mkdir -p "$tmp/live"
  printf "# Company Rules\r\n\r\n# --- agentdock personal config start ---\r\nMy pref.\r\n# --- agentdock personal config end ---\r\n" \
    > "$tmp/live/CLAUDE.md"

  rm -f "$tmp/adapters/claude/personal/CLAUDE.md"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/capture.sh" claude --no-color --only memory

  assert_file_exists "$tmp/adapters/claude/personal/CLAUDE.md" \
    "personal CLAUDE.md created from CRLF live"
  assert_file_contains "$tmp/adapters/claude/personal/CLAUDE.md" "My pref." \
    "content extracted from CRLF live"
  assert_file_not_contains "$tmp/adapters/claude/personal/CLAUDE.md" \
    "# --- agentdock" "sentinel markers stripped (CRLF)"

  rm -rf "$tmp"
}

test_crlf_sentinel_remove() {
  printf '\n[CRLF: remove sentinel from live file with Windows line endings]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  mkdir -p "$tmp/live"
  printf "# Company Rules\r\n\r\n# --- agentdock personal config start ---\r\nMy pref.\r\n# --- agentdock personal config end ---\r\n" \
    > "$tmp/live/CLAUDE.md"
  cp "$tmp/live/CLAUDE.md" "$tmp/adapters/claude/base/CLAUDE.md"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/remove.sh" claude --no-color --only memory

  assert_file_exists "$tmp/live/CLAUDE.md" "CLAUDE.md still exists after remove (CRLF)"
  assert_file_contains "$tmp/live/CLAUDE.md" "Company Rules" "base content preserved (CRLF)"
  assert_file_not_contains "$tmp/live/CLAUDE.md" "My pref." \
    "personal block removed from CRLF file"

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 2. Spaces in the live directory path
# ---------------------------------------------------------------------------

test_spaces_in_live_path() {
  printf '\n[Spaces: live directory path contains spaces]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  local spaced_live="$tmp/my live dir"
  mkdir -p "$spaced_live"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$spaced_live" \
    bash "$tmp/scripts/apply.sh" claude --no-color

  assert_file_exists "$spaced_live/CLAUDE.md" "CLAUDE.md in path with spaces"
  assert_file_contains "$spaced_live/CLAUDE.md" "My Personal Preferences" \
    "personal content injected (spaced path)"
  assert_file_exists "$spaced_live/skills/my-skill.md" "skill in path with spaces"

  rm -rf "$tmp"
}

test_spaces_in_personal_path() {
  printf '\n[Spaces: personal dir path contains spaces]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  local spaced_personal="$tmp/my personal dir"
  mkdir -p "$spaced_personal"
  cp "$tmp/adapters/claude/personal/CLAUDE.md" "$spaced_personal/CLAUDE.md"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --only memory --from "$spaced_personal"

  assert_file_exists "$tmp/live/CLAUDE.md" "CLAUDE.md created (spaced personal)"
  assert_file_contains "$tmp/live/CLAUDE.md" "My Personal Preferences" \
    "content from spaced personal dir"

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 3. NO_COLOR environment variable
# ---------------------------------------------------------------------------

test_no_color_env_var() {
  printf '\n[Color: NO_COLOR env var disables ANSI codes]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  local output
  output="$(NO_COLOR=1 REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/status.sh" claude 2>&1)"

  # ESC character is \033 (octal 33)
  if printf '%s' "$output" | LC_ALL=C grep -q $'\033'; then
    fail "NO_COLOR: ANSI escape codes still present"
  else
    pass "NO_COLOR: no ANSI escape codes in output"
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 4. --no-color flag
# ---------------------------------------------------------------------------

test_no_color_flag() {
  printf '\n[Color: --no-color flag disables ANSI codes]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  local output
  output="$(REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/status.sh" claude --no-color 2>&1)"

  if printf '%s' "$output" | LC_ALL=C grep -q $'\033'; then
    fail "--no-color: ANSI escape codes still present"
  else
    pass "--no-color: no ANSI escape codes in output"
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 5. Piped output: no ANSI when stdout is not a TTY
# ---------------------------------------------------------------------------

test_piped_output_no_ansi() {
  printf '\n[Color: no ANSI codes when stdout is piped]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  # Redirect to a file (not a TTY); colors.sh checks [ -t 1 ]
  local out_file="$tmp/status_output.txt"
  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/status.sh" claude > "$out_file" 2>&1

  if LC_ALL=C grep -q $'\033' "$out_file" 2>/dev/null; then
    fail "piped: ANSI escape codes present when redirected to file"
  else
    pass "piped: no ANSI escape codes when redirected to file"
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 6. Invocation from a different working directory
# ---------------------------------------------------------------------------

test_invocation_from_different_cwd() {
  printf '\n[Self-locating: scripts work from a different working directory]\n'

  local output exit_code
  output="$(cd / && bash "$REAL_REPO_ROOT/agentdock" --help 2>&1)" && exit_code=0 || exit_code=$?

  if [ "$exit_code" = "0" ] && printf '%s' "$output" | grep -q "agentdock"; then
    pass "self-locating: works when invoked from /"
  else
    fail "self-locating: failed from different cwd (exit $exit_code)"
  fi
}

# ---------------------------------------------------------------------------
# 7. Symlink invocation (important for /usr/local/bin installs)
# ---------------------------------------------------------------------------

test_symlink_invocation() {
  printf '\n[Symlink: dispatcher works when called via a symlink]\n'
  local tmp
  tmp="$(mktemp -d)"

  ln -s "$REAL_REPO_ROOT/agentdock" "$tmp/agentdock-link"

  local output exit_code
  output="$(bash "$tmp/agentdock-link" --help 2>&1)" && exit_code=0 || exit_code=$?

  rm -rf "$tmp"

  if [ "$exit_code" = "0" ] && printf '%s' "$output" | grep -q "agentdock"; then
    pass "symlink: dispatcher works via symlink"
  else
    fail "symlink: dispatcher fails via symlink (exit $exit_code)"
  fi
}

test_symlink_script_invocation() {
  printf '\n[Symlink: apply.sh works when called via a symlink]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  local link_dir="$tmp/bin"
  mkdir -p "$link_dir"
  ln -s "$tmp/scripts/apply.sh" "$link_dir/apply-link.sh"
  chmod +x "$link_dir/apply-link.sh"

  local exit_code
  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$link_dir/apply-link.sh" claude --no-color --only memory && exit_code=0 || exit_code=$?

  if [ "$exit_code" = "0" ] && [ -f "$tmp/live/CLAUDE.md" ]; then
    pass "symlink: apply.sh works via symlink"
  else
    fail "symlink: apply.sh fails via symlink (exit $exit_code)"
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 8. jq not installed: clear error with install hints
# ---------------------------------------------------------------------------

test_jq_missing_error() {
  printf '\n[Dependency: missing jq shows actionable install hints]\n'

  # Place a broken fake jq first in PATH. check_jq runs "jq --version" to
  # verify jq actually works, so a fake that exits 1 triggers the error path.
  local fake_bin
  fake_bin="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' > "$fake_bin/jq"
  chmod +x "$fake_bin/jq"

  local output
  output="$(PATH="$fake_bin:$PATH" bash "$REAL_REPO_ROOT/scripts/apply.sh" claude 2>&1 || true)"
  rm -rf "$fake_bin"

  if printf '%s' "$output" | grep -q "brew install jq\|apt install jq\|choco install jq"; then
    pass "jq missing: shows platform install hints"
  else
    fail "jq missing: no install hints in output"
    printf '  (got: %s)\n' "$output"
  fi
}

# ---------------------------------------------------------------------------
# 9. Empty base directory (personal-only / no company base)
# ---------------------------------------------------------------------------

test_empty_base_dir() {
  printf '\n[Edge case: empty base dir (personal-only mode)]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  # Remove all base files
  rm -f "$tmp/adapters/claude/base/CLAUDE.md" \
        "$tmp/adapters/claude/base/settings.json"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --only memory

  assert_file_exists "$tmp/live/CLAUDE.md" "CLAUDE.md created from personal only"
  assert_file_contains "$tmp/live/CLAUDE.md" "My Personal Preferences" \
    "personal content present (no base)"
  assert_file_not_contains "$tmp/live/CLAUDE.md" "# --- agentdock personal config start ---" \
    "no sentinel wrapper when there is no base file"

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 10. Empty personal directory (base-only mode)
# ---------------------------------------------------------------------------

test_empty_personal_dir() {
  printf '\n[Edge case: empty personal dir (base-only mode)]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  # Remove all personal files
  rm -f "$tmp/adapters/claude/personal/CLAUDE.md" \
        "$tmp/adapters/claude/personal/settings.snippet.json"
  rm -rf "$tmp/adapters/claude/personal/skills"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color

  assert_file_exists "$tmp/live/CLAUDE.md" "CLAUDE.md created from base only"
  assert_file_contains "$tmp/live/CLAUDE.md" "Company Rules" "base content present"
  assert_file_not_contains "$tmp/live/CLAUDE.md" "# --- agentdock personal config start ---" \
    "no sentinel when personal is empty"
  assert_file_exists "$tmp/live/settings.json" "settings.json created from base only"
  assert_json_key "$tmp/live/settings.json" '.theme' "dark" "base theme used when no snippet"

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 11. --only and --skip mutual exclusion
# ---------------------------------------------------------------------------

test_only_skip_mutual_exclusion() {
  printf '\n[Flags: --only and --skip are mutually exclusive]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  local exit_code
  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --only memory --skip settings 2>/dev/null \
    && exit_code=0 || exit_code=$?

  if [ "$exit_code" != "0" ]; then
    pass "--only + --skip: exits with error"
  else
    fail "--only + --skip: should have errored but exited 0"
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 12. Dry-run produces no side effects on any platform
# ---------------------------------------------------------------------------

test_dry_run_no_side_effects() {
  printf '\n[Dry-run: no files written on any platform]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --dry-run > /dev/null 2>&1

  local file_count
  file_count="$(find "$tmp/live" -type f 2>/dev/null | wc -l | tr -d ' ')"

  if [ "$file_count" = "0" ]; then
    pass "dry-run: no files written"
  else
    fail "dry-run: $file_count file(s) written unexpectedly"
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 13. --interactive: confirm prompt skips on non-TTY (no hang)
# ---------------------------------------------------------------------------

test_interactive_non_tty() {
  printf '\n[Interactive: --interactive does not hang on non-TTY stdin]\n'
  local tmp
  tmp="$(mktemp -d)"
  setup_test_adapter "$tmp"

  local exit_code
  # Feed "n" to all prompts via stdin pipe (non-TTY)
  printf 'n\nn\nn\nn\nn\n' | \
    REPO_ROOT="$tmp" AGENTDOCK_TEST_LIVE="$tmp/live" \
    bash "$tmp/scripts/apply.sh" claude --no-color --interactive \
    > /dev/null 2>&1 && exit_code=0 || exit_code=$?

  if [ "$exit_code" = "0" ]; then
    pass "--interactive: completes without hanging on non-TTY"
  else
    fail "--interactive: exited with code $exit_code"
  fi

  rm -rf "$tmp"
}
