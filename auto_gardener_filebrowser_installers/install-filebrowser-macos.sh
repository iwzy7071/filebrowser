#!/usr/bin/env bash
set -euo pipefail
RELAY_BASE_URL="${FILEBROWSER_RELAY_BASE_URL:-}"
SETUP_KEY=""
PROVISION_URL=""
INSTALL_DIR="$HOME/Library/Application Support/FileBrowserPublic"
START=1
KEEP_AWAKE=1
usage(){ echo "Usage: install-filebrowser-macos.sh --relay-base-url http://SERVER --setup-key sk_xxx [--install-dir DIR] [--no-start] [--no-keep-awake]"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --relay-base-url) RELAY_BASE_URL="${2:-}"; shift 2 ;;
    --setup-key|-k) SETUP_KEY="${2:-}"; shift 2 ;;
    --provision-url) PROVISION_URL="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --no-start) START=0; shift ;;
    --start|--start-after-install) START=1; shift ;;
    --no-keep-awake) KEEP_AWAKE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done
RELAY_BASE_URL="${RELAY_BASE_URL%/}"
if [[ -z "$PROVISION_URL" ]]; then
  [[ -n "$RELAY_BASE_URL" && -n "$SETUP_KEY" ]] || { usage >&2; exit 1; }
  PROVISION_URL="$RELAY_BASE_URL/downloads/provision/$SETUP_KEY/filebrowser.provision.json"
fi
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
PYTHON_BIN="$(command -v python3 || true)"
[[ -n "$PYTHON_BIN" ]] || { echo "python3 is required. Install Command Line Tools or Python 3 first." >&2; exit 1; }
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;; esac
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/logs" "$INSTALL_DIR/cache"
curl -fsSL --connect-timeout 20 --max-time 120 "$PROVISION_URL" -o "$TMP/provision.json"
"$PYTHON_BIN" - "$TMP/provision.json" "$arch" > "$TMP/provision-values.txt" <<'PY'
import json, sys
j=json.load(open(sys.argv[1])); a=sys.argv[2]
print((j.get('filebrowserPackageUrls') or {}).get('darwin',{}).get(a,'') or '')
print((j.get('filebrowserPackageFallbackUrls') or {}).get('darwin',{}).get(a,'') or '')
print((j.get('frpcDarwinUrls') or {}).get(a,'') or '')
print(j.get('publicUrl','') or '')
print(j.get('webUsername','') or '')
print(j.get('webPassword','') or '')
PY
pkg_url="$(sed -n '1p' "$TMP/provision-values.txt")"
fallback_url="$(sed -n '2p' "$TMP/provision-values.txt")"
frpc_url="$(sed -n '3p' "$TMP/provision-values.txt")"
public_url="$(sed -n '4p' "$TMP/provision-values.txt")"
web_user="$(sed -n '5p' "$TMP/provision-values.txt")"
web_pass="$(sed -n '6p' "$TMP/provision-values.txt")"
if ! curl -fL --connect-timeout 20 --max-time 300 "$pkg_url" -o "$TMP/filebrowser.tgz"; then
  curl -fL --connect-timeout 20 --max-time 300 "$fallback_url" -o "$TMP/filebrowser.tgz"
fi
tar -xzf "$TMP/filebrowser.tgz" -C "$TMP"
fb=$(find "$TMP" -type f -name filebrowser | head -1)
[[ -n "$fb" ]] || { echo "filebrowser not found" >&2; exit 1; }
install -m 0755 "$fb" "$INSTALL_DIR/filebrowser"
curl -fsSL --connect-timeout 20 --max-time 120 "$frpc_url" -o "$INSTALL_DIR/frpc"
chmod +x "$INSTALL_DIR/frpc"
"$PYTHON_BIN" - "$TMP/provision.json" "$INSTALL_DIR/frpc.toml" "$INSTALL_DIR/filebrowser.relay.json" "$KEEP_AWAKE" <<'PY'
import json, sys, pathlib, datetime
j=json.load(open(sys.argv[1]))
pathlib.Path(sys.argv[2]).write_text(j['frpcToml'])
relay={'schemaVersion':1,'user':j.get('user'),'publicUrl':j.get('publicUrl'),'webUsername':j.get('webUsername'),'webPassword':j.get('webPassword'),'installedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'autostart':'LaunchAgents with KeepAlive','keepAwake':sys.argv[4]=='1'}
pathlib.Path(sys.argv[3]).write_text(json.dumps(relay, ensure_ascii=False, indent=2)+'\n')
PY
chmod 600 "$INSTALL_DIR/frpc.toml" "$INSTALL_DIR/filebrowser.relay.json"
cat > "$INSTALL_DIR/start-filebrowser.sh" <<EOF
#!/bin/zsh
exec "$INSTALL_DIR/filebrowser" --database "$INSTALL_DIR/filebrowser.db" --root "\$HOME" --address 127.0.0.1 --port 8091 --baseURL /files --cacheDir "$INSTALL_DIR/cache" --disableExec --noauth >>"$INSTALL_DIR/logs/filebrowser.log" 2>&1
EOF
cat > "$INSTALL_DIR/start-filebrowser-tunnel.sh" <<EOF
#!/bin/zsh
exec "$INSTALL_DIR/frpc" -c "$INSTALL_DIR/frpc.toml" >>"$INSTALL_DIR/logs/frpc.log" 2>&1
EOF
chmod +x "$INSTALL_DIR/start-filebrowser.sh" "$INSTALL_DIR/start-filebrowser-tunnel.sh"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_DIR"
write_plist() {
  local label="$1" program="$2" plist="$LAUNCH_DIR/$label.plist"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$program</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>WorkingDirectory</key><string>$INSTALL_DIR</string>
  <key>StandardOutPath</key><string>$INSTALL_DIR/logs/$label.out.log</string>
  <key>StandardErrorPath</key><string>$INSTALL_DIR/logs/$label.err.log</string>
</dict></plist>
EOF
}
write_plist "com.filebrowser.public" "$INSTALL_DIR/start-filebrowser.sh"
write_plist "com.filebrowser.public.tunnel" "$INSTALL_DIR/start-filebrowser-tunnel.sh"
if [[ "$KEEP_AWAKE" == 1 ]]; then
  write_plist "com.filebrowser.public.keepawake" "/usr/bin/caffeinate"
  /usr/libexec/PlistBuddy -c "Delete :ProgramArguments" "$LAUNCH_DIR/com.filebrowser.public.keepawake.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$LAUNCH_DIR/com.filebrowser.public.keepawake.plist"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string /usr/bin/caffeinate" "$LAUNCH_DIR/com.filebrowser.public.keepawake.plist"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string -dimsu" "$LAUNCH_DIR/com.filebrowser.public.keepawake.plist"
fi
if [[ "$START" == 1 ]]; then
  for label in com.filebrowser.public com.filebrowser.public.tunnel com.filebrowser.public.keepawake; do
    plist="$LAUNCH_DIR/$label.plist"
    [[ -f "$plist" ]] || continue
    launchctl bootout "gui/$UID" "$plist" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$UID" "$plist" >/dev/null 2>&1 || launchctl load -w "$plist" >/dev/null 2>&1 || true
    launchctl kickstart -k "gui/$UID/$label" >/dev/null 2>&1 || true
  done
fi
echo "FileBrowser installed with persistence."
echo "Local URL:  http://127.0.0.1:8091/files/"
echo "Remote URL: $public_url"
echo "Login user: $web_user"
echo "Login password: saved in $INSTALL_DIR/filebrowser.relay.json"
echo "LaunchAgents: com.filebrowser.public, com.filebrowser.public.tunnel, com.filebrowser.public.keepawake"
