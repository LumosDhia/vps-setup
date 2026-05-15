#!/usr/bin/env bash
# ==============================================================================
#  lib/ui.sh  —  Aesthetics, Colors & UI Components
#  Catppuccin Latte palette via TrueColor ANSI escapes
# ==============================================================================

# ── Color Palette ─────────────────────────────────────────────────────────────
ROSEWATER='\e[38;2;220;138;120m'
FLAMINGO='\e[38;2;221;120;120m'
PINK='\e[38;2;234;118;203m'
MAUVE='\e[38;2;136;57;239m'
RED='\e[38;2;210;15;57m'
MAROON='\e[38;2;230;69;83m'
PEACH='\e[38;2;254;100;11m'
YELLOW='\e[38;2;223;142;29m'
GREEN='\e[38;2;64;160;43m'
TEAL='\e[38;2;23;146;153m'
SKY='\e[38;2;4;165;229m'
SAPPHIRE='\e[38;2;32;159;181m'
BLUE='\e[38;2;30;102;245m'
LAVENDER='\e[38;2;114;135;253m'
TEXT='\e[38;2;76;79;105m'
SUBTEXT='\e[38;2;92;95;119m'
NC='\e[0m'
BOLD='\e[1m'
DIM='\e[2m'

# ── Icons ─────────────────────────────────────────────────────────────────────
OK="✔"
ERR="✖"
WARN="⚠"
ARR="›"

# ── Layout ────────────────────────────────────────────────────────────────────
show_header() {
  clear
  echo
  echo -e "  ${MAUVE}${BOLD}  VPS Home Server Manager${NC}  ${DIM}${SUBTEXT}v2.1${NC}"
  echo -e "  ${SUBTEXT}────────────────────────────────────────────────${NC}"
  echo
}

show_footer() {
  echo
  echo -e "  ${DIM}${SUBTEXT}Log: ${LOG_FILE}${NC}"
  echo -e "  ${SUBTEXT}────────────────────────────────────────────────${NC}"
}

separator() { echo -e "  ${DIM}${SUBTEXT}────────────────────────────────────────────────${NC}"; }
label()     { echo -e "  ${LAVENDER}${BOLD}${1}${NC}"; }

# ── Logging ───────────────────────────────────────────────────────────────────
info()    { echo -e "  ${SKY}${ARR}${NC} ${TEXT}${1}${NC}";           echo "[INFO]    $(date '+%F %T') | ${1}" >> "$LOG_FILE"; }
success() { echo -e "  ${GREEN}${OK}${NC} ${TEXT}${1}${NC}";          echo "[SUCCESS] $(date '+%F %T') | ${1}" >> "$LOG_FILE"; }
warn()    { echo -e "  ${YELLOW}${WARN}${NC} ${TEXT}${1}${NC}";       echo "[WARN]    $(date '+%F %T') | ${1}" >> "$LOG_FILE"; }
error()   { echo -e "  ${RED}${ERR}${NC} ${TEXT}${1}${NC}" >&2;       echo "[ERROR]   $(date '+%F %T') | ${1}" >> "$LOG_FILE"; }
die() {
  error "$1"
  printf "\n  ${MAUVE}──${NC} ${BOLD}Press [Enter] to continue${NC}: "
  read -r _
  exit 1
}

# ── Interaction ───────────────────────────────────────────────────────────────
prompt() {
  local msg=$1 var=$2
  printf "  ${MAUVE}?${NC} ${BOLD}${msg}${NC}: "
  read -r "$var"
}

confirm() {
  local msg=$1
  printf "  ${YELLOW}?${NC} ${BOLD}${msg}${NC} [${GREEN}y${NC}/${RED}n${NC}]: "
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

pause() {
  echo
  echo -e "  ${GREEN}${BOLD}Finished!${NC} ${TEXT}Task completed successfully.${NC}"
  printf "  ${MAUVE}──${NC} ${BOLD}Press [Enter] for Main Menu or [0] to Exit to Terminal${NC}: "
  read -r choice
  if [[ "$choice" == "0" ]]; then
    echo -e "\n  ${SUBTEXT}Goodbye.${NC}\n"
    exit 0
  fi
  return 0
}

# ── Task Runner ───────────────────────────────────────────────────────────────
run_task() {
  local msg="$1"
  local cmd="$2"

  info "$msg..."
  echo -e "  ${DIM}┌────────────────────────────────────────────────────────────────────────┐${NC}"

  set +e
  eval "$cmd" 2>&1 | tee -a "$LOG_FILE" | while IFS= read -r line; do
    # Remove ANSI codes for counting length correctly (optional, but good for raw text)
    # Print up to 70 chars to fit standard wide terminal
    printf "  ${DIM}│${NC} %-70s ${DIM}│${NC}\n" "${line:0:70}"
  done
  local exit_code=${PIPESTATUS[0]}
  set -e

  if [[ $exit_code -eq 0 ]]; then
    echo -e "  ${DIM}└────────────────────────────────────────────────────────────────────────┘${NC}"
    return 0
  else
    echo -e "  ${RED}└──────────────────────────────────────────────────────── FAILED ────┘${NC}"
    return $exit_code
  fi
}

# ── Info Viewer ───────────────────────────────────────────────────────────────
show_container_info() {
  local name=$1
  # Flush stdin to ignore any Enter key from the selection menu 
  while read -t 0.1 -r -n 100; do :; done
  
  show_header
  label "Detailed Container Diagnostics: ${name}"
  echo

  # 1. Inspect Stats
  local image;  image=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null)
  local status; status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)
  local ip;     ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" 2>/dev/null)
  local uptime; uptime=$(docker inspect -f '{{.State.StartedAt}}' "$name" 2>/dev/null | cut -d. -f1 | sed 's/T/ /')

  printf "  ${BOLD}${BLUE}Container Details${NC}\n"
  printf "  ${DIM}%-14s${NC} %s\n" "Image:" "${image}"
  printf "  ${DIM}%-14s${NC} %s\n" "Status:" "${status}"
  printf "  ${DIM}%-14s${NC} %s\n" "IP Address:" "${ip:-N/A}"
  printf "  ${DIM}%-14s${NC} %s\n" "Started At:" "${uptime}"
  
  # 2. Network Mapping
  echo
  printf "  ${BOLD}${LAVENDER}Port Mappings${NC}\n"
  docker inspect "$name" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{$p}} -> {{.HostPort}}{{println}}{{end}}{{end}}' | grep "\->" | sort -u | sed 's|^|    › |' | head -n 10
  
  # 3. First and Last Logs
  echo
  printf "  ${BOLD}${PEACH}Logs (First 20 & Last 20 lines)${NC}\n"
  echo -e "  ${DIM}────────────────────────────────────────────────────────────────────────${NC}"
  
  # Display first 20 lines
  docker logs "$name" 2>&1 | head -n 20 | while IFS= read -r line; do
    printf "  ${DIM}│${NC} %s\n" "$line"
  done

  # Check if there are more than 20 lines to determine if we show the tail
  if [[ $(docker logs "$name" 2>&1 | head -n 21 | wc -l) -eq 21 ]]; then
    printf "  ${DIM}│${NC} ${DIM}... [Middle Logs Omitted] ...${NC}\n"
    docker logs --tail 20 "$name" 2>&1 | while IFS= read -r line; do
      printf "  ${DIM}│${NC} %s\n" "$line"
    done
  fi
  echo -e "  ${DIM}────────────────────────────────────────────────────────────────────────${NC}"
  
  echo
  # Wait for Enter clearly, flushing buffer first 
  # (in case they pressed ENTER during the menu selection)
  while read -t 0.1 -n 1 -r; do :; done 
  prompt "Press [Enter] to return" _
}

# ── Resource Management ───────────────────────────────────────────────────────

check_resources() {
  local req_ram=$1 req_disk=$2
  
  # free -m gives RAM in Megabytes
  local free_ram; free_ram=$(free -m | awk '/^Mem:/{print $7}')
  # df -m gives Disk in Megabytes
  local free_disk; free_disk=$(df -m / | awk 'NR==2{print $4}')
  
  # Basic logic: 0 is success, 1 is failure
  [[ $free_ram -lt $req_ram ]] && return 1
  [[ $free_disk -lt $req_disk ]] && return 1
  
  return 0
}

# ── Port Management ───────────────────────────────────────────────────────────

is_port_free() {
  local port=$1
  # Returns 0 (true) if grep finds nothing (port is free)
  ! ss -tuln | grep -q ":${port} "
}

