#!/usr/bin/env bash
# Flag parsing helpers. Source this file; call init_flags then parse in each script.

# init_flags: set default values for all global flags.
init_flags() {
  VERBOSE=0
  QUIET=0
  DRY_RUN=0
  INTERACTIVE=0
  ONLY_CATS=""
  SKIP_CATS=""
  COLOR_DISABLED=0
}

# validate_flags: check for mutually exclusive combinations.
validate_flags() {
  if [ -n "$ONLY_CATS" ] && [ -n "$SKIP_CATS" ]; then
    die "--only and --skip are mutually exclusive"
  fi
}

# should_process_category <category>: returns 0 if the category should run.
should_process_category() {
  local cat="$1"
  if [ -n "$ONLY_CATS" ]; then
    case ",$ONLY_CATS," in
      *,"$cat",*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  if [ -n "$SKIP_CATS" ]; then
    case ",$SKIP_CATS," in
      *,"$cat",*) return 1 ;;
    esac
  fi
  return 0
}

# confirm <prompt>: ask the user Y/n; returns 0 for yes, 1 for no.
confirm() {
  local prompt="$1"
  local answer
  printf '%s [y/N] ' "$prompt" >&2
  read -r answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}
