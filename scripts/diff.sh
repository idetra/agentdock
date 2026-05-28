#!/usr/bin/env bash
# diff.sh: detailed line-by-line diff for one tracked item.
# Usage: diff.sh <tool> [global flags] <path>

set -euo pipefail

_self_dir() {
  local src="$0" dir
  while [ -L "$src" ]; do
    dir="$(cd "$(dirname "$src")" && pwd -P)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  cd "$(dirname "$src")" && pwd -P
}
SELF_DIR="$(_self_dir)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
# shellcheck source=../lib/common.sh
. "$REPO_ROOT/lib/common.sh"

check_jq

TOOL="${1:-}"
[ -z "$TOOL" ] && die "Usage: diff.sh <tool> [options] <path>"
shift

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

init_flags

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

TARGET_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      cat <<EOF
Usage: agentdock $TOOL diff [options] <path>

Show a line-by-line diff for one tracked item with resolution hints.

Arguments:
  <path>   path relative to the live config directory

Options:
  -h, --help
  --no-color
EOF
      exit 0 ;;
    --no-color) COLOR_DISABLED=1 ;;
    -*) die "Unknown flag: $1. Run 'agentdock $TOOL diff --help'." ;;
    *)
      if [ -z "$TARGET_PATH" ]; then
        TARGET_PATH="$1"
      else
        die "diff accepts exactly one path argument. Got extra: $1"
      fi ;;
  esac
  shift
done

init_colors

[ -z "$TARGET_PATH" ] && die "Usage: agentdock $TOOL diff <path>"

validate_tool "$TOOL"

MANIFEST="$(get_manifest_path "$TOOL")"
BASE_DIR="$(get_base_dir "$TOOL")"
PERSONAL_DIR="$(get_personal_dir "$TOOL")"
TARGET_DIR="$(get_target_dir "$TOOL")"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_diff() {
  local label_a="$1"
  local label_b="$2"
  local file_a="$3"
  local file_b="$4"

  if [ ! -f "$file_a" ] && [ ! -f "$file_b" ]; then
    info "Both files absent: $label_a and $label_b"
    return 0
  fi

  local a_arg="/dev/null"
  local b_arg="/dev/null"
  [ -f "$file_a" ] && a_arg="$file_a"
  [ -f "$file_b" ] && b_arg="$file_b"

  if [ "$COLOR_DISABLED" = "0" ] && [ -t 1 ] && command -v diff >/dev/null 2>&1; then
    diff --label "$label_a" --label "$label_b" -u "$a_arg" "$b_arg" | \
      awk '
        /^\+/ && !/^\+\+\+/ { printf "\033[92m%s\033[0m\n", $0; next }
        /^-/  && !/^---/   { printf "\033[91m%s\033[0m\n", $0; next }
        /^@@/              { printf "\033[36m%s\033[0m\n", $0; next }
        { print }
      ' || true
  else
    diff --label "$label_a" --label "$label_b" -u "$a_arg" "$b_arg" || true
  fi
}

# ---------------------------------------------------------------------------
# Find which category and type this path belongs to
# ---------------------------------------------------------------------------

find_category_for_path() {
  local rel="$1"
  while IFS= read -r cat; do
    while IFS= read -r pattern; do
      local name_part dir_part
      name_part="${pattern##*/}"
      dir_part="${pattern%/*}"
      [ "$dir_part" = "$pattern" ] && dir_part=""

      # Match exact file
      if [ "$pattern" = "$rel" ]; then
        printf '%s' "$cat"
        return 0
      fi

      # Match glob
      local rel_dir="${rel%/*}"
      [ "$rel_dir" = "$rel" ] && rel_dir=""
      local rel_name="${rel##*/}"

      case "$name_part" in
        "**")
          if [ -z "$dir_part" ] || [ "$rel_dir" = "$dir_part" ] || \
             case "$rel_dir" in "$dir_part/"*) true ;; *) false ;; esac; then
            printf '%s' "$cat"
            return 0
          fi ;;
        *)
          if [ "$rel_dir" = "$dir_part" ]; then
            case "$rel_name" in
              $name_part)
                printf '%s' "$cat"
                return 0 ;;
            esac
          fi ;;
      esac
    done < <(get_category_files "$MANIFEST" "$cat")
  done < <(get_categories "$MANIFEST")
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CAT="$(find_category_for_path "$TARGET_PATH" || true)"
if [ -z "$CAT" ]; then
  warn "Path '$TARGET_PATH' does not match any category in the manifest."
  warn "Showing raw diff between personal and live anyway."
  run_diff "personal/$TARGET_PATH" "live/$TARGET_PATH" \
    "$PERSONAL_DIR/$TARGET_PATH" "$TARGET_DIR/$TARGET_PATH"
  exit 0
fi

CAT_TYPE="$(get_category_type "$MANIFEST" "$CAT")"

printf '%bDiff for: %s  (category: %s, type: %s)%b\n\n' \
  "$GRAY" "$TARGET_PATH" "$CAT" "$CAT_TYPE" "$RESET"

case "$CAT_TYPE" in
  sentinel)
    local_start="$(get_sentinel_start "$MANIFEST" "$CAT")"
    local_end="$(get_sentinel_end "$MANIFEST" "$CAT")"

    BASE_FILE="$BASE_DIR/$TARGET_PATH"
    PERSONAL_FILE="$PERSONAL_DIR/$TARGET_PATH"
    LIVE_FILE="$TARGET_DIR/$TARGET_PATH"

    # Build expected
    EXPECTED_TMP="$(mktemp)"
    if [ -f "$BASE_FILE" ] && [ -f "$PERSONAL_FILE" ]; then
      do_sentinel_inject "$BASE_FILE" "$PERSONAL_FILE" "$EXPECTED_TMP" \
        "$local_start" "$local_end"
    elif [ -f "$BASE_FILE" ]; then
      cp "$BASE_FILE" "$EXPECTED_TMP"
    elif [ -f "$PERSONAL_FILE" ]; then
      printf '%s\n' "$local_start" > "$EXPECTED_TMP"
      cat "$PERSONAL_FILE" >> "$EXPECTED_TMP"
      printf '%s\n' "$local_end" >> "$EXPECTED_TMP"
    fi

    printf '%bbase + personal (expected)  vs  live:%b\n' "$GRAY" "$RESET"
    run_diff "expected ($TARGET_PATH)" "live ($TARGET_PATH)" \
      "$EXPECTED_TMP" "$LIVE_FILE"
    rm -f "$EXPECTED_TMP"

    printf '\n%bTo resolve:%b\n' "$GRAY" "$RESET"
    if [ ! -f "$LIVE_FILE" ]; then
      printf "  run 'agentdock %s apply %s' to deploy\n" "$TOOL" "$TARGET_PATH"
    else
      printf "  run 'agentdock %s apply %s' to overwrite live with expected\n" "$TOOL" "$TARGET_PATH"
      printf "  run 'agentdock %s capture %s' to record live changes to personal\n" "$TOOL" "$TARGET_PATH"
    fi
    ;;

  merge)
    BASE_FILE="$BASE_DIR/$TARGET_PATH"
    SNIPPET="$PERSONAL_DIR/${TARGET_PATH%.json}.snippet.json"
    LIVE_FILE="$TARGET_DIR/$TARGET_PATH"
    jq_lib="$(read_jq_lib)"

    EXPECTED_TMP="$(mktemp)"
    if [ -f "$BASE_FILE" ] && [ -f "$SNIPPET" ]; then
      jq -n \
        --slurpfile _base "$BASE_FILE" \
        --slurpfile _snip "$SNIPPET" \
        "$jq_lib deepmerge(\$_base[0]; \$_snip[0])" > "$EXPECTED_TMP"
    elif [ -f "$SNIPPET" ]; then
      cp "$SNIPPET" "$EXPECTED_TMP"
    elif [ -f "$BASE_FILE" ]; then
      cp "$BASE_FILE" "$EXPECTED_TMP"
    fi

    # Pretty-print for readability
    EXPECTED_PRETTY="$(mktemp)"
    LIVE_PRETTY="$(mktemp)"
    jq '.' "$EXPECTED_TMP" > "$EXPECTED_PRETTY" 2>/dev/null || cp "$EXPECTED_TMP" "$EXPECTED_PRETTY"
    jq '.' "$LIVE_FILE" > "$LIVE_PRETTY" 2>/dev/null || cp "$LIVE_FILE" "$LIVE_PRETTY"

    printf '%bbase + snippet (expected)  vs  live:%b\n' "$GRAY" "$RESET"
    run_diff "expected ($TARGET_PATH)" "live ($TARGET_PATH)" \
      "$EXPECTED_PRETTY" "$LIVE_PRETTY"
    rm -f "$EXPECTED_TMP" "$EXPECTED_PRETTY" "$LIVE_PRETTY"

    printf '\n%bTo resolve:%b\n' "$GRAY" "$RESET"
    printf "  run 'agentdock %s apply %s' to overwrite live with expected\n" "$TOOL" "$TARGET_PATH"
    printf "  run 'agentdock %s capture %s' to update snippet from live\n" "$TOOL" "$TARGET_PATH"
    ;;

  copy)
    BASE_FILE="$BASE_DIR/$TARGET_PATH"
    PERSONAL_FILE="$PERSONAL_DIR/$TARGET_PATH"
    LIVE_FILE="$TARGET_DIR/$TARGET_PATH"

    EXPECTED="$PERSONAL_FILE"
    [ ! -f "$EXPECTED" ] && EXPECTED="$BASE_FILE"

    printf '%bexpected  vs  live:%b\n' "$GRAY" "$RESET"
    run_diff "expected ($TARGET_PATH)" "live ($TARGET_PATH)" \
      "$EXPECTED" "$LIVE_FILE"

    printf '\n%bTo resolve:%b\n' "$GRAY" "$RESET"
    printf "  run 'agentdock %s apply %s' to overwrite live with expected\n" "$TOOL" "$TARGET_PATH"
    printf "  run 'agentdock %s capture %s' to save live version to personal\n" "$TOOL" "$TARGET_PATH"
    ;;
esac
