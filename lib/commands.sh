#!/usr/bin/env bash
# ==============================================================================
#  lib/commands.sh  —  Interactive Menu Commands
#  Each cmd_* function maps to a main menu option
# ==============================================================================

# ── Initialize ────────────────────────────────────────────────────────────────

cmd_initialize() {
  show_header
  label "Phase 1: Environment Validation"
  validate_os
  install_deps
  separator

  label "Phase 2: Core Infrastructure"
  install_docker
  setup_network
  setup_firewall
  setup_media_dir
  setup_config_dir
  deploy_reverse_proxy
  separator

  success "VPS is fully initialized and ready!"
  state_set ".initialized" "true"
  pause
}

# ── Deploy / Remove ───────────────────────────────────────────────────────────

cmd_up() {
  show_header
  label "Service Catalog & Smart Deployment"
  echo

  local free_ram; free_ram=$(free -m | awk '/^Mem:/{print $7}')
  local i=1
  declare -a menu_keys

  for key in "${ORDERED_SERVICES[@]}"; do
    menu_keys+=("$key")
    local desc="${SERVICE_DESCRIPTIONS[$key]:-}"
    local reqs="${SERVICE_REQUIREMENTS[$key]:-256|1000}"
    local req_ram="${reqs%%|*}"
    local tag="" tag_color=$NC

    # Resolve dynamic docker status
    local docker_status; docker_status=$(docker inspect -f '{{.State.Status}}' "$key" 2>/dev/null || echo "none")

    case "$docker_status" in
      running)    tag="[RUNNING]";  tag_color=$GREEN ;;
      exited)     tag="[OFFLINE]";  tag_color=$RED ;;
      created)    tag="[CREATED]";  tag_color=$YELLOW ;;
      restarting) tag="[RESTARTING]"; tag_color=$MAUVE ;;
      *)
        if (( free_ram < req_ram )); then
          tag="[OUT OF RAM]"; tag_color=$RED
        fi
        ;;
    esac

    printf "  ${MAUVE}%2d)${NC} ${BOLD}%-15s${NC} ${DIM}${SUBTEXT}%-40s${NC} ${tag_color}%s${NC}\n" \
      "$i" "$key" "$desc" "$tag"
    (( i++ ))
  done

  echo
  separator
  prompt "Select service numbers (e.g., '1 4 5', or 0 to cancel)" choice

  if [[ "$choice" == "0" || -z "$choice" ]]; then pause; return; fi

  separator
  
  # Pre-flight: Validation & Input Collection
  local deploy_names=()
  local -A deploy_ports=()

  for c in $choice; do
    if [[ ! "$c" =~ ^[0-9]+$ ]]; then
      error "Invalid input: ${c}. Skipping."
      continue
    fi
    local idx=$(( c - 1 ))
    local selected="${menu_keys[$idx]:-}"
    if [[ -z "$selected" ]]; then
      error "Invalid selection: $c. Skipping."
      continue
    fi

    local def="${SERVICES[$selected]}"
    local _image default_port _unused
    IFS='|' read -r _image default_port _unused <<< "$def"
    local reqs="${SERVICE_REQUIREMENTS[$selected]:-256|1000}"

    if ! check_resources "${reqs%%|*}" "${reqs##*|}"; then
      warn "Insufficient resources for ${selected}. Skipping."
      continue
    fi

    local d_status; d_status=$(docker inspect -f '{{.State.Status}}' "$selected" 2>/dev/null || true)
    if [[ -n "$d_status" ]]; then
      warn "'${selected}' container is currently ${d_status}."
      
      local sub_done=false
      while [[ "$sub_done" == "false" ]]; do
        printf "  ${MAUVE}──${NC} ${BOLD}[R]${NC}edeploy | ${BOLD}[I]${NC}nfo | ${RED}[P]${NC}urge | ${BOLD}[S]kip: "
        read -r -n 1 action
        while read -t 0.05 -r -n 100; do :; done # Clean buffer
        echo
        
        case "${action,,}" in
          r) 
            docker rm -f "$selected" &>> "$LOG_FILE" || true 
            sub_done=true 
            ;;
          i) 
            show_container_info "$selected" 
            ;;
          p) 
            if confirm "Are you ABSOLUTELY sure you want to PURGE ${selected}?"; then
              docker rm -f "$selected" &>> "$LOG_FILE" || true
              sudo rm -rf "${CONFIG_BASE}/${selected}"
              success "${selected} purged."
              sub_done=true
              continue 2 # Move to next selected service
            fi
            ;;
          s) 
            sub_done=true
            continue 2 # Move to next selected service
            ;;
          *) error "Invalid choice. Use R, I, P, or S." ;;
        esac
      done
    fi

    local p
    if ! is_port_free "$default_port"; then
      local auto_port
      auto_port=$(find_free_port "$default_port")
      error "Default port ${default_port} for ${selected} is already in use."
      printf "  ${MAUVE}?${NC} ${BOLD}Port for ${selected}${NC} [${DIM}auto: ${auto_port}${NC}]: "
      read -r p
      [[ -z "$p" ]] && p="$auto_port"
    else
      printf "  ${MAUVE}?${NC} ${BOLD}Port for ${selected}${NC} [${DIM}default: ${default_port}${NC}]: "
      read -r p
      [[ -z "$p" ]] && p="$default_port"
    fi

    deploy_ports["$selected"]="$p"
    deploy_names+=("$selected")
  done

  if [[ ${#deploy_names[@]} -eq 0 ]]; then
    warn "No services queued for deployment."
    pause
    return
  fi

  # Pull Stage: Parallel Pulls
  separator
  info "Pre-fetching images for deployment in parallel..."
  declare -a pull_pids
  for name in "${deploy_names[@]}"; do
    local def="${SERVICES[$name]}"
    local image _unused
    IFS='|' read -r image _unused <<< "$def"
    local custom_df="${DOCKER_FILES_DIR}/${name}-dockerfile"
    
    if [[ ! -f "$custom_df" ]]; then
      docker pull "$image" > /dev/null 2>&1 &
      pull_pids+=($!)
    fi
  done
  wait "${pull_pids[@]}" 2>/dev/null || true
  success "External images downloaded."

  # Initialize summary array
  MULTI_DEPLOY_SUMMARY=()

  # Launch Stage
  for name in "${deploy_names[@]}"; do
    separator
    info "Deploying: ${name}"
    deploy_service "$name" "${deploy_ports[$name]}"
  done

  if [[ "${QBITTORRENT_CHECK_PASSWORD:-}" == "true" ]]; then
    separator
    info "Retrieving temporary qBittorrent admin password..."
    local retries=10 pass=""
    while [[ -z "$pass" && $retries -gt 0 ]]; do
      sleep 2
      pass=$(docker logs qbittorrent 2>&1 | grep -oP 'for this session: \K\S+' | tail -n 1 || true)
      (( retries-- ))
    done
    
    if [[ -n "$pass" ]]; then
      MULTI_DEPLOY_SUMMARY+=("      ${ARR} ${YELLOW}qBittorrent Admin Password: ${BOLD}${pass}${NC}")
    else
      MULTI_DEPLOY_SUMMARY+=("      ${ARR} ${RED}qBittorrent Password not found. Default is usually 'adminadmin' or check 'docker logs qbittorrent'${NC}")
    fi
    unset QBITTORRENT_CHECK_PASSWORD
  fi

  # Print Summary if any deployments took place
  if [[ ${#MULTI_DEPLOY_SUMMARY[@]} -gt 0 ]]; then
    separator
    label "Deployment Summary"
    echo
    for line in "${MULTI_DEPLOY_SUMMARY[@]}"; do
      echo -e "$line"
    done
    echo
  fi
  
  pause

}

cmd_down() {
  local target=${1:-}
  if [[ -z "$target" ]]; then
    show_header
    label "Remove a Service"
    echo

    local i=1
    declare -a containers
    # Get only managed containers (or all running ones)
    while read -r name; do
      containers+=("$name")
      printf "  ${MAUVE}%2d)${NC} ${BOLD}%s${NC}\n" "$i" "$name"
      (( i++ ))
    done < <(docker ps --format '{{.Names}}')

    if [[ ${#containers[@]} -eq 0 ]]; then
      warn "No running containers found."
      pause
      return
    fi

    echo
    separator
    prompt "Select service to remove (1-${#containers[@]}, or 0 to cancel)" pick
    
    [[ -z "$pick" || "$pick" == "0" ]] && { pause; return; }
    
    local idx=$(( pick - 1 ))
    target="${containers[$idx]:-}"
  fi

  [[ -z "$target" ]] && { error "Invalid selection."; pause; return; }

  if confirm "Stop and remove '${target}'?"; then
    run_task "Removing container ${target}" "docker rm -f '${target}'"
    state_remove_service "$target"
    success "'${target}' removed."
  fi
  pause
}

# ── Proxy Management ──────────────────────────────────────────────────────────

cmd_proxy() {
  show_header
  label "Reverse Proxy Management"
  echo
  info "Status: $(docker ps --filter "name=nginx-proxy-manager" --format "{{.Status}}" 2>/dev/null || echo "Not Running")"
  echo
  printf "  ${MAUVE}1)${NC} ${BOLD}Deploy / Redeploy Proxy${NC}\n"
  printf "  ${RED}2)${NC}   ${BOLD}Stop & Remove Proxy${NC}\n"
  printf "  ${RED}0)${NC}   Return to Main Menu\n"
  echo
  prompt "Select" PROXY_CHOICE

  case "${PROXY_CHOICE:-}" in
    1)
      if docker ps -a --format '{{.Names}}' | grep -q "^nginx-proxy-manager$"; then
        if confirm "Proxy is already present. Redeploy it?"; then
          run_task "Removing existing Proxy" "docker rm -f nginx-proxy-manager"
          state_set ".proxy_deployed" "false"
          deploy_reverse_proxy
        fi
      else
        deploy_reverse_proxy
      fi
      ;;
    2)
      if confirm "Are you sure you want to STOP and REMOVE the Reverse Proxy?"; then
        run_task "Removing Proxy" "docker rm -f nginx-proxy-manager"
        state_set ".proxy_deployed" "false"
        success "Reverse Proxy removed."
      fi
      ;;
    0) return ;;
    *) error "Invalid option." ;;
  esac
  pause
}

# ── Health Dashboard ──────────────────────────────────────────────────────────

cmd_status() {
  while true; do
    show_header
    label "Health Dashboard"
    echo

    printf "  ${BOLD}${SUBTEXT}%3s  %-22s %-12s %-18s %s${NC}\n" "#" "CONTAINER" "STATUS" "PORTS" "IMAGE"
    separator

    local i=1
    declare -a _status_containers=()

    while IFS='|' read -r name status image ports; do
      _status_containers+=("$name")
      local col=$GREEN
      [[ "$status" != Up* ]] && col=$RED
      local image_short="${image##*/}"

      local p; p=$(echo "$ports" | grep -oP '(?<=0.0.0.0:)[0-9-]+(?=->)|(?<=\[::\]:)[0-9-]+(?=->)' | sort -un | paste -sd ',' -)
      [[ -z "$p" ]] && p="N/A"

      local cleaner_status; cleaner_status=$(echo "$status" | sed 's/ (.*//' | cut -c1-12)

      printf "  ${MAUVE}%2d)${NC} ${col}%-22s${NC} %-12s ${TEAL}%-18s${NC} ${DIM}%s${NC}\n" \
        "$i" "$name" "$cleaner_status" "$p" "$image_short"
      (( i++ ))
    done < <(docker ps --format '{{.Names}}|{{.Status}}|{{.Image}}|{{.Ports}}' 2>/dev/null)

    separator
    local total used free
    total=$(free -m | awk '/^Mem:/{print $2}')
    used=$(free -m  | awk '/^Mem:/{print $3}')
    free=$(free -m  | awk '/^Mem:/{print $7}')
    echo
    printf "  ${SAPPHIRE}RAM${NC}  total: ${BOLD}%sMB${NC}  used: ${YELLOW}%sMB${NC}  free: ${GREEN}%sMB${NC}\n" \
      "$total" "$used" "$free"

    local disk_used disk_free
    disk_used=$(df -h / | awk 'NR==2{print $3}')
    disk_free=$(df -h / | awk 'NR==2{print $4}')
    printf "  ${SAPPHIRE}DISK${NC} used: ${YELLOW}%s${NC}  free: ${GREEN}%s${NC}\n" "$disk_used" "$disk_free"

    show_footer
    echo

    if [[ ${#_status_containers[@]} -eq 0 ]]; then
      pause
      return
    fi

    printf "  ${MAUVE}?${NC} ${BOLD}Inspect container (1-${#_status_containers[@]}) or [Enter] to return${NC}: "
    read -r pick

    [[ -z "$pick" || "$pick" == "0" ]] && return

    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#_status_containers[@]} )); then
      show_container_info "${_status_containers[$((pick-1))]}"
    else
      error "Invalid selection."
      sleep 1
    fi
  done
}

# ── System Doctor ─────────────────────────────────────────────────────────────

cmd_doctor() {
  set +e # Don't exit if checks fail
  show_header
  label "System Doctor  —  Security & Health Audit"
  echo

  # 1. Docker daemon
  systemctl is-active --quiet docker \
    && success "Docker daemon is running." \
    || error "Docker daemon is NOT running."

  # 2. Restarting containers
  local restarts
  restarts=$(docker ps --filter "status=restarting" --format "{{.Names}}" 2>/dev/null)
  [[ -n "$restarts" ]] \
    && warn "Containers in restart loop: ${restarts}" \
    || success "No containers are in a restart loop."

  # 3. High memory containers (>80% of system RAM)
  local total_mb; total_mb=$(free -m | awk '/^Mem:/{print $2}')
  local threshold=$(( total_mb * 80 / 100 ))
  
  docker stats --no-stream --format "{{.Name}} {{.MemUsage}}" 2>/dev/null \
  | while read -r cname mem_info; do
      local mem_mb; mem_mb=$(echo "$mem_info" | grep -oP '^[\d.]+' | awk '{printf "%d", $1}' 2>/dev/null)
      if [[ -n "$mem_mb" ]] && (( mem_mb > threshold )); then
        warn "${cname} is using high memory: ${mem_info}"
      fi
    done

  # 4. UFW status
  if command -v ufw &>/dev/null; then
    sudo ufw status | grep -q "Status: active" \
      && success "UFW firewall is active." \
      || warn "UFW firewall is NOT active."
  else
    warn "UFW firewall is not installed."
  fi

  # 5. Fail2Ban
  if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban; then
    success "Fail2Ban is active."
  else
    warn "Fail2Ban not detected or inactive."
  fi

  # 6. SSL cert expiry
  local cert_dir="/etc/letsencrypt/live"
  if [[ -d "$cert_dir" ]]; then
    for cert in "${cert_dir}"/*/fullchain.pem; do
      if [[ -f "$cert" ]]; then
        local expiry days
        expiry=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
        days=$(( ( $(date -d "$expiry" +%s) - $(date +%s) ) / 86400 ))
        (( days < 14 )) \
          && warn "SSL cert expires in ${days} days: ${cert}" \
          || success "SSL cert OK (${days} days left): $(basename "$(dirname "$cert")")"
      fi
    done
  fi

  show_footer
  set -e # Restore normal behavior
  pause
}

# ── Clean ─────────────────────────────────────────────────────────────────────

cmd_clean() {
  show_header
  label "Prune Unused Docker Assets"
  echo

  docker system df 2>/dev/null || true
  separator

  if confirm "Remove unused images and stopped containers? (volumes are PRESERVED unless confirmed)"; then
    run_task "Pruning Docker images"     "docker image prune -af"
    run_task "Pruning Docker containers" "docker container prune -f"
    success "Images and stopped containers pruned."

    if confirm "Also remove orphaned volumes? (WARNING: potential data loss)"; then
      run_task "Pruning Docker volumes" "docker volume prune -f"
      success "Orphaned volumes removed."
    else
      warn "Volumes skipped — data is safe."
    fi
  fi

  show_footer
  pause
}

# ── Nuclear Purge ─────────────────────────────────────────────────────────────

cmd_purge() {
  show_header
  label "NUCLEAR PURGE  —  Destroy Setup"
  echo

  warn "WARNING: This will DESTROY all deployed containers, delete all configurations"
  warn "in ${CONFIG_BASE}, remove the docker network, and erase the script state!"
  echo

  if confirm "Are you ABSOLUTELY sure you want to PURGE EVERYTHING?"; then
    run_task "Stopping and removing managed containers" \
      "docker rm -f nginx-proxy-manager $(echo "${!SERVICES[@]}")" || true
    run_task "Removing Docker network (${PROXY_NETWORK})" "docker network rm $PROXY_NETWORK" || true

    if confirm "Delete ALL configurations? (Removes ${CONFIG_BASE})"; then
      run_task "Deleting configuration directory" "rm -rf $CONFIG_BASE"
      success "Configuration directory removed."
    fi

    if confirm "Delete ALL media? (Removes ${MEDIA_DIR})"; then
      sudo rm -rf "$MEDIA_DIR"
      success "Media directory destroyed."
    fi

    info "Resetting script state..."
    rm -f "$STATE_FILE"
    success "System successfully purged. You can now start fresh."
  else
    warn "Purge aborted."
  fi
  pause
}

# ── Main Menu ─────────────────────────────────────────────────────────────────

main_menu() {
  local IN_LOOP=true
  while "$IN_LOOP"; do
    show_header
    label "Main Menu"
    echo
    printf "  ${MAUVE}1)${NC} ${BOLD}Initialize VPS${NC}          ${DIM}${SUBTEXT}Docker + Network + Proxy + Firewall${NC}\n"
    printf "  ${BLUE}2)${NC} ${BOLD}Deploy a Service${NC}         ${DIM}${SUBTEXT}App store (up)${NC}\n"
    printf "  ${TEAL}3)${NC} ${BOLD}Remove a Service${NC}         ${DIM}${SUBTEXT}Stop & clean (down)${NC}\n"
    printf "  ${GREEN}4)${NC} ${BOLD}Health Dashboard${NC}         ${DIM}${SUBTEXT}Status + resources${NC}\n"
    printf "  ${SAPPHIRE}5)${NC} ${BOLD}System Doctor${NC}            ${DIM}${SUBTEXT}Audit + security${NC}\n"
    printf "  ${YELLOW}6)${NC} ${BOLD}Prune & Clean${NC}            ${DIM}${SUBTEXT}Free up disk${NC}\n"
    printf "  ${MAROON}7)${NC} ${BOLD}Nuclear Purge${NC}            ${DIM}${SUBTEXT}Destroy & reset setup${NC}\n"
    printf "  ${SKY}8)${NC} ${BOLD}Proxy Management${NC}         ${DIM}${SUBTEXT}Setup & config proxy (NPM)${NC}\n"
    printf "  ${RED}0)${NC} Exit\n"
    echo
    prompt "Select" CHOICE

    case "${CHOICE:-}" in
      1) cmd_initialize ;;
      2) cmd_up         ;;
      3) cmd_down       ;;
      4) cmd_status     ;;
      5) cmd_doctor     ;;
      6) cmd_clean      ;;
      7) cmd_purge      ;;
      8) cmd_proxy      ;;
      0) 
        echo -e "\n  ${SUBTEXT}Goodbye.${NC}\n"
        exit 0 
        ;;
      *) 
        error "Invalid option."
        sleep 1 
        ;;
    esac
  done
}
