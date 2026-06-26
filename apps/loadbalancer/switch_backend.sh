#!/usr/bin/env bash
# switch_backend.sh
# Called by the dashboard server whenever the user switches nodes.
# Usage: ./switch_backend.sh <new_url>
set -euo pipefail

TARGET_URL="${1:-}"
if [ -z "$TARGET_URL" ]; then
  echo "Usage: $0 <target_url>"
  exit 1
fi

NGINX_CONF_DIR="/etc/nginx/conf.d"
ACTIVE_CONF="$NGINX_CONF_DIR/active_backend.conf"
CONTAINER_NAME="faux-lb-nginx"

mkdir -p "$NGINX_CONF_DIR"

# Extract hostname from URL (e.g. https://foo.example.com/ -> foo.example.com)
TARGET_HOST=$(echo "$TARGET_URL" | awk -F/ '{print $3}')

# Update the Nginx proxy_pass directive and dynamically set the Host header
cat <<EOF > "$ACTIVE_CONF"
proxy_set_header Host $TARGET_HOST;
proxy_pass $TARGET_URL;
EOF

echo "Backend updated to $TARGET_URL"

# Reload Nginx directly (since it runs in the same container as Node)
if pgrep nginx > /dev/null; then
  nginx -s reload
  echo "Nginx reloaded successfully."
else
  echo "Nginx not running yet. Config will be picked up on start."
fi
