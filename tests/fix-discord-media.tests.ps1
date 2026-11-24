$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$srcPath = Join-Path $root 'fix-discord-media.ps1'
$src = [IO.File]::ReadAllText($srcPath)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) 'discord-media-hosts-fix-tests'
Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$script:pass = 0
$script:fail = 0
$script:failures = New-Object System.Collections.Generic.List[string]

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        $script:pass++
        Write-Host ("PASS  {0}" -f $Name) -ForegroundColor Green
    }
    else {
        $script:fail++
        $script:failures.Add($Name)
        Write-Host ("FAIL  {0}  {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

function New-Variant {
    param(
        [string]$Name,
        [switch]$SystemFile,
        [string]$Media = 'ok',
        [string]$Runner = "@('Discord')",
        [switch]$ForceBypass,
        [switch]$AliveStub,
        [switch]$AliveEmpty,
        [switch]$VpnStub
    )

    $code = $src
    if ($SystemFile) {
        $code = $code.Replace(
            '$isSystemFile = ([IO.Path]::GetFullPath($HostsFile) -eq [IO.Path]::GetFullPath($systemHosts))',
            '$isSystemFile = $true')
    }
    $code = $code.Replace(
        '$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
        '$true')
    # Stub the stop of a running client whatever the indentation is, then make
    # sure nothing that could kill a real process survived into the variant.
    $stopPattern = '(?m)^[ \t]*Get-Process -Name \$name -ErrorAction SilentlyContinue \| Stop-Process -Force -ErrorAction SilentlyContinue'
    $code = [regex]::Replace($code, $stopPattern, {
        param($m)
        $indent = $m.Value.Substring(0, $m.Value.Length - $m.Value.TrimStart().Length)
        $indent + 'Write-Host ("[test] stop {0}" -f $name) -ForegroundColor DarkGray'
    }.GetNewClosure())
    if ($code -match '\| Stop-Process') {
        throw ("Test harness failed to stub the client restart in '{0}' - refusing to run it." -f $Name)
    }
    $code = $code.Replace(
        '& ipconfig /flushdns | Out-Null',
        'Write-Host ''[test] dns flush skipped'' -ForegroundColor DarkGray')
    if ($ForceBypass) {
        $code = $code.Replace(
            '$bypassChanged = [bool]($lastStarted -and $bypassUp)',
            '$bypassChanged = $true')
    }

    $stubs = @"
function Test-MediaEndpoint { param([string]`$ResolveTo = '', [string]`$HostName = 'media.discordapp.net', [int]`$TimeoutSec = 8) return '$Media' }
function Get-RunningDiscordClient { return $Runner }
function Start-Discord { param([string[]]`$Names) Write-Host ("[test] start {0}" -f (`$Names -join ',')) -ForegroundColor DarkGray; return `$Names.Count }
function Test-ControlHost { param([string]`$HostName = 'discord.com', [int]`$TimeoutSec = 8) return 'ok' }
function Stop-Winws { Write-Host '[test] winws stop skipped' -ForegroundColor DarkGray }
function Get-VpnDefaultRoute { return `$null }
function Get-VpnAdapters { return @() }
"@
    if ($AliveStub) {
        $stubs += @"
function Get-AliveAddresses { param([string[]]`$Candidates, [string]`$HostName = 'media.discordapp.net', [int]`$Limit = 10, [int]`$TimeoutSec = 6, [int]`$Wanted = 4) return @('162.159.141.232','162.159.141.233','162.159.141.234','162.159.141.235') }
"@
    }
    if ($AliveEmpty) {
        $stubs += @"
function Get-AliveAddresses { param([string[]]`$Candidates, [string]`$HostName = 'media.discordapp.net', [int]`$Limit = 10, [int]`$TimeoutSec = 6, [int]`$Wanted = 4) return @() }
function Get-BlockDiagnosis { param([string[]]`$Addresses, [int]`$TimeoutMs = 6000) return 'blackhole' }
"@
    }
    if ($VpnStub) {
        $stubs += @"
function Get-VpnDefaultRoute { return [pscustomobject]@{ Name = 'TestVPN'; InterfaceIndex = 77 } }
function Get-VpnAdapters { return @() }
"@
    }

    # A stub defined next to the preconditions is too late for the undo branch:
    # that branch runs before it. Rename the real implementations so a stub is
    # the only definition the script can reach from any call site, and put the
    # stubs right after the parameters.
    $stubTargets = @(
        'Test-MediaEndpoint', 'Get-RunningDiscordClient', 'Start-Discord',
        'Test-ControlHost', 'Stop-Winws', 'Get-VpnDefaultRoute', 'Get-VpnAdapters',
        'Get-AliveAddresses', 'Get-BlockDiagnosis'
    )
    foreach ($fn in $stubTargets) {
        $code = $code.Replace(('function {0} {{' -f $fn), ('function {0}-Real {{' -f $fn))
    }
    $anchor = "`$pinEnd   = '# <<< discord-media-pin (auto) <<<'"
    if (-not $code.Contains($anchor)) {
        throw 'Test harness anchor not found - refusing to run.'
    }
    $code = $code.Replace($anchor, $anchor + "`r`n`r`n" + $stubs)
    if (([regex]::Matches($code, '(?m)^function Start-Discord \{')).Count -ne 1) {
        throw ("Test harness cannot isolate Start-Discord in '{0}' - refusing to run it." -f $Name)
    }

    $path = Join-Path $testRoot ("{0}.ps1" -f $Name)
    Set-Content -LiteralPath $path -Value $code -Encoding UTF8
    return $path
}

function Invoke-Script {
    param([string]$Path, [string[]]$Arguments)
    $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 |
        ForEach-Object { $_.ToString() })
    $exit = $LASTEXITCODE
    return @{ Exit = $exit; Lines = $lines }
}

function Has {
    param([hashtable]$Result, [string]$Needle)
    return [bool](@($Result.Lines | Where-Object { $_.Contains($Needle) }).Count -gt 0)
}

function New-HostsFile {
    param([string]$Path, [string]$Text, [switch]$Bom)
    $enc = [System.Text.UTF8Encoding]::new([bool]$Bom)
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

function File-Hash {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
}

function Count-Lines {
    param([string]$Path, [string]$Pattern)
    $text = [IO.File]::ReadAllText($Path)
    return @($text -split "`r?`n" | Where-Object { $_ -match $Pattern }).Count
}

$hosts = Join-Path $testRoot 'hosts.txt'
$plainHosts = "127.0.0.1 localhost`r`n::1 localhost`r`n"

# ---------- static ----------
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($srcPath, [ref]$tokens, [ref]$parseErrors)
Check 'static: parser errors = 0' ($null -eq $parseErrors -or $parseErrors.Count -eq 0) (($parseErrors | ForEach-Object { $_.Message }) -join '; ')

$readme = [IO.File]::ReadAllText((Join-Path $root 'README.md'), [Text.Encoding]::UTF8)
$paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$undocumented = @($paramNames | Where-Object { -not $readme.Contains('-' + $_) })
Check 'static: every parameter is in README' ($undocumented.Count -eq 0) ($undocumented -join ', ')

foreach ($flag in @('-RestartDiscord', '-NoRestart', '-DryRun', '-Force')) {
    Check ("static: synopsis mentions {0}" -f $flag) ([IO.File]::ReadAllText($srcPath).Contains($flag))
}

# The fix must stay a one-shot run: no service, task, autostart or watcher.
$shipped = @('fix-discord-media.bat', 'fix-discord-media.ps1', 'remove-pins.bat')
$persistence = @(
    'schtasks', 'Register-ScheduledTask', 'CurrentVersion\Run', 'Startup',
    'New-Service', 'Start-Job', 'Register-ObjectEvent', 'Start-ThreadJob',
    'WScript.Shell'
)
foreach ($word in $persistence) {
    $found = @($shipped | Where-Object {
        [IO.File]::ReadAllText((Join-Path $root $_)).Contains($word)
    })
    Check ("static: no '{0}' in the shipped files" -f $word) ($found.Count -eq 0) ($found -join ', ')
}

# ---------- version / conflict ----------
$appVersion = [regex]::Match($src, '(?m)^\$AppVersion = ''([0-9]+\.[0-9]+\.[0-9]+)''').Groups[1].Value
Check 'static: AppVersion is a semver' ($appVersion -match '^\d+\.\d+\.\d+$') $appVersion
Check 'static: README names the version' ($readme.Contains("**Version $appVersion**")) $appVersion
$changelog = [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md'), [Text.Encoding]::UTF8)
Check 'static: CHANGELOG has this version' ($changelog.Contains("## [$appVersion]")) $appVersion

$r = Invoke-Script $srcPath @('-Version')
Check 'version: exit 0 and prints the AppVersion' ($r.Exit -eq 0 -and (Has $r $appVersion)) ($r.Lines -join ' | ')

New-HostsFile $hosts $plainHosts
$before = File-Hash $hosts
$r = Invoke-Script $srcPath @('-NoRestart', '-RestartDiscord', '-HostsFile', $hosts)
Check 'flags: -NoRestart + -RestartDiscord rejected' ($r.Exit -eq 1 -and (Has $r 'not both')) ("exit=$($r.Exit)")
Check 'flags: rejected run changes nothing' ((File-Hash $hosts) -eq $before)

# ---------- pins fine branch ----------
$pinsOk = New-Variant -Name 'pins-ok' -SystemFile -Media 'ok' -Runner "@('Discord')"
New-HostsFile $hosts $plainHosts
$before = File-Hash $hosts
$r = Invoke-Script $pinsOk @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'pins ok: exit 0, warns about the open client' ($r.Exit -eq 0 -and (Has $r 'keeps its old addresses') -and (Has $r '-RestartDiscord')) ("exit=$($r.Exit)")
Check 'pins ok: does not restart anything' (-not (Has $r '[test] stop') -and -not (Has $r '[test] start'))
Check 'pins ok: hosts untouched' ((File-Hash $hosts) -eq $before)

$r = Invoke-Script $pinsOk @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-RestartDiscord')
Check 'pins ok + -RestartDiscord: restarts the client' ($r.Exit -eq 0 -and (Has $r 'will be restarted') -and (Has $r '[test] stop Discord') -and (Has $r '[test] start Discord')) ("exit=$($r.Exit)")
Check 'pins ok + -RestartDiscord: hosts untouched' ((File-Hash $hosts) -eq $before)

$bypass = New-Variant -Name 'pins-bypass' -SystemFile -Media 'ok' -ForceBypass
$r = Invoke-Script $bypass @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'pins ok + bypass changed: restarts with the bypass reason' ($r.Exit -eq 0 -and (Has $r 'reconnects through it') -and (Has $r '[test] stop Discord')) ("exit=$($r.Exit)")

$noClient = New-Variant -Name 'pins-noclient' -SystemFile -Media 'ok' -Runner '@()'
$r = Invoke-Script $noClient @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-RestartDiscord')
Check 'no client: never launches one' ($r.Exit -eq 0 -and (Has $r 'Discord is not running') -and -not (Has $r '[test] start')) ("exit=$($r.Exit)")

$r = Invoke-Script $pinsOk @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-NoRestart')
Check 'pins ok + -NoRestart: leaves the client alone' ($r.Exit -eq 0 -and (Has $r '-NoRestart was passed') -and -not (Has $r '[test] stop')) ("exit=$($r.Exit)")

$r = Invoke-Script $pinsOk @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-RestartDiscord', '-DryRun')
Check 'pins ok + dry run: says would restart, does not' ($r.Exit -eq 0 -and (Has $r 'would be restarted') -and -not (Has $r '[test] stop')) ("exit=$($r.Exit)")

# ---------- hosts write path ----------
$write = New-Variant -Name 'write' -Media 'dead' -AliveStub -Runner '@()'
New-HostsFile $hosts $plainHosts
$beforeBackups = @(Get-ChildItem -Path ("{0}.bak-*" -f $hosts) -ErrorAction SilentlyContinue).Count
$r = Invoke-Script $write @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'write: reports the update and no dead pins' ($r.Exit -eq 0 -and (Has $r 'Address list updated') -and (Has $r 'no dead address was pinned') -eq $false) ("exit=$($r.Exit)")
Check 'write: says nothing stays running afterwards' (Has $r 'Nothing stays running in the background')
Check 'write: one marked block' ((Count-Lines $hosts '\# >>> discord-media-pin') -eq 1 -and (Count-Lines $hosts '\# <<< discord-media-pin') -eq 1)
Check 'write: 12 address lines (4 IPs x 3 hosts)' ((Count-Lines $hosts '^\d{1,3}(\.\d{1,3}){3} (media|images-ext)') -eq 12)
foreach ($name in @('media.discordapp.net', 'images-ext-1.discordapp.net', 'images-ext-2.discordapp.net')) {
    Check ("write: {0} pinned 4 times" -f $name) ((Count-Lines $hosts ([regex]::Escape($name))) -eq 4)
}
Check 'write: keeps the existing hosts lines' ((Count-Lines $hosts '127\.0\.0\.1 localhost') -eq 1 -and (Count-Lines $hosts '::1 localhost') -eq 1)
Check 'write: backup created' ((@(Get-ChildItem -Path ("{0}.bak-*" -f $hosts))).Count -eq $beforeBackups + 1)

$afterWrite = File-Hash $hosts
$backupsNow = @(Get-ChildItem -Path ("{0}.bak-*" -f $hosts)).Count
$r = Invoke-Script $write @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'write: second run is idempotent' ($r.Exit -eq 0 -and (Has $r 'already correct') -and (File-Hash $hosts) -eq $afterWrite)
Check 'write: second run creates no backup' ((@(Get-ChildItem -Path ("{0}.bak-*" -f $hosts))).Count -eq $backupsNow)

New-HostsFile $hosts $plainHosts
$r = Invoke-Script $write @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Hosts', 'a.test,b.test')
Check 'write: custom -Hosts list is split' ((Count-Lines $hosts 'a\.test') -eq 4 -and (Count-Lines $hosts 'b\.test') -eq 4 -and (Count-Lines $hosts 'media\.discordapp\.net') -eq 0) ("exit=$($r.Exit)")

$cyr = [string]::Join('', @(0x0442, 0x0435, 0x0441, 0x0442 | ForEach-Object { [char]$_ }))
$bomText = "# keep $cyr`r`n127.0.0.1 localhost`r`n"
New-HostsFile $hosts $bomText -Bom
$r = Invoke-Script $write @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
$bytes = [IO.File]::ReadAllBytes($hosts)
$text = [IO.File]::ReadAllText($hosts, [Text.Encoding]::UTF8)
Check 'write: UTF8 BOM hosts keeps its BOM' ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Check 'write: UTF8 BOM hosts keeps non-ASCII text' ($text.Contains("# keep $cyr"))
Check 'write: UTF8 BOM hosts still gets the block' ((Count-Lines $hosts 'media\.discordapp\.net') -eq 4)

New-HostsFile $hosts $plainHosts
$item = Get-Item -LiteralPath $hosts
$item.IsReadOnly = $true
$r = Invoke-Script $write @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'write: read-only hosts is updated and stays read-only' ($r.Exit -eq 0 -and (Get-Item $hosts).IsReadOnly -and (Count-Lines $hosts 'media\.discordapp\.net') -eq 4) ("exit=$($r.Exit)")
(Get-Item $hosts).IsReadOnly = $false

$stale = "# >>> discord-media-pin (auto) >>>`r`n10.0.0.1 media.discordapp.net`r`n# <<< discord-media-pin (auto) <<<`r`n127.0.0.1 localhost`r`n"
New-HostsFile $hosts $stale
$r = Invoke-Script $write @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'write: replaces an old block instead of duplicating it' ((Count-Lines $hosts '\# >>> discord-media-pin') -eq 1 -and (Count-Lines $hosts '10\.0\.0\.1') -eq 0)
Check 'write: keeps the line after the old block' ((Count-Lines $hosts '127\.0\.0\.1 localhost') -eq 1)

New-HostsFile $hosts $plainHosts
$before = File-Hash $hosts
$r = Invoke-Script $write @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-DryRun')
Check 'write: dry run shows the block, changes nothing' ($r.Exit -eq 0 -and (Has $r 'resulting hosts (dry run') -and (File-Hash $hosts) -eq $before)

$noAlive = New-Variant -Name 'no-alive' -Media 'dead' -AliveEmpty -Runner '@()'
New-HostsFile $hosts $plainHosts
$before = File-Hash $hosts
$r = Invoke-Script $noAlive @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'no alive address: exit 2 and nothing pinned' ($r.Exit -eq 2 -and (Has $r 'hosts was left unchanged') -and (File-Hash $hosts) -eq $before) ("exit=$($r.Exit)")

# ---------- remove ----------
$remove = New-Variant -Name 'remove' -Media 'ok' -Runner '@()'
$withBlock = "# >>> discord-media-pin (auto) >>>`r`n162.159.141.232 media.discordapp.net`r`n# <<< discord-media-pin (auto) <<<`r`n127.0.0.1 localhost`r`n"
New-HostsFile $hosts $withBlock
$r = Invoke-Script $remove @('-Remove', '-HostsFile', $hosts)
Check 'remove: block gone, other lines kept' ($r.Exit -eq 0 -and (Count-Lines $hosts 'discord-media-pin') -eq 0 -and (Count-Lines $hosts '127\.0\.0\.1 localhost') -eq 1) ("exit=$($r.Exit)")
Check 'remove: backup created' ((@(Get-ChildItem -Path ("{0}.bak-*" -f $hosts))).Count -ge 1)

New-HostsFile $hosts $plainHosts
$before = File-Hash $hosts
$r = Invoke-Script $remove @('-Remove', '-DryRun', '-HostsFile', $hosts)
Check 'remove: dry run changes nothing' ($r.Exit -eq 0 -and (File-Hash $hosts) -eq $before)

New-HostsFile $hosts $plainHosts
$r = Invoke-Script $remove @('-Remove', '-HostsFile', $hosts)
Check 'remove: no block reports and exits 0' ($r.Exit -eq 0 -and (Has $r 'No pin block found')) ("exit=$($r.Exit)")

$removeClient = New-Variant -Name 'remove-client' -Media 'ok' -Runner "@('Discord')"
New-HostsFile $hosts $withBlock
$r = Invoke-Script $removeClient @('-Remove', '-HostsFile', $hosts)
Check 'remove: plain run only tells the user to restart' ($r.Exit -eq 0 -and (Has $r 'Restart Discord for the change to take effect') -and -not (Has $r '[test] stop')) ("exit=$($r.Exit)")

New-HostsFile $hosts $withBlock
$r = Invoke-Script $removeClient @('-Remove', '-RestartDiscord', '-HostsFile', $hosts)
Check 'remove + -RestartDiscord: restarts the client' ($r.Exit -eq 0 -and (Has $r 'Restarting Discord as requested') -and (Has $r '[test] stop Discord') -and (Has $r '[test] start Discord')) ("exit=$($r.Exit)")
Check 'remove + -RestartDiscord: block is still gone' ((Count-Lines $hosts 'discord-media-pin') -eq 0)

New-HostsFile $hosts $withBlock
$before = File-Hash $hosts
$r = Invoke-Script $removeClient @('-Remove', '-RestartDiscord', '-DryRun', '-HostsFile', $hosts)
Check 'remove + -RestartDiscord + dry run: says it would, changes nothing' ($r.Exit -eq 0 -and (Has $r 'would be restarted') -and -not (Has $r '[test] stop') -and (File-Hash $hosts) -eq $before) ("exit=$($r.Exit)")

# ---------- VPN ----------
$vpn = New-Variant -Name 'vpn' -SystemFile -Media 'ok' -VpnStub
New-HostsFile $hosts $plainHosts
$before = File-Hash $hosts
$r = Invoke-Script $vpn @('-NoZapret', '-HostsFile', $hosts)
Check 'vpn: exit 3, nothing changed' ($r.Exit -eq 3 -and (Has $r 'VPN is on') -and (File-Hash $hosts) -eq $before) ("exit=$($r.Exit)")

$r = Invoke-Script $vpn @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'vpn: -IgnoreVpn continues' ($r.Exit -eq 0 -and (Has $r 'continuing because -IgnoreVpn')) ("exit=$($r.Exit)")

# ---------- no zapret folder ----------
$noZapret = New-Variant -Name 'no-zapret' -SystemFile -Media 'ok' -Runner '@()'
$r = Invoke-Script $noZapret @('-HostsFile', $hosts, '-IgnoreVpn')
Check 'zapret missing: explains and continues' ($r.Exit -eq 0 -and (Has $r 'No zapret folder next to this file') -and (Has $r 'pins are fine')) ("exit=$($r.Exit)")

# ---------- result ----------
Write-Host ''
if ($script:fail -eq 0) {
    Write-Host ("RESULT: all {0} checks passed" -f $script:pass) -ForegroundColor Green
}
else {
    Write-Host ("RESULT: {0} passed, {1} FAILED" -f $script:pass, $script:fail) -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host ("  - {0}" -f $_) -ForegroundColor Red }
    exit 1
}
