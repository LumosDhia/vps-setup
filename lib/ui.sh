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
    printf "  ${DIM}│${NC} %s\n" "${line}"
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
  local action=""

  while true; do
    while read -t 0.1 -r -n 100; do :; done

    show_header
    label "Container Inspector — ${name}"
    echo

    # 1. Basic details
    local image status ip uptime restart_count
    image=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || echo "N/A")
    status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "N/A")
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" 2>/dev/null || echo "")
    uptime=$(docker inspect -f '{{.State.StartedAt}}' "$name" 2>/dev/null | cut -d. -f1 | sed 's/T/ /')
    restart_count=$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo "0")

    local status_col=$GREEN
    [[ "$status" != "running" ]] && status_col=$RED

    printf "  ${BOLD}${BLUE}  Details${NC}\n"
    printf "  ${DIM}%-16s${NC} %s\n"              "Image:"         "${image}"
    printf "  ${DIM}%-16s${NC} ${status_col}%s${NC}\n" "Status:"   "${status}"
    printf "  ${DIM}%-16s${NC} %s\n"              "IP Address:"    "${ip:-N/A}"
    printf "  ${DIM}%-16s${NC} %s\n"              "Started At:"    "${uptime}"
    printf "  ${DIM}%-16s${NC} %s\n"              "Restarts:"      "${restart_count}"

    # Known log-password patterns: container_name -> grep -oP pattern
    declare -A _LOG_PASS_PATTERNS=(
      [qbittorrent]='(?<=for this session: )\S+'
    )

    if [[ -n "${_LOG_PASS_PATTERNS[$name]:-}" ]]; then
      local _pass
      _pass=$(docker logs "$name" 2>&1 | grep -oP "${_LOG_PASS_PATTERNS[$name]}" | tail -n 1 || true)
      echo
      printf "  ${BOLD}${YELLOW}  Default Session Password${NC}\n"
      if [[ -n "$_pass" ]]; then
        printf "  ${DIM}%-16s${NC} ${BOLD}${GREEN}%s${NC}\n" "Password:" "${_pass}"
      else
        printf "  ${DIM}%-16s${NC} ${SUBTEXT}%s${NC}\n" "Password:" "Not found in logs yet"
      fi
    fi

    # 2. Live resource usage
    echo
    printf "  ${BOLD}${TEAL}  Resource Usage${NC}\n"
    local stats_line
    stats_line=$(docker stats --no-stream --format \
      "CPU: {{.CPUPerc}}   MEM: {{.MemUsage}} ({{.MemPerc}})   NET I/O: {{.NetIO}}   BLOCK I/O: {{.BlockIO}}" \
      "$name" 2>/dev/null || echo "N/A (container not running)")
    printf "  %s\n" "${stats_line}"

    # 3. Port mappings
    echo
    printf "  ${BOLD}${LAVENDER}  Port Mappings${NC}\n"
    local ports_out
    ports_out=$(docker inspect "$name" \
      --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{$p}} -> {{.HostPort}}{{println}}{{end}}{{end}}' \
      2>/dev/null | grep "\->" | sort -u)
    if [[ -n "$ports_out" ]]; then
      echo "$ports_out" | sed 's|^|    › |'
    else
      echo "    › None"
    fi

    # 4. Volume mounts
    echo
    printf "  ${BOLD}${SAPPHIRE}  Volumes / Mounts${NC}\n"
    local mounts_out
    mounts_out=$(docker inspect "$name" \
      --format '{{range .Mounts}}{{.Type}}: {{.Source}} -> {{.Destination}}{{println}}{{end}}' \
      2>/dev/null)
    if [[ -n "$mounts_out" ]]; then
      echo "$mounts_out" | sed 's|^|    › |'
    else
      echo "    › None"
    fi

    # 5. Log preview (last 30 lines)
    echo
    printf "  ${BOLD}${PEACH}  Logs (last 30 lines)${NC}\n"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    docker logs --tail 30 "$name" 2>&1 | while IFS= read -r line; do
      printf "  ${DIM}│${NC} %s\n" "${line}"
    done
    echo -e "  ${DIM}────────────────────────────────────────────────────────────────────────${NC}"

    echo
    printf "  ${MAUVE}L)${NC} Follow live logs   ${MAUVE}R)${NC} Refresh   ${MAUVE}Enter)${NC} Back\n"
    echo
    while read -t 0.1 -n 1 -r; do :; done
    printf "  ${MAUVE}?${NC} ${BOLD}Choice${NC}: "
    read -r -n 1 action
    echo

    case "${action,,}" in
      l)
        echo
        info "Following logs for '${name}' — Press Ctrl+C to stop"
        echo -e "  ${DIM}────────────────────────────────────────────────────────────────────────${NC}"
        docker logs -f --tail 50 "$name" 2>&1 || true
        echo -e "  ${DIM}────────────────────────────────────────────────────────────────────────${NC}"
        echo
        printf "  ${MAUVE}──${NC} ${BOLD}Press [Enter] to continue${NC}: "
        read -r _
        ;;
      r) continue ;;
      *) break ;;
    esac
  done
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
  ! ss -tuln | grep -q ":${port} "
}

find_free_port() {
  local start=$1
  local port=$start
  while ! is_port_free "$port"; do
    (( port++ ))
    [[ $port -gt 65535 ]] && return 1
  done
  echo "$port"
}

