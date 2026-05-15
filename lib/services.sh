#!/usr/bin/env bash
# ==============================================================================
#  lib/services.sh  —  Service Catalog & Deployment Engine
#  Add new services here. Format: image|port|dir|env|extra_ports|extra_volumes|extra_args
# ==============================================================================

# ── Service Catalog ───────────────────────────────────────────────────────────
# Fields: image | default_port | config_dir | extra_env | extra_ports | extra_volumes | extra_args
# extra_env:     comma-separated KEY=VALUE pairs
# extra_ports:   comma-separated HOST:CONTAINER pairs
# extra_volumes: comma-separated HOST:CONTAINER pairs (use CFG_DIR as placeholder)
# extra_args:    raw docker run flags (e.g. --gpus all)

declare -A SERVICES
SERVICES=(
  # ── Tier 1: Management ────────────────────────────────────────────────────
  [homarr]="ghcr.io/homarr-labs/homarr:latest|7575|homarr:appdata|SECRET_ENCRYPTION_KEY=__GENERATE__||/var/run/docker.sock:/var/run/docker.sock|"
  [portainer]="portainer/portainer-ce:latest|9000|portainer:data|||/var/run/docker.sock:/var/run/docker.sock|"

  # ── Tier 2: Personal Cloud ────────────────────────────────────────────────
  [filebrowser]="filebrowser/filebrowser:s6|8080|filebrowser|PUID=1000,PGID=1000,TZ=Africa/Tunis|:80|${MEDIA_DIR}:/srv|"
  [nextcloud]="lscr.io/linuxserver/nextcloud:latest|8090|nextcloud|PUID=1000,PGID=1000,TZ=Africa/Tunis|:443||"

  # ── Tier 3: Media ─────────────────────────────────────────────────────────
  [jellyfin]="lscr.io/linuxserver/jellyfin:latest|8096|jellyfin|PUID=1000,PGID=1000,TZ=Africa/Tunis||${MEDIA_DIR}:/media|"
  [prowlarr]="lscr.io/linuxserver/prowlarr:latest|9696|prowlarr|PUID=1000,PGID=1000,TZ=Africa/Tunis|||"
  [qbittorrent]="lscr.io/linuxserver/qbittorrent:latest|8080|qbittorrent|PUID=1000,PGID=1000,TZ=Africa/Tunis,WEBUI_PORT=8080||${MEDIA_DIR}/downloads:/downloads|"
  [navidrome]="deluan/navidrome:latest|4533|navidrome:data|PUID=1000,PGID=1000,TZ=Africa/Tunis,ND_UILOGINBACKGROUNDURL=https://wallpapercave.com/wp/wp11990842.jpg,ND_DEFAULTTHEME=Catppuccin Macchiato||${MEDIA_DIR}/music:/music|"
  [kavita]="lscr.io/linuxserver/kavita:latest|5000|kavita|PUID=1000,PGID=1000,TZ=Africa/Tunis||${MEDIA_DIR}:/media|"
)

# ── Ordered Service List (for menu) ───────────────────────────────────────────
ORDERED_SERVICES=(
  "homarr" "portainer"
  "filebrowser" "nextcloud"
  "jellyfin" "navidrome" "kavita" "qbittorrent" "prowlarr"
)

declare -A SERVICE_DESCRIPTIONS
SERVICE_DESCRIPTIONS=(
  [homarr]="Tier 1 · Lightweight home dashboard"
  [portainer]="Tier 1 · Docker container visualizer"
  [filebrowser]="Tier 2 · Personal cloud file manager"
  [nextcloud]="Tier 2 · Full personal cloud suite"
  [jellyfin]="Tier 3 · Media streaming server"
  [navidrome]="Tier 3 · Modern music server"
  [qbittorrent]="Tier 3 · Lightweight BitTorrent client"
  [prowlarr]="Tier 3 · Indexer manager for media"
  [kavita]="Tier 3 · Ultimate Ebook & Manga reader"
)

declare -A SERVICE_REQUIREMENTS
SERVICE_REQUIREMENTS=(
  [homarr]="128|500"
  [portainer]="128|500"
  [filebrowser]="128|1000"
  [nextcloud]="512|2000"
  [jellyfin]="1024|4000"
  [navidrome]="256|1000"
  [qbittorrent]="256|2000"
  [prowlarr]="256|1000"
  [kavita]="512|2000"
)

# ── Deployment Logic ──────────────────────────────────────────────────────────

deploy_service() {
  local name=$1 port=$2
  local def="${SERVICES[$name]}"
  [[ -z "$def" ]] && die "Service ${name} not defined in catalog."

  # Parse service definition into local variables
  local image default_port _dir extra_env extra_ports extra_volumes extra_args
  IFS='|' read -r image default_port _dir extra_env extra_ports extra_volumes extra_args <<< "$def"

  # Handle custom internal config mapping if specified as "dir:internal_path"
  local cfg_name_only="${_dir%%:*}"
  local internal_cfg_path="${_dir#*:}"
  
  # Ensure internal path is absolute
  if [[ "$internal_cfg_path" == "$_dir" ]]; then
    internal_cfg_path="/config"
  elif [[ "$internal_cfg_path" != /* ]]; then
    internal_cfg_path="/${internal_cfg_path}"
  fi

  local cfg_dir="${CONFIG_BASE}/${cfg_name_only}"
  mkdir -p "$cfg_dir"

  # Pre-flight: Build or Pull image
  local custom_df="${DOCKER_FILES_DIR}/${name}-dockerfile"
  local active_image="$image"
  
  if [[ -f "$custom_df" ]]; then
    run_task "Building custom ${name} image" "docker build -t local-${name}:latest -f $custom_df $DOCKER_FILES_DIR"
    active_image="local-${name}:latest"
  else
    run_task "Verifying ${name} image" "docker pull ${image}"
  fi

  info "Starting ${name} container..."
  local run_cmd=(docker run -d --name "$name" --restart unless-stopped)
  run_cmd+=(--network "$PROXY_NETWORK")
  
  # Smart port mapping for containers with mismatched internal ports
  local internal_port="$default_port"
  if [[ "$extra_ports" == :* ]]; then
    internal_port="${extra_ports#:}"
    extra_ports="" # Clear it so it's not mapped twice
  fi
  run_cmd+=(-p "${port}:${internal_port}")

  if [[ -n "$extra_args" ]]; then
    local args_arr
    read -ra args_arr <<< "$extra_args"
    run_cmd+=("${args_arr[@]}")
  fi

  if [[ -n "$extra_ports" ]]; then
    local port_arr ep
    IFS=',' read -ra port_arr <<< "$extra_ports"
    for ep in "${port_arr[@]}"; do run_cmd+=(-p "$ep"); done
  fi

  # Firewall safety: Ensure the host port is open to the internet
  if command -v ufw &>/dev/null; then
    sudo ufw allow "$port"/tcp &>> "$LOG_FILE" || true
  fi

  run_cmd+=(-v "${cfg_dir}:${internal_cfg_path}")

  if [[ -n "$extra_volumes" ]]; then
    local vol_arr ev
    IFS=',' read -ra vol_arr <<< "$extra_volumes"
    for ev in "${vol_arr[@]}"; do
      run_cmd+=(-v "${ev//CFG_DIR/$cfg_dir}")
    done
  fi

  if [[ -n "$extra_env" ]]; then
    local env_arr e
    IFS=',' read -ra env_arr <<< "$extra_env"
    for e in "${env_arr[@]}"; do
      if [[ "$e" == *=__GENERATE__ ]]; then
        local key_name="${e%%=*}"
        e="${key_name}=$(openssl rand -hex 32)"
        info "Generated random value for ${key_name}."
      fi
      run_cmd+=(-e "$e")
    done
  fi

  run_cmd+=("$active_image")
  run_task "Launching container" "$(printf "%q " "${run_cmd[@]}")"

  state_set_service "$name" "$port" "running"
  success "${name} deployed on port ${port}.  Config: ${cfg_dir}"
  
  if [[ -v MULTI_DEPLOY_SUMMARY ]]; then
    MULTI_DEPLOY_SUMMARY+=("  ${GREEN}${OK}${NC} ${BOLD}${name}${NC} deployed on port ${TEAL}:${port}${NC}")
  fi

  # ── Post-deploy hooks ──────────────────────────────────────────────────────
  if [[ "$name" == "qbittorrent" ]]; then
    info "Applying robust 'Unauthorized' fix..."
    local conf_file="${cfg_dir}/qBittorrent/qBittorrent.conf"
    
    # Wait for config to be generated (up to 20s)
    local retries=10
    while [[ ! -f "$conf_file" && $retries -gt 0 ]]; do
      sleep 2
      ((retries--))
    done

    if [[ -f "$conf_file" ]]; then
      # Stop to ensure it doesn't overwrite our changes
      docker stop "$name" > /dev/null

      # Remove any existing entries to avoid duplicates
      sed -i '/WebUI\\HostHeaderValidation/d' "$conf_file"
      sed -i '/WebUI\\CSRFProtection/d' "$conf_file"

      # Add bypasses under [Preferences]
      if grep -q "\[Preferences\]" "$conf_file"; then
        sed -i '/\[Preferences\]/a WebUI\\HostHeaderValidation=false\nWebUI\\CSRFProtection=false' "$conf_file"
      else
        echo -e "\n[Preferences]\nWebUI\\HostHeaderValidation=false\nWebUI\\CSRFProtection=false" >> "$conf_file"
      fi

      # Remove stale lock files left by docker stop to prevent single-instance false-positive
      local qbt_dir; qbt_dir="$(dirname "$conf_file")"
      rm -f "${qbt_dir}/lockfile" "${qbt_dir}/ipc-socket"

      docker start "$name" > /dev/null
      success "qBittorrent security checks bypassed successfully."
    else
      warn "qBittorrent.conf not found after waiting. You may need to restart manually."
    fi
    # Flag for cmd_up to show the password
    export QBITTORRENT_CHECK_PASSWORD=true
  fi
}
