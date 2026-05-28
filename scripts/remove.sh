#!/usr/bin/env bash
# remove.sh: restore live config to base only (strip personal overlay).
# Usage: remove.sh <tool> [global flags] [remove flags] [paths...]

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
[ -z "$TOOL" ] && die "Usage: remove.sh <tool> [options] [paths...]"
shift

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

init_flags
REMOVE_RESTORE_BACKUP=0
REMOVE_KEEP_ADDED=0

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      cat <<EOF
Usage: agentdock $TOOL remove [options] [paths...]

Remove personal overlay from live config; restore to base only.

Options:
  -h, --help
  -v, --verbose
  -q, --quiet
  -n, --dry-run         print the plan, change nothing
  -i, --interactive     confirm each change
  --only <categories>   comma-separated whitelist
  --skip <categories>   comma-separated blacklist
  --no-color
  --restore-backup      prefer .bak files over re-applying base
  --keep-added          keep standalone personal-only files (skip their removal)

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
    --restore-backup) REMOVE_RESTORE_BACKUP=1 ;;
    --keep-added) REMOVE_KEEP_ADDED=1 ;;
    --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done; break ;;
    -*) die "Unknown flag: $1. Run 'agentdock $TOOL remove --help'." ;;
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
# Restore helper: prefer .bak if --restore-backup, else re-apply base
# ---------------------------------------------------------------------------

restore_to_base() {
  local rel="$1"
  local base_file="$BASE_DIR/$rel"
  local target_file="$TARGET_DIR/$rel"

  if [ "$DRY_RUN" = "1" ]; then
    if [ -f "$base_file" ]; then
      info "[dry-run] restore base: $rel"
    else
      info "[dry-run] delete (no base): $rel"
    fi
    return 0
  fi

  if [ "$INTERACTIVE" = "1" ]; then
    confirm "Restore $rel to base?" || return 0
  fi

  if [ "$REMOVE_RESTORE_BACKUP" = "1" ]; then
    local bak="$target_file.bak"
    if [ -f "$bak" ]; then
      cp "$bak" "$target_file"
      verbose_log "Restored from backup: $rel"
      return 0
    fi
  fi

  if [ -f "$base_file" ]; then
    cp "$base_file" "$target_file"
    verbose_log "Restored base: $rel"
  else
    rm -f "$target_file"
    verbose_log "Deleted (no base): $rel"
  fi
}

# ---------------------------------------------------------------------------
# Per-type remove handlers
# ---------------------------------------------------------------------------

remove_sentinel_cat() {
  local cat="$1"
  local sentinel_start sentinel_end
  sentinel_start="$(get_sentinel_start "$MANIFEST" "$cat")"
  sentinel_end="$(get_sentinel_end "$MANIFEST" "$cat")"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue

    # For sentinel files that exist in base: strip sentinel block
    while IFS= read -r base_file; do
      [ -z "$base_file" ] && continue
      local rel
      rel="$(relative_path "$base_file" "$BASE_DIR")"
      path_is_requested "$rel" || continue

      local target_file="$TARGET_DIR/$rel"
      [ -f "$target_file" ] || continue

      if [ "$DRY_RUN" = "1" ]; then
        info "[dry-run] strip sentinel: $rel"
        continue
      fi

      if [ "$INTERACTIVE" = "1" ]; then
        confirm "Strip personal block from $rel?" || continue
      fi

      do_sentinel_remove "$target_file" "$sentinel_start" "$sentinel_end"
      verbose_log "Stripped sentinel: $rel"
    done < <(find_matching_files "$BASE_DIR" "$pattern")

    # Personal-only sentinel files: remove from live entirely
    [ "$REMOVE_KEEP_ADDED" = "1" ] && continue

    while IFS= read -r personal_file; do
      [ -z "$personal_file" ] && continue
      local rel
      rel="$(relative_path "$personal_file" "$PERSONAL_DIR")"
      [ -f "$BASE_DIR/$rel" ] && continue  # already handled above
      path_is_requested "$rel" || continue

      local target_file="$TARGET_DIR/$rel"
      [ -f "$target_file" ] || continue

      if [ "$DRY_RUN" = "1" ]; then
        info "[dry-run] delete personal-only: $rel"
        continue
      fi

      if [ "$INTERACTIVE" = "1" ]; then
        confirm "Delete personal-only file $rel from live?" || continue
      fi

      rm -f "$target_file"
      verbose_log "Deleted personal-only: $rel"
    done < <(find_matching_files "$PERSONAL_DIR" "$pattern")

  done < <(get_category_files "$MANIFEST" "$cat")
}

remove_merge_cat() {
  local cat="$1"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue

    local rel="$pattern"
    path_is_requested "$rel" || continue

    restore_to_base "$rel"
  done < <(get_category_files "$MANIFEST" "$cat")
}

remove_copy_cat() {
  local cat="$1"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue

    # Restore base files
    while IFS= read -r base_file; do
      [ -z "$base_file" ] && continue
      local rel
      rel="$(relative_path "$base_file" "$BASE_DIR")"
      path_is_requested "$rel" || continue
      restore_to_base "$rel"
    done < <(find_matching_files "$BASE_DIR" "$pattern")

    # Delete personal-only files from live
    [ "$REMOVE_KEEP_ADDED" = "1" ] && continue

    while IFS= read -r personal_file; do
      [ -z "$personal_file" ] && continue
      local rel
      rel="$(relative_path "$personal_file" "$PERSONAL_DIR")"
      [ -f "$BASE_DIR/$rel" ] && continue  # base file, already handled
      path_is_requested "$rel" || continue

      local target_file="$TARGET_DIR/$rel"
      [ -f "$target_file" ] || continue

      if [ "$DRY_RUN" = "1" ]; then
        info "[dry-run] delete personal-only: $rel"
        continue
      fi

      if [ "$INTERACTIVE" = "1" ]; then
        confirm "Delete personal-only $rel from live?" || continue
      fi

      rm -f "$target_file"
      verbose_log "Deleted: $rel"
    done < <(find_matching_files "$PERSONAL_DIR" "$pattern")

  done < <(get_category_files "$MANIFEST" "$cat")
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  info "Dry run: agentdock $TOOL remove"
else
  info "Removing $TOOL personal overlay from $TARGET_DIR"
fi

while IFS= read -r cat; do
  should_process_category "$cat" || continue
  local_type="$(get_category_type "$MANIFEST" "$cat")"

  verbose_log "Processing category: $cat ($local_type)"

  case "$local_type" in
    sentinel) remove_sentinel_cat "$cat" ;;
    merge) remove_merge_cat "$cat" ;;
    copy) remove_copy_cat "$cat" ;;
    *) warn "Unknown category type '$local_type' for '$cat'; skipping." ;;
  esac
done < <(get_categories "$MANIFEST")

if [ "$DRY_RUN" = "1" ]; then
  info "Dry run complete. No files were changed."
else
  info "Done."
fi
