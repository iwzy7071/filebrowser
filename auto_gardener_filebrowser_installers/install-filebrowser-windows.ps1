param(
  [string]$RelayBaseUrl = $env:FILEBROWSER_RELAY_BASE_URL,
  [string]$SetupKey = "",
  [string]$ProvisionUrl = "",
  [string]$InstallDir = "$env:LOCALAPPDATA\FileBrowserPublic",
  [switch]$NoStart,
  [switch]$NoKeepAwake,
  [switch]$NoPowerTuning
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Info($msg) { Write-Host "[FileBrowser] $msg" }
function Download-File($urls, $outFile) {
  foreach ($url in @($urls)) {
    if ([string]::IsNullOrWhiteSpace($url)) { continue }
    try {
      Write-Info "Downloading $url"
      Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing -TimeoutSec 300
      if ((Test-Path $outFile) -and ((Get-Item $outFile).Length -gt 0)) { return }
    } catch {
      Write-Warning "Download failed: $url - $($_.Exception.Message)"
    }
  }
  throw "All download URLs failed for $outFile"
}

function Register-LongRunningTask($name, $scriptPath, $description) {
  try { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue | Out-Null } catch {}
  try { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {}
  $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 3650)
  Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Description $description -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($ProvisionUrl)) {
  if ([string]::IsNullOrWhiteSpace($RelayBaseUrl) -or [string]::IsNullOrWhiteSpace($SetupKey)) {
    throw "Usage: install-filebrowser-windows.ps1 -RelayBaseUrl http://SERVER -SetupKey sk_xxx"
  }
  $RelayBaseUrl = $RelayBaseUrl.TrimEnd('/')
  $ProvisionUrl = "$RelayBaseUrl/downloads/provision/$SetupKey/filebrowser.provision.json"
} elseif (-not [string]::IsNullOrWhiteSpace($RelayBaseUrl)) {
  $RelayBaseUrl = $RelayBaseUrl.TrimEnd('/')
}

$tmp = Join-Path $env:TEMP ("filebrowser-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
try {
  $provPath = Join-Path $tmp "filebrowser.provision.json"
  Download-File @($ProvisionUrl) $provPath
  $prov = Get-Content $provPath -Raw | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace($RelayBaseUrl)) {
    $RelayBaseUrl = ([Uri]$prov.publicUrl).GetLeftPart([System.UriPartial]::Authority)
  }

  $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -eq "Arm64") { "arm64" } else { "amd64" }
  $zipUrl = $prov.filebrowserPackageUrls.windows.$arch
  $zipFallback = $prov.filebrowserPackageFallbackUrls.windows.$arch
  $zipPath = Join-Path $tmp "filebrowser.zip"
  Download-File @($zipUrl, $zipFallback) $zipPath

  $extract = Join-Path $tmp "extract"
  New-Item -ItemType Directory -Force -Path $extract | Out-Null
  Expand-Archive -Path $zipPath -DestinationPath $extract -Force
  $fbExe = Get-ChildItem -Path $extract -Filter "filebrowser.exe" -Recurse | Select-Object -First 1
  if (-not $fbExe) { throw "filebrowser.exe not found in archive" }
  Copy-Item $fbExe.FullName (Join-Path $InstallDir "filebrowser.exe") -Force

  $frpcUrl = $prov.frpcUrl
  Download-File @($frpcUrl, "$RelayBaseUrl/downloads/frpc.exe") (Join-Path $InstallDir "frpc.exe")
  Set-Content -Path (Join-Path $InstallDir "frpc.toml") -Value $prov.frpcToml -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "logs") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "cache") | Out-Null

  $root = $env:USERPROFILE
  $startFileBrowser = @"
`$ErrorActionPreference = 'Continue'
`$env:HOME = '$($env:USERPROFILE.Replace("'", "''"))'
while (`$true) {
  & '$((Join-Path $InstallDir "filebrowser.exe").Replace("'", "''"))' --database '$((Join-Path $InstallDir "filebrowser.db").Replace("'", "''"))' --root '$($root.Replace("'", "''"))' --address 127.0.0.1 --port 8091 --baseURL /files --cacheDir '$((Join-Path $InstallDir "cache").Replace("'", "''"))' --disableExec --noauth *> '$((Join-Path $InstallDir "logs\filebrowser.log").Replace("'", "''"))'
  Start-Sleep -Seconds 5
}
"@
  Set-Content -Path (Join-Path $InstallDir "start-filebrowser.ps1") -Value $startFileBrowser -Encoding UTF8

  $startTunnel = @"
`$ErrorActionPreference = 'Continue'
while (`$true) {
  & '$((Join-Path $InstallDir "frpc.exe").Replace("'", "''"))' -c '$((Join-Path $InstallDir "frpc.toml").Replace("'", "''"))' *> '$((Join-Path $InstallDir "logs\frpc.log").Replace("'", "''"))'
  Start-Sleep -Seconds 5
}
"@
  Set-Content -Path (Join-Path $InstallDir "start-filebrowser-tunnel.ps1") -Value $startTunnel -Encoding UTF8

  $keepAwake = @"
`$ErrorActionPreference = 'Continue'
Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
`$ES_CONTINUOUS = 0x80000000
`$ES_SYSTEM_REQUIRED = 0x00000001
while (`$true) {
  [void][Win32.NativeMethods]::SetThreadExecutionState(`$ES_CONTINUOUS -bor `$ES_SYSTEM_REQUIRED)
  Start-Sleep -Seconds 60
}
"@
  Set-Content -Path (Join-Path $InstallDir "keep-awake.ps1") -Value $keepAwake -Encoding UTF8

  $relayInfo = [ordered]@{
    schemaVersion = 1
    user = $prov.user
    publicUrl = $prov.publicUrl
    webUsername = $prov.webUsername
    webPassword = $prov.webPassword
    installedAt = (Get-Date).ToUniversalTime().ToString("o")
    autostart = "ScheduledTask AtLogOn; wrappers restart on failure"
    keepAwake = (-not $NoKeepAwake)
  }
  $relayInfo | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $InstallDir "filebrowser.relay.json") -Encoding UTF8

  Register-LongRunningTask "FileBrowserPublic" (Join-Path $InstallDir "start-filebrowser.ps1") "FileBrowser local web service; auto-starts at Windows logon and restarts on failure"
  Register-LongRunningTask "FileBrowserPublicTunnel" (Join-Path $InstallDir "start-filebrowser-tunnel.ps1") "FileBrowser relay tunnel; auto-starts at Windows logon and restarts on failure"
  if (-not $NoKeepAwake) {
    Register-LongRunningTask "FileBrowserPublicKeepAwake" (Join-Path $InstallDir "keep-awake.ps1") "Prevents Windows sleep while this user is logged in so remote FileBrowser remains reachable"
  }

  if (-not $NoPowerTuning) {
    try {
      powercfg /change standby-timeout-ac 0 | Out-Null
      powercfg /change hibernate-timeout-ac 0 | Out-Null
      Write-Info "Set AC sleep/hibernate timeout to never."
    } catch {
      Write-Warning "Could not adjust Windows powercfg. Run PowerShell as Administrator if you want AC sleep disabled globally."
    }
  }

  if (-not $NoStart) {
    Start-ScheduledTask -TaskName "FileBrowserPublic"
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName "FileBrowserPublicTunnel"
    if (-not $NoKeepAwake) { Start-ScheduledTask -TaskName "FileBrowserPublicKeepAwake" }
  }

  Write-Host ""
  Write-Host "FileBrowser installed with persistence."
  Write-Host "Local URL:  http://127.0.0.1:8091/files/"
  Write-Host "Remote URL: $($prov.publicUrl)"
  Write-Host "Login user: $($prov.webUsername)"
  Write-Host "Login password: saved in $InstallDir\filebrowser.relay.json"
  Write-Host "Autostart: Windows Scheduled Tasks: FileBrowserPublic, FileBrowserPublicTunnel, FileBrowserPublicKeepAwake"
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
