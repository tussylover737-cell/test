#!/usr/bin/env bash
# =============================================================================
# setup_n8n_subdomain.sh
# Adds n8n.gearrent.cloud as an Nginx reverse proxy for n8n on port 5678.
# Obtains a Let's Encrypt certificate for the subdomain.
# Does NOT touch your existing website config.
# =============================================================================
set -euo pipefail

SUBDOMAIN="n8n.gearrent.cloud"
EMAIL=""   # ← optionally hardcode your email here

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash setup_n8n_subdomain.sh"

if [[ -z "$EMAIL" ]]; then
  read -rp "Enter your email for Let's Encrypt: " EMAIL
  [[ -z "$EMAIL" ]] && error "Email is required."
fi

# =============================================================================
# STEP 1 — Write Nginx config for the subdomain (HTTP only first)
# =============================================================================
NGINX_CONF="/etc/nginx/sites-available/${SUBDOMAIN}"

info "Writing Nginx config for ${SUBDOMAIN}…"
cat > "$NGINX_CONF" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${SUBDOMAIN};

    # Certbot ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass         http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

nginx -t || error "Nginx config test failed — check the config above."
systemctl reload nginx
info "Nginx reloaded."

# =============================================================================
# STEP 2 — Make sure n8n container env vars match the new subdomain
# =============================================================================
info "Checking n8n container configuration…"

if docker ps --format '{{.Names}}' | grep -q '^n8n$'; then
  warn "n8n is running. Recreating it with correct subdomain env vars…"
  docker rm -f n8n

  N8N_DATA_DIR="/opt/n8n_data"
  N8N_IMAGE="docker.n8n.io/n8nio/n8n"

  # Detect Ollama location
  if docker ps --format '{{.Names}}' | grep -q '^ollama$'; then
    OLLAMA_URL="http://ollama:11434"
  else
    OLLAMA_URL="http://172.17.0.1:11434"
  fi

  docker run -d \
    --name n8n \
    --restart unless-stopped \
    --network stack_net \
    -p 127.0.0.1:5678:5678 \
    -v "${N8N_DATA_DIR}:/home/node/.n8n" \
    -e N8N_HOST="${SUBDOMAIN}" \
    -e N8N_PORT=5678 \
    -e N8N_PROTOCOL=https \
    -e WEBHOOK_URL="https://${SUBDOMAIN}/" \
    -e N8N_PATH=/ \
    -e N8N_EDITOR_BASE_URL="https://${SUBDOMAIN}/" \
    -e OLLAMA_BASE_URL="${OLLAMA_URL}" \
    -e GENERIC_TIMEZONE=Asia/Kolkata \
    "$N8N_IMAGE"

  info "n8n container recreated with subdomain config."
else
  warn "n8n container not found — skipping container update."
fi

# =============================================================================
# STEP 3 — Obtain TLS certificate
# =============================================================================
info "Obtaining Let's Encrypt certificate for ${SUBDOMAIN}…"
certbot --nginx \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$SUBDOMAIN" || {
    warn "Certbot failed. DNS may not have propagated yet."
    warn "Retry manually once DNS is ready:"
    warn "  certbot --nginx -d ${SUBDOMAIN} --email ${EMAIL}"
    warn "Then: systemctl reload nginx"
    exit 1
  }

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  All done!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  n8n is live at → https://${SUBDOMAIN}"
echo ""
echo -e "  Your existing website on gearrent.cloud is untouched."
