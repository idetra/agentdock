#!/usr/bin/env bash
# status.sh: color-coded overview of what's in sync, drifted, pending, etc.
# Usage: status.sh <tool> [global flags]

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
[ -z "$TOOL" ] && die "Usage: status.sh <tool> [options]"
shift

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

init_flags
SHOW_CONTENTS=0

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      cat <<EOF
Usage: agentdock $TOOL status [options]

Show a color-coded overview of sync state for every tracked item.

Options:
  -h, --help
  -v, --verbose
  -q, --quiet
  -c, --show-contents   print each tracked file's live contents after its row
  --only <categories>
  --skip <categories>
  --no-color

States:
  $(printf '✓') (gray)   in sync, from base
  $(printf '✓') (green)  in sync, from personal
  +  (bright green)  pending apply (in personal, not yet on machine)
  -  (red)           missing (expected on machine but absent)
  ~  (yellow)        drift (machine differs from merged expected)
  ?  (yellow italic) uncaptured (on machine, not in base or personal)
  $(printf '⚠') (magenta)   duplicate (same value in base and personal)
EOF
      exit 0 ;;
    -v|--verbose) VERBOSE=1 ;;
    -q|--quiet) QUIET=1 ;;
    -c|--show-contents) SHOW_CONTENTS=1 ;;
    --only) shift; ONLY_CATS="$1" ;;
    --skip) shift; SKIP_CATS="$1" ;;
    --no-color) COLOR_DISABLED=1 ;;
    -*) die "Unknown flag: $1. Run 'agentdock $TOOL status --help'." ;;
  esac
  shift
done

validate_flags
init_colors

validate_tool "$TOOL"

MANIFEST="$(get_manifest_path "$TOOL")"
BASE_DIR="$(get_base_dir "$TOOL")"
PERSONAL_DIR="$(get_personal_dir "$TOOL")"
TARGET_DIR="$(get_target_dir "$TOOL")"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------

CNT_SYNC_BASE=0
CNT_SYNC_PERSONAL=0
CNT_PENDING=0
CNT_MISSING=0
CNT_DRIFT=0
CNT_UNCAPTURED=0
CNT_DUPLICATE=0

# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

print_row() {
  local symbol="$1"
  local color="$2"
  local label="$3"
  printf '%b%-2s%b  %s\n' "$color" "$symbol" "$RESET" "$label"
}

# print_contents_if_enabled <file>: when --show-contents is set, print the
# file's contents indented with a gray gutter. No-op if the flag is off or
# the file doesn't exist.
print_contents_if_enabled() {
  [ "$SHOW_CONTENTS" = "1" ] || return 0
  local f="$1"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  printf '%b' "$DIM"
  sed 's/^/    │ /' "$f"
  # If the file doesn't end with a newline, add one so the next row aligns.
  if [ -n "$(tail -c1 "$f" 2>/dev/null)" ]; then
    printf '\n'
  fi
  printf '%b' "$RESET"
}

# ---------------------------------------------------------------------------
# State computation helpers
# ---------------------------------------------------------------------------

# build_expected_sentinel <base_file> <personal_file> <start> <end>
# Prints to stdout the content that apply would produce.
build_expected_sentinel() {
  local base_file="$1"
  local personal_file="$2"
  local sentinel_start="$3"
  local sentinel_end="$4"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$base_file" ] && [ -f "$personal_file" ]; then
    do_sentinel_inject "$base_file" "$personal_file" "$tmp" "$sentinel_start" "$sentinel_end"
  elif [ -f "$personal_file" ]; then
    printf '%s\n' "$sentinel_start" > "$tmp"
    cat "$personal_file" >> "$tmp"
    printf '%s\n' "$sentinel_end" >> "$tmp"
  elif [ -f "$base_file" ]; then
    cp "$base_file" "$tmp"
  fi
  cat "$tmp"
  rm -f "$tmp"
}

check_sentinel_state() {
  local rel="$1"
  local sentinel_start="$2"
  local sentinel_end="$3"
  local base_file="$BASE_DIR/$rel"
  local personal_file="$PERSONAL_DIR/$rel"
  local live_file="$TARGET_DIR/$rel"

  local has_base=0 has_personal=0 has_live=0
  [ -f "$base_file" ]     && has_base=1
  [ -f "$personal_file" ] && has_personal=1
  [ -f "$live_file" ]     && has_live=1

  # Check for duplicate: personal content identical to base content
  if [ "$has_base" = "1" ] && [ "$has_personal" = "1" ]; then
    if cmp -s "$base_file" "$personal_file" 2>/dev/null; then
      print_row "$(printf '⚠')" "$MAGENTA" "$rel  (duplicate: personal identical to base)"
      print_contents_if_enabled "$live_file"
      CNT_DUPLICATE=$((CNT_DUPLICATE + 1))
      return
    fi
  fi

  if [ "$has_personal" = "0" ] && [ "$has_base" = "1" ]; then
    if [ "$has_live" = "1" ]; then
      if cmp -s "$base_file" "$live_file" 2>/dev/null; then
        print_row "$(printf '✓')" "$GRAY" "$rel"
        print_contents_if_enabled "$live_file"
        CNT_SYNC_BASE=$((CNT_SYNC_BASE + 1))
      else
        print_row "~" "$YELLOW" "$rel  (drift: live differs from base)"
        print_contents_if_enabled "$live_file"
        CNT_DRIFT=$((CNT_DRIFT + 1))
      fi
    else
      print_row "-" "$RED" "$rel  (missing from machine)"
      CNT_MISSING=$((CNT_MISSING + 1))
    fi
    return
  fi

  if [ "$has_personal" = "1" ]; then
    if [ "$has_live" = "0" ]; then
      print_row "+" "$BRIGHT_GREEN" "$rel  (pending apply)"
      CNT_PENDING=$((CNT_PENDING + 1))
      return
    fi

    # Compare live with what apply would produce
    local expected_tmp
    expected_tmp="$(mktemp)"
    if [ "$has_base" = "1" ]; then
      do_sentinel_inject "$base_file" "$personal_file" "$expected_tmp" \
        "$sentinel_start" "$sentinel_end"
    else
      # no base file: apply just copies personal verbatim (no sentinel wrapping).
      # mirror that here so status does not falsely report drift.
      cp "$personal_file" "$expected_tmp"
    fi

    if cmp -s "$expected_tmp" "$live_file" 2>/dev/null; then
      print_row "$(printf '✓')" "$GREEN" "$rel"
      print_contents_if_enabled "$live_file"
      CNT_SYNC_PERSONAL=$((CNT_SYNC_PERSONAL + 1))
    else
      print_row "~" "$YELLOW" "$rel  (drift: live differs from base+personal)"
      print_contents_if_enabled "$live_file"
      CNT_DRIFT=$((CNT_DRIFT + 1))
    fi
    rm -f "$expected_tmp"
    return
  fi

  # Nothing in base or personal: uncaptured if in live
  if [ "$has_live" = "1" ]; then
    print_row "?" "${YELLOW}${ITALIC}" "$rel  (uncaptured)"
    print_contents_if_enabled "$live_file"
    CNT_UNCAPTURED=$((CNT_UNCAPTURED + 1))
  fi
}

check_merge_state() {
  local rel="$1"
  local base_file="$BASE_DIR/$rel"
  local personal_snippet="$PERSONAL_DIR/${rel%.json}.snippet.json"
  local live_file="$TARGET_DIR/$rel"

  local has_base=0 has_snippet=0 has_live=0
  [ -f "$base_file" ]        && has_base=1
  [ -f "$personal_snippet" ] && has_snippet=1
  [ -f "$live_file" ]        && has_live=1

  if [ "$has_live" = "0" ]; then
    if [ "$has_snippet" = "1" ] || [ "$has_base" = "1" ]; then
      print_row "+" "$BRIGHT_GREEN" "$rel  (pending apply)"
      CNT_PENDING=$((CNT_PENDING + 1))
    fi
    return
  fi

  # Live exists but nothing tracked: uncaptured
  if [ "$has_base" = "0" ] && [ "$has_snippet" = "0" ]; then
    print_row "?" "${YELLOW}${ITALIC}" "$rel  (uncaptured)"
    print_contents_if_enabled "$live_file"
    CNT_UNCAPTURED=$((CNT_UNCAPTURED + 1))
    return
  fi

  # Build expected merged result
  local expected_tmp
  expected_tmp="$(mktemp)"
  local jq_lib
  jq_lib="$(read_jq_lib)"

  if [ "$has_base" = "1" ] && [ "$has_snippet" = "1" ]; then
    jq -n \
      --slurpfile _base "$base_file" \
      --slurpfile _snip "$personal_snippet" \
      "$jq_lib deepmerge(\$_base[0]; \$_snip[0])" \
      > "$expected_tmp" 2>/dev/null || true
  elif [ "$has_snippet" = "1" ]; then
    cp "$personal_snippet" "$expected_tmp"
  elif [ "$has_base" = "1" ]; then
    cp "$base_file" "$expected_tmp"
  fi

  # Check for duplicate: snippet content already in base
  if [ "$has_base" = "1" ] && [ "$has_snippet" = "1" ]; then
    local diff_result
    diff_result="$(jq -n \
      --slurpfile base "$base_file" \
      --slurpfile snippet "$personal_snippet" \
      "$jq_lib diff(\$base[0]; \$snippet[0])" 2>/dev/null || echo "{}")"
    if [ "$diff_result" = "{}" ] || [ "$diff_result" = "[]" ]; then
      print_row "$(printf '⚠')" "$MAGENTA" "$rel  (duplicate: snippet identical to base)"
      print_contents_if_enabled "$live_file"
      CNT_DUPLICATE=$((CNT_DUPLICATE + 1))
      rm -f "$expected_tmp"
      return
    fi
  fi

  # Compare live with expected
  local live_norm expected_norm
  live_norm="$(jq -cS '.' "$live_file" 2>/dev/null || true)"
  expected_norm="$(jq -cS '.' "$expected_tmp" 2>/dev/null || true)"
  rm -f "$expected_tmp"

  if [ "$live_norm" = "$expected_norm" ]; then
    if [ "$has_snippet" = "1" ]; then
      print_row "$(printf '✓')" "$GREEN" "$rel"
      print_contents_if_enabled "$live_file"
      CNT_SYNC_PERSONAL=$((CNT_SYNC_PERSONAL + 1))
    else
      print_row "$(printf '✓')" "$GRAY" "$rel"
      print_contents_if_enabled "$live_file"
      CNT_SYNC_BASE=$((CNT_SYNC_BASE + 1))
    fi
  else
    print_row "~" "$YELLOW" "$rel  (drift)"
    print_contents_if_enabled "$live_file"
    CNT_DRIFT=$((CNT_DRIFT + 1))
  fi
}

check_copy_state() {
  local rel="$1"
  local base_file="$BASE_DIR/$rel"
  local personal_file="$PERSONAL_DIR/$rel"
  local live_file="$TARGET_DIR/$rel"

  local has_base=0 has_personal=0 has_live=0
  [ -f "$base_file" ]     && has_base=1
  [ -f "$personal_file" ] && has_personal=1
  [ -f "$live_file" ]     && has_live=1

  # Duplicate: same content in base and personal
  if [ "$has_base" = "1" ] && [ "$has_personal" = "1" ]; then
    if cmp -s "$base_file" "$personal_file" 2>/dev/null; then
      print_row "$(printf '⚠')" "$MAGENTA" "$rel  (duplicate: personal identical to base)"
      print_contents_if_enabled "$live_file"
      CNT_DUPLICATE=$((CNT_DUPLICATE + 1))
      return
    fi
  fi

  local expected_file="$personal_file"
  [ "$has_personal" = "0" ] && expected_file="$base_file"

  if [ "$has_live" = "0" ]; then
    if [ "$has_personal" = "1" ] || [ "$has_base" = "1" ]; then
      print_row "+" "$BRIGHT_GREEN" "$rel  (pending apply)"
      CNT_PENDING=$((CNT_PENDING + 1))
    fi
    return
  fi

  if [ "$has_personal" = "1" ] || [ "$has_base" = "1" ]; then
    if cmp -s "$expected_file" "$live_file" 2>/dev/null; then
      if [ "$has_personal" = "1" ]; then
        print_row "$(printf '✓')" "$GREEN" "$rel"
        print_contents_if_enabled "$live_file"
        CNT_SYNC_PERSONAL=$((CNT_SYNC_PERSONAL + 1))
      else
        print_row "$(printf '✓')" "$GRAY" "$rel"
        print_contents_if_enabled "$live_file"
        CNT_SYNC_BASE=$((CNT_SYNC_BASE + 1))
      fi
    else
      print_row "~" "$YELLOW" "$rel  (drift)"
      print_contents_if_enabled "$live_file"
      CNT_DRIFT=$((CNT_DRIFT + 1))
    fi
  else
    # In live but not in base or personal
    print_row "?" "${YELLOW}${ITALIC}" "$rel  (uncaptured)"
    print_contents_if_enabled "$live_file"
    CNT_UNCAPTURED=$((CNT_UNCAPTURED + 1))
  fi
}

# ---------------------------------------------------------------------------
# Category processors
# ---------------------------------------------------------------------------

status_sentinel_cat() {
  local cat="$1"
  local sentinel_start sentinel_end
  sentinel_start="$(get_sentinel_start "$MANIFEST" "$cat")"
  sentinel_end="$(get_sentinel_end "$MANIFEST" "$cat")"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue

    local seen_rels=""

    while IFS= read -r base_file; do
      [ -z "$base_file" ] && continue
      local rel
      rel="$(relative_path "$base_file" "$BASE_DIR")"
      seen_rels="$seen_rels
$rel"
      check_sentinel_state "$rel" "$sentinel_start" "$sentinel_end"
    done < <(find_matching_files "$BASE_DIR" "$pattern")

    # Personal-only files (no base counterpart)
    while IFS= read -r personal_file; do
      [ -z "$personal_file" ] && continue
      local rel
      rel="$(relative_path "$personal_file" "$PERSONAL_DIR")"
      case "$seen_rels" in
        *"
$rel
"*|"$rel
"*|*"
$rel") continue ;;
      esac
      seen_rels="$seen_rels
$rel"
      check_sentinel_state "$rel" "$sentinel_start" "$sentinel_end"
    done < <(find_matching_files "$PERSONAL_DIR" "$pattern")

    # Uncaptured live files: present in target dir but not in base or personal
    local name_part dir_part
    name_part="${pattern##*/}"
    dir_part="${pattern%/*}"
    [ "$dir_part" = "$pattern" ] && dir_part=""
    local live_search="$TARGET_DIR"
    [ -n "$dir_part" ] && live_search="$TARGET_DIR/$dir_part"

    [ -d "$live_search" ] || continue

    while IFS= read -r live_file; do
      [ -z "$live_file" ] && continue
      local rel
      rel="$(relative_path "$live_file" "$TARGET_DIR")"
      case "$seen_rels" in
        *"
$rel
"*|"$rel
"*|*"
$rel") continue ;;
      esac
      [ -f "$BASE_DIR/$rel" ]     && continue
      [ -f "$PERSONAL_DIR/$rel" ] && continue
      check_sentinel_state "$rel" "$sentinel_start" "$sentinel_end"
      seen_rels="$seen_rels
$rel"
    done < <(
      if [ "$name_part" = "**" ]; then
        find "$live_search" -type f 2>/dev/null | sort
      else
        find "$live_search" -maxdepth 1 -name "$name_part" -type f 2>/dev/null | sort
      fi
    )
  done < <(get_category_files "$MANIFEST" "$cat")
}

status_merge_cat() {
  local cat="$1"
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    check_merge_state "$pattern"
  done < <(get_category_files "$MANIFEST" "$cat")
}

status_copy_cat() {
  local cat="$1"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue

    local seen_rels=""

    # Check all base files
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      local rel
      rel="$(relative_path "$f" "$BASE_DIR")"
      seen_rels="$seen_rels
$rel"
      check_copy_state "$rel"
    done < <(find_matching_files "$BASE_DIR" "$pattern")

    # Check personal-only files
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      local rel
      rel="$(relative_path "$f" "$PERSONAL_DIR")"
      case "$seen_rels" in
        *"
$rel
"*|"$rel
"*|*"
$rel") continue ;;
      esac
      check_copy_state "$rel"
    done < <(find_matching_files "$PERSONAL_DIR" "$pattern")

    # Check uncaptured live files
    local name_part dir_part
    name_part="${pattern##*/}"
    dir_part="${pattern%/*}"
    [ "$dir_part" = "$pattern" ] && dir_part=""
    local live_search="$TARGET_DIR"
    [ -n "$dir_part" ] && live_search="$TARGET_DIR/$dir_part"

    [ -d "$live_search" ] || continue

    while IFS= read -r f; do
      [ -z "$f" ] && continue
      local rel
      rel="$(relative_path "$f" "$TARGET_DIR")"
      case "$seen_rels" in
        *"
$rel
"*|"$rel
"*|*"
$rel") continue ;;
      esac
      # Only flag as uncaptured if not in base or personal
      [ -f "$BASE_DIR/$rel" ]     && continue
      [ -f "$PERSONAL_DIR/$rel" ] && continue
      print_row "?" "${YELLOW}${ITALIC}" "$rel  (uncaptured)"
      print_contents_if_enabled "$f"
      CNT_UNCAPTURED=$((CNT_UNCAPTURED + 1))
      seen_rels="$seen_rels
$rel"
    done < <(
      if [ "$name_part" = "**" ]; then
        find "$live_search" -type f 2>/dev/null | sort
      else
        find "$live_search" -maxdepth 1 -name "$name_part" -type f 2>/dev/null | sort
      fi
    )

  done < <(get_category_files "$MANIFEST" "$cat")
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

printf '%bStatus: agentdock %s -> %s%b\n\n' "$GRAY" "$TOOL" "$TARGET_DIR" "$RESET"

while IFS= read -r cat; do
  should_process_category "$cat" || continue
  local_type="$(get_category_type "$MANIFEST" "$cat")"

  printf '%b[%s]%b\n' "$GRAY" "$cat" "$RESET"

  case "$local_type" in
    sentinel) status_sentinel_cat "$cat" ;;
    merge) status_merge_cat "$cat" ;;
    copy) status_copy_cat "$cat" ;;
    *) warn "Unknown type '$local_type' for '$cat'." ;;
  esac

  printf '\n'
done < <(get_categories "$MANIFEST")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

TOTAL_CLEAN=$((CNT_SYNC_BASE + CNT_SYNC_PERSONAL))
printf 'Summary:\n'
[ "$TOTAL_CLEAN" -gt 0 ]       && printf '%b  ✓  %3d in sync%b\n' "$GRAY" "$TOTAL_CLEAN" "$RESET"
[ "$CNT_PENDING" -gt 0 ]       && printf '%b  +  %3d pending apply%b       run '\''apply'\'' to deploy\n' "$BRIGHT_GREEN" "$CNT_PENDING" "$RESET"
[ "$CNT_MISSING" -gt 0 ]       && printf '%b  -  %3d missing%b              run '\''apply'\'' to restore\n' "$RED" "$CNT_MISSING" "$RESET"
[ "$CNT_DRIFT" -gt 0 ]         && printf '%b  ~  %3d drift%b                run '\''capture'\'' to record, or '\''apply'\'' to overwrite\n' "$YELLOW" "$CNT_DRIFT" "$RESET"
[ "$CNT_UNCAPTURED" -gt 0 ]    && printf '%b  ?  %3d uncaptured%b           run '\''capture'\'' to keep, or '\''apply'\'' to discard\n' "$YELLOW" "$CNT_UNCAPTURED" "$RESET"
[ "$CNT_DUPLICATE" -gt 0 ]     && printf '%b  ⚠  %3d duplicate%b            run '\''capture --tidy'\'' to remove from personal\n' "$MAGENTA" "$CNT_DUPLICATE" "$RESET"

if [ "$((TOTAL_CLEAN + CNT_PENDING + CNT_MISSING + CNT_DRIFT + CNT_UNCAPTURED + CNT_DUPLICATE))" -eq 0 ]; then
  printf '%b  Nothing tracked yet. Add files to base/ or personal/ then run apply.%b\n' "$GRAY" "$RESET"
fi
