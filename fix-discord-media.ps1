#Requires -Version 5.1
<#
  fix-discord-media.ps1

  Discord shows "Failed to load image": avatars, stickers, emoji and attachments
  do not load, while text and voice still work. On many networks the Discord
  media CDN is blocked by destination IP, and no DPI desync can help there -
  only a different destination address can.

  So this script does two things in one run, without asking anything:

    1. makes sure your zapret bypass is up AND working: starts a config if
       winws.exe is not running, and if the Discord media hosts still do not
       answer through it, stops that config and tries the next one until one
       gets through (up to 5 configs). When TCP 443 does not connect to the
       CDN at all, another config cannot help and the switching is skipped;
    2. pins the addresses that actually answer for the Discord media CDN into
       the Windows hosts file, inside a marked block, then restarts Discord.

  Running the .bat is the whole interaction: elevation, config choice, the
  bypass restart and the Discord restart are automatic. If nothing works, the
  script says WHY (blocked by name or the addresses themselves are dropped)
  and leaves hosts unchanged instead of pinning dead addresses.

  It works with any zapret bundle layout (winws.exe in bin\ or in the root),
  finds the folder automatically, and never edits the zapret config itself.

  Usage (double-click the .bat, it asks for administrator rights itself):
      fix-discord-media.bat                 apply the fix
      fix-discord-media.bat -Remove         undo
      fix-discord-media.bat -ShowConfigs    list your zapret configs
      fix-discord-media.bat -DryRun         show what would change

  When zapret is not running yet, the script starts the best config it found
  (the last one that worked, else general.bat) and switches to the next config
  only if media still does not answer. Nothing is asked. The config that
  actually worked is remembered in %LOCALAPPDATA%\discord-media-fix\last-config.txt.

  Options:
      -Remove          delete the pin block and exit
      -NoRestart       do not restart the Discord client
      -DryRun          print the result, change nothing
      -Force           re-probe and re-pin even if everything already works
      -NoZapret        do not touch zapret, only pin hosts
      -IgnoreVpn       continue even when a VPN carries the default route
                       (by default the script stops and explains: pins cannot
                       be reached through a tunnel)
      -ZapretDir PATH  zapret folder (auto-detected when omitted)
      -Config NAME     use only this config, no automatic switching,
                       e.g. "general (ALT11).bat"
      -RestartZapret   restart the bypass even when it already answers
                       (by default a working bypass is left alone)
      -Prompt          show the config menu instead of choosing automatically
      -NoPrompt        never ask (automatic is already the default)
      -ShowConfigs     list the configs found in the zapret folder and exit
      -HostsFile PATH  alternate hosts file (for testing)
      -Hosts NAME...   hostnames to pin (default: the three Discord media hosts)
      -ExtraIPs IP...  extra candidate addresses to probe first
      -Version         print the script version and exit

  Versioning: Semantic Versioning (MAJOR.MINOR.PATCH). The version is defined
  once below in $AppVersion, the tag is v<version>, and every change is written
  down in CHANGELOG.md. When releasing: bump $AppVersion, add a CHANGELOG entry,
  commit, tag v<version>, and attach the three files as discord-media-fix.zip.
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$NoRestart,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$NoZapret,
    [switch]$IgnoreVpn,
    [switch]$ShowConfigs,
    [switch]$RestartZapret,
    [switch]$NoPrompt,
    [switch]$Prompt,
    [switch]$Version,
    [string]$ZapretDir = '',
    [string]$Config = '',
    [string]$HostsFile = (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'),
    [string[]]$Hosts = @(
        'media.discordapp.net',
        'images-ext-1.discordapp.net',
        'images-ext-2.discordapp.net'
    ),
    [string[]]$ExtraIPs = @()
)

# Single source of truth for the version. Keep in sync with CHANGELOG.md.
$AppVersion = '1.5.1'

$ErrorActionPreference = 'Stop'

if ($Version) {
    "fix-discord-media $AppVersion"
    return
}

# When the script is started with -File (which is what the .bat does), PowerShell
# passes list arguments as one literal string: -Hosts a,b,c arrives as "a,b,c".
# Split and trim so both forms work.
$Hosts = @($Hosts | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$ExtraIPs = @($ExtraIPs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if (-not $Hosts -or $Hosts.Count -eq 0) {
    $Hosts = @('media.discordapp.net', 'images-ext-1.discordapp.net', 'images-ext-2.discordapp.net')
}

$pinStart = '# >>> discord-media-pin (auto) >>>'
$pinEnd   = '# <<< discord-media-pin (auto) <<<'

# Adapter names/descriptions that mean "this is a tunnel, not the ISP link".
$vpnPattern = '(?i)vpn|wireguard|wintun|tap-|tap windows|openvpn|nordlynx|amnezia|outline|happ|tailscale|zerotier|globalprotect|anyconnect|wan miniport|sstp|pptp|l2tp|warp|sing-box|clash|tun2socks|nekoray|v2ray|xray'


$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$systemHosts  = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$isSystemFile = ([IO.Path]::GetFullPath($HostsFile) -eq [IO.Path]::GetFullPath($systemHosts))
$curlPath     = Join-Path $env:SystemRoot 'System32\curl.exe'

# Cloudflare anycast addresses that serve the Discord CDN. The first ones are
# known to answer even without a bypass; the rest of the range is scanned as a
# fallback. Addresses that do not answer are never written.
$preferred = @(
    '162.159.141.232',
    '162.159.131.233',
    '162.159.132.233',
    '162.159.133.233',
    '162.159.138.232',
    '162.159.137.232',
    '162.159.135.232',
    '162.159.128.233',
    '162.159.136.232',
    '162.159.129.233'
)

function Write-Step {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Winws {
    return [bool](Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
}

# Raw TCP connect, no SNI and no TLS: answers "is this address readable at all".
# Uses .NET directly so it works on any PowerShell 5.1 and never hangs.
function Test-TcpPort {
    param([string]$Address, [int]$Port = 443, [int]$TimeoutMs = 6000)

    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Address, $Port)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return [bool]$client.Connected
    }
    catch { return $false }
    finally { try { $client.Close() } catch { } }
}

# True when the running winws.exe belongs to a Windows service. Such a bypass is
# managed by the service manager, so the script must not kill and replace it.
function Test-ZapretService {
    try {
        $pids = @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Id)
        if ($pids.Count -eq 0) { return $false }
        $svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
            Where-Object { $pids -contains [int]$_.ProcessId }
        return [bool]$svc
    }
    catch { return $false }
}

# Tunnels that are up right now, by name or by driver description.
function Get-VpnAdapters {
    try {
        return @(Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.Status -eq 'Up' -and
            ($_.Name -match $vpnPattern -or $_.InterfaceDescription -match $vpnPattern)
        })
    }
    catch { return @() }
}

# The adapter that actually carries the default route. If it is a tunnel, every
# outbound connection goes through the VPN - pinned addresses included.
function Get-VpnDefaultRoute {
    try {
        $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric)
        foreach ($route in $routes) {
            $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
            if (-not $adapter) { continue }
            if ($adapter.Name -match $vpnPattern -or $adapter.InterfaceDescription -match $vpnPattern) {
                return $adapter
            }
        }
    }
    catch { }
    return $null
}

function Stop-Winws {
    Get-Process -Name 'winws' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 20 -and (Test-Winws); $i++) { Start-Sleep -Milliseconds 250 }
}

# Starts a zapret config and waits until winws.exe is there and had a moment to
# attach WinDivert, otherwise the very first probe would run before filtering.
function Start-ZapretConfig {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }

    Stop-Winws
    Write-Step ("Starting the bypass: {0}" -f (Split-Path -Leaf $Path)) 'Gray'
    Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) | Out-Null

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not (Test-Winws)) {
        Start-Sleep -Milliseconds 400
    }
    if (-not (Test-Winws)) {
        Write-Step 'winws.exe did not appear within 30 s.' 'Yellow'
        return $false
    }
    Start-Sleep -Seconds 3
    return $true
}

function Test-ZapretFolder {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Dir 'bin\winws.exe')) -or
           (Test-Path -LiteralPath (Join-Path $Dir 'winws.exe')) -or
           (Test-Path -LiteralPath (Join-Path $Dir 'service.bat'))
}

function Find-ZapretDir {
    param([string]$Path)

    if ($Path) {
        if (Test-ZapretFolder -Dir $Path) { return (Resolve-Path -LiteralPath $Path).Path }
        return ''
    }

    $candidates = @(
        $scriptDir,
        (Split-Path -Parent $scriptDir),
        (Join-Path $env:USERPROFILE 'zapret'),
        'C:\zapret',
        'D:\zapret',
        'C:\dis',
        'D:\dis'
    )

    foreach ($dir in $candidates) {
        if (Test-ZapretFolder -Dir $dir) { return (Resolve-Path -LiteralPath $dir).Path }
    }
    return ''
}

function Get-ZapretConfigs {
    param([string]$Dir)

    if (-not $Dir) { return @() }
    $skip = '(?i)^(service|install|uninstall|remove|stop|remove_service|update|check)'
    return @(
        Get-ChildItem -LiteralPath $Dir -Filter '*.bat' -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -notmatch $skip -and
                $_.Name -notmatch '(?i)vpn-guard|discord-media|start-discord'
            } |
            Sort-Object Name
    )
}

function Resolve-ZapretConfig {
    param([string]$Dir, [string]$Name)

    if ($Name) {
        if (Test-Path -LiteralPath $Name) { return (Resolve-Path -LiteralPath $Name).Path }
        $inDir = Join-Path $Dir $Name
        if (Test-Path -LiteralPath $inDir) { return (Resolve-Path -LiteralPath $inDir).Path }
        return ''
    }

    $configs = Get-ZapretConfigs -Dir $Dir
    if ($configs.Count -eq 0) { return '' }

    # general.bat is the safest default; alternative variants are used when it
    # is not there.
    $exact = $configs | Where-Object { $_.Name -ieq 'general.bat' } | Select-Object -First 1
    if ($exact) { return $exact.FullName }

    $general = $configs | Where-Object { $_.Name -match '(?i)general' } | Select-Object -First 1
    if ($general) { return $general.FullName }

    return $configs[0].FullName
}

function Get-SettingsFile {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = $scriptDir }
    return (Join-Path (Join-Path $base 'discord-media-fix') 'last-config.txt')
}

function Get-LastChoice {
    try {
        $file = Get-SettingsFile
        if (Test-Path -LiteralPath $file) { return ([IO.File]::ReadAllText($file)).Trim() }
    }
    catch { }
    return ''
}

function Save-Choice {
    param([string]$Name)

    if (-not $Name) { return }
    try {
        $file = Get-SettingsFile
        $dir = Split-Path -Parent $file
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($file, $Name, [Text.Encoding]::Default)
    }
    catch { }
}

function Show-ConfigList {
    param([object[]]$Configs, [string]$Default)

    for ($i = 0; $i -lt $Configs.Count; $i++) {
        $mark = ''
        if ($Default -and $Configs[$i].FullName -ieq $Default) { $mark = '   <- default' }
        Write-Step ("  [{0}] {1}{2}" -f ($i + 1), $Configs[$i].Name, $mark) 'Gray'
    }
}

# Interactive picker. Returns a full path, '' when there is nothing to pick,
# or $null when the user cancels.
function Select-ZapretConfig {
    param([object[]]$Configs, [string]$Default)

    if (-not $Configs -or $Configs.Count -eq 0) { return '' }
    if ($Configs.Count -eq 1) { return $Configs[0].FullName }

    Write-Step ''
    Write-Step 'Configs found:' 'Gray'
    Show-ConfigList -Configs $Configs -Default $Default
    Write-Step ''
    Write-Step 'Which zapret config should be started?' 'Gray'
    Write-Step 'Enter = the default, q = cancel' 'DarkGray'

    while ($true) {
        $answer = Read-Host '  Number'
        if ($null -eq $answer) { return $null }
        $answer = $answer.Trim()
        if ($answer -match '^(q|quit|exit)$') { return $null }
        if ($answer -eq '') { return $Default }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Configs.Count) {
            return $Configs[$n - 1].FullName
        }
        Write-Step '  Type a number from the list.' 'Yellow'
    }
}

function Get-HostsText {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Text = ''; Kind = 'Default' }
    }

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return @{ Text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3); Kind = 'UTF8BOM' }
    }
    return @{ Text = [Text.Encoding]::Default.GetString($bytes); Kind = 'Default' }
}

function Remove-OldBackups {
    param([string]$Path)
    Get-ChildItem -Path ("{0}.bak-*" -f $Path) -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 5 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Save-HostsText {
    param([string]$Path, [string]$Text, [string]$Kind)

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    $wasReadOnly = $false
    if ($item -and $item.IsReadOnly) {
        $wasReadOnly = $true
        Set-ItemProperty -LiteralPath $Path -Name IsReadOnly -Value $false
    }

    $backup = "{0}.bak-{1}" -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $Path -Destination $backup -Force

    if ($Kind -eq 'UTF8BOM') {
        [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($true)))
    }
    else {
        [IO.File]::WriteAllText($Path, $Text, [Text.Encoding]::Default)
    }

    if ($wasReadOnly) {
        Set-ItemProperty -LiteralPath $Path -Name IsReadOnly -Value $true
    }

    Remove-OldBackups -Path $Path
    return $backup
}

# Drops our marked block, if present, and keeps everything else in the file.
function Get-TextWithoutPin {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $pattern = '(?msi)^[ \t]*' + [regex]::Escape($pinStart) + '.*?^[ \t]*' + [regex]::Escape($pinEnd) + '[^\r\n]*\r?\n?'
    return [regex]::Replace($Text, $pattern, '')
}

# Probes the endpoint through curl.exe with -s (silent), so a timeout never
# becomes a terminating NativeCommandError. Returns ok / dead / nocurl.
# The timeout is generous on purpose: a throttled line needs more than 5 s.
function Test-MediaEndpoint {
    param(
        [string]$ResolveTo = '',
        [string]$HostName = 'media.discordapp.net',
        [int]$TimeoutSec = 8
    )

    if (-not (Test-Path -LiteralPath $curlPath)) { return 'nocurl' }

    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $curlArgs = @('-s', '-o', 'NUL', '-m', "$TimeoutSec", '-w', '%{http_code}')
        if ($ResolveTo) { $curlArgs += @('--resolve', "${HostName}:443:$ResolveTo") }
        $curlArgs += "https://$HostName/"

        $code = & $curlPath @curlArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return 'dead' }
        if ($code -match '^[1-5]\d\d$') { return 'ok' }
        return 'dead'
    }
    catch {
        return 'dead'
    }
    finally {
        $ErrorActionPreference = $saved
    }
}

# True as soon as one of the addresses answers for the Discord media host.
# A single dead address means nothing - only "every seed dead" does.
function Test-MediaAlive {
    param(
        [string[]]$Addresses,
        [string]$HostName = 'media.discordapp.net',
        [int]$Attempts = 1,
        [int]$TimeoutSec = 5
    )

    if (-not $Addresses -or $Addresses.Count -eq 0) { return $false }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        foreach ($ip in $Addresses) {
            if ((Test-MediaEndpoint -ResolveTo $ip -HostName $HostName -TimeoutSec $TimeoutSec) -eq 'ok') {
                return $true
            }
        }
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds 2 }
    }
    return $false
}

# Control probe: does Discord work at all through the current bypass?
# Returns ok / fail, or dns when the name itself does not resolve (then the
# answer says nothing about the bypass, so no conclusion is drawn from it).
function Test-ControlHost {
    param([string]$HostName = 'discord.com', [int]$TimeoutSec = 8)

    if (-not (Test-Path -LiteralPath $curlPath)) { return 'dns' }

    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $code = & $curlPath @('-s', '-o', 'NUL', '-m', "$TimeoutSec", '-w', '%{http_code}', "https://$HostName/") 2>$null
        if ($LASTEXITCODE -eq 5 -or $LASTEXITCODE -eq 6) { return 'dns' }
        if ($LASTEXITCODE -ne 0) { return 'fail' }
        if ($code -match '^[1-5]\d\d$') { return 'ok' }
        return 'fail'
    }
    catch { return 'fail' }
    finally { $ErrorActionPreference = $saved }
}

# Probes candidate addresses and keeps the ones that answer. Bounded in time:
# at most $Limit addresses, each with its own timeout.
function Get-AliveAddresses {
    param(
        [string[]]$Candidates,
        [string]$HostName = 'media.discordapp.net',
        [int]$Limit = 10,
        [int]$TimeoutSec = 6,
        [int]$Wanted = 4
    )

    $alive = New-Object System.Collections.Generic.List[string]
    $tried = 0

    foreach ($ip in $Candidates) {
        if ($alive.Count -ge $Wanted -or $tried -ge $Limit) { break }
        $tried++

        $result = Test-MediaEndpoint -ResolveTo $ip -HostName $HostName -TimeoutSec $TimeoutSec
        if ($result -eq 'ok') {
            $alive.Add($ip)
            Write-Step "  $ip  answers" 'Green'
        }
        elseif ($result -eq 'dead') {
            Write-Step "  $ip  no answer" 'DarkGray'
        }
        else {
            Write-Step "  $ip  skipped (no curl.exe)" 'DarkGray'
        }
    }
    return @($alive)
}

# Distinguishes the two failure modes nobody should mix up:
#   blackhole   - TCP 443 itself does not connect, the addresses are dropped;
#   name|<ip>   - TCP connects, TLS to the Discord host dies, block is by name.
# The connected address is returned so the failure report can stay concrete.
function Get-BlockDiagnosis {
    param([string[]]$Addresses, [int]$TimeoutMs = 6000)

    foreach ($ip in $Addresses) {
        if (Test-TcpPort -Address $ip -TimeoutMs $TimeoutMs) { return "name|$ip" }
    }
    return 'blackhole'
}

# Config order for the automatic start: the wanted one, then general.bat, then
# every other general* config, then the rest.
function Get-ConfigOrder {
    param([object[]]$Configs, [string]$Preferred)

    $order = New-Object System.Collections.Generic.List[string]
    if ($Preferred) { $order.Add($Preferred) }
    foreach ($c in @($Configs)) {
        if ($c.Name -ieq 'general.bat' -and -not $order.Contains($c.FullName)) {
            $order.Add($c.FullName)
        }
    }
    foreach ($c in @($Configs)) {
        if ($c.Name -match '(?i)general' -and -not $order.Contains($c.FullName)) {
            $order.Add($c.FullName)
        }
    }
    foreach ($c in @($Configs)) {
        if (-not $order.Contains($c.FullName)) { $order.Add($c.FullName) }
    }
    return @($order)
}


function Start-Discord {
    param([string[]]$Names)

    $map = @{
        'Discord'            = @('Discord',            'Discord.exe')
        'DiscordPTB'         = @('DiscordPTB',         'DiscordPTB.exe')
        'DiscordCanary'      = @('DiscordCanary',      'DiscordCanary.exe')
        'DiscordDevelopment' = @('DiscordDevelopment', 'DiscordDevelopment.exe')
    }

    $started = 0
    foreach ($name in $Names) {
        if (-not $map.ContainsKey($name)) { continue }
        $folder, $exe = $map[$name]
        $updater = Join-Path $env:LOCALAPPDATA (Join-Path $folder 'Update.exe')
        if (Test-Path -LiteralPath $updater) {
            Start-Process -FilePath $updater -ArgumentList '--processStart', $exe | Out-Null
            $started++
        }
    }
    return $started
}

Write-Step ''
Write-Step ("=== Discord media fix v{0} (zapret + hosts) ===" -f $AppVersion) 'Cyan'

# ---------- undo ----------
if ($Remove) {
    Write-Step 'Removing the pin block from hosts.' 'Yellow'

    $current = Get-HostsText -Path $HostsFile
    $clean = (Get-TextWithoutPin $current.Text).TrimEnd("`r", "`n")
    $newText = $clean + "`r`n"

    if ($DryRun) {
        Write-Step ''
        Write-Step '--- resulting hosts (dry run, nothing written) ---' 'DarkGray'
        Write-Step $newText
        return
    }

    if ($newText -eq $current.Text) {
        Write-Step 'No pin block found - hosts not changed.' 'Green'
        return
    }

    try {
        $backup = Save-HostsText -Path $HostsFile -Text $newText -Kind $current.Kind
        & ipconfig /flushdns | Out-Null
        Write-Step "Done. Backup: $backup" 'Green'
        Write-Step 'Restart Discord for the change to take effect.' 'Gray'
    }
    catch {
        Write-Step ''
        Write-Step "Could not write hosts: $($_.Exception.Message)" 'Red'
        Write-Step 'Usually Microsoft Defender "Controlled folder access" - allow the change for a minute.' 'Yellow'
        exit 1
    }
    return
}

# ---------- preconditions ----------
if ($isSystemFile -and -not (Test-Admin)) {
    Write-Step 'Administrator rights are required to edit the hosts file.' 'Red'
    Write-Step 'Run fix-discord-media.bat (it asks for elevation) or start PowerShell as administrator.' 'Yellow'
    exit 1
}

# ---------- VPN / TUN tunnel check ----------
# The pins point at addresses reached through the ISP directly. Inside a tunnel
# those addresses are not reachable, so the whole fix is pointless while a VPN
# carries the traffic: the script says so instead of writing useless entries.
$vpnDefault  = Get-VpnDefaultRoute
$vpnAdapters = @(Get-VpnAdapters)
if ($vpnDefault -and -not ($vpnAdapters | Where-Object { $_.ifIndex -eq $vpnDefault.ifIndex })) {
    $vpnAdapters += $vpnDefault
}
$vpnNames = (@($vpnAdapters) | Select-Object -ExpandProperty Name -Unique) -join ', '

if ($vpnDefault) {
    Write-Step ''
    if ($DryRun) {
        Write-Step ("VPN is on and carries all traffic: {0}" -f $vpnNames) 'Yellow'
        Write-Step 'The fixed addresses only work on a direct connection - turn the VPN off for the real run.' 'Yellow'
    }
    elseif ($IgnoreVpn) {
        Write-Step ("VPN is on ({0}) - continuing because -IgnoreVpn was passed." -f $vpnNames) 'Yellow'
    }
    else {
        Write-Step ("VPN is on: {0}. Nothing was changed." -f $vpnNames) 'Red'
        Write-Step 'This fix needs a direct connection. While the VPN is on, Discord images already' 'Yellow'
        Write-Step 'travel through the tunnel - and zapret cannot help inside it.' 'Yellow'
        Write-Step ''
        Write-Step 'Turn the VPN off and run this file again.' 'Cyan'
        Write-Step 'Or keep the VPN for everything else and send only Discord through it (split tunneling).' 'Cyan'
        Write-Step 'To try anyway, add -IgnoreVpn.' 'Gray'
        exit 3
    }
}
elseif ($vpnAdapters.Count -gt 0) {
    Write-Step ''
    Write-Step ("A VPN adapter is up ({0}), but your traffic does not go through it." -f $vpnNames) 'DarkGray'
    Write-Step 'Fine for this fix. If Discord still fails later, check what the VPN does with *discordapp.net.' 'DarkGray'
}

$zapretHome   = ''
$zapretConfig = ''
$configs      = @()
$interactive  = $false

if (-not $NoZapret) {
    Write-Step 'One-time fix: this file starts zapret, not Discord. Later, open Discord as usual.' 'DarkGray'
    $zapretHome = Find-ZapretDir -Path $ZapretDir
    if (-not $zapretHome) {
        Write-Step 'No zapret folder found.' 'Yellow'
        Write-Step 'Point the script at it: -ZapretDir "D:\zapret" (the folder with bin\winws.exe).' 'Yellow'
        Write-Step 'Continuing without zapret: only the address list will be checked.' 'Yellow'
    }
    else {
        Write-Step "zapret folder: $zapretHome" 'DarkGray'

        $configs = @(Get-ZapretConfigs -Dir $zapretHome)
        $defaultConfig = Resolve-ZapretConfig -Dir $zapretHome -Name ''

        # The last config the user picked becomes the default on the next run.
        $lastChoice = Get-LastChoice
        if ($lastChoice) {
            $lastPath = Join-Path $zapretHome $lastChoice
            if (Test-Path -LiteralPath $lastPath) { $defaultConfig = (Resolve-Path -LiteralPath $lastPath).Path }
        }

        if ($ShowConfigs) {
            Write-Step ''
            Write-Step 'Configs found:' 'Gray'
            if ($configs.Count -eq 0) { Write-Step '  (none)' 'Yellow' }
            Show-ConfigList -Configs $configs -Default $defaultConfig
            Write-Step ''
            Write-Step 'Run the script without arguments to pick one interactively,' 'Gray'
            Write-Step 'or pass -Config "name.bat".' 'Gray'
            return
        }

        if ($configs.Count -eq 0) {
            Write-Step 'No config (.bat) found in the zapret folder.' 'Yellow'
            Write-Step 'Continuing without starting zapret.' 'Yellow'
        }
        elseif ($Config) {
            $zapretConfig = Resolve-ZapretConfig -Dir $zapretHome -Name $Config
            if (-not $zapretConfig) {
                Write-Step "Config not found: $Config" 'Red'
                Write-Step 'Run with -ShowConfigs to see what is available.' 'Yellow'
                exit 1
            }
        }
        else {
            # Automatic by default: no menu, no questions, the script starts the
            # remembered config and switches on its own if that one fails.
            # -Prompt brings the interactive picker back.
            $interactive = [bool]$Prompt

            if ($interactive) {
                $picked = Select-ZapretConfig -Configs $configs -Default $defaultConfig
                if ($null -eq $picked) {
                    Write-Step ''
                    Write-Step 'Cancelled - nothing was changed.' 'Yellow'
                    exit 0
                }
                $zapretConfig = $picked
            }
            else {
                $zapretConfig = $defaultConfig
            }
        }

        if ($zapretConfig) {
            Write-Step ("Config: {0}" -f (Split-Path -Leaf $zapretConfig)) 'Gray'
            # In automatic mode the choice is remembered only after it is proven
            # to work, below; a manual pick from the menu is remembered here.
            if ($interactive -and -not $DryRun) { Save-Choice (Split-Path -Leaf $zapretConfig) }
        }
    }
}

# ---------- bring the bypass up and make sure it actually works ----------
# Everything here is automatic: start, wait, probe, and if media still does not
# get through, restart with the next config. Skipped when TCP 443 already fails
# on every seed address - no desync strategy can open a dead route.
$bypassUp     = $false
$bypassConfig = ''
$lastStarted  = ''
$controlState = ''

if ($zapretConfig) {
    $seed = @($preferred | Select-Object -First 4)

    if ($DryRun) {
        Write-Step ("Dry run: would start {0} and probe through it." -f (Split-Path -Leaf $zapretConfig)) 'DarkGray'
        $bypassUp = $true
    }
    else {
        $healthy = $false

        if ((Test-Winws) -and -not $RestartZapret) {
            Write-Step 'zapret is already running - checking whether images get through it.' 'DarkGray'
            $healthy = Test-MediaAlive -Addresses $seed -Attempts 2
            if ($healthy) {
                $bypassUp = $true
                Write-Step 'Images get through the running zapret.' 'Green'
            }
            else {
                Write-Step 'Images do not get through it - restarting zapret with another config.' 'Yellow'
                $controlState = Test-ControlHost
                if ($controlState -eq 'ok') {
                    Write-Step 'Discord itself loads through it - only the media hosts are cut off.' 'Yellow'
                }
                elseif ($controlState -eq 'fail') {
                    Write-Step 'Discord does not load through it either - this DPI is not beaten by it.' 'Yellow'
                }
            }
        }

        if (-not $healthy) {
            $serviceMode = Test-ZapretService
            if ($serviceMode) {
                Write-Step 'zapret is installed as a Windows service - the script will not restart it.' 'Yellow'
                Write-Step 'Restart that service yourself if you want another config.' 'Yellow'
            }
            else {
                $order = @(Get-ConfigOrder -Configs $configs -Preferred $zapretConfig)
                # -Config means "use exactly this one": no automatic switching.
                $limit = [Math]::Min($order.Count, 5)
                if ($Config) { $limit = [Math]::Min($order.Count, 1) }

                for ($i = 0; $i -lt $limit; $i++) {
                    $candidate = $order[$i]
                    Write-Step ''
                    Write-Step ("Trying config {0} of {1}: {2}" -f ($i + 1), $limit, (Split-Path -Leaf $candidate)) 'Cyan'

                    if (-not (Start-ZapretConfig -Path $candidate)) { continue }
                    $lastStarted = $candidate

                    if (Test-MediaAlive -Addresses $seed -Attempts 2) {
                        $bypassUp = $true
                        $bypassConfig = $candidate
                        Save-Choice (Split-Path -Leaf $candidate)
                        Write-Step 'This one works - keeping it.' 'Green'
                        break
                    }

                    Write-Step ("{0} did not get images through." -f (Split-Path -Leaf $candidate)) 'Yellow'

                    # If even TCP 443 never connects, another config cannot fix it.
                    if ((Get-BlockDiagnosis -Addresses $seed) -eq 'blackhole') {
                        Write-Step 'The Discord CDN does not answer at all here - another config cannot open it.' 'Yellow'
                        Write-Step 'Keeping zapret up for chat and voice.' 'Yellow'
                        break
                    }

                    # Second opinion: does Discord work at all through this config?
                    $controlState = Test-ControlHost
                    if ($controlState -eq 'ok') {
                        Write-Step 'Discord itself works through it - only the media hosts are cut off.' 'Yellow'
                    }
                    elseif ($controlState -eq 'fail') {
                        Write-Step 'Discord does not load through it either - this config is not beating the DPI.' 'Yellow'
                    }
                }
            }
        }

        if ($bypassUp) {
            Write-Step ''
            Write-Step 'Do not close the minimized zapret window - it keeps the bypass up.' 'Red'
        }
        elseif ($serviceMode) {
            Write-Step ''
            Write-Step 'The service keeps zapret up; the address list is still checked below.' 'Yellow'
        }
        elseif ($configs.Count -gt 0) {
            Write-Step ''
            Write-Step 'No config got the images through.' 'Yellow'
            Write-Step 'The address list is still checked below.' 'Yellow'
        }
    }
}

# ---------- do the pinned addresses still work? ----------
# The bypass is already up, so this is what Discord will actually see. It only
# decides whether hosts has to be rewritten; the file is used to start the
# bypass every day, so a healthy check must never stop it from doing that.
$needFix = $true
if ($isSystemFile -and -not $Force) {
    $dead = @()
    foreach ($name in $Hosts) {
        $ok = (Test-MediaEndpoint -HostName $name -TimeoutSec 8) -eq 'ok'
        if (-not $ok) { $ok = (Test-MediaEndpoint -HostName $name -TimeoutSec 10) -eq 'ok' }
        if (-not $ok) { $dead += $name }
    }

    if ($dead.Count -eq 0) {
        $needFix = $false
    }
    else {
        Write-Step ("Not answering right now: {0} - checking other addresses." -f ($dead -join ', ')) 'Yellow'
    }
}

# ---------- fix the hosts (only when needed) ----------
if ($needFix) {

    # ----- find addresses that answer -----
    Write-Step ''
    Write-Step 'Probing Cloudflare addresses for the Discord CDN...' 'Gray'

    $candidates = @($ExtraIPs) + @($preferred)
    $candidates += foreach ($last in 232, 233) {
        foreach ($n in 128..141) { "162.159.$n.$last" }
    }
    $candidates = @($candidates | Where-Object { $_ } | Select-Object -Unique)

    $alive = @(Get-AliveAddresses -Candidates $candidates -HostName 'media.discordapp.net' -Limit 8 -TimeoutSec 6)

    if ($alive.Count -eq 0 -and (Test-Path -LiteralPath $curlPath)) {
        Write-Step ''
        Write-Step 'Nothing yet - trying again with a longer wait (slow connections need it).' 'Gray'
        $retry = @($candidates | Select-Object -First 4)
        $alive = @(Get-AliveAddresses -Candidates $retry -HostName 'media.discordapp.net' -Limit 4 -TimeoutSec 12 -Wanted 2)
    }

    if ($alive.Count -eq 0 -and (Test-Path -LiteralPath $curlPath)) {
        # Tell the two failures apart instead of blaming the whole Cloudflare range.
        $reason = Get-BlockDiagnosis -Addresses @($candidates | Select-Object -First 3)
        $tcpTarget = ''
        if ($reason -like 'name|*') { $tcpTarget = $reason.Substring(5); $reason = 'name' }

        # One more control probe when the value is not known yet (hosts-only run,
        # or the config loop never ran), so the verdict names the real culprit.
        if (-not $controlState) { $controlState = Test-ControlHost }
        $bypassActive = $bypassUp -or (Test-Winws)

        Write-Step ''
        Write-Step 'No address answered.' 'Red'

        if ($reason -eq 'blackhole') {
            Write-Step 'None of them accepted a connection at all. Something on the network drops' 'Yellow'
            Write-Step 'these addresses (or slows them to a standstill), so another address cannot help.' 'Yellow'
            Write-Step ''
            Write-Step 'What actually works: send only Discord through a VPN (split tunneling)' 'Cyan'
            Write-Step 'or set a proxy for Discord. A VPN for the whole PC is the blunt version.' 'Cyan'
            Write-Step ('Details: TCP 443 refused on {0}.' -f (($candidates | Select-Object -First 3) -join ', ')) 'DarkGray'
        }
        else {
            if ($controlState -eq 'ok') {
                Write-Step 'Discord itself loads through the bypass, but every connection to' 'Yellow'
                Write-Step 'media.discordapp.net is cut off. The block is on the media hosts by name,' 'Yellow'
                Write-Step 'not on the address, so changing addresses cannot fix it.' 'Yellow'
            }
            elseif ($controlState -eq 'fail' -and $bypassActive) {
                Write-Step 'The addresses answer, but Discord does not load through the running bypass' 'Yellow'
                Write-Step 'at all (discord.com fails too), so the media hosts fail for the same reason.' 'Yellow'
                Write-Step 'This DPI is simply not being beaten by the config that is running.' 'Yellow'
            }
            else {
                Write-Step 'The addresses answer, but Discord does not load at all here: even discord.com' 'Yellow'
                Write-Step 'fails. So it is not about the addresses - nothing is getting past this DPI,' 'Yellow'
                Write-Step 'and the media hosts fail for the same reason.' 'Yellow'
            }

            if ($bypassUp -and -not $DryRun) {
                $cfgName = 'the current config'
                if ($bypassConfig) { $cfgName = Split-Path -Leaf $bypassConfig }
                Write-Step ("Running config: {0}." -f $cfgName) 'Gray'
            }

            Write-Step ''
            Write-Step 'Next steps, easiest first:' 'Cyan'
            Write-Step '  1. another zapret config: -ShowConfigs, then -Config "general (ALT...).bat"' 'Cyan'
            Write-Step '  2. a VPN with split tunneling for Discord, or a proxy for Discord' 'Cyan'

            if ($tcpTarget) {
                if ($controlState -eq 'ok') {
                    Write-Step ('Details: TCP 443 to {0} is open; discord.com loads; media.discordapp.net fails.' -f $tcpTarget) 'DarkGray'
                }
                elseif ($controlState -eq 'fail') {
                    Write-Step ('Details: TCP 443 to {0} is open; both discord.com and media.discordapp.net fail.' -f $tcpTarget) 'DarkGray'
                }
                else {
                    Write-Step ('Details: TCP 443 to {0} is open; media.discordapp.net fails (control check unavailable).' -f $tcpTarget) 'DarkGray'
                }
            }
        }

        Write-Step ''
        Write-Step 'hosts was left unchanged - no dead address was pinned.' 'Yellow'
        if ($lastStarted -and -not $bypassUp) {
            Write-Step ("Last started config: {0}. If other sites got slower, start your usual one." -f (Split-Path -Leaf $lastStarted)) 'Gray'
        }
        exit 2
    }

    if ($alive.Count -eq 0) {
        $alive = @('162.159.141.232', '162.159.131.233', '162.159.132.233', '162.159.133.233')
        Write-Step ("curl.exe not found - using a known-good list: {0}" -f ($alive -join ', ')) 'Yellow'
    }

    Write-Step ''
    Write-Step ("Using these addresses: {0}" -f ($alive -join ', ')) 'Green'

    # ----- write hosts -----
    $current = Get-HostsText -Path $HostsFile
    $clean = (Get-TextWithoutPin $current.Text).TrimEnd("`r", "`n")

    $block = @($pinStart)
    foreach ($name in $Hosts) {
        foreach ($ip in $alive) { $block += "$ip $name" }
    }
    $block += $pinEnd

    $newText = $clean + "`r`n`r`n" + ($block -join "`r`n") + "`r`n"

    if ($DryRun) {
        Write-Step ''
        Write-Step '--- resulting hosts (dry run, nothing written) ---' 'DarkGray'
        Write-Step $newText
    }
    elseif ($newText -eq $current.Text) {
        Write-Step 'The address list is already correct - nothing to change.' 'Green'
    }
    else {
        try {
            $backup = Save-HostsText -Path $HostsFile -Text $newText -Kind $current.Kind
            & ipconfig /flushdns | Out-Null
            Write-Step "Address list updated. Backup: $backup" 'Green'
            Write-Step 'DNS cache cleared.' 'Green'
        }
        catch {
            Write-Step ''
            Write-Step "Could not write hosts: $($_.Exception.Message)" 'Red'
            Write-Step 'Usually Microsoft Defender "Controlled folder access" - allow the change for a minute.' 'Yellow'
            exit 1
        }
    }
}
else {
    $current = Get-HostsText -Path $HostsFile
    $pinState = 'no'
    if ($current.Text -match [regex]::Escape($pinStart)) { $pinState = 'yes' }

    Write-Step ''
    Write-Step 'All Discord media hosts answer - the pins are fine, hosts left as is.' 'Green'
    Write-Step ("  hosts pins:      {0}" -f $pinState) 'DarkGray'
    Write-Step ''
    if (Test-Winws) {
        Write-Step 'The bypass is up and the pins are fine - Discord is ready.' 'Cyan'
    }
    else {
        Write-Step 'The pins are fine. Start zapret if it is not running yet.' 'Cyan'
    }
    Write-Step 'This file is not a Discord launcher: open Discord from its usual shortcut.' 'Cyan'
    Write-Step 'If it still shows broken images, close it completely (tray icon too),' 'Yellow'
    Write-Step 'open it again, or run this file with -Force.' 'Yellow'
}

# ---------- restart Discord (only after the hosts really changed) ----------
if ($needFix -and -not ($NoRestart -or $DryRun)) {
    $clientNames = @('Discord', 'DiscordPTB', 'DiscordCanary', 'DiscordDevelopment')
    $running = @()
    foreach ($name in $clientNames) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { $running += $name }
    }

    if ($running.Count -eq 0) {
        Write-Step ''
        Write-Step 'Discord is not running - just open it when you need it.' 'Gray'
    }
    else {
        Write-Step ''
        Write-Step ("Restarting so the new addresses are picked up: {0}" -f ($running -join ', ')) 'Gray'
        foreach ($name in $running) {
            Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 1200

        $started = Start-Discord -Names $running
        if ($started -gt 0) {
            Write-Step 'Discord started.' 'Green'
        }
        else {
            Write-Step 'Could not find the Discord updater - open the client manually.' 'Yellow'
        }
    }
}

if ($DryRun) { return }

if (Test-Winws) {
    Write-Step ''
    Write-Step 'IMPORTANT: do not close the minimized zapret window.' 'Red'
    Write-Step 'It keeps the bypass running - closing it breaks Discord media again.' 'Red'
}
Write-Step ''
if ($bypassConfig) {
    Write-Step ("Bypass config in use: {0} (remembered for the next run)." -f (Split-Path -Leaf $bypassConfig)) 'Green'
}

Write-Step 'The pinned addresses stay in the hosts file, so they keep working after a reboot.' 'Green'
Write-Step 'Everyday use: start zapret the way you always did (general.bat or your shortcut),' 'Cyan'
Write-Step 'then open Discord from its normal shortcut. You do not need this file every day.' 'Cyan'
Write-Step 'Run this file again only when Discord images break: it re-probes and re-pins.' 'Gray'
Write-Step 'Want the bypass checked on every start? Start zapret with this file instead:' 'Cyan'
Write-Step 'it picks a working config by itself and re-pins if the addresses rotate.' 'Cyan'
Write-Step 'That start is a little slower (10-60 s) - the check runs every time.' 'DarkGray'
Write-Step 'A VPN must be off for Discord: this fix needs a direct connection with zapret.' 'Yellow'
Write-Step 'Undo any time: remove-pins.bat' 'DarkGray'
