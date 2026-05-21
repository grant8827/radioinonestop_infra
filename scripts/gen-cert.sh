#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# gen-cert.sh — Generate a self-signed TLS certificate for local
# dev / staging. Place output in ../ssl/ for docker-compose to mount.
#
# Usage: bash scripts/gen-cert.sh [domain]
#   domain defaults to "localhost"
#
# For production use Let's Encrypt via Certbot:
#   certbot certonly --webroot -w ./certbot -d yourdomain.com
#   cp /etc/letsencrypt/live/yourdomain.com/fullchain.pem ssl/cert.pem
#   cp /etc/letsencrypt/live/yourdomain.com/privkey.pem  ssl/key.pem
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

DOMAIN="${1:-localhost}"
SSL_DIR="$(cd "$(dirname "$0")/.." && pwd)/ssl"

mkdir -p "$SSL_DIR"

echo "▸ Generating self-signed certificate for: $DOMAIN"
openssl req -x509 \
  -newkey rsa:4096 \
  -keyout "$SSL_DIR/key.pem" \
  -out "$SSL_DIR/cert.pem" \
  -sha256 -days 365 -nodes \
  -subj "/CN=$DOMAIN" \
  -addext "subjectAltName=DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1"

echo "✓ Certificate: $SSL_DIR/cert.pem"
echo "✓ Key:         $SSL_DIR/key.pem"
echo ""
echo "Start the stack with:"
echo "  docker compose up --build"
