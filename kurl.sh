#!/bin/bash
#===============================================================================
# Script Name: kurl.sh
# Version: 1.0
# Purpose: Interact with the YOURLS API to create, delete, and manage short URLs
# Author: Gerald Drißner
# Github: https://github.com/gerald-drissner
# Last Update: 2025-08-25
# License: MIT
#===============================================================================

# --- App meta -----------------------------------------------------------------
VERSION="1.0"
APP_NAME="kurl.sh"
GITHUB_LINK="https://github.com/gerald-drissner"
CONTACT_EMAIL="yourls@drissner.me"

# --- Colors (use real ANSI ESC with $'...') -----------------------------------
ESC=$'\e'

RED="${ESC}[1;31m"
GRAY="${ESC}[1;90m"
GREEN="${ESC}[1;32m"
ORANGE="${ESC}[1;33m"
YELLOW="${ESC}[38;5;222m"
BLUE="${ESC}[1;34m"
MAGENTA="${ESC}[1;35m"
CYAN="${ESC}[1;36m"
WHITE="${ESC}[1;37m"
RESET="${ESC}[0m"
BOLD_WHITE_ON_BLACK="${ESC}[1;97;100m"
BOLD_BRIGHT_WHITE="${ESC}[1;97m"

# Formatting
BOLD="${ESC}[1m"
ITALIC="${ESC}[3m"
BOLDITALIC="${ESC}[1;3m"

disable_colors() {
  RED=""; GRAY=""; GREEN=""; ORANGE=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; WHITE=""
  RESET=""; BOLD_WHITE_ON_BLACK=""; BOLD_BRIGHT_WHITE=""; BOLD=""; ITALIC=""; BOLDITALIC=""
}

# Auto-disable colors when stdout isn’t a TTY or NO_COLOR is set
NOCLR_ENV="${NO_COLOR:-}"
[[ -t 1 ]] || NOCLR_ENV=1
[[ -n "$NOCLR_ENV" ]] && disable_colors

# --- Config file --------------------------------------------------------------
PROFILE="default"
CONFIG_FILE="$HOME/.config/yourls-cli/${PROFILE}.cfg"

# --- Output controls ----------------------------------------------------------
QUIET=false
VERBOSE=false

say()   { $QUIET && return 0; echo -e "$*"; }
sayv()  { $VERBOSE && echo -e "$*"; }
err()   { echo -e "$*" >&2; }

#===============================================================================
# Utilities
#===============================================================================

# URL-encode: jq if available, otherwise pure bash fallback
urlencode() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -sRr @uri
    return
  fi
  local s="$1" out="" c
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      ' ') out+='%20' ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

# OS detection
is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
is_linux() { [[ "$(uname -s)" == "Linux" ]]; }
is_wsl()   { is_linux && grep -qi microsoft /proc/version 2>/dev/null; }

# Wayland/X11 detection
wayland_socket_exists() {
  local disp="${WAYLAND_DISPLAY:-}"; local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  [[ -z "$disp" ]] && disp="wayland-0"; [[ -S "$runtime/$disp" ]]
}
is_wayland_available() { command -v wl-copy >/dev/null 2>&1 && wayland_socket_exists; }
is_x11_env()           { [[ -n "${DISPLAY:-}" ]]; }
is_x11_available()     { is_x11_env && (command -v xclip >/dev/null 2>&1 || command -v xsel >/dev/null 2>&1); }

# Package manager detection (Linux + macOS/Homebrew)
PKG_MGR="unknown"
detect_pkg_mgr() {
  if is_macos; then PKG_MGR=$([[ -x "$(command -v brew)" ]] && echo brew || echo brew-missing); return; fi
  if is_linux && [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID,,}" in
      arch|cachyos|manjaro) PKG_MGR="pacman" ;;
      debian|ubuntu|linuxmint|pop|elementary|raspbian) PKG_MGR="apt" ;;
      fedora|rhel|centos|rocky|alma) PKG_MGR="dnf" ;;
      opensuse*|sles|suse) PKG_MGR="zypper" ;;
      *) case "${ID_LIKE,,}" in
           *arch*) PKG_MGR="pacman" ;;
           *debian*) PKG_MGR="apt" ;;
           *rhel*|*fedora*) PKG_MGR="dnf" ;;
           *suse*) PKG_MGR="zypper" ;;
           *) PKG_MGR="unknown" ;;
         esac ;;
    esac
  fi
}
pkg_install_cmd() {
  local pkgs=("$@")
  case "$PKG_MGR" in
    pacman) echo "sudo pacman --noconfirm -S ${pkgs[*]}" ;;
    apt)    echo "sudo apt-get -y install ${pkgs[*]}" ;;
    dnf)    echo "sudo dnf -y install ${pkgs[*]}" ;;
    zypper) echo "sudo zypper --non-interactive install ${pkgs[*]}" ;;
    brew)   echo "brew install ${pkgs[*]}" ;;
    *)      echo "# Unknown package manager. Install manually: ${pkgs[*]}" ;;
  esac
}
pkg_install_prompt() {
  local pkgs=("$@"); local cmd; cmd="$(pkg_install_cmd "${pkgs[@]}")"
  if [[ "$cmd" == \#* ]]; then
    say "${ORANGE}Cannot auto-install on this platform.${RESET}\nPlease install: ${pkgs[*]}"; return 1
  fi
  say "${CYAN}Missing packages:${RESET} ${pkgs[*]}\nRun: $cmd"
  read -r -p "Proceed? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then eval "$cmd"; else say "${GRAY}Skipped installation of:${RESET} ${pkgs[*]}"; fi
}

# Clipboard helper (macOS/Wayland/X11/WSL)
copy_to_clipboard() {
  local text="$1"
  if is_macos && command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$text" | pbcopy && { say "The short URL has been copied to your clipboard."; return 0; }
  fi
  if is_wayland_available; then
    printf '%s' "$text" | wl-copy && { say "The short URL has been copied to your clipboard."; return 0; }
  fi
  if is_x11_available; then
    if command -v xclip >/dev/null 2>&1; then
      printf '%s' "$text" | xclip -selection clipboard && { say "The short URL has been copied to your clipboard."; return 0; }
    elif command -v xsel >/dev/null 2>&1; then
      printf '%s' "$text" | xsel -ib && { say "The short URL has been copied to your clipboard."; return 0; }
    fi
  fi
  if command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$text" | clip.exe && { say "The short URL has been copied to your clipboard."; return 0; }
  fi
  say "${ORANGE}Note:${RESET} No suitable clipboard tool detected (need pbcopy, wl-clipboard, xclip/xsel, or clip.exe). Skipping copy."
  return 1
}

# Open URL in browser
open_url() {
  local u="$1"
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$u" >/dev/null 2>&1
  elif command -v open >/dev/null 2>&1; then open "$u" >/dev/null 2>&1
  elif command -v powershell.exe >/dev/null 2>&1; then powershell.exe Start-Process "$u" >/dev/null 2>&1
  fi
}

# QR code (optional dependency: qrencode)
print_qr() { command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$1"; }

# Config permissions
ensure_config_perms() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  local mode
  mode=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE")
  if [[ "$mode" -gt 600 ]]; then chmod 600 "$CONFIG_FILE"; fi
}

#===============================================================================
# Networking / API (POST via stdin)
#===============================================================================

# Default curl opts; can be extended by flags
CURL_OPTS=( -s -L --fail --connect-timeout 7 --max-time 25 --retry 3 --retry-all-errors )
CURL_IPVER=""

api_post() { # api_post action k=v k=v ...
  local action="$1"; shift
  local url="${YOURLS_HOST%/}/yourls-api.php"
  local form="signature=$(urlencode "$YOURLS_KEY")&action=$(urlencode "$action")&format=json"
  local kv
  for kv in "$@"; do form="$form&${kv%%=*}=$(urlencode "${kv#*=}")"; done
  printf '%s' "$form" | curl "${CURL_OPTS[@]}" ${CURL_IPVER:+$CURL_IPVER} -X POST --data @- "$url"
}

#===============================================================================
# Validation helpers
#===============================================================================

is_full_url()       { [[ "$1" =~ ^(https?|ftp|file):// ]] || [[ "$1" =~ ^mailto: ]]; }
is_http_url()       { [[ "$1" =~ ^https?:// ]]; }
is_our_short_host() { [[ -n "$YOURLS_HOST" && "$1" == "$YOURLS_HOST"* ]]; }

# Bare-domain normalization
ASSUME_HTTPS="false"
STRICT_INPUT="false"

looks_like_domain_or_path() {
  local s="$1"
  [[ ! "$s" =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]] && [[ "$s" =~ ^[^[:space:]/]+\.[^[:space:]/]+(/.*)?$ ]]
}
normalize_or_prompt_url() {
  # Sets global URL_OUT or returns non-zero
  local raw="$1"; URL_OUT=""
  if is_http_url "$raw"; then URL_OUT="$raw"; return 0; fi
  if [[ "$raw" =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]]; then
    err "\n${RED}Only http(s) URLs can be shortened.${RESET} Got: $raw\n"; return 1
  fi
  if looks_like_domain_or_path "$raw"; then
    local candidate="https://$raw"
    if [[ "$STRICT_INPUT" == "true" ]]; then err "\n${RED}Strict mode:${RESET} provide an explicit http(s):// URL.\n"; return 1; fi
    if [[ "$ASSUME_HTTPS" == "true" ]]; then URL_OUT="$candidate"; return 0; fi
    say ""
    read -r -p "$(echo -e "${CYAN}Interpret as ${candidate}?${RESET} [Y/n] ")" ans
    if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then URL_OUT="$candidate"; return 0; else
      err "\n${RED}Aborted.${RESET} Please provide a full URL with http:// or https://\n"; return 1
    fi
  fi
  err "\n${RED}That doesn’t look like a URL.${RESET}\nIf you meant a YOURLS keyword, try:  ${YELLOW}-s${RESET} (stats), ${YELLOW}-e${RESET} (expand), or ${YELLOW}-d${RESET} (delete).\nOtherwise, provide a full URL starting with http:// or https://\n"
  return 1
}
normalize_for_batch() {
  # Like normalize_or_prompt_url but NON-interactive; returns 0/1 and sets URL_OUT
  local raw="$1"; URL_OUT=""
  if is_http_url "$raw"; then URL_OUT="$raw"; return 0; fi
  if [[ "$raw" =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]]; then return 1; fi
  if looks_like_domain_or_path "$raw"; then
    [[ "$STRICT_INPUT" == "true" ]] && return 1
    [[ "$ASSUME_HTTPS" == "true" ]] || return 1
    URL_OUT="https://$raw"; return 0
  fi
  return 1
}

#===============================================================================
# Connection & config
#===============================================================================

check_connection() {
  local resp status
  resp=$(api_post db-stats) || return 1
  if command -v jq >/dev/null 2>&1; then
    status=$(echo "$resp" | jq -r '.status // .message // empty')
    [[ "$status" == "success" ]]
  else
    # Fallback: look for "success" in payload
    echo "$resp" | grep -qi '"success"'
  fi
}
handle_connection_error() {
  say "${RED}There was a connection error.${RESET} Re-enter configuration? (y/n)"
  read -r answer
  if [[ "$answer" == "y" ]]; then
    [[ -f "$CONFIG_FILE" ]] && rm -f -- "$CONFIG_FILE"
    say "${GRAY}Let's try again...${RESET}\n"; prompt_for_credentials; say ""
  fi
}
prompt_for_credentials() {
  while true; do
    say "${CYAN}Enter the YOURLS host${RESET} (starts with http:// or https://):"
    read -r YOURLS_HOST; YOURLS_HOST="${YOURLS_HOST%/}"
    if [[ ! "$YOURLS_HOST" =~ ^https?:// ]]; then err "${RED}Host must start with http:// or https://${RESET}\n"; continue; fi
    say ""; say "${CYAN}Enter the YOURLS signature key${RESET}:"; say "${GRAY}${ITALIC}Find it at ${YOURLS_HOST}/admin/tools.php (logged in).${RESET}"
    read -r YOURLS_KEY
    if ! check_connection; then handle_connection_error; continue; fi
    local AUTO_COPY
    while true; do
      say ""; say "${CYAN}Automatically copy new short URLs to clipboard? [y/n] (default: y)${RESET}"
      read -r AUTO_COPY; [[ -z "$AUTO_COPY" ]] && AUTO_COPY="y"
      [[ "$AUTO_COPY" == "y" || "$AUTO_COPY" == "n" ]] && break
      say "Please enter 'y' or 'n'."
    done
    mkdir -p -- "$(dirname "$CONFIG_FILE")"
    { echo "YOURLS_HOST=\"$YOURLS_HOST\""; echo "YOURLS_KEY=\"$YOURLS_KEY\""; echo "AUTO_COPY=\"$AUTO_COPY\""; } > "$CONFIG_FILE"
    ensure_config_perms
    say ""; say "${ORANGE}Configuration saved:${RESET} $CONFIG_FILE"; say ""
    # Non-interactive check; user can run -i later for guided install
    check_dependencies false "$AUTO_COPY" false
    break
  done
}

#===============================================================================
# Dependencies (-i)
#===============================================================================

# Usage: check_dependencies <verbose:true|false> <need_clipboard:true|false> <interactive:true|false>
check_dependencies() {
  local verbose="${1:-false}"; local need_clipboard="${2:-false}"; local interactive="${3:-false}"
  detect_pkg_mgr
  # Core deps
  local missing=()
  for cmd in curl jq; do
    if command -v "$cmd" >/dev/null 2>&1; then [[ "$verbose" == "true" ]] && say "$cmd: ${GREEN}OK${RESET}"
    else missing+=("$cmd"); fi
  done
  ((${#missing[@]})) && { [[ "$interactive" == "true" ]] && pkg_install_prompt "${missing[@]}" || say "${ORANGE}Missing core deps:${RESET} ${missing[*]}"; }
  # Clipboard (optional)
  if [[ "$need_clipboard" == "true" ]]; then
    if is_macos; then
      command -v pbcopy >/dev/null 2>&1 && [[ "$verbose" == "true" ]] && say "pbcopy: ${GREEN}OK${RESET}" || say "pbcopy: ${ORANGE}Not found${RESET} (usually built-in)"
    elif wayland_socket_exists; then
      command -v wl-copy >/dev/null 2>&1 && [[ "$verbose" == "true" ]] && say "wl-clipboard: ${GREEN}OK${RESET}" || { say "wl-clipboard: ${RED}MISSING${RESET}"; [[ "$interactive" == "true" ]] && pkg_install_prompt wl-clipboard; }
    elif is_x11_env; then
      if command -v xclip >/dev/null 2>&1 || command -v xsel >/dev/null 2>&1; then [[ "$verbose" == "true" ]] && say "xclip/xsel: ${GREEN}OK${RESET}"
      else say "xclip/xsel: ${RED}MISSING${RESET}"; [[ "$interactive" == "true" ]] && pkg_install_prompt xclip; fi
    elif command -v clip.exe >/dev/null 2>&1; then [[ "$verbose" == "true" ]] && say "clip.exe: ${GREEN}OK${RESET}"
    else say "${ORANGE}Clipboard check:${RESET} Could not detect Wayland/X11/clip.exe environment."
    fi
    # qrencode (for --qr)
    if command -v qrencode >/dev/null 2>&1; then [[ "$verbose" == "true" ]] && say "qrencode: ${GREEN}OK${RESET}"
    else [[ "$interactive" == "true" ]] && pkg_install_prompt qrencode; fi
  fi
}

#===============================================================================
# Help & version (aligned output)
#===============================================================================

yourls_help() {
  local LWIDTH=28
  sec() { echo; printf "%s%s%s\n" "$CYAN" "$1" "$RESET"; }
  row() {
    local s="$1" l="$2" d="$3"
    if [[ -n "$s" ]]; then
      printf "  %s%-3s%s %s|%s %s%-${LWIDTH}s%s  %s\n" \
        "$YELLOW" "$s" "$RESET" \
        "$GRAY"   "$RESET" \
        "$YELLOW" "$l" "$RESET" \
        "$d"
    else
      printf "  %-5s %s%-${LWIDTH}s%s  %s\n" \
        "" \
        "$YELLOW" "$l" "$RESET" \
        "$d"
    fi
  }

  echo -e "${GRAY}+--------------------------------------------------------+"
  echo -e "${GRAY}|            ${ORANGE}${BOLD}${ITALIC}kurl${RESET}  -  ${BLUE}SHORT URLS WITH YOURLS${RESET}             ${GRAY}|"
  echo -e "${GRAY}+--------------------------------------------------------+${RESET}"
  echo

  sec "To SHORTEN a URL:"
  printf "  %s <url>\n"        "${0##*/}"
  printf "  %s <url> -k <KEYWORD> -t <TITLE>\n" "${0##*/}"

  sec "To MANAGE a SHORT URL:"
  printf "  %s <shorturl-or-keyword> -s | -e | -d\n" "${0##*/}"

  sec "OPTIONS for shortening a URL:"
  row "-k" "--keyword <KEYWORD>" "Custom keyword"
  row "-t" "--title <TITLE>"     "Custom title"

  sec "OPTIONS for managing a SHORT URL:"
  row "-s" "--statistics" "Get statistics"
  row "-e" "--expand"     "Expand to long URL"
  row "-d" "--delete"     "Delete short URL"

  sec "OPTIONS for your YOURLS database:"
  row "-g" "--global" "Global stats"
  row "-l" "--list"   "Interactive list"

  sec "BATCH:"
  row ""  "--batch <file>" "Shorten many URLs (TSV to stdout)"
  printf "  %s\n" "(or pipe stdin: cat urls.txt | ${0##*/})"

  sec "UX & OUTPUT:"
  row ""  "--open"                      "Open new short URL in browser"
  row ""  "--qr"                        "Print terminal QR code (needs qrencode)"
  row "-f" "--format <json|xml|simple>" "Output last API response"
  row ""  "--quiet | --verbose | --no-color" "Control verbosity & colors"

  sec "NETWORK:"
  row "" "--ipv4 | --ipv6" "Force IP family"
  row "" "--insecure"      "Allow insecure TLS (curl -k)"

  sec "SETUP & MAINTENANCE:"
  row "-i" "--check"         "Check & (optionally) install deps"
  row "-c" "--change-config" "Re-enter YOURLS config"
  row "-v" "--version"       "Show version info"
  row ""  "--autocopy-on / --autocopy-off" "Clipboard autocopy toggle"
  row ""  "--assume-https"   "Auto-prefix https:// for bare domains"
  row ""  "--strict"         "Require explicit http(s):// (no normalization)"
  row ""  "--profile <name>" "Use separate config (~/.config/yourls-cli/<name>.cfg)"

  echo
  exit 1
}

show_version() {
  say "${GRAY}+--------------------------------------------------------+"
  say "${GRAY}|${ORANGE}               INFORMATION ABOUT THIS SCRIPT            ${GRAY}|"
  say "${GRAY}+--------------------------------------------------------+${RESET}\n"
  say "${ORANGE}${BOLD}${ITALIC}kurl${RESET} uses the YOURLS API to shorten/manage links."
  say "Works on ${BOLD}Linux${RESET}, ${BOLD}macOS${RESET}, and ${BOLD}WSL${RESET}."
  say "\n${BOLD}${GRAY}Version:${RESET} ${BOLD}$VERSION${RESET}"
  say "${BOLD}${GRAY}Github:${RESET} ${BOLD}$GITHUB_LINK${RESET}"
  say "${BOLD}${GRAY}Contact:${RESET} ${BOLD}$CONTACT_EMAIL${RESET}"
  say "${BOLD}${GRAY}Config file:${RESET} ${BOLD}$CONFIG_FILE${RESET}"
  local loc="(unknown)"
  if command -v realpath >/dev/null 2>&1; then loc=$(realpath "$0")
  elif command -v readlink >/dev/null 2>&1; then loc=$(readlink -f "$0"); fi
  say "${BOLD}${GRAY}Script location:${RESET} ${BOLD}$loc${RESET}\n"
}

#===============================================================================
# Core helpers (management & formatting)
#===============================================================================

resolve_keyword() {
  local input="$1"
  if is_our_short_host "$input"; then basename "${input%%\?*}"
  elif [[ "$input" =~ ^[A-Za-z0-9._~-]+$ ]]; then printf '%s' "$input"
  else return 1; fi
}

print_url_statistics() {
  local keyword="$1"; local resp status msg
  resp=$(api_post url-stats "shorturl=$keyword") || { err "${RED}Failed to fetch stats.${RESET}"; return 1; }
  if command -v jq >/dev/null 2>&1; then
    status=$(echo "$resp" | jq -r '.status // .message // empty')
    if [[ "$status" != "success" ]]; then
      msg=$(echo "$resp" | jq -r '.message // .error // "Unknown error"')
      say "${RED}Failed to fetch statistics for ${keyword}${RESET}\n${RED}Response: ${msg}${RESET}"
      return 1
    fi
    local shorturl longurl date clicks
    shorturl=$(echo "$resp" | jq -r '.shorturl // .link.shorturl // .url.shorturl // (.link.keyword|select(.)) // empty')
    longurl=$( echo "$resp" | jq -r '.longurl // .link.url // .url.longurl // .url // empty')
    date=$(    echo "$resp" | jq -r '.timestamp // .link.timestamp // .url.timestamp // empty')
    clicks=$(  echo "$resp" | jq -r '.clicks // .link.clicks // .url.clicks // 0')
    [[ -z "$shorturl" ]] && shorturl="${YOURLS_HOST%/}/$keyword"
    say ""; say "${GRAY}Statistics for:${RESET}\t${BOLD}$shorturl${RESET}"
    [[ -n "$longurl" ]] && say "${GRAY}Long URL:${RESET}\t${BOLD}$longurl${RESET}"
    [[ -n "$date"    ]] && say "${GRAY}Date created:${RESET}\t${BOLD}$date${RESET}"
    say "${GRAY}Clicks:${RESET}\t\t${BOLD}$clicks${RESET}\n"
  else
    say "${ORANGE}(Install 'jq' to see detailed stats)${RESET}"
  fi
  LAST_RESPONSE="$resp"
  return 0
}

expand_short_url() {
  local keyword="$1"; local resp longurl
  resp=$(api_post expand "shorturl=$keyword") || { err "${RED}Failed to expand.${RESET}"; return 1; }
  if command -v jq >/dev/null 2>&1; then
    longurl=$(echo "$resp" | jq -r '.longurl // empty')
  else
    longurl=$(echo "$resp" | sed -n 's/.*"longurl":"\([^"]*\)".*/\1/p')
  fi
  if [[ -z "$longurl" || "$longurl" == "null" ]]; then say "${RED}No long URL found for '${keyword}'.${RESET}"; return 1; fi
  say "${BOLD_WHITE_ON_BLACK}Expanded URL:${RESET}\t${BOLD_BRIGHT_WHITE}$longurl${RESET}"
  LAST_RESPONSE="$resp"
}

delete_short_url() {
  local keyword="$1"; local resp status msg
  resp=$(api_post delete "shorturl=$keyword") || { err "${RED}Delete request failed.${RESET}"; return 1; }
  if command -v jq >/dev/null 2>&1; then
    status=$(echo "$resp" | jq -r '.status // .message // empty')
    if [[ "$status" == "success" ]]; then
      say "\n${GREEN}Successfully deleted:${RESET} ${YOURLS_HOST%/}/$keyword\n"; LAST_RESPONSE="$resp"; return 0
    fi
    msg=$(echo "$resp" | jq -r '.message // .error // "Unknown error"')
  else
    if echo "$resp" | grep -qi '"success"'; then
      say "\n${GREEN}Successfully deleted:${RESET} ${YOURLS_HOST%/}/$keyword\n"; LAST_RESPONSE="$resp"; return 0
    fi
    msg="$resp"
  fi
  say "${RED}Failed to delete '${keyword}': ${msg}${RESET}"; LAST_RESPONSE="$resp"; return 1
}

format_last_response() {
  local fmt="$1"
  case "$fmt" in
    json|jsonp) [[ -n "${LAST_RESPONSE:-}" ]] && say "${GRAY}${LAST_RESPONSE}${RESET}" ;;
    xml)        say "${ORANGE}(Note) XML output is only shown for list/shorten paths in this script.${RESET}" ;;
    simple|*)   : ;;
  esac
}

#===============================================================================
# Arg parsing
#===============================================================================

[[ -z "$1" || "$1" == "--help" || "$1" == "-h" ]] && yourls_help

POSITIONAL=()
FORMAT="simple"
KEYWORD=""; TITLE=""
STATISTICS=""; EXPAND=""; DELETE=""
LIST=false; GLOBAL=false
AUTO_COPY="n"
OPEN_AFTER="false"; SHOW_QR="false"
BATCH_FILE=""
FETCH_TITLE="false"   # reserved; not used in v1.2.x

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) show_version; exit 0 ;;
    -k|--keyword) KEYWORD="$2"; shift 2 ;;
    -t|--title)   TITLE="$2"; shift 2 ;;
    -f|--format)  FORMAT="$(echo "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
    -s|--statistics) STATISTICS="true"; shift ;;
    -e|--expand)     EXPAND="true"; shift ;;
    -d|--delete)     DELETE="true"; shift ;;
    -l|--list)       LIST=true; shift ;;
    -g|--global)     GLOBAL=true; shift ;;
    --assume-https)  ASSUME_HTTPS="true"; shift ;;
    --strict)        STRICT_INPUT="true"; shift ;;
    --open)          OPEN_AFTER="true"; shift ;;
    --qr)            SHOW_QR="true"; shift ;;
    --batch)         BATCH_FILE="$2"; shift 2 ;;
    --quiet)         QUIET=true; shift ;;
    --verbose)       VERBOSE=true; shift ;;
    --no-color)      disable_colors; shift ;;
    --ipv4)          CURL_IPVER="-4"; shift ;;
    --ipv6)          CURL_IPVER="-6"; shift ;;
    --insecure)      CURL_OPTS+=( -k ); shift ;;
    --profile)       PROFILE="$2"; CONFIG_FILE="$HOME/.config/yourls-cli/${PROFILE}.cfg"; shift 2 ;;
    -i|--check)
      say "\n${GRAY}+--------------------------------------------------------+"
      say "${GRAY}|${ORANGE}            CHECKING & INSTALLING DEPENDENCIES          ${GRAY}|"
      say "${GRAY}+--------------------------------------------------------+${RESET}\n"
      say "${GRAY}Core tools:${RESET} curl, jq"
      say "${GRAY}Clipboard (optional):${RESET} wl-clipboard (Wayland) / xclip (X11) / pbcopy (macOS) / clip.exe (Windows)"
      say "${GRAY}Extras (optional):${RESET} qrencode (for --qr)\n"
      check_dependencies true true true
      say ""; exit 0
      ;;
    -c|--change-config)
      say "${GRAY}+--------------------------------------------------------+"
      say "${GRAY}|${ORANGE}                     CHECK CONFIGURATION                 ${GRAY}|"
      say "${GRAY}+--------------------------------------------------------+${RESET}\n"
      if check_connection; then
        say "${CYAN}Your current config:${RESET}"
        say "${GRAY}${ITALIC}File: $CONFIG_FILE${RESET}\n"; cat "$CONFIG_FILE"; say ""
        say "${ORANGE}Re-enter credentials? [y/n]: ${RESET}"; read -r REENTER; [[ "$REENTER" != "y" ]] && exit 0
      fi
      rm -f -- "$CONFIG_FILE"; prompt_for_credentials; exit 0
      ;;
    --autocopy-on)  sed -i "/^AUTO_COPY=/c\AUTO_COPY=\"y\"" "$CONFIG_FILE" 2>/dev/null; AUTO_COPY="y"; say "\nAutocopy is ${GREEN}ON${RESET}\n"; exit 0 ;;
    --autocopy-off) sed -i "/^AUTO_COPY=/c\AUTO_COPY=\"n\"" "$CONFIG_FILE" 2>/dev/null; AUTO_COPY="n"; say "\nAutocopy is ${RED}OFF${RESET}\n"; exit 0 ;;
    -h|--help) yourls_help; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

#===============================================================================
# Load config & ensure connection
#===============================================================================

# First-run banner
if [[ ! -f "$CONFIG_FILE" ]]; then
  say "${GRAY}+--------------------------------------------------------+"
  say "${GRAY}|${ORANGE}                   SETUP AND CONFIGURATION              ${GRAY}|"
  say "${GRAY}+--------------------------------------------------------+${RESET}\n"
  say "This is the first start of ${APP_NAME}. Please enter your YOURLS credentials.\n"
fi

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  ensure_config_perms
  if [[ "${AUTO_COPY:-n}" != "y" && "${AUTO_COPY:-n}" != "n" ]]; then
    AUTO_COPY="n"; sed -i "/^AUTO_COPY=/c\AUTO_COPY=\"$AUTO_COPY\"" "$CONFIG_FILE"
  fi
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  prompt_for_credentials
elif ! check_connection; then
  say "${RED}Connection failed. Please re-enter your credentials.${RESET}"
  prompt_for_credentials
fi

# Minimal base deps (non-interactive here)
check_dependencies false "${AUTO_COPY:-n}" false

#===============================================================================
# Guards & mutual exclusion checks
#===============================================================================

# Mutually exclusive management flags
if { [[ -n "$STATISTICS" ]] && [[ -n "$EXPAND" ]]; } || \
   { [[ -n "$STATISTICS" ]] && [[ -n "$DELETE" ]]; } || \
   { [[ -n "$EXPAND" ]] && [[ -n "$DELETE" ]]; }; then
  err "\n${RED}Error:${RESET} Only one of -s, -e, -d can be used at a time.\n"; exit 1
fi
# For -s/-e/-d a keyword or your short URL is required
if { [[ -n "$STATISTICS" ]] || [[ -n "$EXPAND" ]] || [[ -n "$DELETE" ]]; } && [[ -z "${1:-}" ]]; then
  err "\n${RED}Error:${RESET} Provide a keyword or short URL with -s/-e/-d.\n"; exit 1
fi

#===============================================================================
# Actions: management, global, list
#===============================================================================

# Management
if [[ -n "$STATISTICS" || -n "$EXPAND" || -n "$DELETE" ]]; then
  kw="$(resolve_keyword "$1")" || { err "${RED}Please provide a keyword or a short URL on ${YOURLS_HOST}${RESET}"; exit 1; }
  if [[ -n "$STATISTICS" ]]; then
    say "\n${ORANGE}Checking statistics for${RESET} $kw..."
    if print_url_statistics "$kw"; then format_last_response "$FORMAT"; exit 0; else format_last_response "$FORMAT"; exit 1; fi
  elif [[ -n "$EXPAND" ]]; then
    say "\n${ORANGE}Expanding${RESET} $kw..."
    if expand_short_url "$kw"; then format_last_response "$FORMAT"; exit 0; else format_last_response "$FORMAT"; exit 1; fi
  elif [[ -n "$DELETE" ]]; then
    say ""; read -r -p "Are you sure you want to delete '${kw}'? [y/N] " REPLY; say ""
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
      if delete_short_url "$kw"; then format_last_response "$FORMAT"; exit 0; else format_last_response "$FORMAT"; exit 1; fi
    else say "${GRAY}Canceled.${RESET}"; exit 0; fi
  fi
fi

# Global DB stats
if [[ "$GLOBAL" == true ]]; then
  resp=$(api_post db-stats) || { err "${RED}Failed to fetch global stats.${RESET}"; exit 1; }
  if command -v jq >/dev/null 2>&1; then
    total_links=$(echo "$resp" | jq -r '.["db-stats"].total_links // .db_stats.total_links // .total_links // 0')
    total_clicks=$(echo "$resp" | jq -r '.["db-stats"].total_clicks // .db_stats.total_clicks // .total_clicks // 0')
  else
    total_links="(install jq for details)"; total_clicks="(install jq for details)"
  fi

  say "${GRAY}+--------------------------------------------------------+"
  say "${GRAY}|${ORANGE}                    GLOBAL STATISTICS                   ${GRAY}|"
  say "${GRAY}+--------------------------------------------------------+${RESET}\n"
  say "SERVER:\t${CYAN}${BOLD}${YOURLS_HOST}${RESET}\n"
  say "Total links:\t${CYAN}${BOLD}${total_links}${RESET}"
  say "Total clicks:\t${CYAN}${BOLD}${total_clicks}${RESET}\n"

  resp=$(api_post stats "filter=top" "limit=3") || true
  if command -v jq >/dev/null 2>&1 && [[ "$(echo "$resp" | jq -r '.links | length')" -gt 0 ]]; then
    say "${YELLOW}TOP 3 MOST ACCESSED URLs:${RESET}\n"
    echo "$resp" | jq -r '.links | to_entries[] | [.value.shorturl, .value.clicks] | @tsv'
  else say "${ORANGE}No links in the database or jq missing.${RESET}"; fi
  say "\n###\n"
  resp=$(api_post stats "filter=bottom" "limit=3") || true
  if command -v jq >/dev/null 2>&1 && [[ "$(echo "$resp" | jq -r '.links | length')" -gt 0 ]]; then
    say "${YELLOW}TOP 3 LEAST ACCESSED URLs:${RESET}\n"
    echo "$resp" | jq -r '.links | to_entries[] | [.value.shorturl, .value.clicks] | @tsv'
  else say "${ORANGE}No links in the database or jq missing.${RESET}"; fi
  say ""; exit 0
fi

# List (interactive)
if [[ "$LIST" == true ]]; then
  say "${GRAY}+--------------------------------------------------------+"
  say "${GRAY}|${ORANGE}                      DATABASE LIST                     ${GRAY}|"
  say "${GRAY}+--------------------------------------------------------+${RESET}\n"
  say "Choose the output format:\n"
  say "1. XML"
  say "2. JSON (default)"
  say "3. Export XML to file"
  say "4. Export JSON to file"
  say "5. Show as table"
  say "6. Most accessed URLs"
  say "7. Least accessed URLs\n"
  read -r -p "Enter your choice (1-7, or press return to exit): " choice
  [[ -z "$choice" ]] && say "${ITALIC}Exiting...${RESET}\n" && exit 0

  if [[ "$choice" == "1" || "$choice" == "3" ]]; then list_format="xml"; limit="1000000"
  elif [[ "$choice" == "6" || "$choice" == "7" ]]; then list_format="json"; limit="10"
  else list_format="json"; limit="1000000"; fi

  if [[ "$choice" == "6" ]]; then filter="top"
  elif [[ "$choice" == "7" ]]; then filter="bottom"
  else filter="all"; fi

  response=$(api_post stats "filter=$filter" "limit=$limit" "format=$list_format") || { err "${RED}Failed to fetch list.${RESET}"; exit 1; }

  if [[ "$list_format" == "json" && command -v jq >/dev/null 2>&1 && "$(echo "$response" | jq -r '.links | length')" -eq 0 ]]; then
    say "${CYAN}No links in the database.${RESET}"; exit 0
  fi

  default_filepath="$HOME/yourls_data.$list_format"

  case "$choice" in
    3)
      say "Default path: $default_filepath"
      read -r -p "Save XML to (press enter for default): " filepath
      filepath=${filepath:-$default_filepath}; printf '%s' "$response" > "$filepath"; say "XML exported to $filepath"
      ;;
    4)
      say "Default path: $default_filepath"
      read -r -p "Save JSON to (press enter for default): " filepath
      filepath=${filepath:-$default_filepath}; printf '%s' "$response" > "$filepath"; say "JSON exported to $filepath"
      ;;
    5|6|7)
      if [[ "$list_format" == "json" && command -v jq >/dev/null 2>&1 ]]; then
        say ""
        if [[ "$choice" == "5" ]]; then say "${CYAN}LIST OF URLs:\n${RESET}"
        elif [[ "$choice" == "6" ]]; then say "${CYAN}TOP 10 MOST ACCESSED URLs\n${RESET}"
        else say "${CYAN}TOP 10 LEAST ACCESSED URLs\n${RESET}"; fi
        printf "%s%-5s  %-30s  %-30s  %-35s  %-15s  %-20s  %-10s%s\n" "$(tput setaf 4)" "#" "Short-URL" "Long-URL" "Title" "Date" "IP" "Clicks" "$(tput sgr0)"
        echo
        i=0; tempfile=$(mktemp)
        echo "$response" | jq -r '.links | to_entries[] | [.value.shorturl, .value.url, .value.title, .value.timestamp, .value.ip, .value.clicks] | @tsv' > "$tempfile"
        while IFS=$'\t' read -r shorturl url title timestamp ip clicks; do
          url=$(echo "$url" | awk '{print substr($0, 1, 30)}')
          title=$(echo "$title" | awk '{print substr($0, 1, 35)}' | sed 's/[^[:print:]\t]//g')
          date=$(echo "$timestamp" | cut -d ' ' -f1)
          printf "%-5s  %-30s  %-30s  %-35s  %-15s  %-20s  %-10s\n" "$((++i))" "$shorturl" "$url" "$title" "$date" "$ip" "$clicks"
        done < "$tempfile" | more
        rm -f -- "$tempfile"
      else
        say "Table view is not supported for XML or when 'jq' is missing."
      fi
      ;;
    1|2) echo "$response" | ( [[ "$list_format" == "json" && $(command -v jq) ]] && jq || cat ) ;;
    *) echo "$response" | ( command -v jq >/dev/null 2>&1 && jq || cat ) ;;
  esac
  say ""; exit 0
fi

#===============================================================================
# Batch mode (stdin or --batch file)
#===============================================================================

if [[ -n "$BATCH_FILE" || (! -t 0 && -z "${1:-}") ]]; then
  SRC="${BATCH_FILE:--}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    RAW_INPUT="$line"
    if ! normalize_for_batch "$RAW_INPUT"; then
      err "SKIP\t$RAW_INPUT"  # to stderr
      continue
    fi
    URL="$URL_OUT"
    resp=$(api_post shorturl "url=$URL" "keyword=$KEYWORD" "title=$TITLE") || { err "ERR\t$URL"; continue; }
    if command -v jq >/dev/null 2>&1; then
      short=$(echo "$resp" | jq -r '.shorturl // empty')
    else
      short=$(echo "$resp" | sed -n 's/.*"shorturl":"\([^"]*\)".*/\1/p')
    fi
    echo -e "$URL\t$short"  # TSV to stdout
  done < "$SRC"
  exit 0
fi

#===============================================================================
# Shorten path (single)
#===============================================================================

if [[ -z "${1:-}" ]]; then
  err "\n${RED}Error:${RESET} Please provide a URL to shorten (or use -h).\nExamples:\n  ${0##*/} https://example.com\n  ${0##*/} example.com ${GRAY}(will prompt or auto-https with --assume-https)${RESET}\n"
  exit 1
fi

RAW_INPUT="$1"; shift || true
if ! normalize_or_prompt_url "$RAW_INPUT"; then exit 1; fi
URL="$URL_OUT"

if is_our_short_host "$URL"; then
  err "${GRAY}It is not possible to shorten a short URL on ${YOURLS_HOST}.${RESET}\n"; exit 1
fi

response=$(api_post shorturl "url=$URL" "keyword=$KEYWORD" "title=$TITLE") || { err "${RED}Shorten request failed.${RESET}"; exit 1; }
if command -v jq >/dev/null 2>&1; then
  status=$(echo "$response" | jq -r '.status // .message // empty')
  message=$(echo "$response" | jq -r '.message // empty')
  shorturl=$(echo "$response" | jq -r '.shorturl // empty')
else
  status=$([[ "$(echo "$response" | grep -qi '"success"'; echo $?)" -eq 0 ]] && echo "success" || echo "fail")
  message="$response"
  shorturl=$(echo "$response" | sed -n 's/.*"shorturl":"\([^"]*\)".*/\1/p')
fi

if [[ "$status" == "fail" ]]; then
  say ""; say "${ORANGE}${message}${RESET}"
  if [[ -n "$shorturl" && "$shorturl" != "null" ]]; then
    say ""; say "${BOLD}${GRAY}Existing short URL:${RESET} ${BOLD}${CYAN}$shorturl${RESET}"
    kw="$(basename "${shorturl%%\?*}")"; print_url_statistics "$kw" || true
    [[ "${AUTO_COPY:-n}" == "y" ]] && { copy_to_clipboard "$shorturl"; say ""; }
  fi
  LAST_RESPONSE="$response"; format_last_response "$FORMAT"; exit 0
elif [[ "$status" == "success" ]]; then
  say ""; say "The URL ${BOLD}${CYAN}$URL${RESET} was ${BOLD}${GREEN}successfully${RESET} shortened."
  say ""; say "${BOLD}${ORANGE}Your SHORT URL:${RESET}${BOLD}${CYAN}$shorturl${RESET}\n"
  [[ "${AUTO_COPY:-n}" == "y" && -n "$shorturl" && "$shorturl" != "null" ]] && { copy_to_clipboard "$shorturl"; say ""; }
  [[ "$OPEN_AFTER" == "true" ]] && open_url "$shorturl"
  [[ "$SHOW_QR"   == "true" ]] && print_qr "$shorturl"
  LAST_RESPONSE="$response"; format_last_response "$FORMAT"; exit 0
else
  err "${RED}Unexpected response from YOURLS.${RESET}\n${GRAY}$response${RESET}"; exit 1
fi
