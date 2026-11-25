# Discord media hosts fix for Windows (zapret + hosts)

One-click fix for the situation when you already run **zapret** (DPI bypass), but Discord still **does not load images** — "Failed to load image", empty avatars, no stickers, emoji or attachments, while text and voice work normally.

The script checks that no VPN is carrying the traffic, starts your zapret config if it is not running, restarts it with the next config if media still does not answer, probes Cloudflare addresses that serve the Discord media CDN, keeps the ones that actually answer, pins them in the Windows `hosts` file inside a marked block, and restarts Discord.

> **This is a one-time fix.** Run it once and you are done. After that, start zapret the way you always did — `general.bat`, `service.bat` or your shortcut — and open Discord normally. Run this file again only if images break again. It is **not** a Discord launcher and **not** an everyday step. The full explanation is in [Everyday use](#everyday-use--this-file-is-not-a-discord-launcher).

**Version 1.10.1** · [Changelog](CHANGELOG.md) · [Releases](https://github.com/TestSoulja/discord-media-hosts-fix/releases)

* [Русское описание — ниже](#русский)

---

## Quick start

**Easiest way:** open the [Releases page](https://github.com/TestSoulja/discord-media-hosts-fix/releases/latest), download `discord-media-hosts-fix.zip`, unpack it — and go to step 2. The archive contains only the three files below, so copying them into your bundle overwrites nothing.

**1. What to download** (three files):

| File | What it is |
|---|---|
| `fix-discord-media.bat` | the file you double-click |
| `fix-discord-media.ps1` | the actual logic — must sit next to the `.bat` |
| `remove-pins.bat` | undo, if you ever need it |

All three are in this repository. Do not download only the `.bat`: it needs the `.ps1` in the same folder.

**2. Where to put them:** into your zapret folder — the one that contains `service.bat` and `bin\winws.exe`. Copy the three files there, next to `general.bat`:

```
D:\zapret\
  bin\winws.exe
  lists\
  service.bat
  general.bat
  general (ALT11).bat
  fix-discord-media.bat      <- copied here
  fix-discord-media.ps1      <- copied here
  remove-pins.bat            <- copied here
```

**3. Run:** double-click `fix-discord-media.bat`.

1. Windows asks for administrator rights — click **Yes**.
2. Wait 10–60 seconds: it starts zapret, checks the media CDN, and switches to another config by itself if the first one does not get through. No questions.
3. Discord restarts by itself if the pins changed. Images load.

**That was the one-time part.** The pinned addresses stay in `hosts` after reboots. From now on start zapret the way you always did (`general.bat`, `service.bat`, or your shortcut) and open Discord normally. This file is only needed again when images break: it re-probes and re-pins. Keep the minimized zapret window open: closing it stops the bypass.

If a VPN is on, the script stops before changing anything and tells you why — the pins cannot be reached through a tunnel. Turn the VPN off, or exclude `*.discordapp.net` from it.

### Everyday use — this file is not a Discord launcher

`fix-discord-media.bat` starts the **zapret bypass**; it does not open Discord, and it is **not required every day**. Discord opens from its normal shortcut or the tray, as always.

After the first run the pinned addresses live in the `hosts` file: they survive reboots and apply whenever zapret is running, whichever file started it. So the usual routine stays the same:

1. Start zapret as before (`general.bat`, `service.bat`, or your shortcut).
2. Open Discord normally.

Run `fix-discord-media.bat` again only when media breaks again (Cloudflare addresses rotate) — it re-probes and re-pins. Running it every day is harmless too: it starts the bypass if needed, sees that the pins still work and changes nothing.

If Discord is open while the script rewrites the addresses, or starts/replaces the bypass, the client is restarted automatically — a running client keeps its old addresses and connections until then. When nothing changed but Discord is running, the script says so: close it completely (tray icon too) and open it again, or run `fix-discord-media.bat -RestartDiscord` and let the script do it.

If it does run with everything healthy, it says so:

```
All Discord media hosts answer - the pins are fine, hosts left as is.
The bypass is up and the pins are fine - Discord is ready.
This file is not a Discord launcher: open Discord from its usual shortcut.
```

#### Want the bypass checked on every start?

Two valid ways to start zapret — pick one:

| | Everyday launcher (`general.bat`, shortcut) | This file |
|---|---|---|
| Start time | instant | 10–60 s: it probes before starting Discord |
| If the provider changes and the config stops working | images break silently, you find out later | switches config by itself until one works |
| If the pinned addresses rotate | nothing happens, you re-pin manually | re-probes and re-pins on the spot |
| Restarts Discord | no | only when it has something new to pick up: new addresses, a started/replaced bypass, or `-RestartDiscord` |

So: `general.bat` is faster, this file is more reliable. If media broke on you more than once, start zapret with `fix-discord-media.bat` — it never does damage on a healthy day, it just checks and says everything is fine.

> **A VPN must be off for Discord.** The fix does not work while a VPN or a TUN-mode tunnel (for example Happ) is active: traffic leaves through the tunnel and the pinned direct addresses are not reachable, so images break again. Turn the VPN off, or exclude `*.discordapp.net` from the tunnel.

**Don't want to copy anything into the bundle?** Keep the files in any folder and point the script at zapret:

```bat
fix-discord-media.bat -ZapretDir "C:\path\to\zapret"
```

The script looks for zapret only in its own folder, so this argument is required when the files and the bundle are separate.

---

## Why zapret alone does not fix this

On some networks the Discord media CDN (`media.discordapp.net`, `images-ext-1/2.discordapp.net`) is blocked **by destination IP address**, not by domain name. The diagnostic signature is:

```
TCP 443 to 162.159.128.232        -> connects
TLS with SNI media.discordapp.net -> timeout
TLS with SNI example.org          -> timeout
TLS 1.2 / HTTP 1.1                -> timeout
```

TCP connects and the connection dies on TLS for **any** hostname and **any** protocol version. That means the block is not SNI-based, so DPI desync (fake, split, multisplit, fooling) cannot do anything: the real and the fake packets both go to a blackholed address. DNS/DoH does not help either — resolvers hand out the same dead set.

The only thing that works is a **different destination address** that serves the same CDN. That is what this script pins — and zapret is started first, because with the desync running a much larger share of the Cloudflare range answers, so there are more addresses to choose from.

## What the script does

1. Refuses to run while a VPN or TUN tunnel carries the default route (exit code `3`): pinned addresses are not reachable through a tunnel, so nothing would be fixed. Started from the `.bat`, it instead offers a choice — stop and keep the VPN off, or continue with the VPN on (see [When continuing with the VPN on is safe](#when-continuing-with-the-vpn-on-is-safe)).
2. Reads the configs (`general.bat`, `general (ALT11).bat`, …) from the folder it lives in.
3. Starts the remembered config (or `general.bat`), waits for `winws.exe`, then waits a few seconds so WinDivert really attaches before the first probe.
4. Checks four seed addresses of `media.discordapp.net` through the bypass. If they answer, that config stays.
5. If they do not, asks a control question — does `discord.com` load through this bypass at all — and names which of the two it is: only the media hosts are cut, or the bypass is not beating the DPI. Then stops the bypass and starts the next config and repeats, through every config found in the folder. When even TCP 443 does not connect, no desync can help and the switching stops.
6. Checks the three Discord media hosts. If all answer, `hosts` is left alone — that is the normal second and later run.
7. Probes the whole known Cloudflare range for the Discord CDN in parallel, plus whatever the resolver hands out for `media.discordapp.net`, and keeps the addresses that answer. Because the resolver is asked too, a run also recovers when the pinned addresses have rotated. A network where only a few of them answer still ends with pins. If nothing answers, the first dozen are retried with twice the timeout. Measured twice on a network where no address answered at all: 57–58 seconds in total, of which 48 are the two probe passes — two `curl --parallel` processes, never one per address. A build older than 7.66 prints `this curl has no --parallel - checking one address at a time (slower)` and probes the list one address at a time: just over five minutes for the same range (28 × 6 s + 12 × 12 s ≈ 312 s). If the parallel pass comes back with fewer records than it was given, the script says `the parallel probe reported N of M addresses - at most six of the rest are retried one by one` and probes no more than six of the missing addresses one at a time — a broken batch no longer turns into minutes of separate processes. Both lines are progress output on the console, not an error: the run continues with whatever it did get.
8. Writes them into `hosts`, one line per hostname per address — 12 lines when four addresses answer. After the write, every pinned name is requested through `hosts`: a run reports success only when the name really resolves and the node serves it.
9. Flushes the DNS cache. Restarts the Discord client that was running (Stable / PTB / Canary / Development) when `hosts` changed or the bypass was started/replaced; a client that was not running is never launched. `-RestartDiscord` forces the restart, `-NoRestart` turns it off.

If no address answers, nothing is written and the script exits with code `2` — after naming the real cause: by name (Discord works, only the media hosts are cut), by config (even `discord.com` fails through the bypass) or by address (TCP 443 never connects). When nothing connects at all, it also checks whether only port 443 is cut, the addresses themselves are dropped, the TLS handshake is killed, or the machine itself refuses — four different situations with four different answers. Every `hosts` write is read back and verified, and every pinned name is then requested through `hosts`: if a security product restores the old file, or the pinned node refuses the name, the script says so and exits with code `1` instead of reporting success. It never pins a dead address, and it never edits zapret's configs, lists or `service.bat`. A zapret installed as a Windows service is never killed and replaced.

## Requirements

- A zapret bundle (for example the Flowseal / `zapret-discord-youtube` style build) with `winws.exe` in `bin\` or in the root
- Windows 10 1803+ or Windows 11, Windows PowerShell 5.1 (built in)
- `curl.exe` (built into Windows since 1803; if missing, a known-good address list is used)
- Administrator rights — the `.bat` asks for them itself

## Usage

| Action | How |
|---|---|
| Apply the fix | double-click **`fix-discord-media.bat`** |
| List the configs found next to the script | `fix-discord-media.bat -ShowConfigs` |
| Preview without changing anything | `fix-discord-media.bat -DryRun` |
| Undo | double-click **`remove-pins.bat`** |

Options (pass them through the `.bat` or call the `.ps1` from an elevated PowerShell):

| Option | Meaning |
|---|---|
| `-Remove` | delete the pin block and exit |
| `-Force` | re-probe and re-pin even if everything already works; when `curl.exe` is missing it also pins the known-good list, and says the result is unverified |
| `-DryRun` | print the resulting `hosts`, change nothing |
| `-NoRestart` | do not touch the Discord client |
| `-RestartDiscord` | restart the Discord client even when nothing changed, and after `-Remove` (a closed client is not launched) |
| `-NoZapret` | do not look for or start zapret, only pin hosts |
| `-IgnoreVpn` | same as answering 2 to the VPN question: continue even when a VPN carries the default route (the run then says everything was measured through the tunnel) |
| `-ZapretDir <path>` | zapret folder (default: the folder this script is in) |
| `-Config <name>` | use only this config, no automatic switching, for example `"general (ALT11).bat"` |
| `-MaxConfigs <n>` | stop the automatic sweep after `n` configs (default: all of them) |
| `-RestartZapret` | restart the bypass even if it already answers |
| `-ShowConfigs` | list configs found in the zapret folder and exit |
| `-Prompt` | show the config menu instead of choosing automatically |
| `-NoPrompt` | never ask anything: no config menu, no VPN question |
| `-HostsFile <path>` | alternate `hosts` file (for testing) |
| `-Hosts <name...>` | hostnames to pin (default: the three Discord media hosts) |
| `-ExtraIPs <ip...>` | additional candidate addresses to probe first |
| `-Version` | print the script version and exit (no admin rights needed) |

Typical cases:

```bat
:: the files are not inside the zapret folder
fix-discord-media.bat -ZapretDir "D:\zapret"

:: you normally run a specific alternative config
fix-discord-media.bat -Config "general (ALT11).bat"

:: pin only, without touching zapret
fix-discord-media.bat -NoZapret
```

### When continuing with the VPN on is safe

If a tunnel carries the default route, the script stops and — when started from the `.bat` — asks which way to go:

```
  1  Classic - stop here, turn the VPN off and run again   (default)
  2  With the VPN on - only if Discord bypasses this tunnel
```

Option 2 is harmless **only when the tunnel does not carry the traffic these hosts are reached through**: a split tunneling setup where Discord is excluded from the tunnel, or a VPN client that is up while the default route still goes through the physical adapter. In that case the stop was a false alarm and continuing changes nothing about the result.

If the tunnel carries everything, option 2 cannot fix the media: pinned addresses are unreachable inside a tunnel and zapret does not work there either. It cannot break anything either — when no address answers, `hosts` is left untouched and the script exits with code `2` — but it will not help. Such a run says in its own words that everything was measured through the tunnel and does not pretend to know what your provider blocks.

`-IgnoreVpn` does the same as option 2 for scripts and shortcuts; `-NoPrompt` removes the question.

## Choosing the config

Nothing to choose by hand: the script starts the config that worked last time, or `general.bat`, and moves on to the next config only if the media hosts still do not answer through it — through every config in the folder, until one works.

```
Configs to try: 12. Each check takes up to a minute,
so let it run - the one that works is remembered for next time.

Trying config 1 of 12: general.bat
Starting the bypass: general.bat
This one works - keeping it.
```

- The config that actually worked is remembered in `%LOCALAPPDATA%\discord-media-hosts-fix\last-config.txt` and is tried first next time.
- Order: the remembered config, then `general.bat`, then other `general*` configs, then the rest. **Every** config found in the folder is tried, one at a time, so on a big bundle the sweep can take several minutes; that is why the winner is remembered.
- `-MaxConfigs 5` stops the sweep after five configs if you would rather not wait.
- Switching stops early when TCP 443 does not connect to the CDN at all: that is not something another desync strategy can fix.
- `-Config "name.bat"` uses exactly that config and disables switching.
- `-Prompt` brings the old numbered menu back; `-ShowConfigs` prints the list and exits.
- If zapret is already running and media answers through it, it is left alone. `-RestartZapret` restarts it anyway.
- A zapret installed as a Windows service is not touched: restart the service yourself if you want another config.

## Where it looks for zapret

Only in one place:

1. `-ZapretDir`, if you passed it;
2. otherwise the folder where this script lives.

Nothing else is scanned - no parent folder, no `C:\zapret` / `D:\zapret` guesses. On a machine with several zapret copies that keeps the answer predictable: the bundle used is always the one holding the three files (or the one you named).

A folder counts as a zapret folder when it contains `bin\winws.exe`, `winws.exe` or `service.bat`. Configs are picked as: the one that worked last time, then `general.bat`, then any `general*.bat`, then the rest; every config found is tried (`-MaxConfigs N` limits the sweep). `service.bat`, installers and helper scripts are skipped.

## What exactly is changed on the machine

Only this block, appended to `C:\Windows\System32\drivers\etc\hosts`:

```
# >>> discord-media-pin (auto) >>>
162.159.141.232 media.discordapp.net
... 12 lines, 3 hostnames x 4 addresses ...
# <<< discord-media-pin (auto) <<<
```

Safety details:

- the existing file is backed up as `hosts.bak-YYYYMMDD-HHmmss` before every write (the last 5 backups are kept);
- the read-only attribute and the file encoding (ANSI or UTF-8 with BOM) are preserved;
- re-running is idempotent: an old block is replaced, other entries are untouched;
- the write is verified twice: the text is read back, then every pinned hostname is requested through `hosts`. A node that answers `403`/`421` or does not answer at all is reported and the run exits with code `1`, so "updated" never means "pinned something that cannot work";
- no changes to DNS settings, firewall, proxy, routing or the registry;
- nothing about the antivirus or firewall is changed either: no exclusions, no settings, no reading of its logs. The script only looks at the certificate a site presents and reports what it sees. It deliberately does not ask Windows for the antivirus state (`SecurityCenter2`): on a machine where the product had already been removed, that query once returned two ghost Kaspersky entries, and a report built on it would have lied;
- zapret itself is not modified — the script only starts the config you already have;
- other sites, LAN names and `cdn.discordapp.com` are not affected;
- it is a one-shot run: **no service, no scheduled task, no autostart entry, no background process**. When the script exits, nothing of it keeps running, so it cannot reset, restart or re-pin anything on its own later;
- the Discord client is restarted at most once per run, and only if it was already open: the script never launches a closed client and never touches it again afterwards;
- nothing else is written: just `hosts` (plus its backups) and `%LOCALAPPDATA%\discord-media-hosts-fix\last-config.txt`, which is only read on the next manual run.

## Limitations

- The addresses are Cloudflare anycast IPs and can rotate. If media breaks again months later, run the script again — it re-probes.
- **Does not work with a VPN or TUN tunnel enabled.** The pinned addresses are reached directly through your ISP; inside a tunnel they are not available, and zapret itself also does not work through a VPN. The script checks this itself: if the default route goes through a tunnel it stops with exit code `3` and writes nothing, or asks whether to continue (see [When continuing with the VPN on is safe](#when-continuing-with-the-vpn-on-is-safe)). A tunnel that is up but does not carry the default route (split tunneling) is fine and only gets a note.
- If the block covers every address in the range, no `hosts` entry can help: this method is done, use a tunnel or a proxy for Discord instead.
- If the block is by name (not by address), the pins are not the cure either — another zapret config or a tunnel is. The script tells these two cases apart and says which one you hit.
- If only port 443 is cut (Cloudflare also answers on 2053, 2083, 2087 and 2096), a local redirect `127.0.0.1:443 -> <address>:2053` can carry the images — but that is a background tool, not this one-shot fix. The script says when this is your case.
- The fix is per hostname and per machine. It is not a VPN and does not hide traffic.
- IPv6-only networks that resolve the CDN over IPv6 are out of scope: the block pins IPv4 addresses.

## Troubleshooting

**"then was unexpected at this time" and nothing runs (exit code `255`)** — this is the broken entry point of 1.10.0: an unescaped parenthesis in `fix-discord-media.bat` ended a cmd block, so cmd rejected the whole file before running anything. 1.10.1 fixes it. Download the current release and replace the three files; nothing is wrong with your machine, your zapret folder or the `.ps1`.

**"All Discord media hosts answer — the pins are fine, hosts left as is"** — the script checked all three hosts through the running bypass and each one responded, so it left `hosts` alone on purpose. That is the normal state on the second and later runs. If Discord still shows broken images, close it completely (tray icon too) and open it again: a running client keeps its old addresses until restart. To re-probe and re-pin anyway, run with `-Force`. With a VPN on, this check can also pass while Discord still fails. If the client is open, the script now says so by name and suggests `-RestartDiscord`, which restarts it for you.

**"VPN is on: … Nothing was changed." (exit code `3`)** — the VPN carries all traffic, so the fixed addresses are unreachable. Started from the `.bat`, the script offers a choice instead of only stopping: classic (turn the VPN off and run again) or continue with the VPN on. Choose the second one only if you know the tunnel does not carry Discord traffic — see [When continuing with the VPN on is safe](#when-continuing-with-the-vpn-on-is-safe). `-IgnoreVpn` answers that question from the command line.

**"No address answered"** — followed by one of these explanations:

- *"discord.com fails too"* — the bypass is not beating this DPI at all, so the media hosts fail for the same reason. The script already tried every config in the folder; the next moves are a newer zapret build (then run this file again — it re-tries everything), or a tunnel/proxy for Discord.
- *"every connection to media.discordapp.net is cut off"* — Discord itself loads through the bypass, only the media hosts are blocked by name. Changing addresses cannot fix that either; the same next steps: a newer zapret build, then a tunnel/proxy.
- *"Port 2053 answers for … but port 443 does not"* — only the port is cut, not the address and not the name. A local redirect `127.0.0.1:443 -> <address>:2053` keeps TLS valid and can carry the images, but it needs a small redirect tool running in the background. This one-shot fix deliberately installs nothing like that: use a proxy or a tunnel for now.
- *"Port 443 accepts TCP, but the TLS handshake is killed"* — the block is by name, so neither another port nor another address helps. Another zapret config, or a tunnel/proxy for Discord.
- *"The machine refused the connection itself"* — a local firewall or an antivirus blocks `curl.exe` or the port. Allow `curl.exe` and PowerShell in the firewall, check the antivirus log, then run the file again.
- *"None of them accepted a connection at all"* — the addresses themselves are dropped or slowed to a standstill. No config helps; the way out is a tunnel for Discord only (VPN with split tunneling) or a proxy.

If something local inspects HTTPS, the report adds a line: *"HTTPS here is signed by CN=Kaspersky Anti-Virus Personal Root Certificate"* means an antivirus or proxy is decrypting the connection, and its own certificate can break the handshake to the media hosts. Turn its HTTPS scanning off for a test — no address change can cure that. That line can only appear when a site actually answers over HTTPS (`discord.com`, `example.com`); if HTTPS is blocked completely, there is no certificate to name and the line is absent.

In every case `hosts` is left unchanged on purpose: no dead address is pinned. The gray `Details:` line keeps the technical fact, useful when you report the problem.

**"curl.exe was not found"** — the addresses cannot be checked, so nothing is pinned and the script exits with code `2` (Windows 10 1803+ and Windows 11 ship `curl.exe`; a security product may hide it). Update Windows, allow `curl.exe`, or pass `-Force` to pin a known-good list knowing it was not verified.

**"The address list disappeared right after it was written"** — something protects the `hosts` file and restored it (an antivirus, or Defender *Controlled folder access*). The fix cannot stay that way; allow the change and run the file again. Exit code `1`.

**"The addresses are in hosts, but the names do not answer through them"** — the pins landed, but the nodes behind them do not serve the Discord media host: a `403`/`421` means the node answered and refused the name, "no answer" means it said nothing at all. The block stays in `hosts` (undo with `remove-pins.bat`), but the run is not a success and exits with code `1`, because images would stay broken. Run the file again — addresses rotate; if it repeats, the pins are not on the path: check that the VPN is off and the bypass is running.

**"fix-discord-media.ps1 is missing next to this file"** — the archive was unpacked without it, or an antivirus quarantined the script after unpacking. Restore it from quarantine (or unpack the archive again) and run the `.bat` again; the `.bat` alone cannot do anything.

**"winws.exe did not appear … The file itself is gone"** — an antivirus deleted the binary. Restore the zapret bundle or allow its folder, then run the file again. If `winws.exe` is still there but the bypass never starts, an antivirus may be blocking the WinDivert driver it loads. The script cannot see that directly: it only sees that `winws.exe` did not appear or that connections are refused. Check the antivirus log for a blocked driver, allow it, and run the file again.

**"Could not write hosts"** — usually Microsoft Defender *Controlled folder access*. Allow the change for a minute, or add `powershell.exe` as an allowed app.

**The block was written but images still fail** — close Discord completely (tray icon too) and open it again, or run the file with `-RestartDiscord`; a running client only re-resolves hostnames on restart.

**zapret is already running under a different config** — if media answers through it, it is left alone; if not, the script restarts it with the next config and restarts an open Discord so it reconnects through the new bypass. `-RestartZapret` forces a bypass restart, `-Config` pins one config.

## Versioning and releases

This is a versioned project, not a loose set of scripts.

- The version follows **Semantic Versioning** (`MAJOR.MINOR.PATCH`) and lives in one place: `$AppVersion` at the top of `fix-discord-media.ps1`. Run `fix-discord-media.bat -Version` to print it.
- Every change is written down in [CHANGELOG.md](CHANGELOG.md) under `Added` / `Changed` / `Fixed` / `Removed`.
- Every release is a git tag `v<version>`. The archive is built from that tag and never committed: `dist/` and the zip names are listed in `.gitignore`.
- A published release is never rewritten. If one turns out broken, its page keeps its files and gets a warning at the top, and a patch release becomes the latest.
- `build-release.ps1` writes `dist/discord-media-hosts-fix.zip`, `dist/SHA256SUMS` and `dist/release-notes.md` (the CHANGELOG section). It checks the PowerShell syntax, refuses a tag that does not match `$AppVersion`, requires README and CHANGELOG to name the version, normalises CRLF and fixes the zip timestamps, so the same commit built with the same Windows PowerShell gives a byte-identical archive. Both workflows run its steps under Windows PowerShell, the same runtime as the command above.
- Pushing the tag runs [`.github/workflows/release.yml`](.github/workflows/release.yml): it builds from the tagged commit with that script, creates the GitHub release with the CHANGELOG notes and attaches the archive plus `SHA256SUMS`. No manual zip upload, no stale file.
- [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push to `main` and on pull requests: it builds the archive and runs the test suite in [`tests/fix-discord-media.tests.ps1`](tests/fix-discord-media.tests.ps1). That suite drives the real script against temporary `hosts` files with the network, the Discord client and admin rights stubbed out, and covers the pins-fine branch, restart reasons, `-Remove`, VPN stop, BOM and read-only `hosts`, idempotency, backups and dry runs. The real `.bat` entry points are started through `cmd` (the version path and the missing-`.ps1` path), so a parse error in the entry point fails the suite. Run it locally with `powershell -ExecutionPolicy Bypass -File .\tests\fix-discord-media.tests.ps1`.
- Release checklist: bump `$AppVersion` → update the version line in README → add a CHANGELOG entry → commit → tag `v<version>` → push the tag.
- Manual fallback: `powershell -ExecutionPolicy Bypass -File .\build-release.ps1 -Tag v<version>`, then upload `dist/discord-media-hosts-fix.zip` and `dist/SHA256SUMS` to the release.

The current release is **v1.10.1**.

Version 1.10.0 never started: an unescaped `)` in the missing-`.ps1` message closed the `.bat` block and cmd rejected the whole file (`then was unexpected at this time`). If you have 1.10.0, replace it with 1.10.1. The 1.10.0 page stays up with its own archive and a warning at the top; 1.10.1 is a separate release, not a re-upload.

## License

MIT. Do whatever you want, no warranty. See [LICENSE](LICENSE).

---

## Русский

Однокликовый фикс для случая, когда **zapret уже запущен, а картинки в Discord всё равно не грузятся** — «Не удалось загрузить изображение», пустые аватарки, нет стикеров, эмодзи и вложений, при этом текст и голос работают.

Скрипт проверяет, что трафик не уходит в VPN, поднимает ваш конфиг zapret (если `winws.exe` не запущен), при необходимости сам перезапускает его со следующим конфигом — перебирая все найденные в папке конфиги, пока один не заработает, — параллельно проверяет весь известный диапазон Cloudflare для медиа-CDN Discord и то, что резолвер сейчас выдаёт для `media.discordapp.net`, оставляет только те адреса, что реально отвечают, прописывает их в `hosts` Windows — в отдельном помеченном блоке — и проверяет каждое имя через записанные адреса. Потом перезапускает Discord, если ему есть что подхватить: изменились адреса или обход был запущен/сменён при уже открытом клиенте.

Помогает и когда отвечает меньшинство диапазона, и когда закреплённые адреса сдвинулись: проверяются весь известный диапазон и ответы резолвера. Не помогает, когда не отвечает ни один адрес или TLS рвётся по имени, — тогда скрипт называет причину и ничего не пишет.

Что видно в консоли во время проверки адресов. Если `curl` старше 7.66, скрипт пишет `this curl has no --parallel - checking one address at a time (slower)` и проверяет список по одному адресу — на том же диапазоне это пять с небольшим минут (28 × 6 с + 12 × 12 с ≈ 312 с) вместо примерно минуты. Если параллельный проход вернул меньше записей, чем получил адресов, он пишет `the parallel probe reported N of M addresses - at most six of the rest are retried one by one` и добивает по одному не больше шести пропущенных адресов, а не весь список. Обе строки — ход работы, а не ошибка: запуск продолжается с тем, что удалось проверить.

> **Это одноразовый фикс.** Запустить нужно один раз — и всё. Дальше запускайте zapret как раньше (`general.bat`, `service.bat` или ярлык) и открывайте Discord как обычно. Этот файл нужен снова только если картинки опять отвалились. Он **не** запускает Discord и **не** является ежедневным шагом. Подробнее — ниже, в разделе «Каждый день».

### Быстрый старт

**Проще всего:** откройте [страницу релизов](https://github.com/TestSoulja/discord-media-hosts-fix/releases/latest), скачайте `discord-media-hosts-fix.zip`, распакуйте — и переходите к пункту 2. В архиве только три нужных файла, так что при копировании в сборку ничего не перезапишется.

**1. Что скачать** — три файла:

| Файл | Это что |
|---|---|
| `fix-discord-media.bat` | по нему вы кликаете |
| `fix-discord-media.ps1` | сама логика, должен лежать рядом с `.bat` |
| `remove-pins.bat` | откат, если понадобится |

Скачивать один `.bat` нельзя: без `.ps1` в той же папке он не заработает.

**2. Куда положить:** в папку своей сборки zapret — ту, где лежат `service.bat` и `bin\winws.exe`. Скопируйте туда все три файла, рядом с `general.bat`:

```
D:\zapret\
  bin\winws.exe
  lists\
  service.bat
  general.bat
  general (ALT11).bat
  fix-discord-media.bat      <- сюда
  fix-discord-media.ps1      <- сюда
  remove-pins.bat            <- сюда
```

**3. Запуск:** двойной клик по `fix-discord-media.bat`.

1. Windows спросит права администратора — **Да**.
2. Подождите 10–60 секунд (если `curl.exe` старше 7.66, проверка идёт по одному адресу и занимает дольше): скрипт запустит zapret, проверит медиа-CDN и сам переключится на другой конфиг, если через первый ничего не проходит. Вопросов не задаёт — единственное исключение: выбор при включённом VPN (см. ниже).
3. Discord перезапустится сам, если пины изменились или обход был запущен/сменён при уже открытом клиенте. Картинки загрузятся.

**Это и была одноразовая часть.** Закреплённые адреса остаются в `hosts` после перезагрузок. Дальше запускайте zapret как раньше — `general.bat`, `service.bat` или ярлыком — и открывайте Discord как обычно. Этот файл нужен снова только если картинки опять отвалились: он заново проверит адреса и перепишет блок. Свёрнутое окно zapret не закрывайте: закрыли — обход выключился.

Если включён VPN, скрипт остановится до любых изменений и объяснит почему: через туннель закреплённые адреса недоступны. При запуске через `.bat` он предложит выбор — классический запуск (VPN выключить) или продолжение с VPN; второй вариант безвреден только если Discord идёт мимо туннеля. Подробнее — [Когда продолжать с включённым VPN точно не помешает](#когда-продолжать-с-включённым-vpn-точно-не-помешает).

### Каждый день — этот файл не запускает Discord

`fix-discord-media.bat` запускает **обход zapret**, а не Discord, и **не обязателен каждый день**. Сам Discord открывается как обычно — ярлыком или из трея.

После первого запуска адреса лежат в `hosts`: они переживают перезагрузку и работают при любом способе запуска zapret. Поэтому привычный порядок не меняется:

1. Запускаете zapret как раньше (`general.bat`, `service.bat` или ярлык).
2. Открываете Discord как обычно.

`fix-discord-media.bat` нужен снова только если картинки опять отвалились (адреса Cloudflare сменились) — он заново проверит и перепишет `hosts`. Запускать его каждый день тоже можно, вреда нет: поднимет обход, если тот не запущен, увидит, что пины живы, и ничего не изменит.

Если Discord открыт, а скрипт меняет адреса или запускает/сменяет обход, клиент перезапустится сам: открытый Discord держит старые адреса и соединения до перезапуска. Если же ничего не менялось, но Discord запущен, скрипт так и скажет — закройте его полностью (включая иконку в трее) и откройте снова либо запустите файл с `-RestartDiscord`, и он сделает это за вас.

Если всё в порядке, он так и скажет:

```
All Discord media hosts answer - the pins are fine, hosts left as is.
The bypass is up and the pins are fine - Discord is ready.
This file is not a Discord launcher: open Discord from its usual shortcut.
```

#### Хотите, чтобы обход проверялся при каждом запуске?

Запускать zapret можно двумя способами — выберите один:

| | Обычный запуск (`general.bat`, ярлык) | Этот файл |
|---|---|---|
| Время старта | мгновенно | 10–60 с: сначала проверка, потом Discord |
| Провайдер сменил DPI, конфиг перестал работать | картинки тихо отваливаются, узнаёте позже | сам перебирает конфиги, пока один не заработает |
| Адреса Cloudflare сменились | ничего не происходит, перепиннинг вручную | сразу перепроверяет и переписывает |
| Перезапуск Discord | нет | только если есть что подхватить: новые адреса, запущенный/сменённый обход или `-RestartDiscord` |

Итого: `general.bat` — быстрее, этот файл — надёжнее. Если картинки уже отваливались не раз, запускайте zapret этим файлом: в здоровый день он ничего не портит, просто проверяет и говорит, что всё в порядке.

> **VPN должен быть выключен.** С включённым VPN или туннелем (например, Happ в TUN-режиме) фикс не работает: трафик уходит через туннель, закреплённые адреса прямого подключения недоступны — картинки снова отвалятся. Выключите VPN или исключите `*.discordapp.net` из туннеля.

**Не хотите ничего копировать в сборку?** Держите файлы где угодно и укажите папку zapret:

```bat
fix-discord-media.bat -ZapretDir "C:\путь\к\zapret"
```

Скрипт ищет zapret только в своей папке, поэтому без этого аргумента он сборку не найдёт.

### Почему одного zapret не хватает

В части сетей эти хосты блокируются **по IP назначения**, а не по имени:

```
TCP 443 до 162.159.128.232        -> соединение есть
TLS с SNI media.discordapp.net    -> таймаут
TLS с SNI example.org             -> таймаут
TLS 1.2 / HTTP 1.1                -> таймаут
```

TCP-хендшейк проходит, а дальше соединение умирает с **любым** доменом и **любой** версией протокола. Значит блок не по SNI, и обход DPI (fake, split, multisplit) тут бессилен: и настоящий, и поддельный пакеты летят на заблокированный адрес. DNS и DoH тоже не спасают — резолверы отдают тот же мёртвый набор.

Работает только **другой адрес** того же CDN. Именно его и закрепляет скрипт, а zapret запускается первым: с работающим обходом отвечает гораздо большая часть диапазона Cloudflare, и есть из чего выбирать.

### Как пользоваться

| Действие | Как |
|---|---|
| Применить | двойной клик по **`fix-discord-media.bat`** |
| Посмотреть найденные конфиги zapret | `fix-discord-media.bat -ShowConfigs` |
| Посмотреть без изменений | `fix-discord-media.bat -DryRun` |
| Отменить | двойной клик по **`remove-pins.bat`** |

Права администратора `.bat` запрашивает сам. Полезные аргументы:

```bat
fix-discord-media.bat -ZapretDir "D:\zapret"              :: сборка лежит в другом месте
fix-discord-media.bat -Config "general (ALT11).bat"       :: только этот конфиг, без переключения
fix-discord-media.bat -MaxConfigs 5                       :: перебрать не все конфиги, а первые 5
fix-discord-media.bat -NoZapret                           :: только пиннинг, zapret не трогать
fix-discord-media.bat -Force -NoRestart                   :: прописать и не перезапускать Discord
fix-discord-media.bat -RestartDiscord                     :: перезапустить Discord, даже если ничего не менялось
fix-discord-media.bat -Remove -RestartDiscord             :: снять пиннинг и перезапустить Discord
fix-discord-media.bat -IgnoreVpn                          :: ответить «2» на вопрос про VPN из командной строки
```

`-Force` — перепроверить и перепрописать, даже если всё уже работает. Если `curl.exe` в системе нет, только с `-Force` скрипт пропишет известный список — и прямо предупредит, что проверить его не смог.

### Когда продолжать с включённым VPN точно не помешает

Если туннель несёт маршрут по умолчанию, скрипт останавливается и (при запуске через `.bat`) спрашивает, как поступить:

```
  1  Classic - stop here, turn the VPN off and run again   (default)
  2  With the VPN on - only if Discord bypasses this tunnel
```

Вариант 2 безвреден **только если туннель не несёт трафик к этим хостам**: split tunneling, где Discord исключён из туннеля, или VPN-клиент поднят, а маршрут по умолчанию всё равно идёт через физический адаптер. В этом случае остановка была ложной тревогой, и выбор ничего не меняет в результате.

Если туннель несёт всё, вариант 2 медиа не починит: закреплённые адреса внутри туннеля недоступны, и zapret там тоже не работает. Сломать он тоже ничего не может — если ни один адрес не ответил, `hosts` остаётся нетронутым и скрипт выходит с кодом `2` — но и помочь не поможет. Такой прогон прямо пишет, что всё измерено через туннель, и не делает вид, что знает, что блокирует провайдер.

`-IgnoreVpn` делает то же, что вариант 2, для скриптов и ярлыков; `-NoPrompt` убирает вопрос совсем.

### Выбор конфига

Выбирать руками ничего не нужно: скрипт запускает конфиг, который сработал в прошлый раз (или `general.bat`), и переходит к следующему только если через него медиа-хосты не отвечают — по всем конфигам в папке, пока один не заработает.

```
Configs to try: 12. Each check takes up to a minute,
so let it run - the one that works is remembered for next time.

Trying config 1 of 12: general.bat
Starting the bypass: general.bat
This one works - keeping it.
```

- Конфиг, который реально сработал, запоминается в `%LOCALAPPDATA%\discord-media-hosts-fix\last-config.txt` и в следующий раз пробуется первым.
- Порядок: запомненный конфиг, затем `general.bat`, затем остальные `general*`, затем все прочие. Пробуется **каждый** найденный конфиг по очереди, поэтому на большой сборке перебор может занять несколько минут — именно поэтому рабочий конфиг запоминается.
- `-MaxConfigs 5` останавливает перебор после пяти конфигов, если ждать не хочется.
- Перебор прекращается, если TCP 443 вообще не соединяется с CDN: это не лечится другой стратегией desync.
- `-Config "имя.bat"` — строго этот конфиг, без переключения.
- `-Prompt` — вернуть старое меню с номерами; `-ShowConfigs` — показать список и выйти.
- Если zapret уже запущен и медиа через него работает, его не трогают. `-RestartZapret` перезапускает принудительно. После смены конфига открытый Discord перезапускается, чтобы переподключиться через новый обход.
- zapret, установленный службой Windows, не трогается: перезапустите службу сами, если нужен другой конфиг.

### Где скрипт ищет zapret

Только в одном месте:

1. `-ZapretDir`, если он передан;
2. иначе папка самого скрипта.

Больше ничего не сканируется — ни родительская папка, ни `C:\zapret` / `D:\zapret`. Когда на машине несколько сборок, так всегда понятно, какая из них используется: та, где лежат три файла (или та, что указана вручную).

Папка считается сборкой zapret, если в ней есть `bin\winws.exe`, `winws.exe` или `service.bat`. Конфиг выбирается так: сработавший в прошлый раз, затем `general.bat`, затем любой `general*.bat`, затем остальные; пробуется каждый найденный (`-MaxConfigs N` ограничивает перебор). Служебные вроде `service.bat` пропускаются.

### Что именно меняется

Только этот блок в конце `C:\Windows\System32\drivers\etc\hosts`:

```
# >>> discord-media-pin (auto) >>>
162.159.141.232 media.discordapp.net
... 12 строк: 3 хоста x 4 адреса ...
# <<< discord-media-pin (auto) <<<
```

Перед каждой записью делается `hosts.bak-дата-время` (хранятся 5 последних), атрибут «только чтение» и кодировка файла сохраняются, повторный запуск заменяет блок, а не дублирует. Запись проверяется дважды: текст перечитывается, затем каждое привязанное имя запрашивается через `hosts`. Узел, который ответил `403`/`421` или не ответил вовсе, успехом не считается: скрипт называет имя и выходит с кодом `1`, чтобы «адреса обновлены» не означало «картинки по-прежнему битые».

Что скрипт **не** делает:

- не ставит службу, задачу в планировщике, автозапуск или фоновый процесс — после выхода из скрипта от него ничего не остаётся в памяти и в системе, поэтому сам по себе он никогда не перезапустит Discord, не перепишет адреса и не «сбросит» настройку;
- не трогает DNS, фаервол, прокси, маршруты и реестр, не меняет конфиги zapret и `service.bat`;
- не трогает антивирус: ни исключений, ни настроек, ни журналов, ни состояния защиты — скрипт смотрит только сертификат, который показывает сайт, и пишет то, что увидел. Состояние антивируса он намеренно не запрашивает (`SecurityCenter2`): на машине, где продукт уже удалён, такой запрос однажды вернул два «призрачных» Kaspersky — отчёт на его основе врал бы;
- не затрагивает другие сайты, имена в локальной сети и `cdn.discordapp.com`;
- не запускает Discord, если он был закрыт: клиент перезапускается не более одного раза за прогон и только если уже работал;
- не пишет ничего, кроме `hosts` (и его бэкапов) и `%LOCALAPPDATA%\discord-media-hosts-fix\last-config.txt`; последний читается только при следующем ручном запуске.

### Ограничения

- Адреса Cloudflare могут меняться — просто запустите файл ещё раз, он всё перепроверит.
- **Не работает при включённом VPN/TUN.** Адреса закреплены для прямого подключения через провайдера; внутри туннеля они недоступны, да и zapret с VPN не работает. Скрипт проверяет это сам: если default route идёт в туннель — выходит с кодом `3` и ничего не пишет, либо (при запуске через `.bat`) предлагает выбор: классический запуск или продолжение с VPN. Второй вариант безвреден только если туннель не несёт трафик к этим хостам — [Когда продолжать с включённым VPN точно не помешает](#когда-продолжать-с-включённым-vpn-точно-не-помешает). Туннель, который просто поднят, но трафик через него не идёт (split tunneling), не мешает — будет только пометка в консоли.
- Если сеть режет весь диапазон, `hosts` не спасёт: нужен туннель или прокси для Discord.
- Если блок по имени, а не по адресу, пины тоже не лекарство: нужен другой конфиг zapret или туннель. Скрипт различает эти случаи и говорит, какой именно у вас.
- Если режут только порт 443 (Cloudflare отвечает ещё на 2053, 2083, 2087 и 2096), помочь может локальный редирект `127.0.0.1:443 -> <адрес>:2053` — но это фоновый инструмент, а не этот одноразовый фикс. Скрипт прямо говорит, когда у вас именно такой случай.
- Это не VPN и не сокрытие трафика, а локальная таблица адресов.
- Закрепляются IPv4-адреса.

### Если не сработало

- **«then was unexpected at this time» и ничего не запускается (код `255`)** — это сломанный вход 1.10.0: незаэкранированная скобка в `fix-discord-media.bat` закрывала блок cmd, и cmd отвергал весь файл ещё до запуска. В 1.10.1 это исправлено. Скачайте текущий релиз и замените три файла; с машиной, папкой zapret и `.ps1` всё в порядке.
- **«VPN is on: … Nothing was changed.» (код выхода `3`)** — VPN несёт весь трафик, закреплённые адреса недоступны. При запуске через `.bat` скрипт не просто останавливается, а предлагает выбор: классический запуск (выключить VPN и запустить снова) или продолжить с включённым VPN. Второй вариант выбирайте только если точно знаете, что Discord в туннель не попадает — см. [Когда продолжать с включённым VPN точно не помешает](#когда-продолжать-с-включённым-vpn-точно-не-помешает). `-IgnoreVpn` отвечает на этот вопрос из командной строки.
- **«No address answered»** — дальше одно из объяснений:
  - *«discord.com fails too»* — обход вообще не берёт этот DPI, поэтому и медиа-хосты падают по той же причине. Все конфиги в папке скрипт уже перебрал; дальше — свежая сборка zapret (затем запустите файл снова, он переберёт всё заново) либо туннель/прокси для Discord.
  - *«every connection to media.discordapp.net is cut off»* — сам Discord через обход грузится, режут только медиа-хосты по имени. Сменой адресов это тоже не лечится: те же шаги — свежая сборка zapret, затем туннель/прокси.
  - *«Port 2053 answers for … but port 443 does not»* — режут только порт, не адрес и не имя. Локальный редирект `127.0.0.1:443 -> <адрес>:2053` сохраняет валидный TLS и может вернуть картинки, но для него нужен небольшой фоновый инструмент. Этот одноразовый фикс такое намеренно не устанавливает: пока — прокси или туннель.
  - *«Port 443 accepts TCP, but the TLS handshake is killed»* — блок по имени: ни другой порт, ни другой адрес не помогут. Нужен другой конфиг zapret либо туннель/прокси.
  - *«The machine refused the connection itself»* — соединение отвергает сама машина: локальный файрвол или антивирус блокирует `curl.exe` или порт. Разрешите `curl.exe` и PowerShell в файрволе, посмотрите лог антивируса и запустите файл снова.
  - *«None of them accepted a connection at all»* — режут сами адреса (или душат так, что соединение не встаёт). Конфиги не помогут: нужен туннель только для Discord (VPN со split tunneling) или прокси.
  Если какая-то локальная защита расшифровывает HTTPS, скрипт называет её: строка *«HTTPS here is signed by CN=Kaspersky Anti-Virus Personal Root Certificate»* означает, что соединение вскрывает антивирус, и его же сертификат может ломать рукопожатие с медиа-хостами. Выключите его HTTPS-сканирование на один тест — сменой адреса это не лечится.
  Во всех случаях `hosts` намеренно не меняется: мёртвые адреса не пишутся. Техническая деталь осталась в серой строке `Details:` — её удобно приложить, если сообщаете о проблеме.
- **«curl.exe was not found»** — проверить адреса нечем, поэтому ничего не пишется и скрипт выходит с кодом `2` (`curl.exe` есть в Windows 10 1803+ и Windows 11; его может скрывать защита). Обновите Windows, разрешите `curl.exe` либо запустите с `-Force`, понимая, что список не проверен.
- **«The address list disappeared right after it was written»** — что-то защищает `hosts` и вернуло файл обратно (антивирус или Defender *Controlled folder access*). Так фикс не удержится: разрешите изменение и запустите снова. Код выхода `1`.
- **«The addresses are in hosts, but the names do not answer through them»** — блок записан, но узлы за этими адресами не обслуживают медиа-хост Discord: `403`/`421` значит «узел ответил и отказал имени», «no answer» — «не ответил вовсе». Блок остаётся в `hosts` (снять — `remove-pins.bat`), но прогон успехом не считается и выходит с кодом `1`: картинки были бы битыми. Запустите файл ещё раз — адреса меняются; если повторяется, значит записанные адреса не на пути: проверьте, что VPN выключен и обход запущен.
- **«fix-discord-media.ps1 is missing next to this file»** — архив распаковали без него или антивирус унёс скрипт в карантин после распаковки. Восстановите файл из карантина (или распакуйте архив заново) и запустите `.bat` снова: один `.bat` ничего не сделает.
- **«winws.exe did not appear … The file itself is gone»** — антивирус удалил бинарник. Восстановите бандл zapret или разрешите его папку, затем запустите снова. Если `winws.exe` на месте, а обход так и не стартует, антивирус может блокировать драйвер WinDivert, который тот загружает. Напрямую скрипт этого не видит: он видит только, что `winws.exe` не появился или что соединения отвергаются. Посмотрите в логе антивируса блокировку драйвера, разрешите её и запустите файл снова.
- **«All Discord media hosts answer — the pins are fine, hosts left as is»** — скрипт проверил все три хоста через работающий обход, каждый ответил, поэтому `hosts` он намеренно не трогал. Это нормальное состояние при втором и последующих запусках. Если в Discord картинки всё равно битые — закройте его полностью (включая иконку в трее) и откройте снова: работающий клиент держит старые адреса до перезапуска. Перепроверить и перепинить принудительно — запуск с `-Force`. При включённом VPN эта проверка тоже может пройти, хотя Discord будет ломаться. Если клиент открыт, скрипт теперь называет его и предлагает `-RestartDiscord` — перезапустит сам.
- **«Could not write hosts»** — чаще всего Defender *Controlled folder access*: разрешите изменение на минуту.
- **Блок записался, но картинок нет** — полностью закройте Discord (включая иконку в трее) и откройте снова либо запустите файл с `-RestartDiscord`.

### Версии и релизы

Проект версионируется по-настоящему.

- Версия по **Semantic Versioning** (`MAJOR.MINOR.PATCH`) хранится в одном месте — `$AppVersion` в начале `fix-discord-media.ps1`. Показать её: `fix-discord-media.bat -Version`.
- Все изменения записываются в [CHANGELOG.md](CHANGELOG.md) в разделах «Добавлено / Изменено / Исправлено / Удалено».
- Каждый релиз — тег `v<версия>`. Архив собирается из этого тега и в git не коммитится: `dist/` и имена zip перечислены в `.gitignore`.
- Опубликованный релиз не переписывается. Если он оказался сломан, его страница сохраняет файлы и получает предупреждение сверху, а исправление выходит патч-релизом и становится последним.
- `build-release.ps1` создаёт `dist/discord-media-hosts-fix.zip`, `dist/SHA256SUMS` и `dist/release-notes.md` (секция из CHANGELOG). Скрипт проверяет синтаксис PowerShell, отказывается собирать при несовпадении тега с `$AppVersion`, требует, чтобы README и CHANGELOG называли эту версию, приводит переводы строк к CRLF и фиксирует timestamps в zip — один и тот же коммит, собранный одним и тем же Windows PowerShell, даёт байт-в-байт одинаковый архив. Оба workflow выполняют шаги сборки под Windows PowerShell — тем же рантаймом, что и команда выше.
- Пуш тега запускает [`.github/workflows/release.yml`](.github/workflows/release.yml): сборка из отмеченного коммита этим же скриптом, создание GitHub-релиза с заметками из CHANGELOG и прикрепление архива вместе с `SHA256SUMS`. Вручную zip загружать не нужно, старый файл прикрепить невозможно.
- [`.github/workflows/ci.yml`](.github/workflows/ci.yml) работает на каждый пуш в `main` и на пул-реквесты: собирает архив и прогоняет тесты из [`tests/fix-discord-media.tests.ps1`](tests/fix-discord-media.tests.ps1). Тесты гоняют настоящий скрипт на временных `hosts`-файлах, подменяя сеть, клиент Discord и права администратора, и покрывают ветку «пины в порядке», причины перезапуска, `-Remove`, остановку при VPN, BOM и read-only `hosts`, идемпотентность, бэкапы и dry-run. Настоящие входные `.bat` запускаются через `cmd` (путь `-Version` и путь без `.ps1`), поэтому ошибка разбора во входе валит набор. Локально: `powershell -ExecutionPolicy Bypass -File .\tests\fix-discord-media.tests.ps1`.
- Порядок выпуска: поднять `$AppVersion` → обновить строку версии в README → добавить запись в CHANGELOG → коммит → тег `v<версия>` → пуш тега.
- Запасной путь: `powershell -ExecutionPolicy Bypass -File .\build-release.ps1 -Tag v<версия>`, затем загрузить `dist/discord-media-hosts-fix.zip` и `dist/SHA256SUMS` в релиз.

Текущий релиз — **v1.10.1**.

Версия 1.10.0 не запускалась: незаэкранированная `)` в сообщении об отсутствующем `.ps1` закрывала блок `.bat`, и cmd отвергал весь файл (`then was unexpected at this time`). Если у вас 1.10.0 — замените её на 1.10.1. Страница 1.10.0 остаётся со своим архивом и предупреждением сверху; 1.10.1 — отдельный релиз, а не перезаливка.
