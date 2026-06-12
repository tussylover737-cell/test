#!/bin/bash
# =============================================================================
# install_stack.sh
# Installs Docker, Ollama (qwen3:0.6b), and n8n on a VPS
# n8n is accessible at: https://gearrent.cloud/n8n/
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
N8N_PATH="/n8n"                         # sub-path
N8N_PORT=5678                           # internal container port
OLLAMA_PORT=11434                       # internal container port
N8N_DATA_DIR="/opt/n8n_data"
OLLAMA_DATA_DIR="/opt/ollama_data"
N8N_CONTAINER="n8n"
OLLAMA_CONTAINER="ollama"
DOCKER_NETWORK="stack_net"

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

    # Use Docker's official install script (does NOT overwrite other packages)
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
    log "Docker installed successfully."
fi

# Ensure Docker daemon is running
systemctl is-active --quiet docker || systemctl start docker

# ── 2. Create isolated Docker network ─────────────────────────────────────────
header "Step 2 — Docker network"

if docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
    log "Network '$DOCKER_NETWORK' already exists."
else
    docker network create "$DOCKER_NETWORK"
    log "Created Docker network: $DOCKER_NETWORK"
fi

# ── 3. Ollama + qwen3:0.6b ────────────────────────────────────────────────────
header "Step 3 — Ollama (qwen3:0.6b)"

mkdir -p "$OLLAMA_DATA_DIR"

if docker ps -a --format '{{.Names}}' | grep -q "^${OLLAMA_CONTAINER}$"; then
    log "Ollama container already exists — skipping creation."
    docker start "$OLLAMA_CONTAINER" 2>/dev/null || true
else
    log "Pulling Ollama image..."
    docker pull ollama/ollama:latest

    log "Starting Ollama container..."
    docker run -d \
        --name "$OLLAMA_CONTAINER" \
        --network "$DOCKER_NETWORK" \
        --restart unless-stopped \
        -p 127.0.0.1:${OLLAMA_PORT}:11434 \
        -v "${OLLAMA_DATA_DIR}:/root/.ollama" \
        ollama/ollama:latest

    log "Ollama container started."
fi

# Pull the model (safe to re-run; Ollama skips if already downloaded)
log "Pulling model qwen3:0.6b (this may take a few minutes)..."
docker exec "$OLLAMA_CONTAINER" ollama pull qwen3:0.6b
log "Model qwen3:0.6b ready."

# ── 4. n8n ────────────────────────────────────────────────────────────────────
header "Step 4 — n8n"

mkdir -p "$N8N_DATA_DIR"
chown -R 1000:1000 "$N8N_DATA_DIR" 2>/dev/null || true

if docker ps -a --format '{{.Names}}' | grep -q "^${N8N_CONTAINER}$"; then
    log "n8n container already exists — skipping creation."
    docker start "$N8N_CONTAINER" 2>/dev/null || true
else
    log "Pulling n8n image..."
    docker pull n8nio/n8n:latest

    log "Starting n8n container..."
    docker run -d \
        --name "$N8N_CONTAINER" \
        --network "$DOCKER_NETWORK" \
        --restart unless-stopped \
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
# ── n8n sub-path proxy ──────────────────────────────────────────────────────
# Managed by install_stack.sh — edit carefully.
# Placed inside the server block for gearrent.cloud (HTTP — add SSL separately).

server {
    listen 80;
    server_name gearrent.cloud www.gearrent.cloud;

    # ── n8n at /n8n/ ────────────────────────────────────────────────────────
    location /n8n/ {
        proxy_pass         http://127.0.0.1:5678/;
        proxy_http_version 1.1;

        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        # WebSocket support (required by n8n)
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "upgrade";

        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_buffering     off;
    }

    # ── n8n webhook (same sub-path) ──────────────────────────────────────────
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

# Enable the site
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/n8n_proxy.conf

# Remove default site only if it conflicts on port 80
if [ -f /etc/nginx/sites-enabled/default ]; then
    warn "Default Nginx site is enabled. If it also listens on port 80 for gearrent.cloud,"
    warn "it may conflict. Leaving it in place — disable manually if needed:"
    warn "  rm /etc/nginx/sites-enabled/default && nginx -s reload"
fi

# Test and reload Nginx
nginx -t && systemctl reload nginx
log "Nginx configured and reloaded."

# ── 6. SSL via Certbot (optional but recommended) ─────────────────────────────
header "Step 6 — SSL / HTTPS (Certbot)"

if command -v certbot &>/dev/null; then
    log "Certbot already installed. Attempting certificate for ${N8N_HOST}..."
    certbot --nginx -d "$N8N_HOST" --non-interactive --agree-tos \
        -m "admin@${N8N_HOST}" --redirect 2>/dev/null \
        && log "SSL certificate obtained!" \
        || warn "Certbot failed — ensure DNS points to this server and port 80 is open."
else
    log "Installing Certbot..."
    apt-get install -y -qq certbot python3-certbot-nginx
    certbot --nginx -d "$N8N_HOST" --non-interactive --agree-tos \
        -m "admin@${N8N_HOST}" --redirect 2>/dev/null \
        && log "SSL certificate obtained!" \
        || warn "Certbot failed — ensure DNS points to this server and port 80 is open."
fi

# ── 7. Summary ────────────────────────────────────────────────────────────────
header "✅ Installation complete"

echo ""
echo -e "  ${GREEN}n8n URL:${NC}        https://${N8N_HOST}${N8N_PATH}/"
echo -e "  ${GREEN}Ollama API:${NC}     http://127.0.0.1:${OLLAMA_PORT}  (localhost only)"
echo -e "  ${GREEN}Ollama model:${NC}   qwen3:0.6b"
echo ""
echo -e "  ${YELLOW}Useful commands:${NC}"
echo "    docker ps                         — list running containers"
echo "    docker logs -f n8n                — tail n8n logs"
echo "    docker logs -f ollama             — tail Ollama logs"
echo "    docker exec ollama ollama list    — list downloaded models"
echo "    docker exec ollama ollama run qwen3:0.6b  — interactive chat"
echo ""
echo -e "  ${YELLOW}Data directories:${NC}"
echo "    n8n data:    $N8N_DATA_DIR"
echo "    Ollama data: $OLLAMA_DATA_DIR"
echo ""
echo -e "  ${CYAN}If SSL failed, run manually after DNS is set:${NC}"
echo "    certbot --nginx -d ${N8N_HOST} --redirect"
echo ""
