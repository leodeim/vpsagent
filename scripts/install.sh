#!/usr/bin/env bash
set -euo pipefail
umask 077

# Install the standalone VPSmon Cloud agent. This script does not inspect or
# change an existing vpsmon dashboard installation.
REPO=leodeim/vpsagent
APP_NAME=vpsagent
REMOTE_DIR=/opt/vpsagent
SERVICE_USER=vpsagent
CLOUD_URL=
SETUP_TOKEN=
ALLOW_INSECURE_LOCAL=false

usage() {
  echo 'Usage: install.sh --cloud-url URL --setup-token TOKEN [--allow-insecure-local]' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud-url) [[ $# -ge 2 ]] || usage; CLOUD_URL=$2; shift 2 ;;
    --setup-token) [[ $# -ge 2 ]] || usage; SETUP_TOKEN=$2; shift 2 ;;
    --allow-insecure-local) ALLOW_INSECURE_LOCAL=true; shift ;;
    -h|--help) echo 'Usage: install.sh --cloud-url URL --setup-token TOKEN [--allow-insecure-local]'; exit 0 ;;
    *) usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo 'Run this installer with sudo.' >&2; exit 1; }
[[ -n $CLOUD_URL && -n $SETUP_TOKEN ]] || usage
if [[ $CLOUD_URL =~ ^https:// ]]; then
  :
elif [[ $ALLOW_INSECURE_LOCAL == true && $CLOUD_URL =~ ^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{1,5})?$ ]]; then
  :
else
  echo 'Cloud URL must use HTTPS; loopback HTTP requires --allow-insecure-local.' >&2
  exit 1
fi
for dependency in curl sha256sum systemctl; do
  command -v "$dependency" >/dev/null 2>&1 || { echo "Missing command: $dependency" >&2; exit 1; }
done

case $(uname -m) in
  x86_64) GOARCH=amd64 ;;
  aarch64|armv8l) GOARCH=arm64 ;;
  *) echo 'Unsupported architecture' >&2; exit 1 ;;
esac

mkdir -p "$REMOTE_DIR"
chmod 700 "$REMOTE_DIR"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$REMOTE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi
chown "$SERVICE_USER:$SERVICE_USER" "$REMOTE_DIR"
BIN_PATH="$REMOTE_DIR/$APP_NAME"

if [[ -n ${VPSAGENT_BINARY:-} ]]; then
  [[ -f $VPSAGENT_BINARY ]] || { echo 'VPSAGENT_BINARY does not exist.' >&2; exit 1; }
  install -m 0755 "$VPSAGENT_BINARY" "$BIN_PATH.tmp"
else
  RELEASE_JSON=$(curl --proto '=https' --proto-redir '=https' -fsSL "https://api.github.com/repos/$REPO/releases/latest")
  RELEASE_TAG=$(printf '%s\n' "$RELEASE_JSON" | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4)
  ASSET_NAME="$APP_NAME-linux-$GOARCH"
  DOWNLOAD_URL=$(printf '%s\n' "$RELEASE_JSON" | grep '"browser_download_url":' | grep "/${ASSET_NAME}\"" | cut -d '"' -f 4 | head -n 1 || true)
  EXPECTED_URL="https://github.com/$REPO/releases/download/$RELEASE_TAG/$ASSET_NAME"
  [[ -n $RELEASE_TAG && $DOWNLOAD_URL == "$EXPECTED_URL" ]] || { echo 'No matching agent release found.' >&2; exit 1; }
  curl --proto '=https' --proto-redir '=https' -fsSL "$DOWNLOAD_URL" -o "$BIN_PATH.tmp"
  EXPECTED_SHA=$(curl --proto '=https' --proto-redir '=https' -fsSL "https://github.com/$REPO/releases/download/$RELEASE_TAG/checksums.txt" | awk -v asset="$ASSET_NAME" '$2 == asset {print $1}')
  [[ $EXPECTED_SHA =~ ^[[:xdigit:]]{64}$ ]] || { echo 'No valid release checksum found.' >&2; exit 1; }
  printf '%s  %s\n' "$EXPECTED_SHA" "$BIN_PATH.tmp" | sha256sum -c -
  chmod 0755 "$BIN_PATH.tmp"
fi
chown "$SERVICE_USER:$SERVICE_USER" "$BIN_PATH.tmp"
mv -f "$BIN_PATH.tmp" "$BIN_PATH"

CONNECT_ARGS=(--url "$CLOUD_URL" --setup-token "$SETUP_TOKEN" --config "$REMOTE_DIR/cloud.json")
if [[ $ALLOW_INSECURE_LOCAL == true ]]; then
  CONNECT_ARGS+=(--allow-insecure-local)
fi
"$BIN_PATH" connect "${CONNECT_ARGS[@]}"
chown "$SERVICE_USER:$SERVICE_USER" "$REMOTE_DIR/cloud.json"

{
  printf 'VPSAGENT_CONFIG=%s/cloud.json\n' "$REMOTE_DIR"
  if [[ $ALLOW_INSECURE_LOCAL == true ]]; then
    printf 'VPSAGENT_ALLOW_INSECURE=true\n'
  fi
} > "$REMOTE_DIR/.env"
chmod 0600 "$REMOTE_DIR/.env"
chown "$SERVICE_USER:$SERVICE_USER" "$REMOTE_DIR/.env"

cat > "/etc/systemd/system/$APP_NAME.service" <<SERVICE
[Unit]
Description=VPSmon Cloud agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$REMOTE_DIR
EnvironmentFile=$REMOTE_DIR/.env
ExecStart=$BIN_PATH
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
SERVICE
chmod 0644 "/etc/systemd/system/$APP_NAME.service"
systemctl daemon-reload
systemctl enable "$APP_NAME" --quiet
systemctl restart "$APP_NAME"
sleep 2
[[ $(systemctl is-active "$APP_NAME" 2>/dev/null || true) == active ]] || {
  echo "Agent did not start; inspect journalctl -u $APP_NAME -n 50" >&2
  exit 1
}
echo 'vpsagent installed and connected to VPSmon Cloud.'
echo "Service status: systemctl status $APP_NAME"
