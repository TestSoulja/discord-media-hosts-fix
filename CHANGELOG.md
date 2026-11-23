# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html):
`MAJOR.MINOR.PATCH`.

- **MAJOR** — a change that breaks an existing setup or command line.
- **MINOR** — new behavior or options, backwards compatible.
- **PATCH** — fixes and documentation only, no behavior change.

Every release is a git tag `v<version>` (for example `v1.3.0`), and the release
archive `discord-media-fix.zip` always contains exactly the three working files:
`fix-discord-media.bat`, `fix-discord-media.ps1`, `remove-pins.bat`.

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
