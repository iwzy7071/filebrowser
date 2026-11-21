# FileBrowser public relay installers

These installers keep the local FileBrowser remote-access dependencies persistent:

- `filebrowser`: local web file service bound to `127.0.0.1:8091`
- `frpc`: reverse tunnel to the relay server
- keep-awake helper: prevents the machine from sleeping while the user session is active

The FileBrowser root is the current user's home directory. `/files/` can redirect to Desktop while still allowing access to folders outside Desktop under the same user home.

## Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest http://RELAY/downloads/install-filebrowser-windows.ps1 -OutFile $env:TEMP\install-filebrowser-windows.ps1; & $env:TEMP\install-filebrowser-windows.ps1 -RelayBaseUrl http://RELAY -SetupKey sk_xxx"
```

Persistence:

- Scheduled Task `FileBrowserPublic`
- Scheduled Task `FileBrowserPublicTunnel`
- Scheduled Task `FileBrowserPublicKeepAwake`
- The service wrappers restart the process if it exits.
- The installer also tries to set AC sleep/hibernate timeout to never. Use `-NoPowerTuning` to skip this.

## macOS

```bash
curl -fsSL http://RELAY/downloads/install-filebrowser-macos.sh -o install-filebrowser-macos.sh \
  && bash install-filebrowser-macos.sh --relay-base-url http://RELAY --setup-key sk_xxx --start-after-install
```

Persistence:

- LaunchAgent `com.filebrowser.public`
- LaunchAgent `com.filebrowser.public.tunnel`
- LaunchAgent `com.filebrowser.public.keepawake`
- The keep-awake agent runs `caffeinate -dimsu`.

## Ubuntu / Linux

```bash
curl -fsSL http://RELAY/downloads/install-filebrowser-linux.sh -o install-filebrowser-linux.sh \
  && bash install-filebrowser-linux.sh --relay-base-url http://RELAY --setup-key sk_xxx --start-after-install
```

Persistence:

- systemd user service `filebrowser-public.service`
- systemd user service `filebrowser-public-tunnel.service`
- systemd user service `filebrowser-public-keepawake.service`
- The installer tries to enable lingering with `loginctl enable-linger "$USER"`, so services can start after reboot before interactive login.
- If automatic lingering fails, run:

```bash
sudo loginctl enable-linger "$USER"
systemctl --user enable --now filebrowser-public.service filebrowser-public-tunnel.service filebrowser-public-keepawake.service
```

## Useful checks

Windows:

```powershell
Get-ScheduledTask FileBrowserPublic,FileBrowserPublicTunnel,FileBrowserPublicKeepAwake
Get-Content "$env:LOCALAPPDATA\FileBrowserPublic\logs\frpc.log" -Tail 80
```

macOS:

```bash
launchctl print gui/$UID/com.filebrowser.public
launchctl print gui/$UID/com.filebrowser.public.tunnel
launchctl print gui/$UID/com.filebrowser.public.keepawake
```

Ubuntu / Linux:

```bash
systemctl --user status filebrowser-public.service
systemctl --user status filebrowser-public-tunnel.service
systemctl --user status filebrowser-public-keepawake.service
journalctl --user -u filebrowser-public-tunnel.service -f
```
