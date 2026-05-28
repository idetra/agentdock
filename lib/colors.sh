#!/usr/bin/env bash
# ANSI color codes for the seven status states.
# Source this file; call init_colors after flag parsing.

init_colors() {
  if [ "${COLOR_DISABLED:-0}" = "1" ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    GREEN=""
    BRIGHT_GREEN=""
    YELLOW=""
    RED=""
    MAGENTA=""
    GRAY=""
    DIM=""
    ITALIC=""
    RESET=""
  else
    GREEN="\033[32m"
    BRIGHT_GREEN="\033[92m"
    YELLOW="\033[33m"
    RED="\033[31m"
    MAGENTA="\033[35m"
    GRAY="\033[90m"
    DIM="\033[2m"
    ITALIC="\033[3m"
    RESET="\033[0m"
  fi
}

# color_text <color_var> <text>
color_text() {
  local color="$1"
  local text="$2"
  printf '%b%s%b' "$color" "$text" "$RESET"
}
