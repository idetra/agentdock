#!/usr/bin/env bash
# Shared utilities. Expects REPO_ROOT to be set before sourcing.

# shellcheck source=lib/parse-args.sh
. "$REPO_ROOT/lib/parse-args.sh"
# shellcheck source=lib/colors.sh
. "$REPO_ROOT/lib/colors.sh"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

err() {
  printf 'Error: %s\n' "$*" >&2
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

info() {
  [ "${QUIET:-0}" = "1" ] && return 0
  printf '%s\n' "$*"
}

verbose_log() {
  [ "${VERBOSE:-0}" = "1" ] || return 0
  printf '  %s\n' "$*"
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

check_jq() {
  command -v jq >/dev/null 2>&1 && jq --version >/dev/null 2>&1 && return 0
  cat >&2 <<'EOF'
Error: jq is required but not installed.
  macOS:    brew install jq
  Ubuntu:   sudo apt install jq
  Windows:  choco install jq  (or use WSL/Git Bash with jq installed)
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Adapter / manifest helpers
# ---------------------------------------------------------------------------

get_manifest_path() {
  echo "$REPO_ROOT/adapters/$1/manifest.json"
}

get_adapter_dir() {
  echo "$REPO_ROOT/adapters/$1"
}

get_base_dir() {
  echo "$REPO_ROOT/adapters/$1/base"
}

get_personal_dir() {
  echo "$REPO_ROOT/adapters/$1/personal"
}

get_target_dir() {
  local tool="$1"
  local manifest
  manifest="$(get_manifest_path "$tool")"
  local env_override
  env_override="$(jq -r '.target_dir_env_override // empty' "$manifest" 2>/dev/null)"
  local target_dir
  if [ -n "$env_override" ]; then
    # Indirect expansion: read the env var named by env_override
    eval "target_dir=\"\${${env_override}:-}\""
  fi
  if [ -z "${target_dir:-}" ]; then
    target_dir="$(jq -r '.target_dir' "$manifest")"
    # Expand leading ~
    case "$target_dir" in
      "~/"*) target_dir="$HOME/${target_dir#'~/'}" ;;
      "~") target_dir="$HOME" ;;
    esac
  fi
  echo "$target_dir"
}

get_categories() {
  local manifest="$1"
  jq -r '.categories | keys[]' "$manifest"
}

get_category_type() {
  local manifest="$1"
  local cat="$2"
  jq -r ".categories[\"$cat\"].type" "$manifest"
}

get_category_files() {
  local manifest="$1"
  local cat="$2"
  jq -r ".categories[\"$cat\"].files[]" "$manifest"
}

get_sentinel_start() {
  local manifest="$1"
  local cat="$2"
  jq -r ".categories[\"$cat\"].sentinel_start" "$manifest"
}

get_sentinel_end() {
  local manifest="$1"
  local cat="$2"
  jq -r ".categories[\"$cat\"].sentinel_end" "$manifest"
}

# Read deepmerge.jq for inline use with jq -e / --args
read_jq_lib() {
  cat "$REPO_ROOT/lib/deepmerge.jq"
}

# ---------------------------------------------------------------------------
# File helpers
# ---------------------------------------------------------------------------

# find_matching_files <base_dir> <glob_pattern>
# Prints absolute paths of files matching the pattern under base_dir.
find_matching_files() {
  local base_dir="$1"
  local pattern="$2"

  [ -d "$base_dir" ] || return 0

  local name_part dir_part
  name_part="${pattern##*/}"
  dir_part="${pattern%/*}"

  if [ "$dir_part" = "$pattern" ]; then
    # No slash: single file directly under base_dir
    [ -f "$base_dir/$pattern" ] && echo "$base_dir/$pattern"
    return 0
  fi

  local search_dir="$base_dir/$dir_part"
  [ -d "$search_dir" ] || return 0

  case "$name_part" in
    "**")
      find "$search_dir" -type f 2>/dev/null | sort
      ;;
    *)
      find "$search_dir" -maxdepth 1 -name "$name_part" -type f 2>/dev/null | sort
      ;;
  esac
}

# relative_path <abs_path> <base_dir>
# Strips base_dir prefix (with trailing slash) from abs_path.
relative_path() {
  local abs="$1"
  local base="$2"
  printf '%s' "${abs#$base/}"
}

# backup_file <path>: copy file to path.bak (or path.bak.N if .bak exists).
backup_file() {
  local file="$1"
  [ -f "$file" ] || return 0

  local bak="$file.bak"
  if [ ! -f "$bak" ]; then
    cp "$file" "$bak"
    verbose_log "Backed up: $file -> $bak"
    return 0
  fi

  local n=1
  while [ -f "$file.bak.$n" ]; do
    n=$((n + 1))
  done
  cp "$file" "$file.bak.$n"
  verbose_log "Backed up: $file -> $file.bak.$n"
}

# ensure_dir <path>: create directory and parents if needed.
ensure_dir() {
  [ -d "$1" ] && return 0
  mkdir -p "$1" || die "Cannot create directory: $1"
}

# files_identical <a> <b>: return 0 if files have identical content.
files_identical() {
  cmp -s "$1" "$2"
}

# ---------------------------------------------------------------------------
# Sentinel injection helpers
# ---------------------------------------------------------------------------

# do_sentinel_inject <base_file> <personal_file> <target_file> <start> <end>
# Merges personal content into base using sentinel markers, writes to target.
do_sentinel_inject() {
  local base_file="$1"
  local personal_file="$2"
  local target_file="$3"
  local sentinel_start="$4"
  local sentinel_end="$5"

  local tmp
  tmp="$(mktemp)"

  if grep -qF "$sentinel_start" "$base_file" 2>/dev/null; then
    # Replace the existing sentinel block inside base with fresh personal content.
    # sub(/\r$/, "") normalizes CRLF so sentinel markers match on Windows-edited files.
    awk \
      -v s="$sentinel_start" \
      -v e="$sentinel_end" \
      -v pf="$personal_file" \
      'BEGIN { in_block=0 }
       { sub(/\r$/, "") }
       $0 == s {
         in_block=1
         print s
         while ((getline ln < pf) > 0) { sub(/\r$/, "", ln); print ln }
         close(pf)
         print e
         next
       }
       in_block && $0 == e { in_block=0; next }
       in_block { next }
       { print }' \
      "$base_file" > "$tmp"
  else
    # Append sentinel block after base content, normalizing CRLF to LF.
    awk '{ sub(/\r$/, ""); print }' "$base_file" > "$tmp"
    printf '\n%s\n' "$sentinel_start" >> "$tmp"
    awk '{ sub(/\r$/, ""); print }' "$personal_file" >> "$tmp"
    printf '%s\n' "$sentinel_end" >> "$tmp"
  fi

  mv "$tmp" "$target_file"
}

# do_sentinel_extract <live_file> <personal_file> <start> <end>
# Extracts the sentinel block from live_file and writes it to personal_file.
do_sentinel_extract() {
  local live_file="$1"
  local personal_file="$2"
  local sentinel_start="$3"
  local sentinel_end="$4"

  if ! grep -qF "$sentinel_start" "$live_file" 2>/dev/null; then
    verbose_log "No sentinel block in: $live_file"
    return 0
  fi

  ensure_dir "$(dirname "$personal_file")"

  awk \
    -v s="$sentinel_start" \
    -v e="$sentinel_end" \
    'BEGIN { in_block=0 }
     { sub(/\r$/, "") }
     $0 == s { in_block=1; next }
     $0 == e { in_block=0; next }
     in_block { print }' \
    "$live_file" > "$personal_file"
}

# do_sentinel_remove <target_file> <start> <end>
# Strips the sentinel block from target_file in place.
do_sentinel_remove() {
  local target_file="$1"
  local sentinel_start="$2"
  local sentinel_end="$3"

  [ -f "$target_file" ] || return 0
  grep -qF "$sentinel_start" "$target_file" 2>/dev/null || return 0

  local tmp
  tmp="$(mktemp)"

  awk \
    -v s="$sentinel_start" \
    -v e="$sentinel_end" \
    'BEGIN { in_block=0 }
     { sub(/\r$/, "") }
     $0 == s { in_block=1; next }
     in_block && $0 == e { in_block=0; next }
     in_block { next }
     { print }' \
    "$target_file" > "$tmp"

  mv "$tmp" "$target_file"
}

# ---------------------------------------------------------------------------
# Adapter validation
# ---------------------------------------------------------------------------

validate_tool() {
  local tool="$1"
  local adapter_dir
  adapter_dir="$(get_adapter_dir "$tool")"
  [ -d "$adapter_dir" ] || die "Unknown tool: '$tool'. Run 'agentdock list' to see available tools."
  [ -f "$adapter_dir/manifest.json" ] || die "Adapter '$tool' has no manifest.json."
}

# list_adapters: print tool name + display name for every configured adapter.
list_adapters() {
  local adapters_dir="$REPO_ROOT/adapters"
  if [ ! -d "$adapters_dir" ]; then
    info "No adapters configured."
    return 0
  fi
  local found=0
  for dir in "$adapters_dir"/*/; do
    [ -f "$dir/manifest.json" ] || continue
    found=1
    local name display_name
    name="$(basename "$dir")"
    display_name="$(jq -r '.display_name // .tool' "$dir/manifest.json" 2>/dev/null || echo "$name")"
    printf '  %-12s  %s\n' "$name" "$display_name"
  done
  [ "$found" = "0" ] && info "No adapters configured."
  return 0
}
