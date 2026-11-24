# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html):
`MAJOR.MINOR.PATCH`.

- **MAJOR** — a change that breaks an existing setup or command line.
- **MINOR** — new behavior or options, backwards compatible.
- **PATCH** — fixes and documentation only, no behavior change.

Every release is a git tag `v<version>` (for example `v1.3.0`), and the release
archive `discord-media-hosts-fix.zip` (`discord-media-fix.zip` before 1.7.1)
always contains exactly the three working files:
`fix-discord-media.bat`, `fix-discord-media.ps1`, `remove-pins.bat`.
The workflow builds it with the same Windows PowerShell as the documented local
command, so the released archive is byte-identical to a local rebuild.

## [1.8.1] - 2026-11-24

### Added

- The closing output now states that nothing stays running: no service, no
  scheduled task, no autostart. The script is a one-shot run, and after it
  returns nothing of it remains in memory or on the startup path.
- The synopsis and the README say the same up front, next to what the run
  changes on the machine.
- The test suite now fails if a persistence mechanism (`schtasks`,
  `Register-ScheduledTask`, `CurrentVersion\Run`, `Startup`, `New-Service`,
  background jobs, `WScript.Shell`) appears in any shipped file, so this
  guarantee cannot be lost silently later.
- The test suite also checks the closing note and derives the expected version
  from `$AppVersion`, then asserts that README and CHANGELOG name that version.

### Changed

- No behavior change: the same fixes, options and files. Only the reassurance
  and the tests around it are new.

## [1.8.0] - 2026-11-24

### Added

- `build-release.ps1` builds the release archive reproducibly (CRLF, fixed zip
  timestamps) together with `SHA256SUMS` and release notes taken from this
  changelog; the same commit built with the same Windows PowerShell gives the
  same bytes. It refuses a tag that does not match `$AppVersion`, and stops on a
  PowerShell syntax error or a stale README/CHANGELOG version.
- `.github/workflows/release.yml` publishes a pushed `v*` tag: it builds from
  the tagged commit with that script and attaches the archive and `SHA256SUMS`
  to the GitHub release, so a release cannot be published without its files.
- `tests/fix-discord-media.tests.ps1` — a test suite that drives the real script
  against temporary `hosts` files with the network, the Discord client and admin
  rights stubbed out: 48 checks over the pins-fine branch, restart reasons,
  `-Remove`, VPN stop, BOM and read-only `hosts`, idempotency, backups and dry
  runs. `.github/workflows/ci.yml` runs it with a build on every push to `main`
  and on pull requests.
- **`-RestartDiscord`** — restart the Discord client even when nothing changed.
  Useful when a client has been open for a long time and keeps stale CDN
  connections; a client that is not running is still never launched. It also
  restarts after `-Remove`, where before the flag was silently ignored.
- The client is now also restarted when the bypass was started or replaced
  during the run while Discord was already open. Before, that happened only
  after `hosts` was rewritten, so the config sweep could leave an open client
  on connections that predate the new bypass.

### Changed

- Release artifacts are no longer left as untracked files: `dist/` and the
  archive names are listed in `.gitignore`. The archive is built, never
  committed.
- The "pins are fine, hosts left as is" path now says out loud when Discord is
  running and will keep its old addresses until restarted, instead of a generic
  hint at the end. It names the running client and suggests `-RestartDiscord`
  (or a full close, including the tray icon).
- `-NoRestart` and `-RestartDiscord` together are rejected before anything is
  changed, with exit code `1`.

## [1.7.1] - 2026-11-23

### Changed

- **The project is now `discord-media-hosts-fix`** - the GitHub repository, the
  README title, the console banner and the release archive. The name now states
  what the fix actually is: reachable addresses for the Discord media hosts,
  pinned in `hosts`. The problem it repairs stays the same: the CDN is blocked by
  destination address, so only a different address gets through.
- The download link printed by the `.bat` files and every repository link in the
  README point at the new name; the archive is now
  `discord-media-hosts-fix.zip`. Old `github.com/TestSoulja/discord-media-fix`
  links keep working through GitHub's redirect - do not create a new repository
  under the old name, or the redirect stops.
- The remembered zapret config lives in
  `%LOCALAPPDATA%\discord-media-hosts-fix\last-config.txt`. The old file is not
  read, so the first run after the update picks a config again; no other effect.

### Not changed on purpose

- File names (`fix-discord-media.bat`, `fix-discord-media.ps1`,
  `remove-pins.bat`), every option and the hosts marker
  `# >>> discord-media-pin (auto) >>>` stay as they were. Existing shortcuts
  keep working, a block pinned by an older version is still recognised and
  removed, and nothing has to be reinstalled or re-pinned.

### Fixed

- README (EN/RU) still showed `v1.6.1` after the 1.7.0 release; it now shows the
  current version.

## [1.7.0] - 2026-11-23

### Changed

- **The zapret folder is no longer guessed.** The script uses the folder it
  lives in, and `-ZapretDir` for every other case. The extra candidates - the
  parent folder and `%USERPROFILE%\zapret`, `C:\zapret`, `D:\zapret`, `C:\dis`,
  `D:\dis` - are gone. On a machine with several zapret copies the old search
  could pick the wrong one and then never start the bypass: it reported
  `No config (.bat) found in the zapret folder` and continued without zapret,
  while the real bundle sat in another folder that was not in the list.
- The console now names the folder it looked in and says the two ways to fix
  it: copy the three files into the zapret bundle, or pass `-ZapretDir`.
- README (EN/RU) drops the "auto-detected in the usual places" wording and the
  three-step search order; it states the single rule and when `-ZapretDir` is
  required.

## [1.6.1] - 2026-11-23

### Changed

- License notice travels with the shipped copies: every file in the archive
  (`fix-discord-media.bat`, `fix-discord-media.ps1`, `remove-pins.bat`) now
  carries `License: MIT, Copyright (c) 2026 TestSoulja` in its header, as the
  MIT terms require for copies. Comments only - no behavior change, no fourth
  file in the archive.

## [1.6.0] - 2026-11-23

### Added

- **Every config is tried, not just the first five.** When the media hosts still
  do not answer, the sweep now goes through the whole zapret folder: the
  remembered config, `general.bat`, every other `general*`, then the rest. The
  winner is remembered, so the full sweep is paid only once.
- `-MaxConfigs N` bounds the sweep for people who would rather not wait; the
  default is all configs. `-Config` still pins exactly one.
- The console says how many configs are queued, and after an exhausted sweep
  says so honestly ("All 12 configs were tried") and changes the next-step hint
  to "update zapret to a newer build", since there is no untried config left.

### Changed

- README (EN/RU) documents the full sweep, the time it can take and
  `-MaxConfigs`, instead of promising "up to 5".

## [1.5.1] - 2026-11-23

### Changed

- The closing lines now offer the second way to start zapret: run this file
  every day and the bypass is checked each time - config switching and
  re-pinning happen on their own, at the cost of a slower start. The README
  (EN/RU) compares both options side by side instead of deciding for the user.
- That note is only text: the script's behaviour is unchanged.

## [1.5.0] - 2026-11-23

### Added

- **Control probe for `discord.com`** next to the media probe. Two failures that
  used to look identical are now separated: "Discord works through the bypass,
  only the media hosts are cut off" (block by name) and "Discord does not load
  through the bypass at all" (this config is not beating the DPI). The verdict
  and the `Details:` line name the real culprit.
- `dns` handling: when `discord.com` does not resolve, the control probe is
  ignored instead of producing a false conclusion.

## [1.4.0] - 2026-11-23

### Added

- **VPN / TUN check before anything is changed.** If the default route goes
  through a tunnel, the script stops with exit code `3`, leaves `hosts`
  untouched and explains that the pinned addresses are unreachable that way;
  `-IgnoreVpn` continues anyway. A tunnel adapter that is up but does not carry
  the default route only gets a note, so split tunneling stays usable.
- **Automatic config fallback.** When the started config does not get the media
  hosts through, the bypass is restarted with the next config (up to 5,
  `general.bat` first) and the config that worked is remembered.
- **Failure diagnosis** from a raw TCP 443 probe: "blocked by name" (TCP
  connects, TLS dies) is now clearly separated from "the addresses themselves
  are dropped" (TCP never connects), so the advice matches the real block.
- `-IgnoreVpn`.

### Changed

- No questions in the normal run: the config menu is gone by default. `-Prompt`
  brings it back, `-Config` pins one config and disables the switching.
- The bypass is restarted when it is running but media does not answer through
  it; a working bypass is still left alone unless `-RestartZapret` is passed.
- A zapret installed as a Windows service is never killed and replaced.
- Timeouts are longer (`8 s`, then a slow retry with `12 s`) and the first probe
  waits until WinDivert has attached.
- "No address answered" is no longer blamed on the whole Cloudflare range.
- Console messages are written in plain language. The technical fact (which
  check failed, on which address) moved to a gray `Details:` line instead of
  being the headline, so support reports keep the same information.

### Fixed

- False "no answer" for every address on throttled networks: the old 5 s
  timeout, no retry and probes fired before the bypass was filtering.
- Misleading advice in the failure path.

## [1.3.2] - 2026-11-23

### Changed

- The README now opens with a plain one-time-fix note: run it once, then keep
  starting zapret with `general.bat` (or the usual shortcut) and open Discord
  normally. It is not a Discord launcher and not an everyday step.
- The console says the same in its first line.

## [1.3.1] - 2026-11-23

### Fixed

- Corrected the everyday-use guidance: after the first run the pins persist in
  `hosts`, so it is enough to start zapret with `general.bat` (or the usual
  shortcut) and open Discord normally. The script is needed again only when
  images break, not on every boot.

### Changed

- The closing summary no longer tells users to replace their usual zapret
  launcher. It now explains that the pins survive reboots and that the file is
  a repair tool to re-run when media breaks.

## [1.3.0] - 2026-11-23

### Fixed

- Running the file a second time did not start the zapret bypass: a healthy
  address check exited before the bypass was brought up. The bypass is now
  started first, on every run, and the check only decides whether `hosts` needs
  to be rewritten.
- Comma-separated list arguments (`-Hosts a,b,c`) are split correctly when the
  script is started through the `.bat` with `-File`.

### Changed

- The console now says plainly that this file starts the zapret bypass and that
  Discord is opened separately, from its usual shortcut.
- When everything already works, the summary is explicit: the pins are fine,
  the bypass is up, Discord is ready — instead of a terse "nothing to do".

### Added

- `-Version` prints the script version without touching anything or asking for
  administrator rights.
- The version is shown in the console banner.

## [1.2.0] - 2026-11-23

### Changed

- The release archive contains only the three working files. `README.md` and
  `LICENSE` live in the repository only, so unpacking the archive into a zapret
  folder never asks about replacing documentation files.
- README quick start now states that the archive holds only the three files.

## [1.1.0] - 2026-11-23

### Added

- README: what to do every day (start zapret with this file, open Discord as
  usual) and a warning that the fix does not work while a VPN or TUN tunnel is
  on.
- A red "do not close the minimized zapret window" warning right after
  `winws.exe` starts and at the end of the run.
- The `.bat` refuses to run with a clear message and a download link when
  `fix-discord-media.ps1` is missing next to it.

## [1.0.0] - 2026-11-23

### Added

- Automatic discovery of the zapret folder and its configs.
- Interactive numbered config picker with the last choice remembered in
  `%LOCALAPPDATA%\discord-media-fix\last-config.txt`.
- Probing of Cloudflare addresses for the Discord media CDN and pinning the
  ones that answer into a marked `hosts` block.
- Discord restart after the pins change.
- `-Remove` / `remove-pins.bat` to undo, `-DryRun`, `-Force`, `-NoZapret`,
  `-NoRestart`, `-RestartZapret`, `-ShowConfigs`.
