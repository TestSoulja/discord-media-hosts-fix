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
       gets through - every config found in the zapret folder, in a sensible
       order. When TCP 443 does not connect to the CDN at all, another config
       cannot help and the switching is skipped;
    2. pins the addresses that actually answer for the Discord media CDN into
       the Windows hosts file, inside a marked block, and restarts Discord when
       it has something new to pick up: rewritten addresses or a new bypass.

  Running the .bat is the whole interaction: elevation, config choice, the
  bypass restart and the Discord restart are automatic. If nothing works, the
  script says WHY and leaves hosts unchanged instead of pinning dead addresses.
  It also says what exactly is blocked: only port 443 (a local redirect could
  still help), the addresses themselves (only a tunnel helps), or the TLS
  handshake (blocked by name - no port and no address help). When a local
  antivirus or proxy re-signs HTTPS, it names that too.

  It is a one-shot fix: no service, no scheduled task, no autostart, nothing
  left running after it returns. Run it again only when you choose to.

  It works with any zapret bundle layout (winws.exe in bin\ or in the root).
  It only uses the folder it lives in - copy the three files into the zapret
  bundle, or pass -ZapretDir - and never edits the zapret config itself.

  Usage (double-click the .bat, it asks for administrator rights itself):
      fix-discord-media.bat                 apply the fix
      fix-discord-media.bat -Remove         undo
      fix-discord-media.bat -ShowConfigs    list your zapret configs
      fix-discord-media.bat -DryRun         show what would change

  When zapret is not running yet, the script starts the best config it found
  (the last one that worked, else general.bat) and switches to the next config
  only if media still does not answer. Nothing is asked. The config that
  actually worked is remembered in %LOCALAPPDATA%\discord-media-hosts-fix\last-config.txt.

  A running Discord keeps the addresses it resolved and its open connections
  until the process restarts - closing it to the tray is not a restart. That is
  why the client is restarted after a hosts rewrite or after the bypass was
  started or replaced while Discord was already open, and why an untouched
  client is reported instead of leaving the user guessing.

  Options:
      -Remove          delete the pin block and exit
      -NoRestart       do not restart the Discord client
      -RestartDiscord  restart the Discord client even when nothing changed,
                       and after -Remove
                       (a closed client is not launched, only a running one)
      -DryRun          print the result, change nothing
      -Force           re-probe and re-pin even if everything already works
      -NoZapret        do not touch zapret, only pin hosts
      -IgnoreVpn       continue even when a VPN carries the default route -
                       the same as answering 2 to the VPN question. The run then
                       says everything was measured through the tunnel.
      -ZapretDir PATH  zapret folder (default: the folder of this script)
      -Config NAME     use only this config, no automatic switching,
                       e.g. "general (ALT11).bat"
      -MaxConfigs N    stop the automatic sweep after N configs
                       (default: try every config in the folder)
      -RestartZapret   restart the bypass even when it already answers
                       (by default a working bypass is left alone)
      -Prompt          show the config menu instead of choosing automatically
      -NoPrompt        never ask anything: no config menu, no VPN question
      -ShowConfigs     list the configs found in the zapret folder and exit
      -HostsFile PATH  alternate hosts file (for testing)
      -Hosts NAME...   hostnames to pin (default: the three Discord media hosts)
      -ExtraIPs IP...  extra candidate addresses to probe first
      -Version         print the script version and exit

  Versioning: Semantic Versioning (MAJOR.MINOR.PATCH). The version is defined
  once below in $AppVersion, the tag is v<version>, and every change is written
  down in CHANGELOG.md. When releasing: bump $AppVersion, add a CHANGELOG entry,
  commit, tag v<version> and push the tag - build-release.ps1 runs in CI, builds
  discord-media-hosts-fix.zip and attaches it with SHA256SUMS to the release.

  License: MIT, Copyright (c) 2026 TestSoulja. See LICENSE in the repository.
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$NoRestart,
    [switch]$RestartDiscord,
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
    [int]$MaxConfigs = 0,
    [string]$HostsFile = (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'),
    [string[]]$Hosts = @(
        'media.discordapp.net',
        'images-ext-1.discordapp.net',
        'images-ext-2.discordapp.net'
    ),
    [string[]]$ExtraIPs = @()
)

# Single source of truth for the version. Keep in sync with CHANGELOG.md.
$AppVersion = '1.10.1'

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

# A real double-click goes through the .bat, which sets this variable: only then
# does the VPN choice appear. Tests, scripts and -NoPrompt never see a question
# they could not answer.
$menuEnabled     = ($env:DISCORD_MEDIA_FIX_MENU -eq '1') -and -not $NoPrompt
$continueWithVpn = $false

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

# Ports Cloudflare serves the same hostname on. Discord always uses 443; the
# others exist only to tell "the port is cut" from "the address is dropped".
$altPorts = @(2053, 2083, 2087, 2096)

# Vendors that re-sign HTTPS with their own root certificate to inspect it. A
# public CA is never named after security software, so a match is proof.
$tlsInterceptors = '(?i)kaspersky|eset|avast|avg|bitdefender|dr\.?web|avira|comodo|sophos|trend ?micro|zscaler|fortinet|palo ?alto|cisco|netskope|blue ?coat|mcafee|g ?data|emsisoft|adguard|qihoo'

# How long a started config gets to show winws.exe before the start counts as
# failed. Tests shorten it; 30 s is what a real machine needs with antivirus.
$winwsStartWaitSec = 30

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

    $deadline = (Get-Date).AddSeconds($winwsStartWaitSec)
    while ((Get-Date) -lt $deadline -and -not (Test-Winws)) {
        Start-Sleep -Milliseconds 400
    }
    if (-not (Test-Winws)) {
        Write-Step ("winws.exe did not appear within {0} s." -f $winwsStartWaitSec) 'Yellow'
        # A missing file and a file that never starts look the same in the process
        # list but need different advice: one is an antivirus, the other a block
        # or a broken bundle.
        $folder = Split-Path -Parent $Path
        $exe = @((Join-Path $folder 'bin\winws.exe'), (Join-Path $folder 'winws.exe')) |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $exe) {
            Write-Step 'The file itself is gone - something deleted it, usually an antivirus.' 'Yellow'
            Write-Step 'Restore the zapret bundle, or allow its folder in the antivirus.' 'Yellow'
        }
        else {
            Write-Step 'The file is there, but no process started - a security product may block it.' 'Yellow'
            Write-Step 'Check the antivirus log, or allow the zapret folder, then run this again.' 'Yellow'
        }
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

# The zapret folder is never guessed: it is the folder this script lives in,
# or exactly what -ZapretDir points at. On a machine with several zapret copies
# a wider search could pick the wrong one, which is why nothing else is scanned.
function Find-ZapretDir {
    param([string]$Path)

    if (-not $Path) { $Path = $scriptDir }
    if ($Path -and (Test-ZapretFolder -Dir $Path)) { return (Resolve-Path -LiteralPath $Path).Path }
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
    return (Join-Path (Join-Path $base 'discord-media-hosts-fix') 'last-config.txt')
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

# The one place that talks to curl. Every call site goes through it, so the test
# suite can stand in for the network without touching the invocation code.
function Invoke-CurlRaw {
    param([string[]]$CurlArgs)

    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return @(& $curlPath @CurlArgs 2>$null | ForEach-Object { [string]$_ })
    }
    finally {
        $ErrorActionPreference = $saved
    }
}

# curl 7.66+ can run a whole list of transfers in one process. Windows 10 1803-
# 1909 ship older builds, so the answer decides how the sweep probes, not
# whether it works.
function Test-CurlParallel {
    if (-not (Test-Path -LiteralPath $curlPath)) { return $false }
    $line = ''
    $lines = @(Invoke-CurlRaw -CurlArgs @('--version'))
    if ($lines.Count -gt 0) { $line = $lines[0] }
    if ($line -notmatch 'curl\s+(\d+)\.(\d+)') { return $false }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    return ($major -gt 7 -or ($major -eq 7 -and $minor -ge 66))
}

# Probes many addresses in one curl process and returns @{ ip = state } where
# state is ok / tls / odd / dead. Each request is tagged with ?probe=<ip>, so a
# transfer that never connected can still be attributed: curl's write-out prints
# the URL it belongs to. No exit code is read - with several transfers it belongs
# to the last one only, and the times carry the same information.
function Get-ProbeBatch {
    param(
        [string[]]$Addresses,
        [string]$HostName = 'media.discordapp.net',
        [int]$Port = 443,
        [int]$TimeoutSec = 6,
        [int]$MaxParallel = 8
    )

    $states = @{}
    if (-not $Addresses -or $Addresses.Count -eq 0) { return $states }
    if (-not (Test-CurlParallel)) { return $states }

    # The record separator is a literal \n, which curl expands itself. A real
    # newline must never be built into argv: '@(..., 'x' + "`n")' is the array
    # plus a string, so the newline becomes its own argument and -w loses it.
    $format = '%{http_code} %{time_connect} %{time_appconnect} %{url_effective}\n'
    $curlArgs = New-Object System.Collections.Generic.List[string]
    foreach ($part in @('-s', '--parallel', '--parallel-max', "$MaxParallel", '-m', "$TimeoutSec", '-w', $format)) {
        $curlArgs.Add($part)
    }
    foreach ($ip in $Addresses) {
        $curlArgs.Add('-o')
        $curlArgs.Add('NUL')
        $curlArgs.Add('--resolve')
        $curlArgs.Add("${HostName}:${Port}:$ip")
        $curlArgs.Add(("https://{0}:{1}/?probe={2}" -f $HostName, $Port, $ip))
    }

    foreach ($line in @(Invoke-CurlRaw -CurlArgs $curlArgs.ToArray())) {
        # http_code connect_time appconnect_time url
        # Exactly one tag per line or the line is dropped: a glued pair of records
        # would otherwise be credited to the last address in it - a wrong answer
        # is worse than a missing one.
        if (([regex]::Matches($line, '\?probe=')).Count -ne 1) { continue }
        if ($line -notmatch '^(\d{3}) (\d+\.?\d*) (\d+\.?\d*) \S*\?probe=([0-9.]+)$') { continue }
        $code = $Matches[1]
        $connect = [double]$Matches[2]
        $appconnect = [double]$Matches[3]
        $ip = $Matches[4]

        if ($connect -le 0) { $states[$ip] = 'dead' }
        elseif ($appconnect -le 0) { $states[$ip] = 'tls' }
        elseif ($code -match '^[1-5]\d\d$') { $states[$ip] = 'ok' }
        else { $states[$ip] = 'odd' }
    }
    return $states
}

# One HTTPS request that keeps the reason it failed. curl's exit code is the only
# thing that separates "nobody listens" (7) from "the connection is dropped" (28)
# from "TCP is fine, TLS is killed" (35/56) - and to the person reading the
# verdict those three are completely different problems.
function Get-HttpsProbe {
    param(
        [string]$ResolveTo = '',
        [string]$HostName = 'media.discordapp.net',
        [int]$Port = 443,
        [int]$TimeoutSec = 8
    )

    if (-not (Test-Path -LiteralPath $curlPath)) { return @{ State = 'nocurl'; Http = ''; Exit = -1 } }

    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $curlArgs = @('-s', '-o', 'NUL', '-m', "$TimeoutSec", '-w', '%{http_code}')
        if ($ResolveTo) { $curlArgs += @('--resolve', "${HostName}:${Port}:$ResolveTo") }
        $curlArgs += ("https://{0}:{1}/" -f $HostName, $Port)

        $lines = @(Invoke-CurlRaw -CurlArgs $curlArgs)
        $exit = $LASTEXITCODE
        $code = ''
        if ($lines.Count -gt 0) { $code = $lines[-1] }

        if ($exit -eq 0) {
            if ($code -match '^[1-5]\d\d$') { return @{ State = 'ok'; Http = $code; Exit = 0 } }
            return @{ State = 'odd'; Http = $code; Exit = 0 }
        }
        if ($exit -eq 5 -or $exit -eq 6) { return @{ State = 'dns'; Http = $code; Exit = $exit } }
        if ($exit -eq 7) { return @{ State = 'refused'; Http = $code; Exit = 7 } }
        if ($exit -eq 28) { return @{ State = 'timeout'; Http = $code; Exit = 28 } }
        if (@(35, 51, 53, 54, 56, 58, 59, 60, 64, 66, 77, 80, 82, 83, 90, 91) -contains $exit) {
            return @{ State = 'tls'; Http = $code; Exit = $exit }
        }
        return @{ State = 'error'; Http = $code; Exit = $exit }
    }
    catch {
        return @{ State = 'error'; Http = ''; Exit = -1 }
    }
    finally {
        $ErrorActionPreference = $saved
    }
}

# Boolean view of the same request: ok / dead / nocurl, for the callers that only
# care whether the address answers at all. The timeout is generous on purpose:
# a throttled line needs more than 5 s.
function Test-MediaEndpoint {
    param(
        [string]$ResolveTo = '',
        [string]$HostName = 'media.discordapp.net',
        [int]$TimeoutSec = 8
    )

    $probe = Get-HttpsProbe -ResolveTo $ResolveTo -HostName $HostName -TimeoutSec $TimeoutSec
    if ($probe.State -eq 'ok') { return 'ok' }
    if ($probe.State -eq 'nocurl') { return 'nocurl' }
    return 'dead'
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

# Addresses the resolver hands out right now. Usually they are the dead set that
# made the person run this at all, but "usually" is not "always": on a network
# where the pins rotated, the fresh answer holds a working address that the
# hardcoded range does not.
function Get-DnsAddresses {
    param([string[]]$Names = @('media.discordapp.net'), [int]$Max = 12)

    $found = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Names) {
        try {
            foreach ($answer in [System.Net.Dns]::GetHostAddresses($name)) {
                if ($answer.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $ip = $answer.IPAddressToString
                if (-not $found.Contains($ip) -and $found.Count -lt $Max) { $found.Add($ip) }
            }
        }
        catch {
            # No resolver answer is not an error: the range below still stands.
        }
    }
    return @($found)
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
        $lines = @(Invoke-CurlRaw -CurlArgs @('-s', '-o', 'NUL', '-m', "$TimeoutSec", '-w', '%{http_code}', "https://$HostName/"))
        $code = ''
        if ($lines.Count -gt 0) { $code = $lines[-1] }
        if ($LASTEXITCODE -eq 5 -or $LASTEXITCODE -eq 6) { return 'dns' }
        if ($LASTEXITCODE -ne 0) { return 'fail' }
        if ($code -match '^[1-5]\d\d$') { return 'ok' }
        return 'fail'
    }
    catch { return 'fail' }
    finally { $ErrorActionPreference = $saved }
}

# Which of the four blocks is it? Short, testable verdicts:
#   port    - 443 is cut, another Cloudflare port answers: a redirect could work
#   tls     - TCP 443 connects, the handshake dies: blocked by name
#   refused - this machine refuses: firewall or antivirus, not the provider
#   ip      - everything is dropped: only another path (tunnel/proxy) helps
function Get-PortVerdict {
    param(
        [string[]]$Addresses,
        [string]$HostName = 'media.discordapp.net',
        [int]$TimeoutSec = 5
    )

    $unknown = @{ Kind = 'unknown'; Port = 0; Ip = ''; Detail = '' }
    if (-not (Test-Path -LiteralPath $curlPath)) { return $unknown }

    $targets = @($Addresses | Where-Object { $_ } | Select-Object -First 2)
    if ($targets.Count -eq 0) { return $unknown }

    $sawTls     = $false
    $sawTimeout = $false
    $allRefused = $true
    $tcpOpen    = ''
    $first      = $targets[0]

    for ($i = 0; $i -lt $targets.Count; $i++) {
        $ip = $targets[$i]
        # The first address gets the whole port list; a second one only the most
        # likely port, so a dead network cannot stretch this check to a minute.
        $ports = $altPorts
        if ($i -gt 0) { $ports = @(2053) }

        foreach ($port in $ports) {
            $probe = Get-HttpsProbe -ResolveTo $ip -HostName $HostName -Port $port -TimeoutSec $TimeoutSec
            if ($probe.State -eq 'nocurl') { return $unknown }
            if ($probe.State -eq 'ok' -or $probe.State -eq 'odd') {
                return @{ Kind = 'port'; Port = $port; Ip = $ip; Detail = $probe.State }
            }
            if ($probe.State -eq 'tls') { $sawTls = $true }
            if ($probe.State -eq 'timeout') { $sawTimeout = $true }
            if ($probe.State -ne 'refused') { $allRefused = $false }
        }

        if (-not $tcpOpen -and -not $sawTimeout) {
            if (Test-TcpPort -Address $ip -Port 443 -TimeoutMs ($TimeoutSec * 1000)) { $tcpOpen = $ip }
        }
    }

    if ($sawTls -or $tcpOpen) { return @{ Kind = 'tls'; Port = 0; Ip = $tcpOpen; Detail = '' } }
    if ($allRefused) { return @{ Kind = 'refused'; Port = 0; Ip = $first; Detail = '' } }
    return @{ Kind = 'ip'; Port = 0; Ip = $first; Detail = '' }
}

# Issuer of the certificate a site actually presents, empty when nothing answers.
# The synchronous handshake is bounded by the socket timeouts: a filter that
# accepts TCP and then says nothing moves the handshake to the timeout, not a hang.
function Get-TlsIssuer {
    param([string]$HostName = 'discord.com', [int]$Port = 443, [int]$TimeoutMs = 6000)

    $client = New-Object Net.Sockets.TcpClient
    $ssl = $null
    try {
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs

        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutMs)) { return '' }
        if (-not $client.Connected) { return '' }

        $ssl = New-Object Net.Security.SslStream($client.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($HostName)

        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        return [string]$cert.Issuer
    }
    catch { return '' }
    finally {
        if ($ssl) { try { $ssl.Dispose() } catch { } }
        try { $client.Close() } catch { }
    }
}

# A security product that inspects HTTPS has to re-sign the certificate with its
# own root. Seeing such an issuer is proof that it sits in the middle, which
# explains TLS failures that no address change can cure.
function Get-TlsInterceptor {
    param([string[]]$HostNames = @('discord.com', 'example.com'))

    foreach ($name in $HostNames) {
        $issuer = Get-TlsIssuer -HostName $name
        if (-not $issuer) { continue }
        if ($issuer -match $tlsInterceptors) { return @{ Host = $name; Issuer = $issuer } }
    }
    return $null
}

# Is the pin block really in the file? A security product may accept the write and
# then put the old content back, so the write is verified instead of assumed.
function Test-PinBlock {
    param([string]$Text, [string[]]$Addresses, [string[]]$Names)

    if (-not $Text) { return $false }
    if (-not ($Text.Contains($pinStart) -and $Text.Contains($pinEnd))) { return $false }
    foreach ($name in $Names) {
        foreach ($ip in $Addresses) {
            if (-not $Text.Contains("$ip $name")) { return $false }
        }
    }
    return $true
}

# Probes candidate addresses and keeps the ones that answer. The whole list goes
# through one curl process when the build supports --parallel; otherwise the
# fallback probes one at a time, bounded by $Limit. Either way it stops as soon
# as $Wanted addresses answer - a minority profile must not be read as "dead".
function Get-AliveAddresses {
    param(
        [string[]]$Candidates,
        [string]$HostName = 'media.discordapp.net',
        [int]$Limit = 64,
        [int]$TimeoutSec = 6,
        [int]$Wanted = 4
    )

    $alive = New-Object System.Collections.Generic.List[string]
    $queue = @($Candidates | Where-Object { $_ } | Select-Object -Unique)
    if ($queue.Count -eq 0) { return @() }
    # Without curl there is nothing to probe: one reason is printed by the caller,
    # not one "skipped" line per candidate.
    if (-not (Test-Path -LiteralPath $curlPath)) { return @() }

    $batch = Get-ProbeBatch -Addresses $queue -HostName $HostName -TimeoutSec $TimeoutSec
    $silent = 0
    $oneByOne = 0

    # A batch that answered for most of the list is trusted; a few silent addresses
    # are an anomaly, not a reason to spend minutes on them one at a time. A batch
    # that answered for nothing at all is announced, because the slow path that
    # follows is the only way to a verdict then.
    $lost = @($queue | Where-Object { -not $batch.ContainsKey($_) }).Count
    $fallbackLimit = $Limit
    if ($lost -gt 0 -and $batch.Count -gt 0) {
        $fallbackLimit = 6
        Write-Step ("  the parallel probe reported {0} of {1} addresses - at most six of the rest are retried one by one" -f $batch.Count, $queue.Count) 'Yellow'
    }
    elseif ($lost -gt 0 -and $batch.Count -eq 0) {
        if (Test-CurlParallel) {
            Write-Step '  the parallel probe reported nothing - checking one address at a time (slow)' 'Yellow'
        }
        else {
            Write-Step '  this curl has no --parallel - checking one address at a time (slower)' 'DarkGray'
        }
    }

    foreach ($ip in $queue) {
        if ($alive.Count -ge $Wanted) { break }

        if ($batch.ContainsKey($ip)) {
            if ($batch[$ip] -eq 'ok') {
                $alive.Add($ip)
                Write-Step "  $ip  answers" 'Green'
            }
            else {
                $silent++
            }
            continue
        }

        if ($oneByOne -ge $fallbackLimit) { break }
        $oneByOne++

        $result = Test-MediaEndpoint -ResolveTo $ip -HostName $HostName -TimeoutSec $TimeoutSec
        if ($result -eq 'ok') {
            $alive.Add($ip)
            Write-Step "  $ip  answers" 'Green'
        }
        elseif ($result -eq 'dead') {
            $silent++
        }
        else {
            Write-Step "  $ip  skipped (no curl.exe)" 'DarkGray'
        }
    }

    # One line instead of one per dead address: a wide sweep would otherwise fill
    # the window with forty lines nobody reads.
    if ($silent -gt 0) {
        Write-Step ("  {0} addresses did not answer" -f $silent) 'DarkGray'
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

# Discord clients that are running right now. A client "closed" to the tray is
# still a process and still holds the addresses it resolved before, so it has to
# be restarted, not just clicked away. Order is stable for readable messages.
function Get-RunningDiscordClient {
    $names = @('Discord', 'DiscordPTB', 'DiscordCanary', 'DiscordDevelopment')
    return @($names | Where-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
}

# Restarts the clients that are running right now. Never launches a closed one:
# this project fixes hosts and the bypass, it is not a Discord launcher.
function Restart-DiscordClient {
    param([string]$Reason = 'requested')

    $running = @(Get-RunningDiscordClient)
    if ($running.Count -eq 0) {
        Write-Step ''
        Write-Step 'Discord is not running - just open it when you need it.' 'Gray'
        return
    }

    Write-Step ''
    switch ($Reason) {
        'hosts' {
            Write-Step ("Restarting so the new addresses are picked up: {0}" -f ($running -join ', ')) 'Gray'
        }
        'bypass' {
            Write-Step ("The bypass was started or replaced - restarting Discord so it reconnects through it: {0}" -f ($running -join ', ')) 'Gray'
        }
        default {
            Write-Step ("Restarting Discord as requested: {0}" -f ($running -join ', ')) 'Gray'
        }
    }

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

Write-Step ''
Write-Step ("=== Discord media hosts fix v{0} (zapret + hosts) ===" -f $AppVersion) 'Cyan'

if ($NoRestart -and $RestartDiscord) {
    Write-Step 'Use either -NoRestart or -RestartDiscord, not both.' 'Red'
    Write-Step 'Nothing was changed.' 'Yellow'
    exit 1
}

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
        if ($RestartDiscord) {
            Write-Step ''
            Write-Step 'Dry run: Discord would be restarted afterwards.' 'Yellow'
        }
        return
    }

    if ($newText -eq $current.Text) {
        Write-Step 'No pin block found - hosts not changed.' 'Green'
        return
    }

    try {
        $backup = Save-HostsText -Path $HostsFile -Text $newText -Kind $current.Kind
        & ipconfig /flushdns | Out-Null

        $after = Get-HostsText -Path $HostsFile
        if ($after.Text -match [regex]::Escape($pinStart)) {
            Write-Step ''
            Write-Step 'The pin block came back right after it was removed.' 'Red'
            Write-Step 'Something protects the hosts file (an antivirus or "Controlled folder access").' 'Red'
            Write-Step ("Backup before the change: {0}" -f $backup) 'Gray'
            exit 1
        }

        Write-Step "Done. Backup: $backup" 'Green'
        if ($RestartDiscord) {
            Restart-DiscordClient -Reason 'requested'
        }
        else {
            Write-Step 'Restart Discord for the change to take effect.' 'Gray'
        }
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
        Write-Step 'The pins only work on a direct connection. The real run offers a choice here:' 'Yellow'
        Write-Step 'stop and keep the VPN off, or continue with the VPN on (see -IgnoreVpn).' 'Yellow'
    }
    else {
        # Classic stays the default. The VPN mode is a deliberate, explicit
        # choice: it is only harmless when the tunnel does not carry the traffic
        # these hosts are reached through.
        $vpnChoice = 'classic'
        if ($IgnoreVpn) {
            $vpnChoice = 'vpn'
        }
        elseif ($menuEnabled) {
            Write-Step ("VPN is on and carries your traffic: {0}" -f $vpnNames) 'Yellow'
            Write-Step 'The pins only work on a direct connection: inside a tunnel these addresses' 'Yellow'
            Write-Step 'are unreachable, and zapret cannot help there either.' 'Yellow'
            Write-Step ''
            Write-Step '  1  Classic - stop here, turn the VPN off and run again   (default)' 'Gray'
            Write-Step '  2  With the VPN on - only if Discord bypasses this tunnel' 'Gray'
            Write-Step ''
            while ($true) {
                $answer = Read-Host '  Choice'
                if ($null -eq $answer) { $answer = '' } else { $answer = $answer.Trim() }
                if ($answer -eq '' -or $answer -eq '1') { $vpnChoice = 'classic'; break }
                if ($answer -eq '2') { $vpnChoice = 'vpn'; break }
                Write-Step '  Type 1 or 2, or press Enter for the classic run.' 'Yellow'
            }
            Write-Step ''
        }

        if ($vpnChoice -eq 'vpn') {
            $continueWithVpn = $true
            Write-Step ("Continuing with the VPN on ({0})." -f $vpnNames) 'Yellow'
            Write-Step 'Everything measured from here goes through that tunnel, not through your provider.' 'DarkGray'
        }
        else {
            Write-Step ("VPN is on: {0}. Nothing was changed." -f $vpnNames) 'Red'
            Write-Step 'This fix needs a direct connection. While the VPN is on, Discord images already' 'Yellow'
            Write-Step 'travel through the tunnel - and zapret cannot help inside it.' 'Yellow'
            Write-Step ''
            Write-Step 'Turn the VPN off and run this file again.' 'Cyan'
            Write-Step 'If Discord already works on this VPN, you do not need this fix at all.' 'Cyan'
            Write-Step 'If only Discord should go around the tunnel, set up split tunneling and run again.' 'Cyan'
            exit 3
        }
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
        if ($ZapretDir) {
            Write-Step ("No zapret folder at: {0}" -f $ZapretDir) 'Yellow'
            Write-Step 'It must contain bin\winws.exe, winws.exe or service.bat.' 'Yellow'
        }
        else {
            Write-Step ("No zapret folder next to this file: {0}" -f $scriptDir) 'Yellow'
            Write-Step 'Copy the three files into your zapret folder, or point the script at it:' 'Yellow'
            Write-Step '-ZapretDir "D:\zapret" (the folder with bin\winws.exe).' 'Yellow'
        }
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
$allConfigsTried = $false
$sweepReported = $false

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
                # Otherwise every config is fair game: the one that gets images
                # through is remembered, so the full sweep is paid only once.
                $limit = $order.Count
                if ($Config) { $limit = 1 }
                elseif ($MaxConfigs -gt 0) { $limit = [Math]::Min($order.Count, $MaxConfigs) }

                if ($limit -gt 1) {
                    Write-Step ("Configs to try: {0}. Each check takes up to a minute," -f $limit) 'DarkGray'
                    Write-Step 'so let it run - the one that works is remembered for next time.' 'DarkGray'
                }

                $stoppedOnBlackhole = $false
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
                        $stoppedOnBlackhole = $true
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

                if (-not $bypassUp -and -not $stoppedOnBlackhole -and $limit -gt 1) {
                    if ($limit -eq $order.Count) {
                        Write-Step ("All {0} configs were tried - none got the images through." -f $limit) 'Yellow'
                        $allConfigsTried = $true
                    }
                    else {
                        Write-Step ("First {0} configs were tried - none got the images through." -f $limit) 'Yellow'
                    }
                    $sweepReported = $true
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
            if (-not $sweepReported) {
                Write-Step 'No config got the images through.' 'Yellow'
            }
            Write-Step 'The address list is still checked below.' 'Yellow'
        }
    }
}

# A bypass that was started or replaced during this run, while a client may
# already be open: that client's connections and resolved names predate it, so it
# only routes through the new bypass after a restart. A failed sweep is not a
# reason to touch the client - there is nothing to reconnect to.
$bypassChanged = [bool]($lastStarted -and $bypassUp)

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

    $candidates = @($ExtraIPs) + @($preferred) + @(Get-DnsAddresses -Names @('media.discordapp.net'))
    $candidates += foreach ($last in 232, 233) {
        foreach ($n in 128..141) { "162.159.$n.$last" }
    }
    $candidates = @($candidates | Where-Object { $_ } | Select-Object -Unique)

    $alive = @(Get-AliveAddresses -Candidates $candidates -HostName 'media.discordapp.net' -TimeoutSec 6)

    if ($alive.Count -eq 0 -and (Test-Path -LiteralPath $curlPath)) {
        # A short timeout and a thin line look identical from here, so the first
        # dozen get a second chance with twice the wait before the range is
        # declared dead.
        Write-Step ''
        Write-Step 'Nothing yet - trying again with a longer wait (slow connections need it).' 'Gray'
        $retry = @($candidates | Select-Object -First 12)
        $alive = @(Get-AliveAddresses -Candidates $retry -HostName 'media.discordapp.net' -TimeoutSec 12 -Wanted 4)
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

        if ($continueWithVpn) {
            # Every probe went through a tunnel, so the verdicts below would be a
            # lie: the tunnel itself produces exactly these results.
            Write-Step 'The probes ran through the tunnel, so they cannot tell you what your provider blocks.' 'Yellow'
            Write-Step ''
            Write-Step 'What this means:' 'Cyan'
            Write-Step '  - if Discord media work on this VPN, you do not need this fix;' 'Cyan'
            Write-Step '  - if they do not, the tunnel is not helping either: try another server or another VPN;' 'Cyan'
            Write-Step '  - and either way, pinned addresses cannot work inside a tunnel.' 'Cyan'
            Write-Step ''
            Write-Step ('Details: no answer from inside the tunnel ({0}).' -f $vpnNames) 'DarkGray'
        }
        elseif ($reason -eq 'blackhole') {
            # Which of the four blocks is it? Only the port case leaves a way out
            # without a tunnel, so this is worth the half minute it can take.
            Write-Step ''
            Write-Step 'Checking what exactly is blocked - up to half a minute.' 'Gray'
            $ports = Get-PortVerdict -Addresses @($candidates | Select-Object -First 3)

            if ($ports.Kind -eq 'port') {
                Write-Step ("Port {0} answers for {1}, but port 443 does not." -f $ports.Port, $ports.Ip) 'Green'
                Write-Step 'So the block is on the port, not on the address or on the name.' 'Yellow'
                Write-Step ''
                Write-Step ("A local redirect 127.0.0.1:443 -> {0}:{1} can carry the images." -f $ports.Ip, $ports.Port) 'Cyan'
                Write-Step 'It needs a small redirect tool running in the background, and this one-shot' 'Cyan'
                Write-Step 'fix deliberately installs nothing like that. Meanwhile: a proxy or a tunnel.' 'Cyan'
            }
            elseif ($ports.Kind -eq 'tls') {
                Write-Step 'Port 443 accepts TCP, but the TLS handshake is killed.' 'Yellow'
                Write-Step 'That is a block by name: another port or another address cannot help.' 'Yellow'
                Write-Step ''
                Write-Step 'What actually works: another zapret config, or a tunnel/proxy for Discord.' 'Cyan'
            }
            elseif ($ports.Kind -eq 'refused') {
                Write-Step 'The machine refused the connection itself - this is not your provider.' 'Yellow'
                Write-Step 'A local firewall or an antivirus is blocking curl.exe or the port.' 'Yellow'
                Write-Step ''
                Write-Step 'What actually works: allow curl.exe and PowerShell in the firewall, check' 'Cyan'
                Write-Step 'the antivirus log, then run this file again.' 'Cyan'
            }
            else {
                Write-Step 'None of them accepted a connection at all. Something on the network drops' 'Yellow'
                Write-Step 'these addresses (or slows them to a standstill), so another address cannot help.' 'Yellow'
                Write-Step ''
                Write-Step 'What actually works: send only Discord through a VPN (split tunneling)' 'Cyan'
                Write-Step 'or set a proxy for Discord. A VPN for the whole PC is the blunt version.' 'Cyan'
            }

            # An antivirus that inspects HTTPS re-signs every certificate with its
            # own root, and that alone can break the handshake to the media hosts.
            $interceptor = Get-TlsInterceptor
            if ($interceptor) {
                Write-Step ''
                Write-Step ("HTTPS here is signed by {0}" -f $interceptor.Issuer) 'Red'
                Write-Step ("(not by a public CA - that is what inspecting {0} looks like)." -f $interceptor.Host) 'Yellow'
                Write-Step 'So a local security product may be the reason, not your provider.' 'Yellow'
                Write-Step 'Turn its HTTPS scanning off for a test and run this file again.' 'Cyan'
            }

            Write-Step ('Details: TCP 443 does not connect to {0}.' -f (($candidates | Select-Object -First 3) -join ', ')) 'DarkGray'
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
            if ($allConfigsTried) {
                Write-Step '  1. every config was already tried - update zapret to a newer build, then run this file again' 'Cyan'
            }
            else {
                Write-Step '  1. another zapret config: -ShowConfigs, then -Config "general (ALT...).bat"' 'Cyan'
            }
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
        # Only reachable when curl.exe is missing: with curl present the branch
        # above already explained the failure and stopped.
        Write-Step ''
        Write-Step 'curl.exe was not found, so no address could be checked.' 'Red'
        Write-Step 'It ships with Windows 10 1803+ and Windows 11; a security product may hide it.' 'Yellow'

        if (-not $Force) {
            Write-Step ''
            Write-Step 'hosts was left unchanged - nothing is pinned without a check.' 'Yellow'
            Write-Step 'Update Windows, or run this file again with -Force to pin a known-good list.' 'Cyan'
            exit 2
        }

        $alive = @('162.159.141.232', '162.159.131.233', '162.159.132.233', '162.159.133.233')
        Write-Step '-Force was passed - pinning a known-good list that could not be checked:' 'Yellow'
        Write-Step ("  {0}" -f ($alive -join ', ')) 'Gray'
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

            # The write is verified, not assumed: a security product can accept it
            # and then restore the old file a moment later.
            $written = Get-HostsText -Path $HostsFile
            if (-not (Test-PinBlock -Text $written.Text -Addresses $alive -Names $Hosts)) {
                Write-Step ''
                Write-Step 'The address list disappeared right after it was written.' 'Red'
                Write-Step 'Something protects the hosts file (an antivirus or "Controlled folder access"),' 'Red'
                Write-Step 'so the fix cannot stay. Allow the change and run this file again.' 'Yellow'
                Write-Step ("Backup of the file before the write: {0}" -f $backup) 'Gray'
                exit 1
            }

            # The check above proves the text landed. This proves the name, through
            # hosts, reaches a node that serves it. 403/421 means a node answered
            # but refused this host - pinning it is "fixed" with broken images.
            if ($isSystemFile -and -not $DryRun -and (Test-Path -LiteralPath $curlPath)) {
                $unserved = @()
                foreach ($name in $Hosts) {
                    $probe = Get-HttpsProbe -HostName $name -TimeoutSec 8
                    if ($probe.State -eq 'ok' -and @('403', '421') -notcontains $probe.Http) { continue }
                    $why = 'no answer'
                    if ($probe.State -eq 'ok') { $why = "refused this host (HTTP $($probe.Http))" }
                    $unserved += ("{0} ({1})" -f $name, $why)
                }

                if ($unserved.Count -gt 0) {
                    Write-Step ''
                    Write-Step 'The addresses are in hosts, but the names do not answer through them:' 'Red'
                    foreach ($item in $unserved) { Write-Step ("  {0}" -f $item) 'Red' }
                    Write-Step 'Pinning an address that does not serve the name would leave images' 'Yellow'
                    Write-Step 'broken, so this run is not a success. Run this file again - the' 'Yellow'
                    Write-Step 'addresses rotate - and if it repeats, the pins are not on the path:' 'Yellow'
                    Write-Step 'check that the VPN is off and the bypass is running.' 'Yellow'
                    Write-Step ("Backup of the file before the write: {0}" -f $backup) 'Gray'
                    Write-Step 'Undo: remove-pins.bat' 'Gray'
                    exit 1
                }
            }

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

    # The exact trap this branch can hide: everything is healthy, the client is
    # open, and it still shows broken images because it keeps its old addresses
    # and connections. Say that out loud instead of hoping for the README.
    $running = @(Get-RunningDiscordClient)
    $restartPlanned = $RestartDiscord -or $bypassChanged
    if ($running.Count -gt 0) {
        Write-Step ''
        if ($NoRestart) {
            Write-Step ("Discord is running ({0}) and keeps its old addresses until it is" -f ($running -join ', ')) 'Yellow'
            Write-Step 'restarted. -NoRestart was passed, so it was left alone; close it' 'Yellow'
            Write-Step 'completely (tray icon too) if images stay broken.' 'Yellow'
        }
        elseif ($restartPlanned -and $DryRun) {
            Write-Step ("Dry run: Discord is running ({0}) and would be restarted." -f ($running -join ', ')) 'Yellow'
        }
        elseif ($restartPlanned) {
            Write-Step ("Discord is running ({0}) - it will be restarted so it picks this up." -f ($running -join ', ')) 'Yellow'
        }
        else {
            Write-Step ("Discord is running ({0}) - it keeps its old addresses until it is" -f ($running -join ', ')) 'Yellow'
            Write-Step 'restarted. Close it completely (tray icon too) and open it again,' 'Yellow'
            Write-Step 'or run this file with -RestartDiscord.' 'Yellow'
        }
    }
    Write-Step 'To re-probe and re-pin anyway, run this file with -Force.' 'DarkGray'
}

# ---------- restart Discord (only when it has something new to pick up) ----------
# A running client keeps its resolved addresses and open connections: neither a
# rewritten hosts file nor a replaced bypass is picked up until the process
# restarts. Closing to the tray is not a restart. So restart only for a reason,
# and never launch a client that was not running.
$restartReason = ''
if ($RestartDiscord) { $restartReason = 'requested' }
elseif ($needFix) { $restartReason = 'hosts' }
elseif ($bypassChanged) { $restartReason = 'bypass' }

if ($restartReason -and -not ($NoRestart -or $DryRun)) {
    Restart-DiscordClient -Reason $restartReason
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
Write-Step 'Nothing stays running in the background: no service, no scheduled task, no autostart.' 'DarkGray'
