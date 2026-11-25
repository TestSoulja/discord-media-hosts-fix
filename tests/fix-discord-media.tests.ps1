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

# A scripted network: every address in __ALIVE__ answers, everything else times
# out, and a request that does not name an address (the post-write check through
# hosts) answers __THROUGH__. Both call shapes are supported - the single-URL one
# and the --parallel batch - so the real probing code runs unmodified.
$fakeCurl = @'
function Invoke-CurlRaw {
    param([string[]]$CurlArgs)
    $all = ($CurlArgs -join ' ')
    $alive = @(__ALIVE__)
    $drop = @(__DROP__)
    $global:LASTEXITCODE = 0
    if ('__ARGVLOG__' -ne '') {
        foreach ($a in $CurlArgs) { Add-Content -LiteralPath '__ARGVLOG__' -Value (ConvertTo-Json -Compress $a) -Encoding UTF8 }
    }
    if ($all -match '--version') { return @('curl 8.22.0 (Windows) libcurl/8.22.0') }

    $ips = @([regex]::Matches($all, 'probe=([0-9.]+)') | ForEach-Object { $_.Groups[1].Value })
    if ($ips.Count -eq 0) {
        $m = [regex]::Match($all, ':443:([0-9.]+)')
        if ($m.Success) { $ips = @($m.Groups[1].Value) }
    }

    if ($all -match '--parallel') {
        $lines = @()
        $ok = 0
        foreach ($ip in $ips) {
            if ($drop -contains $ip) { continue }
            if ($alive -contains $ip) {
                $ok++
                $lines += "200 0.010 0.040 https://media.discordapp.net/?probe=$ip"
            }
            else {
                $lines += "000 0.000000 0.000000 https://media.discordapp.net/?probe=$ip"
            }
        }
        if ($ok -eq 0) { $global:LASTEXITCODE = 28 }
        if ('__GLUE__' -eq 'yes') { return @(($lines -join '')) }
        return $lines
    }

    if ($ips.Count -eq 0) {
        if ('__THROUGH__' -eq '000') { $global:LASTEXITCODE = 28 }
        return @('__THROUGH__')
    }

    if ($alive -contains $ips[0]) { $global:LASTEXITCODE = 0; return @('200') }
    $global:LASTEXITCODE = 28
    return @('000')
}
'@

function New-Variant {
    param(
        [string]$Name,
        [switch]$SystemFile,
        [string]$Media = 'ok',
        [string]$Runner = "@('Discord')",
        [switch]$ForceBypass,
        [switch]$AliveStub,
        [switch]$AliveEmpty,
        [switch]$VpnStub,
        [switch]$NoCurl,
        [switch]$RevertHosts,
        [switch]$FastWinwsWait,
        [switch]$NoWinws,
        [string]$ExtraStubs = '',
        [switch]$FakeProbes,
        [switch]$NoParallel,
        [switch]$RealProbes,
        [string[]]$AliveIps = @(),
        [string]$ThroughCode = '200',
        [string[]]$DnsIps = @(),
        [string]$ArgvLog = '',
        [string[]]$DropIps = @(),
        [switch]$GlueLines
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
    if ($NoCurl) {
        $code = $code.Replace(
            '$curlPath     = Join-Path $env:SystemRoot ''System32\curl.exe''',
            '$curlPath     = Join-Path $env:TEMP ''no-such-curl.exe''')
        if ($code.Contains("'System32\curl.exe'")) {
            throw ("Test harness failed to hide curl.exe in '{0}' - refusing to run it." -f $Name)
        }
    }
    if ($FastWinwsWait) {
        $code = $code.Replace('$winwsStartWaitSec = 30', '$winwsStartWaitSec = 1')
    }

    $stubs = @"
function Test-MediaEndpoint { param([string]`$ResolveTo = '', [string]`$HostName = 'media.discordapp.net', [int]`$TimeoutSec = 8) return '$Media' }
function Get-RunningDiscordClient { return $Runner }
function Start-Discord { param([string[]]`$Names) Write-Host ("[test] start {0}" -f (`$Names -join ',')) -ForegroundColor DarkGray; return `$Names.Count }
function Test-ControlHost { param([string]`$HostName = 'discord.com', [int]`$TimeoutSec = 8) return 'ok' }
function Stop-Winws { Write-Host '[test] winws stop skipped' -ForegroundColor DarkGray }
function Get-VpnDefaultRoute { return `$null }
function Get-VpnAdapters { return @() }
function Get-PortVerdict { param([string[]]`$Addresses, [string]`$HostName = 'media.discordapp.net', [int]`$TimeoutSec = 5) return @{ Kind = 'ip'; Port = 0; Ip = ''; Detail = '' } }
function Get-BlockDiagnosis { param([string[]]`$Addresses, [int]`$TimeoutMs = 6000) return 'blackhole' }
function Get-TlsIssuer { param([string]`$HostName = 'discord.com', [int]`$Port = 443, [int]`$TimeoutMs = 6000) return '' }
function Get-TlsInterceptor { param([string[]]`$HostNames = @('discord.com','example.com')) return `$null }
function Invoke-CurlRaw { param([string[]]`$CurlArgs) `$global:LASTEXITCODE = 0; return @('200') }
function Test-CurlParallel { return `$true }
function Get-DnsAddresses { param([string[]]`$Names = @('media.discordapp.net'), [int]`$Max = 12) return @() }
"@
    if ($AliveStub) {
        $stubs += @"
function Get-AliveAddresses { param([string[]]`$Candidates, [string]`$HostName = 'media.discordapp.net', [int]`$Limit = 10, [int]`$TimeoutSec = 6, [int]`$Wanted = 4) return @('162.159.141.232','162.159.141.233','162.159.141.234','162.159.141.235') }
"@
    }
    if ($AliveEmpty) {
        $stubs += @"
function Get-AliveAddresses { param([string[]]`$Candidates, [string]`$HostName = 'media.discordapp.net', [int]`$Limit = 10, [int]`$TimeoutSec = 6, [int]`$Wanted = 4) return @() }
"@
    }
    if ($VpnStub) {
        $stubs += @"
function Get-VpnDefaultRoute { return [pscustomobject]@{ Name = 'TestVPN'; InterfaceIndex = 77 } }
function Get-VpnAdapters { return @() }
"@
    }
    if ($RevertHosts) {
        # A hosts file that loses the block again right after the write: the shape
        # of "a security product restored the old file".
        $stubs += "`r`n" + @'
$script:hostsReads = 0
function Get-HostsText { param([string]$Path)
    $script:hostsReads++
    $lines = @()
    if (Test-Path -LiteralPath $Path) { $lines = [IO.File]::ReadAllLines($Path) }
    if ($script:hostsReads -gt 1) {
        $lines = @($lines | Where-Object {
            $_ -notmatch 'discord-media-pin' -and
            $_ -notmatch '^(162\.159\.|media\.discordapp|images-ext)'
        })
    }
    return @{ Text = (($lines -join [Environment]::NewLine) + [Environment]::NewLine); Kind = 'Default' }
}
'@
    }
    if ($ExtraStubs) { $stubs += "`r`n" + $ExtraStubs }
    if ($FakeProbes) {
        $aliveList = (@($AliveIps | ForEach-Object { "'$_'" }) -join ',')
        $dropList = (@($DropIps | ForEach-Object { "'$_'" }) -join ',')
        $glue = if ($GlueLines) { 'yes' } else { 'no' }
        $stubs += "`r`n" + $fakeCurl.Replace('__ALIVE__', $aliveList).Replace('__THROUGH__', $ThroughCode).Replace('__ARGVLOG__', $ArgvLog).Replace('__DROP__', $dropList).Replace('__GLUE__', $glue)
    }
    if ($NoParallel) {
        $stubs += "`r`n" + 'function Test-CurlParallel { return $false }'
    }
    if ($DnsIps.Count -gt 0) {
        $dnsList = (@($DnsIps | ForEach-Object { "'$_'" }) -join ',')
        $stubs += "`r`n" + ('function Get-DnsAddresses {{ param([string[]]$Names = @(), [int]$Max = 12) return @({0}) }}' -f $dnsList)
    }
    if ($NoWinws) {
        # A zapret folder that passes the folder check but whose binary never
        # starts: what an antivirus leaving the folder intact looks like.
        $stubs += @"
function Test-Winws { return `$false }
function Start-Process { param([string]`$FilePath, [string]`$WorkingDirectory, `$ArgumentList, [switch]`$Verb) }
"@
    }

    # A stub defined next to the preconditions is too late for the undo branch:
    # that branch runs before it. Rename the real implementations so a stub is
    # the only definition the script can reach from any call site, and put the
    # stubs right after the parameters.
    $stubTargets = @(
        'Test-MediaEndpoint', 'Get-RunningDiscordClient', 'Start-Discord',
        'Test-ControlHost', 'Stop-Winws', 'Get-VpnDefaultRoute', 'Get-VpnAdapters',
        'Get-AliveAddresses', 'Get-BlockDiagnosis',
        'Get-PortVerdict', 'Get-TlsIssuer', 'Get-TlsInterceptor',
        'Invoke-CurlRaw', 'Test-CurlParallel', 'Get-DnsAddresses'
    )
    if ($RevertHosts) { $stubTargets += 'Get-HostsText' }
    if ($NoWinws) { $stubTargets += 'Test-Winws' }
    if ($RealProbes) { $stubTargets = @($stubTargets | Where-Object { $_ -ne 'Test-MediaEndpoint' }) }
    if ($FakeProbes) { $stubTargets = @($stubTargets | Where-Object { $_ -ne 'Get-AliveAddresses' }) }
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
    param([string]$Path, [string[]]$Arguments, [switch]$Feed, [string]$InputText = '')
    if ($Feed) {
        # Answering a prompt: the child must get the text on stdin.
        $lines = @($InputText | & powershell -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 |
            ForEach-Object { $_.ToString() })
    }
    else {
        $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 |
            ForEach-Object { $_.ToString() })
    }
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

# The fix names the security software when it interferes; it never weakens it.
foreach ($word in @('Add-MpPreference', 'Set-MpPreference', 'ExclusionPath')) {
    Check ("static: never changes antivirus settings ('{0}')" -f $word) (-not $src.Contains($word))
}

# The failure message must never offer its own bypass again: that is exactly how
# people ended up forcing a run that could not work.
Check 'static: the VPN stop is a choice, not a hidden flag hint' (-not $src.Contains('add -IgnoreVpn'))
Check 'static: the VPN menu exists' ($src.Contains('Classic - stop here') -and $src.Contains('With the VPN on'))

# One seam for the network: every curl call goes through Invoke-CurlRaw, so the
# suite can script the network without touching the probing code.
Check 'static: curl is invoked in exactly one place' `
    (([regex]::Matches($src, '& \$curlPath')).Count -eq 1)
Check 'static: the parallel batch needs curl 7.66' ($src.Contains('$minor -ge 66'))

# The VPN question appears only when the entry point sets this variable. The
# menu text is asserted above; this asserts the .bat still turns the menu on,
# and does it before the run - a variable set after the call would do nothing.
$bat = [IO.File]::ReadAllText((Join-Path $root 'fix-discord-media.bat'))
$menuAt = $bat.IndexOf('set "DISCORD_MEDIA_FIX_MENU=1"')
$runAt = $bat.IndexOf('-File "%~dp0fix-discord-media.ps1" %*')
Check 'static: the .bat enables the VPN menu before the run' `
    ($menuAt -ge 0 -and $runAt -ge 0 -and $menuAt -lt $runAt) `
    ("menuAt=$menuAt runAt=$runAt")

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
$r = Invoke-Script $vpn -Arguments @('-NoZapret', '-HostsFile', $hosts)
Check 'vpn: exit 3, nothing changed' ($r.Exit -eq 3 -and (Has $r 'VPN is on') -and (File-Hash $hosts) -eq $before) ("exit=$($r.Exit)")
Check 'vpn: the stop does not advertise the bypass flag' (-not (Has $r '-IgnoreVpn'))

$r = Invoke-Script $vpn -Arguments @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'vpn: -IgnoreVpn continues and says what it measured' ($r.Exit -eq 0 -and (Has $r 'Continuing with the VPN on') -and (Has $r 'goes through that tunnel')) ("exit=$($r.Exit)")

# The choice is only offered by the real entry point (.bat sets the variable),
# and only when a tunnel actually carries the default route.
$env:DISCORD_MEDIA_FIX_MENU = '1'
try {
    New-HostsFile $hosts $plainHosts
    $before = File-Hash $hosts
    $r = Invoke-Script $vpn -Arguments @('-NoZapret', '-HostsFile', $hosts) -Feed -InputText ''
    Check 'vpn menu: Enter picks the classic run' ($r.Exit -eq 3 -and (Has $r 'Classic - stop here') -and (Has $r 'With the VPN on') -and (File-Hash $hosts) -eq $before) ("exit=$($r.Exit)")

    $vpnWrite = New-Variant -Name 'vpn-write' -Media 'dead' -AliveStub -Runner '@()' -VpnStub
    $r = Invoke-Script $vpnWrite -Arguments @('-NoZapret', '-HostsFile', $hosts) -Feed -InputText '2'
    Check 'vpn menu: 2 continues with the VPN on' ($r.Exit -eq 0 -and (Has $r 'Continuing with the VPN on') -and (Count-Lines $hosts '^162\.159\.') -eq 12) ("exit=$($r.Exit)")

    $r = Invoke-Script $vpnWrite -Arguments @('-NoZapret', '-HostsFile', $hosts) -Feed -InputText "x`r`n2"
    Check 'vpn menu: a wrong answer asks again' ($r.Exit -eq 0 -and (Has $r 'Type 1 or 2') -and (Has $r 'Continuing with the VPN on')) ("exit=$($r.Exit)")

    $r = Invoke-Script $vpn -Arguments @('-NoZapret', '-HostsFile', $hosts, '-NoPrompt') -Feed -InputText '2'
    Check 'vpn menu: -NoPrompt never asks' ($r.Exit -eq 3 -and -not (Has $r 'Classic - stop here')) ("exit=$($r.Exit)")

    New-HostsFile $hosts ("# >>> discord-media-pin (auto) >>>`r`n162.159.141.232 media.discordapp.net`r`n# <<< discord-media-pin (auto) <<<`r`n127.0.0.1 localhost`r`n")
    $r = Invoke-Script $vpn -Arguments @('-Remove', '-HostsFile', $hosts) -Feed -InputText ''
    Check 'vpn menu: -Remove never asks and still works' ($r.Exit -eq 0 -and -not (Has $r 'Classic - stop here') -and (Count-Lines $hosts 'discord-media-pin') -eq 0) ("exit=$($r.Exit)")

    # No tunnel: the variable alone must not turn the run into a questionnaire.
    $noVpnMenu = New-Variant -Name 'menu-no-vpn' -SystemFile -Media 'ok' -Runner '@()'
    New-HostsFile $hosts $plainHosts
    $r = Invoke-Script $noVpnMenu -Arguments @('-NoZapret', '-HostsFile', $hosts) -Feed -InputText '2'
    Check 'vpn menu: no VPN means no question' ($r.Exit -eq 0 -and -not (Has $r 'Classic - stop here')) ("exit=$($r.Exit)")
}
finally {
    Remove-Item Env:\DISCORD_MEDIA_FIX_MENU -ErrorAction SilentlyContinue
}

# A failed run through the tunnel must blame the tunnel, not the provider.
$vpnDead = New-Variant -Name 'vpn-dead' -Media 'dead' -AliveEmpty -Runner '@()' -VpnStub
New-HostsFile $hosts $plainHosts
$before = File-Hash $hosts
$r = Invoke-Script $vpnDead -Arguments @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'vpn: a failed run through the tunnel names the tunnel, not the provider' ($r.Exit -eq 2 -and (Has $r 'ran through the tunnel') -and -not (Has $r 'None of them accepted a connection')) ("exit=$($r.Exit)")
Check 'vpn: that run still leaves hosts alone' ((File-Hash $hosts) -eq $before)

# ---------- no zapret folder ----------
$noZapret = New-Variant -Name 'no-zapret' -SystemFile -Media 'ok' -Runner '@()'
$r = Invoke-Script $noZapret @('-HostsFile', $hosts, '-IgnoreVpn')
Check 'zapret missing: explains and continues' ($r.Exit -eq 0 -and (Has $r 'No zapret folder next to this file') -and (Has $r 'pins are fine')) ("exit=$($r.Exit)")

# ---------- sweep: a minority of the range answers ----------
# The profile from the issue: most of the range times out, one address deep in
# it answers. Before the widening the sweep stopped at probe eight, ran the
# four-verdict diagnosis and told the person the addresses themselves were cut.
$minority = New-Variant -Name 'sweep-minority' -SystemFile -FakeProbes -RealProbes `
    -AliveIps @('162.159.140.232')
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $minority @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'sweep: one answering address deep in the range is pinned' `
    ($r.Exit -eq 0 -and (Count-Lines $hosts '^162\.159\.140\.232 media\.discordapp\.net') -eq 1) `
    ("exit=$($r.Exit)")
Check 'sweep: a minority profile is not reported as a dead network' `
    (-not (Has $r 'No address answered') -and -not (Has $r 'None of them accepted a connection'))

$fallback = New-Variant -Name 'sweep-fallback' -SystemFile -FakeProbes -RealProbes -NoParallel `
    -AliveIps @('162.159.140.232')
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $fallback @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'sweep: an old curl without --parallel still finds it' `
    ($r.Exit -eq 0 -and (Count-Lines $hosts '^162\.159\.140\.232 media\.discordapp\.net') -eq 1) `
    ("exit=$($r.Exit)")
# The empty batch on that path is not silent: the slow route is named, because a
# person watching a five-minute run deserves to know why it is slow.
Check 'sweep: an old curl names the slow path' `
    (Has $r 'this curl has no --parallel - checking one address at a time (slower)')

# A batch that parsed fewer records than it was given must say so, and must not
# turn the missing ones into a minute of one-process-per-address probing.
$partial = New-Variant -Name 'sweep-partial' -SystemFile -FakeProbes -RealProbes -DropIps @('162.159.130.232')
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $partial @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'sweep: a batch that lost a record is counted out loud' `
    ((Has $r 'the parallel probe reported') -and (Has $r 'at most six of the rest are retried one by one')) `
    (($r.Lines | Where-Object { $_ -match 'parallel probe' }) -join '; ')

# A glued response - several records in one line, exactly what the broken 1.10.0
# produced - must yield no keys at all. The greedy parser credited such a line to
# the last address in it, and a wrong attribution is worse than a missing one.
$glued = New-Variant -Name 'sweep-glued' -SystemFile -FakeProbes -RealProbes -GlueLines
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $glued @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'sweep: a glued batch is refused, not guessed' `
    ((Has $r 'the parallel probe reported nothing') -and (Count-Lines $hosts '^162\.159\.') -eq 0) `
    (($r.Lines | Where-Object { $_ -match 'parallel probe' }) -join '; ')

# ---------- candidates: the resolver is a source too ----------
$dns = New-Variant -Name 'dns-candidates' -SystemFile -FakeProbes -RealProbes `
    -AliveIps @('188.114.97.3') -DnsIps @('188.114.97.3')
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $dns @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'candidates: an address from the resolver is probed and pinned' `
    ($r.Exit -eq 0 -and (Count-Lines $hosts '^188\.114\.97\.3 media\.discordapp\.net') -eq 1) `
    ("exit=$($r.Exit)")

# ---------- the pin must serve the name, not just answer ----------
$refused = New-Variant -Name 'verify-421' -SystemFile -FakeProbes -RealProbes `
    -AliveIps @('162.159.137.232') -ThroughCode '421'
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $refused @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'verify: a node that refuses the host is not called a success' `
    ($r.Exit -eq 1 -and (Has $r 'do not answer through them')) ("exit=$($r.Exit)")
Check 'verify: the refused run does not print the success line' (-not (Has $r 'Address list updated'))

# 403 and 421 are the same verdict in the code; the second one exists so a future
# edit that special-cases only 421 cannot pass unnoticed.
$forbidden = New-Variant -Name 'verify-403' -SystemFile -FakeProbes -RealProbes `
    -AliveIps @('162.159.137.232') -ThroughCode '403'
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $forbidden @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'verify: an HTTP 403 node is refused like 421' `
    ($r.Exit -eq 1 -and (Has $r 'refused this host (HTTP 403)')) ("exit=$($r.Exit)")

$dead = New-Variant -Name 'verify-dead' -SystemFile -FakeProbes -RealProbes `
    -AliveIps @('162.159.137.232') -ThroughCode '000'
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $dead @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'verify: a pin nothing answers through is reported, not claimed' `
    ($r.Exit -eq 1 -and (Has $r 'do not answer through them') -and (Has $r 'no answer')) ("exit=$($r.Exit)")

$served = New-Variant -Name 'verify-ok' -SystemFile -FakeProbes -RealProbes `
    -AliveIps @('162.159.137.232')
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $served @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'verify: a served name still ends in the success line' `
    ($r.Exit -eq 0 -and (Has $r 'Address list updated')) ("exit=$($r.Exit)")

# Without curl nothing can be checked through the names: the run says the list is
# unverified (-Force) instead of calling every name dead.
$noCurlWrite = New-Variant -Name 'verify-no-curl' -SystemFile -Media 'dead' -AliveEmpty -Runner '@()' -NoCurl
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $noCurlWrite @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'verify: without curl it does not pretend the names were checked' `
    ($r.Exit -eq 0 -and (Has $r '-Force was passed') -and -not (Has $r 'do not answer through them')) `
    ("exit=$($r.Exit)")

# ---------- batch: what curl actually receives, and what it answers ----------
# The fake network above sits on Invoke-CurlRaw, so it never saw the argument
# list. A real newline in argv broke every wide sweep in 1.10.0 while the fake
# kept answering: the suite was green and the shipped script fell back to one
# process per address. These two checks close that gap from both ends.
$argvLog = Join-Path $testRoot 'argv-batch.log'
Remove-Item -LiteralPath $argvLog -ErrorAction SilentlyContinue
$hygiene = New-Variant -Name 'argv-hygiene' -SystemFile -FakeProbes -RealProbes -ArgvLog $argvLog
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $hygiene @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
$argvSeen = @()
if (Test-Path -LiteralPath $argvLog) {
    $argvSeen = @(Get-Content -LiteralPath $argvLog | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}
Check 'argv: curl received a --parallel invocation' `
    (@($argvSeen | Where-Object { $_ -eq '--parallel' }).Count -ge 1) `
    ("args={0}" -f $argvSeen.Count)
$newlineArgs = @($argvSeen | Where-Object { $_ -match "[`r`n]" })
Check 'argv: no argument handed to curl contains a raw CR or LF' `
    ($newlineArgs.Count -eq 0) `
    (($newlineArgs | ForEach-Object { '[' + ($_ -replace "`r", '\r' -replace "`n", '\n') + ']' }) -join ' ')

# Lifted from the shipped file rather than copied: if the functions move or change
# shape, this check says so instead of testing a stale copy. Two loopback
# addresses on a dead port need no network: both transfers must still produce
# their own line, attributed to their own tag.
$fnStart = $src.IndexOf('function Invoke-CurlRaw {')
$fnEnd = $src.IndexOf('# One HTTPS request that keeps the reason it failed.')
$fnText = ''
if ($fnStart -ge 0 -and $fnEnd -gt $fnStart) { $fnText = $src.Substring($fnStart, $fnEnd - $fnStart) }
Check 'batch: the probe functions can be lifted for a live check' `
    ($fnText -match 'function Invoke-CurlRaw' -and $fnText -match 'function Test-CurlParallel' -and $fnText -match 'function Get-ProbeBatch')

# Explicit precondition, not a skip: without curl there is nothing to check, and
# a suite that quietly loses the live check is how the 1.10.0 defect survived.
$curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
Check 'batch: curl.exe is present for the live check' (Test-Path -LiteralPath $curlExe) `
    ("curl.exe not found at {0} - the live batch check cannot run, so this run is red" -f $curlExe)

$livePath = Join-Path $testRoot 'batch-live.ps1'
$liveBody = @'
$ErrorActionPreference = 'Stop'
$curlPath = '__CURL__'
__FUNCS__
$b = Get-ProbeBatch -Addresses @('127.0.0.1', '127.0.0.2') -Port 1 -TimeoutSec 3
"keys=$($b.Keys.Count)"
"one=[$($b['127.0.0.1'])]"
"two=[$($b['127.0.0.2'])]"
'@
$liveBody = $liveBody.Replace('__CURL__', $curlExe).Replace('__FUNCS__', $fnText)
Set-Content -LiteralPath $livePath -Value $liveBody -Encoding UTF8
$live = Invoke-Script $livePath @()
$liveText = ($live.Lines -join "`n")
$liveDetail = (($live.Lines | Where-Object { $_ -match '^(keys|one|two)=' }) -join '; ')

# The invariant is attribution, not the network: a refusal, a filtered port and a
# proxy all answer differently, but every address must still get its own record.
Check 'batch: real curl returns one line per address (2 of 2 keys)' `
    ($liveText -match 'keys=2') $liveDetail
Check 'batch: a silent address is attributed, not dropped' `
    ($liveText -match 'one=\[(ok|dead|tls|odd)\]' -and $liveText -match 'two=\[(ok|dead|tls|odd)\]') $liveDetail

# ---------- diagnostics: what exactly is blocked ----------
$diagIp = New-Variant -Name 'diag-ip' -Media 'dead' -AliveEmpty -Runner '@()'
New-HostsFile $hosts $plainHosts
$before = File-Hash $hosts
$r = Invoke-Script $diagIp @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'diagnostics: a dropped network says the addresses themselves are cut' ($r.Exit -eq 2 -and (Has $r 'None of them accepted a connection') -and (Has $r 'TCP 443 does not connect to')) ("exit=$($r.Exit)")
Check 'diagnostics: a dropped network still leaves hosts alone' ((File-Hash $hosts) -eq $before)

$portStub = @'
function Get-PortVerdict { param([string[]]$Addresses, [string]$HostName = 'media.discordapp.net', [int]$TimeoutSec = 5) return @{ Kind = 'port'; Port = 2053; Ip = '162.159.141.232'; Detail = 'ok' } }
'@
$diagPort = New-Variant -Name 'diag-port' -Media 'dead' -AliveEmpty -Runner '@()' -ExtraStubs $portStub
$r = Invoke-Script $diagPort @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'diagnostics: a port-only block points at the working port' ($r.Exit -eq 2 -and (Has $r 'Port 2053 answers for 162.159.141.232') -and (Has $r '127.0.0.1:443 -> 162.159.141.232:2053')) ("exit=$($r.Exit)")
Check 'diagnostics: a port-only block does not send the user straight to a VPN' (-not (Has $r 'send only Discord through a VPN'))

$tlsStub = @'
function Get-PortVerdict { param([string[]]$Addresses, [string]$HostName = 'media.discordapp.net', [int]$TimeoutSec = 5) return @{ Kind = 'tls'; Port = 0; Ip = '162.159.141.232'; Detail = '' } }
'@
$diagTls = New-Variant -Name 'diag-tls' -Media 'dead' -AliveEmpty -Runner '@()' -ExtraStubs $tlsStub
$r = Invoke-Script $diagTls @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'diagnostics: a killed handshake is named as a block by name' ($r.Exit -eq 2 -and (Has $r 'TLS handshake is killed') -and (Has $r 'block by name')) ("exit=$($r.Exit)")

$refusedStub = @'
function Get-PortVerdict { param([string[]]$Addresses, [string]$HostName = 'media.discordapp.net', [int]$TimeoutSec = 5) return @{ Kind = 'refused'; Port = 0; Ip = '162.159.141.232'; Detail = '' } }
'@
$diagRefused = New-Variant -Name 'diag-refused' -Media 'dead' -AliveEmpty -Runner '@()' -ExtraStubs $refusedStub
$r = Invoke-Script $diagRefused @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'diagnostics: a local refusal blames the machine, not the provider' ($r.Exit -eq 2 -and (Has $r 'refused the connection itself') -and (Has $r 'firewall')) ("exit=$($r.Exit)")

$mitmStub = @'
function Get-TlsInterceptor { param([string[]]$HostNames = @('discord.com','example.com')) return @{ Host = 'discord.com'; Issuer = 'CN=Kaspersky Anti-Virus Personal Root Certificate, O=AO Kaspersky Lab' } }
'@
$diagMitm = New-Variant -Name 'diag-mitm' -Media 'dead' -AliveEmpty -Runner '@()' -ExtraStubs $mitmStub
$r = Invoke-Script $diagMitm @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'diagnostics: an HTTPS-interceptor certificate is named' ($r.Exit -eq 2 -and (Has $r 'HTTPS here is signed by') -and (Has $r 'Kaspersky') -and (Has $r 'HTTPS scanning off')) ("exit=$($r.Exit)")

# ---------- no curl: never pin blind ----------
$noCurl = New-Variant -Name 'no-curl' -Media 'dead' -AliveEmpty -Runner '@()' -NoCurl
New-HostsFile $hosts $plainHosts
$before = File-Hash $hosts
$r = Invoke-Script $noCurl @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'no curl: exit 2, nothing pinned, says why' ($r.Exit -eq 2 -and (Has $r 'curl.exe was not found') -and (Has $r 'nothing is pinned without a check') -and (File-Hash $hosts) -eq $before) ("exit=$($r.Exit)")

$r = Invoke-Script $noCurl @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'no curl + -Force: pins the known-good list and admits it is unchecked' ($r.Exit -eq 0 -and (Has $r '-Force was passed') -and (Count-Lines $hosts '^162\.159\.') -eq 12) ("exit=$($r.Exit)")

# ---------- hosts write that does not stick ----------
$revert = New-Variant -Name 'revert' -Media 'dead' -AliveStub -Runner '@()' -RevertHosts
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $revert @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn')
Check 'revert: a write that does not stay is reported as a protected hosts file' ($r.Exit -eq 1 -and (Has $r 'disappeared right after it was written') -and (Has $r 'Controlled folder access')) ("exit=$($r.Exit)")
Check 'revert: it does not claim success' (-not (Has $r 'Address list updated') -and -not (Has $r 'Nothing stays running'))

# ---------- zapret: a binary deleted between the check and the start ----------
$fakeZapret = Join-Path $testRoot 'zapret-nowinws'
New-Item -ItemType Directory -Path $fakeZapret -Force | Out-Null
Set-Content -LiteralPath (Join-Path $fakeZapret 'general.bat') -Value '@echo off' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $fakeZapret 'service.bat') -Value '@echo off' -Encoding ASCII
$nowinws = New-Variant -Name 'nowinws' -Media 'dead' -AliveEmpty -Runner '@()' -FastWinwsWait -NoWinws
$r = Invoke-Script $nowinws @('-ZapretDir', $fakeZapret, '-HostsFile', $hosts, '-IgnoreVpn', '-NoRestart')
Check 'zapret: a vanished winws.exe is named as an antivirus problem' ($r.Exit -eq 2 -and (Has $r 'did not appear within 1 s') -and (Has $r 'The file itself is gone')) ("exit=$($r.Exit)")

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
