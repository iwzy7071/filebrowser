#!/usr/bin/env bash
set -euo pipefail
RELAY_BASE_URL="${FILEBROWSER_RELAY_BASE_URL:-}"
SETUP_KEY=""
PROVISION_URL=""
INSTALL_DIR="$HOME/.local/share/FileBrowserPublic"
START=1
KEEP_AWAKE=1
ENABLE_LINGER=1
usage(){ echo "Usage: install-filebrowser-linux.sh --relay-base-url http://SERVER --setup-key sk_xxx [--install-dir DIR] [--no-start] [--no-keep-awake] [--no-linger]"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --relay-base-url) RELAY_BASE_URL="${2:-}"; shift 2 ;;
    --setup-key|-k) SETUP_KEY="${2:-}"; shift 2 ;;
    --provision-url) PROVISION_URL="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --no-start) START=0; shift ;;
    --start|--start-after-install) START=1; shift ;;
    --no-keep-awake) KEEP_AWAKE=0; shift ;;
    --no-linger) ENABLE_LINGER=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done
RELAY_BASE_URL="${RELAY_BASE_URL%/}"
if [[ -z "$PROVISION_URL" ]]; then
  [[ -n "$RELAY_BASE_URL" && -n "$SETUP_KEY" ]] || { usage >&2; exit 1; }
  PROVISION_URL="$RELAY_BASE_URL/downloads/provision/$SETUP_KEY/filebrowser.provision.json"
fi
command -v curl >/dev/null 2>&1 || { echo "curl is required: sudo apt-get update && sudo apt-get install -y curl" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required: sudo apt-get update && sudo apt-get install -y python3" >&2; exit 1; }
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;; esac
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/logs" "$INSTALL_DIR/cache"
curl -fsSL --connect-timeout 20 --max-time 120 "$PROVISION_URL" -o "$TMP/provision.json"
mapfile -t provision_values < <(python3 - "$TMP/provision.json" "$arch" <<'PY'
import json, sys
j=json.load(open(sys.argv[1])); a=sys.argv[2]
print((j.get('filebrowserPackageUrls') or {}).get('linux',{}).get(a,'') or '')
print((j.get('filebrowserPackageFallbackUrls') or {}).get('linux',{}).get(a,'') or '')
print((j.get('frpcLinuxUrls') or {}).get(a,'') or '')
print(j.get('publicUrl','') or '')
print(j.get('webUsername','') or '')
print(j.get('webPassword','') or '')
PY
)
pkg_url="${provision_values[0]:-}"
fallback_url="${provision_values[1]:-}"
frpc_url="${provision_values[2]:-}"
public_url="${provision_values[3]:-}"
web_user="${provision_values[4]:-}"
web_pass="${provision_values[5]:-}"
if ! curl -fL --connect-timeout 20 --max-time 300 "$pkg_url" -o "$TMP/filebrowser.tgz"; then
  curl -fL --connect-timeout 20 --max-time 300 "$fallback_url" -o "$TMP/filebrowser.tgz"
fi
tar -xzf "$TMP/filebrowser.tgz" -C "$TMP"
fb=$(find "$TMP" -type f -name filebrowser | head -1)
[[ -n "$fb" ]] || { echo "filebrowser not found" >&2; exit 1; }
install -m 0755 "$fb" "$INSTALL_DIR/filebrowser"
curl -fsSL --connect-timeout 20 --max-time 120 "$frpc_url" -o "$INSTALL_DIR/frpc"
chmod +x "$INSTALL_DIR/frpc"
python3 - "$TMP/provision.json" "$INSTALL_DIR/frpc.toml" "$INSTALL_DIR/filebrowser.relay.json" "$KEEP_AWAKE" "$ENABLE_LINGER" <<'PY'
import json, sys, pathlib, datetime
j=json.load(open(sys.argv[1]))
pathlib.Path(sys.argv[2]).write_text(j['frpcToml'])
relay={'schemaVersion':1,'user':j.get('user'),'publicUrl':j.get('publicUrl'),'webUsername':j.get('webUsername'),'webPassword':j.get('webPassword'),'installedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'autostart':'systemd user services with Restart=always','keepAwake':sys.argv[4]=='1','lingerRequested':sys.argv[5]=='1'}
pathlib.Path(sys.argv[3]).write_text(json.dumps(relay, ensure_ascii=False, indent=2)+'\n')
PY
chmod 600 "$INSTALL_DIR/frpc.toml" "$INSTALL_DIR/filebrowser.relay.json"
cat > "$INSTALL_DIR/start-filebrowser.sh" <<EOF
#!/usr/bin/env bash
exec "$INSTALL_DIR/filebrowser" --database "$INSTALL_DIR/filebrowser.db" --root "\$HOME" --address 127.0.0.1 --port 8091 --baseURL /files --cacheDir "$INSTALL_DIR/cache" --disableExec --noauth >>"$INSTALL_DIR/logs/filebrowser.log" 2>&1
EOF
cat > "$INSTALL_DIR/start-filebrowser-tunnel.sh" <<EOF
#!/usr/bin/env bash
exec "$INSTALL_DIR/frpc" -c "$INSTALL_DIR/frpc.toml" >>"$INSTALL_DIR/logs/frpc.log" 2>&1
EOF
cat > "$INSTALL_DIR/keep-awake.sh" <<'EOF'
#!/usr/bin/env bash
if command -v systemd-inhibit >/dev/null 2>&1; then
  exec systemd-inhibit --what=sleep:idle --who=FileBrowserPublic --why="Keep FileBrowser relay reachable" --mode=block sleep infinity
fi
while true; do sleep 3600; done
EOF
chmod +x "$INSTALL_DIR/start-filebrowser.sh" "$INSTALL_DIR/start-filebrowser-tunnel.sh" "$INSTALL_DIR/keep-awake.sh"
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/filebrowser-public.service" <<EOF
[Unit]
Description=FileBrowser public local service
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$INSTALL_DIR/start-filebrowser.sh
Restart=always
RestartSec=3
[Install]
WantedBy=default.target
EOF
cat > "$HOME/.config/systemd/user/filebrowser-public-tunnel.service" <<EOF
[Unit]
Description=FileBrowser public relay tunnel
After=network-online.target filebrowser-public.service
Wants=network-online.target filebrowser-public.service
[Service]
Type=simple
ExecStart=$INSTALL_DIR/start-filebrowser-tunnel.sh
Restart=always
RestartSec=3
[Install]
WantedBy=default.target
EOF
cat > "$HOME/.config/systemd/user/filebrowser-public-keepawake.service" <<EOF
[Unit]
Description=Keep system awake for FileBrowser public relay
After=default.target
[Service]
Type=simple
ExecStart=$INSTALL_DIR/keep-awake.sh
Restart=always
RestartSec=10
[Install]
WantedBy=default.target
EOF
if [[ "$ENABLE_LINGER" == 1 ]] && command -v loginctl >/dev/null 2>&1; then
  if loginctl enable-linger "$USER" 2>/dev/null; then
    echo "Enabled systemd lingering for $USER."
  elif command -v sudo >/dev/null 2>&1 && sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
    echo "Enabled systemd lingering for $USER via sudo."
  else
    echo "Warning: could not enable lingering automatically. To start after reboot before login, run: sudo loginctl enable-linger $USER" >&2
  fi
fi
if [[ "$START" == 1 ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload || true
  systemctl --user enable --now filebrowser-public.service || true
  systemctl --user enable --now filebrowser-public-tunnel.service || true
  if [[ "$KEEP_AWAKE" == 1 ]]; then systemctl --user enable --now filebrowser-public-keepawake.service || true; fi
fi
echo "FileBrowser installed with persistence."
echo "Local URL:  http://127.0.0.1:8091/files/"
echo "Remote URL: $public_url"
echo "Login user: $web_user"
echo "Login password: saved in $INSTALL_DIR/filebrowser.relay.json"
echo "Services: filebrowser-public.service, filebrowser-public-tunnel.service, filebrowser-public-keepawake.service"
