# Wider address sweep Implementation Plan

> **For agentic workers:** implement this plan task-by-task, in order, checking off each step as it lands. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks 1-2 are sequential (Task 2 uses the helper Task 1 extracts); tasks 3-4 are independent of each other and can be done in either order after Task 2.

**Goal:** make the automatic fix finish on a network where only a minority of the Discord CDN range answers, instead of giving up after eight probes and telling the person the network is dead.

**Architecture:** the sweep currently stops after `$Limit = 8` probes out of ~38 candidates, sequentially, with 6 s each. This plan probes the whole candidate list in one `curl --parallel` process (with a sequential fallback for old curl builds), adds resolver answers as extra candidates, and verifies the finished pin through the host names before claiming success. The verdicts ("port", "tls", "refused", "ip") and the four-verdict report stay as they are: they run only when the sweep still finds nothing.

**Tech Stack:** Windows PowerShell 5.1, `curl.exe` from `C:\Windows\System32`, a hand-rolled test harness in `tests/fix-discord-media.tests.ps1` (no Pester), GitHub Actions on `windows-latest`.

**Non-goals:** no service, no scheduled task, no background process, no local redirect tool, no proxy, no antivirus or firewall settings. The fix stays a one-shot hosts pin plus `zapret`.

---

## Files

- Modify: `fix-discord-media.ps1` — probe helper, sweep, candidate sources, post-write verification, `$AppVersion`
- Modify: `tests/fix-discord-media.tests.ps1` — fake `Invoke-CurlRaw`, new variant switches, new checks
- Modify: `README.md` — what the sweep does now (English and Russian sections)
- Modify: `CHANGELOG.md` — 1.10.0 entry
- Modify: `BACKLOG.md` — note what this release does not cover
- Create: `docs/plans/2026-11-25-wider-address-sweep.md` (this file; `build-release.ps1` ships only the three product files, so it cannot leak into an archive)

Two labels used below:

- **the script** — `C:\VS\discord-media-hosts-fix\fix-discord-media.ps1`
- **the harness** — `C:\VS\discord-media-hosts-fix\tests\fix-discord-media.tests.ps1`

Run the suite after every task:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\fix-discord-media.tests.ps1
```

Expected at the end of a green run: `RESULT: all <N> checks passed`.

---

## Task 1: One place that talks to curl

Today `Get-HttpsProbe` and `Test-ControlHost` call `& $curlPath` directly, so the suite cannot stand in for the network: every existing test stubs one level higher (`Test-MediaEndpoint`, `Get-AliveAddresses`). This task extracts the invocation so Tasks 2-4 can be tested against a scripted network profile.

**Files:**
- Modify: `fix-discord-media.ps1:481-582` (the probe functions)
- Modify: `tests/fix-discord-media.tests.ps1:27-169` (`New-Variant`)

- [x] **Step 1: Add `Invoke-CurlRaw` right before `Get-HttpsProbe`**

Insert above the comment block that starts `# One HTTPS request that keeps the reason it failed.`:

```powershell
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
```

- [x] **Step 2: Make `Get-HttpsProbe` use it**

Replace the body block from `$saved = $ErrorActionPreference` through the `$exit = $LASTEXITCODE` line (currently lines 495-503) with:

```powershell
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
```

The rest of the function (`if ($exit -eq 0) { ... }` and the return table) stays exactly as it is. Keep the existing outer `try`/`finally` that restores `$ErrorActionPreference`.

- [x] **Step 3: Make `Test-ControlHost` use it**

Replace the two lines that build `$code` with:

```powershell
        $lines = @(Invoke-CurlRaw -CurlArgs @('-s', '-o', 'NUL', '-m', "$TimeoutSec", '-w', '%{http_code}', "https://$HostName/"))
        $code = ''
        if ($lines.Count -gt 0) { $code = $lines[-1] }
```

- [x] **Step 4: Add the fake network to the harness**

In the harness, above `function New-Variant` (currently line 27), add a single-quoted template so no `$` has to be escaped:

```powershell
# A scripted network: every address in __ALIVE__ answers, everything else times
# out, and a request that does not name an address (the post-write check through
# hosts) answers __THROUGH__. Both call shapes are supported - the single-URL one
# and the --parallel batch - so the real probing code runs unmodified.
$fakeCurl = @'
function Invoke-CurlRaw {
    param([string[]]$CurlArgs)
    $all = ($CurlArgs -join ' ')
    $alive = @(__ALIVE__)
    $global:LASTEXITCODE = 0
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
            if ($alive -contains $ip) {
                $ok++
                $lines += "200 0.010 0.040 https://media.discordapp.net/?probe=$ip"
            }
            else {
                $lines += "000 0.000000 0.000000 https://media.discordapp.net/?probe=$ip"
            }
        }
        if ($ok -eq 0) { $global:LASTEXITCODE = 28 }
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
```

- [x] **Step 5: Add the switches to `New-Variant`**

Add to the parameter block (after `[string]$ExtraStubs = ''`):

```powershell
        [switch]$FakeProbes,
        [switch]$NoParallel,
        [switch]$RealProbes,
        [string[]]$AliveIps = @(),
        [string]$ThroughCode = '200',
        [string[]]$DnsIps = @()
```

- [x] **Step 6: Inject the stub when asked**

Add after the `if ($ExtraStubs) { ... }` block (currently line 132):

```powershell
    if ($FakeProbes) {
        $aliveList = (@($AliveIps | ForEach-Object { "'$_'" }) -join ',')
        $stubs += "`r`n" + $fakeCurl.Replace('__ALIVE__', $aliveList).Replace('__THROUGH__', $ThroughCode)
    }
    if ($NoParallel) {
        $stubs += "`r`n" + 'function Test-CurlParallel { return $false }'
    }
```

- [x] **Step 7: Let the fake replace the real function**

Two changes in the same function:

1. In `$stubTargets` (currently lines 146-151), add `'Invoke-CurlRaw'` at the end of the base list.
2. Right after `if ($NoWinws) { $stubTargets += 'Test-Winws' }`, add:

```powershell
    if ($RealProbes) { $stubTargets = @($stubTargets | Where-Object { $_ -ne 'Test-MediaEndpoint' }) }
```

The base `$stubs` text still defines `Test-MediaEndpoint`, but the real definition further down the script wins when it is not renamed — that is how `-RealProbes` works.

- [x] **Step 8: Run the suite**

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\fix-discord-media.tests.ps1
```

Expected: unchanged count of checks, all passing. This task is a pure refactor; no existing check may change meaning.

- [x] **Step 9: Commit**

```
git add fix-discord-media.ps1 tests/fix-discord-media.tests.ps1
git commit -m "Change: route every curl call through one helper (test seam)"
```

---

## Task 2: Probe the whole list instead of the first eight

The failing case from the issue: most of the range times out, one address deep in the range answers. Today the sweep stops at probe eight (`-Limit 8`) and reports "No address answered", then runs the four-verdict diagnosis and exits 2.

**Files:**
- Test: `tests/fix-discord-media.tests.ps1` (new section after `# ---------- diagnostics...`, currently line 441)
- Modify: `fix-discord-media.ps1:481-560` (probe helpers), `:694-725` (`Get-AliveAddresses`), `:1218-1231` (call sites)

- [x] **Step 1: Write the failing test**

Add right before `# ---------- diagnostics: what exactly is blocked ----------`:

```powershell
# ---------- sweep: a minority of the range answers ----------
# The profile from the issue: most of the range times out, one address deep in
# it answers. Before the widening the sweep stopped at probe eight, ran the
# four-verdict diagnosis and told the person the addresses themselves were cut.
$minority = New-Variant -Name 'sweep-minority' -SystemFile -FakeProbes -RealProbes `
    -AliveIps @('162.159.140.232')
New-HostsFile $hosts $plainHosts
$before = File-Hash $hosts
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
```

- [x] **Step 2: Run the suite and watch it fail**

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\fix-discord-media.tests.ps1
```

Expected: `FAIL  sweep: one answering address deep in the range is pinned  exit=2` and `FAIL  sweep: an old curl without --parallel still finds it  exit=2`, with `RESULT: <N-2> passed, 2 FAILED`.

If it passes, the profile is not exercising the limit: `162.159.140.232` must sit beyond the tenth `$preferred` entry (it is the 13th address of the scanned range, i.e. probe 23 overall).

- [x] **Step 3: Add the parallel probe**

Insert after `Invoke-CurlRaw` (Task 1):

```powershell
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

    $curlArgs = @('-s', '--parallel', '--parallel-max', "$MaxParallel", '-m', "$TimeoutSec",
                  '-w', '%{http_code} %{time_connect} %{time_appconnect} %{url_effective}' + "`n")
    foreach ($ip in $Addresses) {
        $curlArgs += @('-o', 'NUL',
                       '--resolve', "${HostName}:${Port}:$ip",
                       ("https://{0}:{1}/?probe={2}" -f $HostName, $Port, $ip))
    }

    foreach ($line in @(Invoke-CurlRaw -CurlArgs $curlArgs)) {
        # http_code connect_time appconnect_time url
        if ($line -notmatch '^(\d{3}) (\d+\.?\d*) (\d+\.?\d*) .*\?probe=([0-9.]+)') { continue }
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
```

Also add `'Test-CurlParallel'` to `$stubTargets` in the harness: the `-NoParallel` variant defines it after `$pinEnd`, so without the rename the real definition further down would win.

- [x] **Step 4: Rewrite `Get-AliveAddresses` to use it**

Replace the whole function (currently lines 694-725) with:

```powershell
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

    $batch = Get-ProbeBatch -Addresses $queue -HostName $HostName -TimeoutSec $TimeoutSec
    $silent = 0
    $oneByOne = 0

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

        if ($oneByOne -ge $Limit) { break }
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
```

- [x] **Step 5: Widen the two call sites**

Replace the block at `:1224-1231` with:

```powershell
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
```

Worst case the sweep is now ~40 addresses in 5 waves of 6 s, plus a 12 s retry pass: about 45 s, inside the 10-60 s the README promises.

- [x] **Step 6: Run the suite**

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\fix-discord-media.tests.ps1
```

Expected: both new checks pass, everything else still green.

- [x] **Step 7: Commit**

```
git add fix-discord-media.ps1 tests/fix-discord-media.tests.ps1
git commit -m "Feat: probe the whole CDN range in parallel instead of the first eight"
```

---

## Task 3: Add resolver answers as candidates

The range is hardcoded to `162.159.128-141.{232,233}`. On a network where the working addresses sit outside it — which is what a person's manual "check what DNS gave me" loop finds — the sweep cannot succeed.

**Files:**
- Test: `tests/fix-discord-media.tests.ps1` (new section after the sweep section from Task 2)
- Modify: `fix-discord-media.ps1:543-560` area (new function next to the probes), `:1218-1222` (candidate list)

- [x] **Step 1: Write the failing test**

```powershell
# ---------- candidates: the resolver is a source too ----------
$dns = New-Variant -Name 'dns-candidates' -SystemFile -FakeProbes -RealProbes `
    -AliveIps @('188.114.97.3') -DnsIps @('188.114.97.3')
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $dns @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'candidates: an address from the resolver is probed and pinned' `
    ($r.Exit -eq 0 -and (Count-Lines $hosts '^188\.114\.97\.3 media\.discordapp\.net') -eq 1) `
    ("exit=$($r.Exit)")
```

- [x] **Step 2: Run it and watch it fail**

Expected: `FAIL  candidates: an address from the resolver is probed and pinned  exit=2` — the fake answers only `188.114.97.3`, which the candidate list never contains.

- [x] **Step 3: Add `Get-DnsAddresses`**

Insert after `Test-MediaAlive` (currently ends at line 561):

```powershell
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
```

- [x] **Step 4: Put it in the candidate list**

In the sweep block (currently `:1218`), replace

```powershell
    $candidates = @($ExtraIPs) + @($preferred)
```

with

```powershell
    $candidates = @($preferred) + @(Get-DnsAddresses -Names @('media.discordapp.net')) + @($ExtraIPs)
```

The preferred entries stay first: they are the known-good ones, and the sweep now stops as soon as four answer.

- [x] **Step 5: Stub it in the harness**

Add to `$stubTargets` the name `'Get-DnsAddresses'`, and to the base `$stubs` text:

```powershell
function Get-DnsAddresses { param([string[]]$Names = @('media.discordapp.net'), [int]$Max = 12) return @() }
```

Then, after the `if ($NoParallel) { ... }` block from Task 1:

```powershell
    if ($DnsIps.Count -gt 0) {
        $dnsList = (@($DnsIps | ForEach-Object { "'$_'" }) -join ',')
        $stubs += "`r`n" + ('function Get-DnsAddresses {{ param([string[]]$Names = @(), [int]$Max = 12) return @({0}) }}' -f $dnsList)
    }
```

- [x] **Step 6: Run the suite**

Expected: the new check passes; no existing check changes.

- [x] **Step 7: Commit**

```
git add fix-discord-media.ps1 tests/fix-discord-media.tests.ps1
git commit -m "Feat: probe resolver answers along with the known range"
```

---

## Task 4: Verify the pin through the host names before claiming success

Right now the write is verified as text only (`Test-PinBlock`). A node that answers with `403`/`421` — the wrong zone or a misdirected request — counts as `ok` everywhere, gets pinned, and the run still says `Address list updated`. That is how someone ends up with "fixed" and broken images.

**Files:**
- Test: `tests/fix-discord-media.tests.ps1` (new section after Task 3's)
- Modify: `fix-discord-media.ps1:1405-1422` (after the write, before the success messages)

- [x] **Step 1: Write the failing tests**

```powershell
# ---------- the pin must serve the name, not just answer ----------
$refused = New-Variant -Name 'verify-421' -SystemFile -FakeProbes -RealProbes `
    -AliveIps @('162.159.137.232') -ThroughCode '421'
New-HostsFile $hosts $plainHosts
$r = Invoke-Script $refused @('-NoZapret', '-HostsFile', $hosts, '-IgnoreVpn', '-Force')
Check 'verify: a node that refuses the host is not called a success' `
    ($r.Exit -eq 1 -and (Has $r 'do not answer through them')) ("exit=$($r.Exit)")
Check 'verify: the refused run does not print the success line' (-not (Has $r 'Address list updated'))

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
```

- [x] **Step 2: Run and watch them fail**

Expected: `FAIL  verify: a node that refuses the host is not called a success  exit=0` (the script currently reports success on a `421`), and the other two failures or passes as described. If `verify-421` passes, the fake's through-hosts branch is not reached — check that the requests carry no `probe=` tag and no `--resolve`.

- [x] **Step 3: Add the check**

Inside the `else` branch of the hosts write, after the `Test-PinBlock` guard (currently ends at line 1419) and **before** `Write-Step "Address list updated..."`:

```powershell
            # The check above proves the text landed. This proves the name, through
            # hosts, reaches a node that serves it. 403/421 means a node answered
            # but refused this host - pinning it is "fixed" with broken images.
            if ($isSystemFile -and -not $DryRun) {
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
```

- [x] **Step 4: Run the suite**

Expected: all three new checks pass. The existing `revert` check still passes because that failure exits before this block.

- [x] **Step 5: Commit**

```
git add fix-discord-media.ps1 tests/fix-discord-media.tests.ps1
git commit -m "Feat: verify the pin through the host names before reporting success"
```

---

## Task 5: Docs, version, release

**Files:**
- Modify: `fix-discord-media.ps1:116` (`$AppVersion`)
- Modify: `README.md` (English "What the script does", Russian mirror, troubleshooting)
- Modify: `CHANGELOG.md` (top entry)
- Modify: `BACKLOG.md` (what is still open)

- [x] **Step 1: Bump the version**

`$AppVersion = '1.9.1'` → `$AppVersion = '1.10.0'`.

- [x] **Step 2: Write the changelog entry**

Follow the shape of the existing entries; content:

```markdown
## 1.10.0

The fix no longer gives up on a network where only a few addresses of the Discord
CDN range answer - the profile where a manual `curl --resolve` loop shows a mix
of success and `exit=28`.

- The sweep probes the whole known range instead of the first eight addresses,
  in one `curl --parallel` process; a curl older than 7.66 falls back to one
  process per address. Worst case is about 45 s.
- Resolver answers for `media.discordapp.net` are probed too, so an address
  outside the hardcoded range can be used.
- After the write, every pinned name is requested through `hosts`. A node that
  answers `403`/`421` refuses the host, and a name that does not answer at all
  is a failure now - the run no longer prints "Address list updated" over a pin
  that cannot work.
```

- [x] **Step 3: Update the README**

In "What the script does", the probing step (5) should say that the range is scanned in parallel and that resolver answers are included; and the write step should say the pin is verified through the names. Mirror both sentences in the Russian section. Also state the new worst case (`about 45 s`) where the README currently promises 10-60 s.

Use these sentences, English side:

```markdown
5. Probes the whole known Cloudflare range for the Discord CDN in parallel, plus
   whatever the resolver hands out for `media.discordapp.net`, and keeps the
   addresses that answer. A network where only a few of them answer still ends
   with pins. Worst case is about 45 seconds.
```

```markdown
   After the write, every pinned name is requested through `hosts`: a run reports
   success only when the name really resolves and the node serves it.
```

Russian side:

```markdown
5. Параллельно проверяет весь известный диапазон Cloudflare для медиа-CDN Discord
   и то, что резолвер сейчас выдаёт для `media.discordapp.net`, оставляя только
   отвечающие адреса. Даже если отвечает меньшинство адресов, привязка всё равно
   произойдёт. Худший случай — около 45 секунд.
```

```markdown
   После записи каждое привязанное имя запрашивается через `hosts`: успех
   сообщается только если имя действительно резолвится и узел его обслуживает.
```


- [x] **Step 4: Update the backlog**

Add one item under a new `## Probing` heading:

```markdown
7. **The candidate range is still a guess.** `162.159.128-141.{232,233}` plus the
   resolver answer covers the networks seen so far. A user report from a range
   outside it would be the moment to ask DoH for the same name instead of
   widening the hardcoded list again.
```

and note that the planned 1.9.2 documentation release is still open.

- [x] **Step 5: Build and run the full release check**

```
powershell -ExecutionPolicy Bypass -File .\build-release.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\fix-discord-media.tests.ps1
```

Expected: the build writes `dist\` with the three files and the version from `$AppVersion`; the suite ends with `RESULT: all <N> checks passed`.

- [x] **Step 6: Commit**

```
git add fix-discord-media.ps1 README.md CHANGELOG.md BACKLOG.md
git commit -m "Docs: describe the wider sweep and the post-write check (v1.10.0)"
```

---

## Acceptance on a real machine

CI cannot reproduce the block: on a GitHub runner every address answers. Before tagging the release, run once on the affected network (the machine that produced the `exit=0` / `exit=28` mix):

- [ ] `fix-discord-media.bat` finds and pins addresses instead of printing `No address answered`.
- [ ] The console shows a smaller number of lines than the old per-address output, and the run finishes inside a minute.
- [ ] `Address list updated` appears only when the names answered through the pins.
- [ ] Images load in Discord after the automatic restart.
- [ ] A second run with the pins in place says `All Discord media hosts answer` and changes nothing.

---

## Risks

- **`--parallel` output format.** The batch reads `http_code`, `time_connect` and `time_appconnect` from the write-out. A curl build that omits a field leaves those addresses out of `$states`, and they fall through to the one-by-one path — slower, not wrong.
- **`-m` semantics.** The timeout is per transfer, and all transfers share one process; a stalled wave can add up. `--parallel-max 8` keeps the worst case bounded.
- **403 as "not served".** A CDN that answers `403` for the bare `/` path on a healthy network would now fail the run. Nothing seen so far does that (Discord answers `404` for `/`), but if a report says "everything was fine before 1.10.0", this check is the first suspect: `Get-HttpsProbe` records the code, so the report names it.
- **The 12-address retry** re-probes from the start of the list. If a future candidate source puts slow addresses first, the retry spends its 12 slots there — acceptable, because the first pass already covered the rest.
