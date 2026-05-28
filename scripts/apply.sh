#!/usr/bin/env bash
# apply.sh: merge base + personal and write to the live config dir.
# Usage: apply.sh <tool> [global flags] [apply flags] [paths...]

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
[ -z "$TOOL" ] && die "Usage: apply.sh <tool> [options] [paths...]"
shift

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

init_flags
APPLY_NO_BACKUP=0
APPLY_FORCE=0
APPLY_FROM=""

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      cat <<EOF
Usage: agentdock $TOOL apply [options] [paths...]

Apply base + personal overlay to the live config directory.

Options:
  -h, --help
  -v, --verbose
  -q, --quiet
  -n, --dry-run         print the plan, change nothing
  -i, --interactive     confirm each change
  --only <categories>   comma-separated whitelist
  --skip <categories>   comma-separated blacklist
  --no-color
  --no-backup           skip writing .bak files
  --force               overwrite without prompting on conflicts
  --from <dir>          use a different source than personal/ (testing)

Paths: if given, restrict to those files/dirs (relative to personal/).
EOF
      exit 0 ;;
    -v|--verbose) VERBOSE=1 ;;
    -q|--quiet) QUIET=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -i|--interactive) INTERACTIVE=1 ;;
    --only) shift; ONLY_CATS="$1" ;;
    --skip) shift; SKIP_CATS="$1" ;;
    --no-color) COLOR_DISABLED=1 ;;
    --no-backup) APPLY_NO_BACKUP=1 ;;
    --force) APPLY_FORCE=1 ;;
    --from) shift; APPLY_FROM="$1" ;;
    --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done; break ;;
    -*) die "Unknown flag: $1. Run 'agentdock $TOOL apply --help'." ;;
    *) POSITIONAL+=("$1") ;;
  esac
  shift
done

validate_flags
init_colors

validate_tool "$TOOL"

MANIFEST="$(get_manifest_path "$TOOL")"
BASE_DIR="$(get_base_dir "$TOOL")"
PERSONAL_DIR="${APPLY_FROM:-$(get_personal_dir "$TOOL")}"
TARGET_DIR="$(get_target_dir "$TOOL")"

ensure_dir "$TARGET_DIR"

# ---------------------------------------------------------------------------
# Path filter: if positional args given, restrict processing to those paths
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
# Per-type apply handlers
# ---------------------------------------------------------------------------

apply_sentinel_cat() {
  local cat="$1"
  local manifest="$MANIFEST"
  local sentinel_start sentinel_end
  sentinel_start="$(get_sentinel_start "$manifest" "$cat")"
  sentinel_end="$(get_sentinel_end "$manifest" "$cat")"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue

    # Collect all base files for this pattern
    while IFS= read -r base_file; do
      [ -z "$base_file" ] && continue
      local rel
      rel="$(relative_path "$base_file" "$BASE_DIR")"
      path_is_requested "$rel" || continue

      local personal_file="$PERSONAL_DIR/$rel"
      local target_file="$TARGET_DIR/$rel"

      ensure_dir "$(dirname "$target_file")"

      if [ "$DRY_RUN" = "1" ]; then
        if [ -f "$personal_file" ]; then
          info "[dry-run] sentinel inject: $rel"
        else
          info "[dry-run] copy base: $rel"
        fi
        continue
      fi

      if [ "$INTERACTIVE" = "1" ]; then
        confirm "Apply sentinel for $rel?" || continue
      fi

      [ "$APPLY_NO_BACKUP" = "0" ] && backup_file "$target_file"

      if [ -f "$personal_file" ]; then
        do_sentinel_inject "$base_file" "$personal_file" "$target_file" \
          "$sentinel_start" "$sentinel_end"
        verbose_log "Sentinel injected: $rel"
      else
        cp "$base_file" "$target_file"
        verbose_log "Copied base: $rel"
      fi
    done < <(find_matching_files "$BASE_DIR" "$pattern")

    # Also handle personal-only sentinel files (no base counterpart)
    while IFS= read -r personal_file; do
      [ -z "$personal_file" ] && continue
      local rel
      rel="$(relative_path "$personal_file" "$PERSONAL_DIR")"
      local base_file="$BASE_DIR/$rel"
      [ -f "$base_file" ] && continue  # already handled above

      path_is_requested "$rel" || continue

      local target_file="$TARGET_DIR/$rel"
      ensure_dir "$(dirname "$target_file")"

      if [ "$DRY_RUN" = "1" ]; then
        info "[dry-run] copy personal (no base): $rel"
        continue
      fi

      if [ "$INTERACTIVE" = "1" ]; then
        confirm "Apply personal-only file $rel?" || continue
      fi

      [ "$APPLY_NO_BACKUP" = "0" ] && backup_file "$target_file"
      cp "$personal_file" "$target_file"
      verbose_log "Copied personal-only: $rel"
    done < <(find_matching_files "$PERSONAL_DIR" "$pattern")

  done < <(get_category_files "$MANIFEST" "$cat")
}

apply_merge_cat() {
  local cat="$1"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue

    local rel="$pattern"
    path_is_requested "$rel" || continue

    local base_file="$BASE_DIR/$rel"
    local personal_snippet="$PERSONAL_DIR/${rel%.json}.snippet.json"
    local target_file="$TARGET_DIR/$rel"

    ensure_dir "$(dirname "$target_file")"

    if [ "$DRY_RUN" = "1" ]; then
      info "[dry-run] deep-merge: $rel"
      continue
    fi

    if [ "$INTERACTIVE" = "1" ]; then
      confirm "Apply merge for $rel?" || continue
    fi

    [ "$APPLY_NO_BACKUP" = "0" ] && backup_file "$target_file"

    local jq_lib
    jq_lib="$(read_jq_lib)"

    if [ -f "$base_file" ] && [ -f "$personal_snippet" ]; then
      local tmp
      tmp="$(mktemp)"
      jq -n \
        --slurpfile _base "$base_file" \
        --slurpfile _snip "$personal_snippet" \
        "$jq_lib deepmerge(\$_base[0]; \$_snip[0])" > "$tmp"
      mv "$tmp" "$target_file"
      verbose_log "Deep-merged: $rel"
    elif [ -f "$personal_snippet" ]; then
      cp "$personal_snippet" "$target_file"
      verbose_log "Copied personal snippet (no base): $rel"
    elif [ -f "$base_file" ]; then
      cp "$base_file" "$target_file"
      verbose_log "Copied base (no snippet): $rel"
    else
      verbose_log "Skipped (neither base nor snippet found): $rel"
    fi
  done < <(get_category_files "$MANIFEST" "$cat")
}

apply_copy_cat() {
  local cat="$1"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue

    # Copy base files first
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      local rel
      rel="$(relative_path "$src" "$BASE_DIR")"
      path_is_requested "$rel" || continue

      local dst="$TARGET_DIR/$rel"
      ensure_dir "$(dirname "$dst")"

      if [ "$DRY_RUN" = "1" ]; then
        info "[dry-run] copy base: $rel"
        continue
      fi

      if [ "$INTERACTIVE" = "1" ]; then
        confirm "Copy base file $rel?" || continue
      fi

      [ "$APPLY_NO_BACKUP" = "0" ] && backup_file "$dst"
      cp "$src" "$dst"
      verbose_log "Copied base: $rel"
    done < <(find_matching_files "$BASE_DIR" "$pattern")

    # Then copy personal files (may overwrite base)
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      local rel
      rel="$(relative_path "$src" "$PERSONAL_DIR")"
      path_is_requested "$rel" || continue

      local dst="$TARGET_DIR/$rel"
      ensure_dir "$(dirname "$dst")"

      if [ "$DRY_RUN" = "1" ]; then
        info "[dry-run] copy personal: $rel"
        continue
      fi

      if [ "$INTERACTIVE" = "1" ]; then
        confirm "Copy personal file $rel?" || continue
      fi

      [ "$APPLY_NO_BACKUP" = "0" ] && backup_file "$dst"
      cp "$src" "$dst"
      verbose_log "Copied personal: $rel"
    done < <(find_matching_files "$PERSONAL_DIR" "$pattern")

  done < <(get_category_files "$MANIFEST" "$cat")
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "${QUIET:-0}" = "0" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    info "Dry run: agentdock $TOOL apply -> $TARGET_DIR"
  else
    info "Applying $TOOL -> $TARGET_DIR"
  fi
fi

while IFS= read -r cat; do
  should_process_category "$cat" || continue
  local_type="$(get_category_type "$MANIFEST" "$cat")"

  verbose_log "Processing category: $cat ($local_type)"

  case "$local_type" in
    sentinel) apply_sentinel_cat "$cat" ;;
    merge) apply_merge_cat "$cat" ;;
    copy) apply_copy_cat "$cat" ;;
    *) warn "Unknown category type '$local_type' for '$cat'; skipping." ;;
  esac
done < <(get_categories "$MANIFEST")

if [ "$DRY_RUN" = "1" ]; then
  info "Dry run complete. No files were changed."
else
  info "Done."
fi
