#!/usr/bin/env bash
# capture.sh: read live config, diff against base, write delta to personal/.
# Usage: capture.sh <tool> [global flags] [capture flags] [paths...]

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
[ -z "$TOOL" ] && die "Usage: capture.sh <tool> [options] [paths...]"
shift

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

init_flags
CAPTURE_REVIEW=0
CAPTURE_PRUNE=0
CAPTURE_TIDY=0

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      cat <<EOF
Usage: agentdock $TOOL capture [options] [paths...]

Capture live config changes back to personal/. Additive by default.

Options:
  -h, --help
  -v, --verbose
  -q, --quiet
  -n, --dry-run         print the plan, change nothing
  -i, --interactive     confirm each change
  --only <categories>   comma-separated whitelist
  --skip <categories>   comma-separated blacklist
  --no-color
  --review              open git diff in pager after writing
  --prune               also remove items from personal/ not in live
  --tidy                remove from personal/ anything identical to base

Paths: if given, restrict to those files/dirs.
EOF
      exit 0 ;;
    -v|--verbose) VERBOSE=1 ;;
    -q|--quiet) QUIET=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -i|--interactive) INTERACTIVE=1 ;;
    --only) shift; ONLY_CATS="$1" ;;
    --skip) shift; SKIP_CATS="$1" ;;
    --no-color) COLOR_DISABLED=1 ;;
    --review) CAPTURE_REVIEW=1 ;;
    --prune) CAPTURE_PRUNE=1 ;;
    --tidy) CAPTURE_TIDY=1 ;;
    --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done; break ;;
    -*) die "Unknown flag: $1. Run 'agentdock $TOOL capture --help'." ;;
    *) POSITIONAL+=("$1") ;;
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
# Path filter
# ---------------------------------------------------------------------------

path_is_requested() {
  local rel="$1"
  [ "${#POSITIONAL[@]}" -eq 0 ] && return 0
  local p
  for p in "${POSITIONAL[@]}"; do
    case "$rel" in
      "$p"|"$p/"*) return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# Per-type capture handlers
# ---------------------------------------------------------------------------

capture_sentinel_cat() {
  local cat="$1"
  local sentinel_start sentinel_end
  sentinel_start="$(get_sentinel_start "$MANIFEST" "$cat")"
  sentinel_end="$(get_sentinel_end "$MANIFEST" "$cat")"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue

    local seen_rels=""

    # Process files that exist in base (sentinel injection targets)
    while IFS= read -r base_file; do
      [ -z "$base_file" ] && continue
      local rel
      rel="$(relative_path "$base_file" "$BASE_DIR")"
      seen_rels="$seen_rels
$rel"
      path_is_requested "$rel" || continue

      local live_file="$TARGET_DIR/$rel"
      local personal_file="$PERSONAL_DIR/$rel"

      [ -f "$live_file" ] || { verbose_log "Skipped (not in live): $rel"; continue; }

      if ! grep -qF "$sentinel_start" "$live_file" 2>/dev/null; then
        verbose_log "No sentinel block in live: $rel"
        continue
      fi

      if [ "$DRY_RUN" = "1" ]; then
        info "[dry-run] extract sentinel: $rel"
        continue
      fi

      if [ "$INTERACTIVE" = "1" ]; then
        confirm "Capture sentinel from $rel?" || continue
      fi

      do_sentinel_extract "$live_file" "$personal_file" "$sentinel_start" "$sentinel_end"
      verbose_log "Extracted sentinel: $rel"

      # --tidy: remove if now identical to base
      if [ "$CAPTURE_TIDY" = "1" ] && [ -f "$personal_file" ]; then
        if [ ! -s "$personal_file" ]; then
          rm -f "$personal_file"
          verbose_log "Tidied (empty): $personal_file"
        fi
      fi
    done < <(find_matching_files "$BASE_DIR" "$pattern")

    # Capture live-only files (no base counterpart): treat whole file as personal
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
      [ -f "$BASE_DIR/$rel" ] && continue
      path_is_requested "$rel" || continue

      local personal_file="$PERSONAL_DIR/$rel"

      if [ "$DRY_RUN" = "1" ]; then
        info "[dry-run] capture sentinel (no base): $rel"
        continue
      fi

      if [ "$INTERACTIVE" = "1" ]; then
        confirm "Capture $rel as personal (no base exists)?" || continue
      fi

      ensure_dir "$(dirname "$personal_file")"

      # If the live file happens to contain sentinel markers, extract just the
      # block; otherwise the whole file is personal content.
      if grep -qF "$sentinel_start" "$live_file" 2>/dev/null; then
        do_sentinel_extract "$live_file" "$personal_file" "$sentinel_start" "$sentinel_end"
      else
        cp "$live_file" "$personal_file"
      fi
      verbose_log "Captured (no base): $rel"
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

capture_merge_cat() {
  local cat="$1"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue

    local rel="$pattern"
    path_is_requested "$rel" || continue

    local base_file="$BASE_DIR/$rel"
    local live_file="$TARGET_DIR/$rel"
    local personal_snippet="$PERSONAL_DIR/${rel%.json}.snippet.json"

    [ -f "$live_file" ] || { verbose_log "Skipped (not in live): $rel"; continue; }

    if [ "$DRY_RUN" = "1" ]; then
      info "[dry-run] compute settings diff: $rel"
      continue
    fi

    if [ "$INTERACTIVE" = "1" ]; then
      confirm "Capture settings diff from $rel?" || continue
    fi

    local jq_lib
    jq_lib="$(read_jq_lib)"

    ensure_dir "$(dirname "$personal_snippet")"

    if [ -f "$base_file" ]; then
      jq -n \
        --slurpfile base "$base_file" \
        --slurpfile live "$live_file" \
        "$jq_lib diff(\$base[0]; \$live[0])" \
        > "$personal_snippet"
    else
      cp "$live_file" "$personal_snippet"
    fi

    # --tidy: remove if snippet is empty
    if [ "$CAPTURE_TIDY" = "1" ]; then
      local snippet_content
      snippet_content="$(jq -c '.' "$personal_snippet" 2>/dev/null || true)"
      if [ "$snippet_content" = "{}" ] || [ "$snippet_content" = "[]" ] || [ -z "$snippet_content" ]; then
        rm -f "$personal_snippet"
        verbose_log "Tidied (no personal additions): $personal_snippet"
      fi
    fi

    verbose_log "Captured settings diff: $rel"
  done < <(get_category_files "$MANIFEST" "$cat")
}

capture_copy_cat() {
  local cat="$1"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue

    # Find all files in the live dir under this pattern's directory
    local name_part dir_part
    name_part="${pattern##*/}"
    dir_part="${pattern%/*}"
    [ "$dir_part" = "$pattern" ] && dir_part=""

    local live_search_dir="$TARGET_DIR"
    [ -n "$dir_part" ] && live_search_dir="$TARGET_DIR/$dir_part"

    [ -d "$live_search_dir" ] || continue

    local find_args=("-type" "f")
    case "$name_part" in
      "**") : ;;  # no extra filter
      *)    find_args+=("-name" "$name_part") ;;
    esac

    local depth_arg=""
    case "$name_part" in
      "**") : ;;
      *) depth_arg="-maxdepth 1" ;;
    esac

    while IFS= read -r live_file; do
      [ -z "$live_file" ] && continue
      local rel
      rel="$(relative_path "$live_file" "$TARGET_DIR")"
      path_is_requested "$rel" || continue

      # Only capture files not already in base
      local base_file="$BASE_DIR/$rel"
      [ -f "$base_file" ] && continue

      local personal_file="$PERSONAL_DIR/$rel"

      if [ "$DRY_RUN" = "1" ]; then
        info "[dry-run] capture copy: $rel"
        continue
      fi

      if [ "$INTERACTIVE" = "1" ]; then
        confirm "Capture $rel?" || continue
      fi

      ensure_dir "$(dirname "$personal_file")"
      cp "$live_file" "$personal_file"
      verbose_log "Captured: $rel"
    done < <(
      if [ "$name_part" = "**" ]; then
        find "$live_search_dir" -type f 2>/dev/null | sort
      else
        find "$live_search_dir" -maxdepth 1 -name "$name_part" -type f 2>/dev/null | sort
      fi
    )

    # --prune: remove from personal/ anything not present in live
    if [ "$CAPTURE_PRUNE" = "1" ]; then
      while IFS= read -r personal_file; do
        [ -z "$personal_file" ] && continue
        local rel
        rel="$(relative_path "$personal_file" "$PERSONAL_DIR")"
        local live_file="$TARGET_DIR/$rel"
        if [ ! -f "$live_file" ]; then
          if [ "$DRY_RUN" = "1" ]; then
            info "[dry-run] prune: $rel"
          else
            rm -f "$personal_file"
            verbose_log "Pruned: $rel"
          fi
        fi
      done < <(find_matching_files "$PERSONAL_DIR" "$pattern")
    fi

  done < <(get_category_files "$MANIFEST" "$cat")
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

info "Capturing $TOOL <- $TARGET_DIR"

while IFS= read -r cat; do
  should_process_category "$cat" || continue
  local_type="$(get_category_type "$MANIFEST" "$cat")"

  verbose_log "Processing category: $cat ($local_type)"

  case "$local_type" in
    sentinel) capture_sentinel_cat "$cat" ;;
    merge) capture_merge_cat "$cat" ;;
    copy) capture_copy_cat "$cat" ;;
    *) warn "Unknown category type '$local_type' for '$cat'; skipping." ;;
  esac
done < <(get_categories "$MANIFEST")

if [ "$DRY_RUN" = "1" ]; then
  info "Dry run complete. No files were changed."
else
  info "Done."
  if [ "$CAPTURE_REVIEW" = "1" ]; then
    git -C "$REPO_ROOT" diff -- "adapters/$TOOL/personal" | "${PAGER:-less}"
  fi
fi
