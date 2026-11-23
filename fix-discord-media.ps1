#Requires -Version 5.1
<#
  fix-discord-media.ps1

  Discord shows "Failed to load image": avatars, stickers, emoji and attachments
  do not load, while text and voice still work. On many networks the Discord
  media CDN is blocked by destination IP, and no DPI desync can help there -
  only a different destination address can.

  So this script does two things in one run:

    1. makes sure your zapret bypass is up (starts the config if winws.exe is
       not running yet), because the reachable addresses only answer while the
       desync is active on some networks;
    2. pins the addresses that actually answer for the Discord media CDN into
       the Windows hosts file, inside a marked block, then restarts Discord.

  It works with any zapret bundle layout (winws.exe in bin\ or in the root),
  finds the folder automatically, and never edits the zapret config itself.

  Usage (double-click the .bat, it asks for administrator rights itself):
      fix-discord-media.bat                 apply the fix
      fix-discord-media.bat -Remove         undo
      fix-discord-media.bat -ShowConfigs    list your zapret configs
      fix-discord-media.bat -DryRun         show what would change

  Options:
      -Remove          delete the pin block and exit
      -NoRestart       do not restart the Discord client
      -DryRun          print the result, change nothing
      -Force           pin even if Discord media already loads here
      -NoZapret        do not touch zapret, only pin hosts
      -ZapretDir PATH  zapret folder (auto-detected when omitted)
      -Config NAME     config to start, e.g. "general (ALT11).bat"
                       (relative to -ZapretDir, or a full path)
      -ShowConfigs     list the configs found in the zapret folder and exit
      -HostsFile PATH  alternate hosts file (for testing)
      -Hosts NAME...   hostnames to pin (default: the three Discord media hosts)
      -ExtraIPs IP...  extra candidate addresses to probe first
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$NoRestart,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$NoZapret,
    [switch]$ShowConfigs,
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

$ErrorActionPreference = 'Stop'

$pinStart = '# >>> discord-media-pin (auto) >>>'
$pinEnd   = '# <<< discord-media-pin (auto) <<<'

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
function Test-MediaEndpoint {
    param([string]$ResolveTo = '')

    if (-not (Test-Path -LiteralPath $curlPath)) { return 'nocurl' }

    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $curlArgs = @('-s', '-o', 'NUL', '-m', '5', '-w', '%{http_code}')
        if ($ResolveTo) { $curlArgs += @('--resolve', "media.discordapp.net:443:$ResolveTo") }
        $curlArgs += 'https://media.discordapp.net/'

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
Write-Step '=== Discord media fix (zapret + hosts) ===' 'Cyan'

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

$zapretHome   = ''
$zapretConfig = ''

if (-not $NoZapret) {
    $zapretHome = Find-ZapretDir -Path $ZapretDir
    if (-not $zapretHome) {
        Write-Step 'zapret folder not found.' 'Yellow'
        Write-Step 'Pass it explicitly: -ZapretDir "D:\zapret" (the folder with bin\winws.exe).' 'Yellow'
        Write-Step 'Continuing in hosts-only mode: probing and pinning anyway.' 'Yellow'
    }
    else {
        Write-Step "zapret folder: $zapretHome" 'DarkGray'
        $zapretConfig = Resolve-ZapretConfig -Dir $zapretHome -Name $Config

        if ($ShowConfigs) {
            Write-Step ''
            Write-Step 'Configs found:' 'Gray'
            $allConfigs = Get-ZapretConfigs -Dir $zapretHome
            if ($allConfigs.Count -eq 0) { Write-Step '  (none)' 'Yellow' }
            foreach ($c in $allConfigs) {
                $mark = ''
                if ($c.FullName -eq $zapretConfig) { $mark = '  <- default' }
                Write-Step ("  {0}{1}" -f $c.Name, $mark) 'Gray'
            }
            Write-Step ''
            Write-Step 'Start a specific one with: -Config "general (ALT11).bat"' 'Gray'
            return
        }

        if (-not $zapretConfig) {
            Write-Step 'No config (.bat) found in the zapret folder.' 'Yellow'
            Write-Step 'Continuing in hosts-only mode.' 'Yellow'
        }
    }
}

# ---------- already fixed? ----------
if ($isSystemFile -and -not $Force) {
    if ((Test-MediaEndpoint) -eq 'ok') {
        Write-Step ''
        Write-Step 'Discord media already loads on this machine - nothing to do.' 'Green'
        Write-Step 'Use -Force to start zapret and pin the addresses anyway.' 'DarkGray'
        exit 0
    }
}

# ---------- bring the bypass up ----------
if ($zapretConfig) {
    if (Test-Winws) {
        Write-Step 'zapret (winws) is already running - using it.' 'DarkGray'
    }
    elseif ($DryRun) {
        Write-Step ("Dry run: would start {0}" -f $zapretConfig) 'DarkGray'
    }
    else {
        Write-Step ("Starting the bypass: {0}" -f (Split-Path -Leaf $zapretConfig)) 'Gray'
        Start-Process -FilePath $zapretConfig -WorkingDirectory $zapretHome | Out-Null

        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline -and -not (Test-Winws)) {
            Start-Sleep -Milliseconds 500
        }
        if (Test-Winws) { Write-Step 'winws.exe is running.' 'Green' }
        else { Write-Step 'winws.exe did not appear within 45 s - check its window, pressing on anyway.' 'Yellow' }
    }
}

# ---------- find addresses that answer ----------
Write-Step ''
Write-Step 'Probing Cloudflare addresses for the Discord CDN...' 'Gray'

$candidates = @($ExtraIPs) + @($preferred)
$candidates += foreach ($last in 232, 233) {
    foreach ($n in 128..141) { "162.159.$n.$last" }
}
$candidates = @($candidates | Where-Object { $_ } | Select-Object -Unique)

$alive = @()
$tried = 0
$probeLimit = 20

foreach ($ip in $candidates) {
    if ($alive.Count -ge 4 -or $tried -ge $probeLimit) { break }
    $tried++

    $result = Test-MediaEndpoint -ResolveTo $ip
    if ($result -eq 'ok') {
        $alive += $ip
        Write-Step "  $ip  answers" 'Green'
    }
    elseif ($result -eq 'dead') {
        Write-Step "  $ip  no answer" 'DarkGray'
    }
    else {
        Write-Step "  $ip  skipped (no curl.exe)" 'DarkGray'
    }
}

if ($alive.Count -eq 0 -and (Test-Path -LiteralPath $curlPath)) {
    Write-Step ''
    Write-Step 'No address answered.' 'Red'
    Write-Step 'zapret is not up, or the whole Cloudflare range is blocked on this network.' 'Yellow'
    Write-Step 'Start your zapret config and run this file again, or use a VPN for Discord.' 'Yellow'
    Write-Step 'hosts was left unchanged.' 'Yellow'
    exit 2
}

if ($alive.Count -eq 0) {
    $alive = @('162.159.141.232', '162.159.131.233', '162.159.132.233', '162.159.133.233')
    Write-Step ("curl.exe not found - using the known-good list: {0}" -f ($alive -join ', ')) 'Yellow'
}

Write-Step ''
Write-Step ("Pinning {0}: {1}" -f $alive.Count, ($alive -join ', ')) 'Green'

# ---------- write hosts ----------
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
    Write-Step 'hosts already has these pins - nothing to change.' 'Green'
}
else {
    try {
        $backup = Save-HostsText -Path $HostsFile -Text $newText -Kind $current.Kind
        & ipconfig /flushdns | Out-Null
        Write-Step "hosts updated. Backup: $backup" 'Green'
        Write-Step 'DNS cache flushed.' 'Green'
    }
    catch {
        Write-Step ''
        Write-Step "Could not write hosts: $($_.Exception.Message)" 'Red'
        Write-Step 'Usually Microsoft Defender "Controlled folder access" - allow the change for a minute.' 'Yellow'
        exit 1
    }
}

# ---------- restart Discord ----------
if ($NoRestart -or $DryRun) { return }

$clientNames = @('Discord', 'DiscordPTB', 'DiscordCanary', 'DiscordDevelopment')
$running = @()
foreach ($name in $clientNames) {
    if (Get-Process -Name $name -ErrorAction SilentlyContinue) { $running += $name }
}

if ($running.Count -eq 0) {
    Write-Step ''
    Write-Step 'Discord is not running - just open it when you need it.' 'Gray'
    return
}

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

Write-Step ''
Write-Step 'Done. zapret keeps running in its minimized window - do not close it.' 'Cyan'
Write-Step 'If media breaks again later, just run this file again.' 'Cyan'
Write-Step 'Undo any time: fix-discord-media.bat -Remove' 'DarkGray'
