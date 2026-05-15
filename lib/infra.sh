#!/usr/bin/env bash
# ==============================================================================
#  lib/infra.sh  —  Core Infrastructure
#  Handles OS validation, Docker install, network, firewall, and media dirs
# ==============================================================================

# ── Environment Validation ────────────────────────────────────────────────────

validate_os() {
  [[ -f /etc/os-release ]] || die "Cannot detect OS."
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "$ID" == "ubuntu" || "$ID" == "debian" ]] \
    || die "Unsupported OS: ${ID}. This script requires Ubuntu 22.04+ or Debian 12+."
  local arch; arch=$(uname -m)
  [[ "$arch" == "x86_64" || "$arch" == "aarch64" ]] \
    || die "Unsupported architecture: ${arch}."
  success "OS: ${PRETTY_NAME} (${arch})"
}

install_deps() {
  local deps=("curl" "git" "jq" "gawk" "openssl" "ufw" "acl")
  local missing=()
  for dep in "${deps[@]}"; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    run_task "Installing missing dependencies" "sudo apt-get update -qq && sudo apt-get install -y ${missing[*]}"
  fi
  success "All dependencies satisfied."
}

handle_user() {
  if [[ $EUID -eq 0 ]]; then
    warn "Running as root. A non-root sudo user is required."
    prompt "Enter deployment username" TARGET_USER

    if id "$TARGET_USER" &>/dev/null; then
      info "User '${TARGET_USER}' exists. Ensuring sudo access..."
      usermod -aG sudo "$TARGET_USER"
    else
      if confirm "User '${TARGET_USER}' not found. Create it?"; then
        adduser --gecos "" "$TARGET_USER"
        usermod -aG sudo "$TARGET_USER"
        success "User '${TARGET_USER}' created."
      else
        die "Deployment requires a non-root user. Aborting."
      fi
    fi

    local target_script="/home/${TARGET_USER}/manager.sh"
    cp "$0" "$target_script"
    chmod +x "$target_script"

    # Copy the lib/ directory so sourced modules are available after the switch
    rm -rf "/home/${TARGET_USER}/lib"
    cp -r "${SCRIPT_DIR}/lib" "/home/${TARGET_USER}/lib"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$target_script" "/home/${TARGET_USER}/lib"

    # Ensure the target user owns their own home config directory if it exists
    local target_home="/home/${TARGET_USER}"
    [[ -d "${target_home}/.config" ]] && chown -R "${TARGET_USER}:${TARGET_USER}" "${target_home}/.config"

    info "Transitioning session to '${TARGET_USER}'..."
    exec sudo -u "$TARGET_USER" -H bash "$target_script" --child "$@"
  fi
}

# ── Docker ────────────────────────────────────────────────────────────────────

install_docker() {
  if command -v docker &>/dev/null; then
    success "Docker already installed: $(docker --version | awk '{print $3}' | tr -d ',')"
    return
  fi

  info "Setting up Docker official repositories..."
  # shellcheck source=/dev/null
  source /etc/os-release
  sudo apt-get update -qq >> "$LOG_FILE"
  sudo apt-get install -y ca-certificates curl gnupg >> "$LOG_FILE"

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  run_task "Installing Docker Engine" "sudo apt-get update -qq && \
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && \
    sudo systemctl enable --now docker"

  sudo usermod -aG docker "$USER"
  if command -v setfacl &>/dev/null; then
    info "Applying immediate Docker permissions via setfacl..."
    sudo setfacl -m user:"$USER":rw /var/run/docker.sock 2>/dev/null || true
  fi
  success "Docker Engine V2 installed. Docker now runs without sudo."
  state_set ".docker_installed" "true"
}

# ── Network ───────────────────────────────────────────────────────────────────

setup_network() {
  if docker network inspect "$PROXY_NETWORK" &>/dev/null; then
    success "Docker network '${PROXY_NETWORK}' already exists."
  else
    run_task "Creating isolated Docker network '${PROXY_NETWORK}'" "docker network create $PROXY_NETWORK"
    success "Network '${PROXY_NETWORK}' created."
  fi
}

# ── Firewall ──────────────────────────────────────────────────────────────────

setup_firewall() {
  local ssh_port
  ssh_port=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || true)
  [[ -z "$ssh_port" ]] && ssh_port=$(ss -tlnp 2>/dev/null | awk '/sshd/{print $4}' | grep -oP ':\K[0-9]+' | head -1 || true)
  ssh_port=${ssh_port:-22}

  info "Configuring UFW firewall (SSH: ${ssh_port}, HTTP: 80, HTTPS: 443)..."
  sudo ufw allow "$ssh_port"/tcp >> "$LOG_FILE"
  sudo ufw allow 80/tcp  >> "$LOG_FILE"
  sudo ufw allow 443/tcp >> "$LOG_FILE"
  run_task "Enabling Firewall" "sudo ufw --force enable"
  success "Firewall configured."
}

# ── Media Directory ───────────────────────────────────────────────────────────

setup_media_dir() {
  if [[ -d "$MEDIA_DIR" ]]; then
    success "Media directory '${MEDIA_DIR}' already exists."
  else
    info "Creating shared media directory at ${MEDIA_DIR}..."
    sudo mkdir -p "$MEDIA_DIR"
    sudo chown "${USER}:${USER}" "$MEDIA_DIR"
    sudo chmod 775 "$MEDIA_DIR"
    success "Media directory created: ${MEDIA_DIR}"
  fi
  mkdir -p "${MEDIA_DIR}/movies" "${MEDIA_DIR}/tv" "${MEDIA_DIR}/music" \
           "${MEDIA_DIR}/books" "${MEDIA_DIR}/downloads"
  success "Media sub-dirs ready: movies/ tv/ music/ books/ downloads/"
}

# ── Configuration Directory ───────────────────────────────────────────────────

setup_config_dir() {
  if [[ ! -d "$CONFIG_BASE" ]]; then
    info "Creating configuration base at ${CONFIG_BASE}..."
    sudo mkdir -p "$CONFIG_BASE"
  fi
  sudo chown -R "${USER}:${USER}" "$CONFIG_BASE"
  success "Configuration directory ready and owned by ${USER}."
}

# ── Reverse Proxy ─────────────────────────────────────────────────────────────

deploy_reverse_proxy() {
  if [[ "$(state_get '.proxy_deployed')" == "true" ]]; then
    success "Nginx Proxy Manager already deployed."
    return
  fi

  local custom_df="${DOCKER_FILES_DIR}/nginx-proxy-manager-dockerfile"
  local cfg_dir="${CONFIG_BASE}/nginx-proxy-manager"
  mkdir -p "${cfg_dir}/data" "${cfg_dir}/letsencrypt"

  local active_image="jc21/nginx-proxy-manager:latest"
  if [[ -f "$custom_df" ]]; then
    run_task "Building custom Nginx Proxy Manager image" "docker build -t local-nginx-proxy-manager:latest -f $custom_df $DOCKER_FILES_DIR"
    active_image="local-nginx-proxy-manager:latest"
  else
    run_task "Pulling generic Nginx Proxy Manager image" "docker pull $active_image"
  fi

  run_task "Deploying Nginx Proxy Manager container" "docker run -d \
    --name nginx-proxy-manager \
    --restart unless-stopped \
    --network $PROXY_NETWORK \
    -p 80:80 \
    -p 81:81 \
    -p 443:443 \
    -v ${cfg_dir}/data:/data \
    -v ${cfg_dir}/letsencrypt:/etc/letsencrypt \
    -v ${MEDIA_DIR}:${MEDIA_DIR} \
    $active_image"

  state_set ".proxy_deployed" "true"
  success "Nginx Proxy Manager running on port 81 (admin UI)."
  info "Visit :81 to complete setup and create your admin account."
}
