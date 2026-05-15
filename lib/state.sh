#!/usr/bin/env bash
# ==============================================================================
#  lib/state.sh  —  JSON-backed State Management
#  Tracks deployed services and global flags in .vps_state.json
# ==============================================================================

state_init() {
  [[ -f "$STATE_FILE" ]] || echo '{"services":{}}' > "$STATE_FILE"
}

state_get() {
  jq -r "${1} // empty" "$STATE_FILE" 2>/dev/null || true
}

state_set() {
  local key=$1 val=$2
  local tmp; tmp=$(mktemp)
  jq --arg v "$val" "${key} = \$v" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_set_service() {
  local name=$1 port=$2 status=$3
  local tmp; tmp=$(mktemp)
  jq --arg n "$name" --arg p "$port" --arg s "$status" \
    '.services[$n] = {port: $p, status: $s, deployed_at: (now | todate)}' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_remove_service() {
  local tmp; tmp=$(mktemp)
  jq --arg n "$1" 'del(.services[$n])' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}
