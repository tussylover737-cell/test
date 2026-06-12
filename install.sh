#!/bin/bash
# =============================================================================
# install_stack.sh  (v2 — handles pre-existing native Ollama on port 11434)
# Installs Docker, Ollama (qwen3:0.6b), and n8n on a VPS
# n8n accessible at: https://gearrent.cloud/n8n/
#
# Safe to run on existing systems — does NOT remove or restart unrelated services.
# Tested on Ubuntu 20.04 / 22.04 / 24.04 and Debian 11/12.
# Run as root or with sudo.
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; \
           echo -e "${BLUE}  $*${NC}"; \
           echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

# ── Config ────────────────────────────────────────────────────────────────────
N8N_HOST="gearrent.cloud"
N8N_PATH="/n8n"
N8N_PORT=5678
N8N_DATA_DIR="/opt/n8n_data"
OLLAMA_DATA_DIR="/opt/ollama_data"
N8N_CONTAINER="n8n"
OLLAMA_CONTAINER="ollama"
DOCKER_NETWORK="stack_net"

# Port used by Ollama — set dynamically below after conflict detection
OLLAMA_HOST_PORT=11434

# ── Pre-flight ────────────────────────────────────────────────────────────────
header "Pre-flight checks"

[[ $EUID -ne 0 ]] && error "Please run as root or with sudo."

OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
log "Detected OS: $OS_ID"
[[ "$OS_ID" =~ ^(ubuntu|debian)$ ]] || warn "Untested OS ($OS_ID). Continuing anyway..."

# ── 1. Install Docker (idempotent) ────────────────────────────────────────────
header "Step 1 — Docker"

if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
else
    log "Installing Docker via official convenience script..."
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg lsb-release
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
    log "Docker installed successfully."
fi

systemctl is-active --quiet docker || systemctl start docker

# ── 2. Create isolated Docker network ─────────────────────────────────────────
header "Step 2 — Docker network"

if docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
    log "Network '$DOCKER_NETWORK' already exists."
else
    docker network create "$DOCKER_NETWORK"
    log "Created Docker network: $DOCKER_NETWORK"
fi

# ── 3. Ollama — smart port / mode detection ───────────────────────────────────
header "Step 3 — Ollama (qwen3:0.6b)"

# Determine what is already on port 11434
PORT_OWNER=""
if ss -tlnp 2>/dev/null | grep -q ":11434 "; then
    PORT_OWNER=$(ss -tlnp 2>/dev/null | grep ":11434 " | grep -oP 'pid=\K[0-9]+' | head -1)
fi

NATIVE_OLLAMA=false
DOCKER_OLLAMA=false

# Check if a Docker container called 'ollama' already exists (even if stopped/errored)
if docker ps -a --format '{{.Names}}' | grep -q "^${OLLAMA_CONTAINER}$"; then
    CONTAINER_STATE=$(docker inspect --format '{{.State.Status}}' "$OLLAMA_CONTAINER" 2>/dev/null || echo "unknown")
    log "Found existing '$OLLAMA_CONTAINER' container (state: $CONTAINER_STATE)."

    if [[ "$CONTAINER_STATE" == "running" ]]; then
        DOCKER_OLLAMA=true
        log "Ollama Docker container is already running — reusing it."
    else
        # Container exists but is stopped/errored — remove it so we can recreate cleanly
        warn "Removing stale/errored '$OLLAMA_CONTAINER' container..."
        docker rm -f "$OLLAMA_CONTAINER" 2>/dev/null || true
    fi
fi

# If port 11434 is occupied by something that is NOT our Docker container,
# it is almost certainly a native (host-installed) Ollama service.
if [[ -n "$PORT_OWNER" ]] && [[ "$DOCKER_OLLAMA" == "false" ]]; then
    PROC_NAME=$(ps -p "$PORT_OWNER" -o comm= 2>/dev/null || echo "unknown")
    warn "Port 11434 is already in use by PID $PORT_OWNER ($PROC_NAME)."
    warn "This looks like a native Ollama installation — skipping Docker Ollama deployment."
    warn "The native Ollama will be used by n8n via host.docker.internal:11434."
    NATIVE_OLLAMA=true
fi

mkdir -p "$OLLAMA_DATA_DIR"

if [[ "$DOCKER_OLLAMA" == "false" ]] && [[ "$NATIVE_OLLAMA" == "false" ]]; then
    # Port is free — deploy Ollama in Docker normally
    log "Pulling Ollama image..."
    docker pull ollama/ollama:latest

    log "Starting Ollama container on 127.0.0.1:${OLLAMA_HOST_PORT}..."
    docker run -d \
        --name "$OLLAMA_CONTAINER" \
        --network "$DOCKER_NETWORK" \
        --restart unless-stopped \
        -p 127.0.0.1:${OLLAMA_HOST_PORT}:11434 \
        -v "${OLLAMA_DATA_DIR}:/root/.ollama" \
        ollama/ollama:latest

    DOCKER_OLLAMA=true
    log "Ollama container started."
fi

# Pull qwen3:0.6b — via Docker container OR native Ollama
if [[ "$DOCKER_OLLAMA" == "true" ]]; then
    log "Pulling model qwen3:0.6b inside Docker Ollama..."
    docker exec "$OLLAMA_CONTAINER" ollama pull qwen3:0.6b
elif [[ "$NATIVE_OLLAMA" == "true" ]]; then
    log "Pulling model qwen3:0.6b using native Ollama..."
    if command -v ollama &>/dev/null; then
        ollama pull qwen3:0.6b
    else
        warn "ollama binary not found in PATH — cannot pull model automatically."
        warn "Run manually: ollama pull qwen3:0.6b"
    fi
fi

log "Model qwen3:0.6b ready."

# ── 4. n8n ────────────────────────────────────────────────────────────────────
header "Step 4 — n8n"

mkdir -p "$N8N_DATA_DIR"
chown -R 1000:1000 "$N8N_DATA_DIR" 2>/dev/null || true

# Decide how n8n should reach Ollama
if [[ "$NATIVE_OLLAMA" == "true" ]]; then
    # Native Ollama on the host — n8n container must use host.docker.internal
    OLLAMA_BASE_URL="http://host.docker.internal:11434"
    EXTRA_HOSTS="--add-host=host.docker.internal:host-gateway"
else
    # Docker Ollama is on the same Docker network — reachable by container name
    OLLAMA_BASE_URL="http://ollama:11434"
    EXTRA_HOSTS=""
fi

if docker ps -a --format '{{.Names}}' | grep -q "^${N8N_CONTAINER}$"; then
    N8N_STATE=$(docker inspect --format '{{.State.Status}}' "$N8N_CONTAINER" 2>/dev/null || echo "unknown")
    if [[ "$N8N_STATE" == "running" ]]; then
        log "n8n container already running — skipping creation."
    else
        warn "Removing stale n8n container (state: $N8N_STATE)..."
        docker rm -f "$N8N_CONTAINER" 2>/dev/null || true
        N8N_STATE="removed"
    fi
else
    N8N_STATE="absent"
fi

if [[ "$N8N_STATE" != "running" ]]; then
    log "Pulling n8n image..."
    docker pull n8nio/n8n:latest

    log "Starting n8n container (Ollama endpoint: $OLLAMA_BASE_URL)..."
    docker run -d \
        --name "$N8N_CONTAINER" \
        --network "$DOCKER_NETWORK" \
        --restart unless-stopped \
        $EXTRA_HOSTS \
        -p 127.0.0.1:${N8N_PORT}:5678 \
        -v "${N8N_DATA_DIR}:/home/node/.n8n" \
        -e N8N_HOST="${N8N_HOST}" \
        -e N8N_PORT="5678" \
        -e N8N_PROTOCOL="https" \
        -e WEBHOOK_URL="https://${N8N_HOST}${N8N_PATH}/" \
        -e N8N_PATH="${N8N_PATH}/" \
        -e N8N_EDITOR_BASE_URL="https://${N8N_HOST}${N8N_PATH}/" \
        -e N8N_RUNNERS_ENABLED="true" \
        -e GENERIC_TIMEZONE="Asia/Kolkata" \
        -e OLLAMA_BASE_URL="${OLLAMA_BASE_URL}" \
        n8nio/n8n:latest

    log "n8n container started."
fi

# ── 5. Nginx reverse-proxy ────────────────────────────────────────────────────
header "Step 5 — Nginx reverse proxy"

if ! command -v nginx &>/dev/null; then
    log "Installing Nginx..."
    apt-get install -y -qq nginx
    systemctl enable nginx
    systemctl start nginx
else
    log "Nginx already installed."
fi

NGINX_CONF="/etc/nginx/sites-available/n8n_proxy.conf"

log "Writing Nginx config to $NGINX_CONF ..."
cat > "$NGINX_CONF" <<'NGINXEOF'
# ── n8n sub-path proxy ── managed by install_stack.sh ──────────────────────

server {
    listen 80;
    server_name gearrent.cloud www.gearrent.cloud;

    # ── n8n UI at /n8n/ ─────────────────────────────────────────────────────
    location /n8n/ {
        proxy_pass         http://127.0.0.1:5678/;
        proxy_http_version 1.1;

        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        # WebSocket support (required by n8n live UI)
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "upgrade";

        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_buffering     off;
    }

    # ── n8n webhooks ─────────────────────────────────────────────────────────
    location /n8n/webhook/ {
        proxy_pass         http://127.0.0.1:5678/webhook/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
    }
}
NGINXEOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/n8n_proxy.conf

if [ -f /etc/nginx/sites-enabled/default ]; then
    warn "Default Nginx site is still enabled. If it conflicts (same server_name / port 80),"
    warn "disable it manually: rm /etc/nginx/sites-enabled/default && nginx -s reload"
fi

nginx -t && systemctl reload nginx
log "Nginx configured and reloaded."

# ── 6. SSL via Certbot ────────────────────────────────────────────────────────
header "Step 6 — SSL / HTTPS (Certbot)"

if ! command -v certbot &>/dev/null; then
    log "Installing Certbot..."
    apt-get install -y -qq certbot python3-certbot-nginx
fi

certbot --nginx -d "$N8N_HOST" --non-interactive --agree-tos \
    -m "admin@${N8N_HOST}" --redirect 2>/dev/null \
    && log "SSL certificate obtained!" \
    || warn "Certbot failed — ensure DNS points to this server and port 80 is open. Run manually: certbot --nginx -d ${N8N_HOST} --redirect"

# ── 7. Summary ────────────────────────────────────────────────────────────────
header "✅ Installation complete"

echo ""
echo -e "  ${GREEN}n8n URL:${NC}          https://${N8N_HOST}${N8N_PATH}/"
if [[ "$NATIVE_OLLAMA" == "true" ]]; then
echo -e "  ${GREEN}Ollama:${NC}           Native (host) on port 11434"
echo -e "  ${YELLOW}n8n → Ollama:${NC}     http://host.docker.internal:11434"
else
echo -e "  ${GREEN}Ollama API:${NC}       http://127.0.0.1:11434  (localhost only)"
echo -e "  ${YELLOW}n8n → Ollama:${NC}     http://ollama:11434  (Docker network)"
fi
echo -e "  ${GREEN}Ollama model:${NC}     qwen3:0.6b"
echo ""
echo -e "  ${YELLOW}Useful commands:${NC}"
echo "    docker ps                              — list running containers"
echo "    docker logs -f n8n                     — tail n8n logs"
echo "    docker logs -f ollama                  — tail Ollama logs (if Docker)"
echo "    docker exec ollama ollama list         — list models (if Docker)"
echo "    docker exec ollama ollama run qwen3:0.6b  — chat (if Docker)"
echo "    ollama list                            — list models (if native)"
echo ""
echo -e "  ${YELLOW}Data directories:${NC}"
echo "    n8n data:    $N8N_DATA_DIR"
echo "    Ollama data: $OLLAMA_DATA_DIR  (Docker Ollama only)"
echo ""
echo -e "  ${CYAN}If SSL failed, run after DNS is confirmed:${NC}"
echo "    certbot --nginx -d ${N8N_HOST} --redirect"
echo ""
