# Discord media fix for Windows (zapret + hosts)

One-click fix for the situation when you already run **zapret** (DPI bypass), but Discord still **does not load images** — "Failed to load image", empty avatars, no stickers, emoji or attachments, while text and voice work normally.

The script checks that no VPN is carrying the traffic, starts your zapret config if it is not running, restarts it with the next config if media still does not answer, probes Cloudflare addresses that serve the Discord media CDN, keeps the ones that actually answer, pins them in the Windows `hosts` file inside a marked block, and restarts Discord.

> **This is a one-time fix.** Run it once and you are done. After that, start zapret the way you always did — `general.bat`, `service.bat` or your shortcut — and open Discord normally. Run this file again only if images break again. It is **not** a Discord launcher and **not** an everyday step. The full explanation is in [Everyday use](#everyday-use--this-file-is-not-a-discord-launcher).

**Version 1.4.0** · [Changelog](CHANGELOG.md) · [Releases](https://github.com/TestSoulja/discord-media-fix/releases)

* [Русское описание — ниже](#русский)

---

## Quick start

**Easiest way:** open the [Releases page](https://github.com/TestSoulja/discord-media-fix/releases/latest), download `discord-media-fix.zip`, unpack it — and go to step 2. The archive contains only the three files below, so copying them into your bundle overwrites nothing.

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

If it does run with everything healthy, it says so:

```
All Discord media hosts answer - the pins are fine, hosts left as is.
The bypass is up and the pins are fine - Discord is ready.
This file is not a Discord launcher: open Discord from its usual shortcut.
```

> **A VPN must be off for Discord.** The fix does not work while a VPN or a TUN-mode tunnel (for example Happ) is active: traffic leaves through the tunnel and the pinned direct addresses are not reachable, so images break again. Turn the VPN off, or exclude `*.discordapp.net` from the tunnel.

**Don't want to copy anything into the bundle?** Keep the files in any folder and run:

```bat
fix-discord-media.bat -ZapretDir "C:\path\to\zapret"
```

The folder is auto-detected in the usual places, so on most machines this is not needed.

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

1. Refuses to run while a VPN or TUN tunnel carries the default route (exit code `3`): pinned addresses are not reachable through a tunnel, so nothing would be fixed.
2. Finds your zapret folder and your configs (`general.bat`, `general (ALT11).bat`, …).
3. Starts the remembered config (or `general.bat`), waits for `winws.exe`, then waits a few seconds so WinDivert really attaches before the first probe.
4. Checks four seed addresses of `media.discordapp.net` through the bypass. If they answer, that config stays.
5. If they do not, stops the bypass and starts the next config (up to 5) and checks again. When even TCP 443 does not connect, no desync can help and the switching stops.
6. Checks the three Discord media hosts. If all answer, `hosts` is left alone — that is the normal second and later run.
7. Otherwise probes Cloudflare edge addresses: 8 fast tries, then 4 slow retries with a longer timeout, keeping up to 4 that answer.
8. Writes them into `hosts`, once per hostname — 12 lines in a marked block.
9. Flushes the DNS cache and restarts the Discord client that was running (Stable / PTB / Canary / Development).

If no address answers, nothing is written and the script exits with code `2` — after saying which block it is: by name (TCP connects, TLS dies) or by address (TCP 443 never connects). It never pins a dead address, and it never edits zapret's configs, lists or `service.bat`. A zapret installed as a Windows service is never killed and replaced.

## Requirements

- A zapret bundle (for example the Flowseal / `zapret-discord-youtube` style build) with `winws.exe` in `bin\` or in the root
- Windows 10 1803+ or Windows 11, Windows PowerShell 5.1 (built in)
- `curl.exe` (built into Windows since 1803; if missing, a known-good address list is used)
- Administrator rights — the `.bat` asks for them itself

## Usage

| Action | How |
|---|---|
| Apply the fix | double-click **`fix-discord-media.bat`** |
| List detected zapret configs | `fix-discord-media.bat -ShowConfigs` |
| Preview without changing anything | `fix-discord-media.bat -DryRun` |
| Undo | double-click **`remove-pins.bat`** |

Options (pass them through the `.bat` or call the `.ps1` from an elevated PowerShell):

| Option | Meaning |
|---|---|
| `-Remove` | delete the pin block and exit |
| `-Force` | re-probe and re-pin even if everything already works |
| `-DryRun` | print the resulting `hosts`, change nothing |
| `-NoRestart` | do not touch the Discord client |
| `-NoZapret` | do not look for or start zapret, only pin hosts |
| `-IgnoreVpn` | continue even when a VPN carries the default route |
| `-ZapretDir <path>` | zapret folder (auto-detected when omitted) |
| `-Config <name>` | use only this config, no automatic switching, for example `"general (ALT11).bat"` |
| `-RestartZapret` | restart the bypass even if it already answers |
| `-ShowConfigs` | list configs found in the zapret folder and exit |
| `-Prompt` | show the config menu instead of choosing automatically |
| `-NoPrompt` | never ask (automatic is already the default) |
| `-HostsFile <path>` | alternate `hosts` file (for testing) |
| `-Hosts <name...>` | hostnames to pin (default: the three Discord media hosts) |
| `-ExtraIPs <ip...>` | additional candidate addresses to probe first |
| `-Version` | print the script version and exit (no admin rights needed) |

Typical cases:

```bat
:: the bundle sits somewhere unusual
fix-discord-media.bat -ZapretDir "D:\zapret"

:: you normally run a specific alternative config
fix-discord-media.bat -Config "general (ALT11).bat"

:: pin only, without touching zapret
fix-discord-media.bat -NoZapret
```

## Choosing the config

Nothing to choose by hand: the script starts the config that worked last time, or `general.bat`, and moves on to the next config only if the media hosts still do not answer through it.

```
Config 1/5: general.bat
Starting the bypass: general.bat
This config works - keeping it.
```

- The config that actually worked is remembered in `%LOCALAPPDATA%\discord-media-fix\last-config.txt` and is tried first next time.
- Order: the remembered config, then `general.bat`, then other `general*` configs, then the rest. Up to 5 are tried.
- Switching stops early when TCP 443 does not connect to the CDN at all: that is not something another desync strategy can fix.
- `-Config "name.bat"` uses exactly that config and disables switching.
- `-Prompt` brings the old numbered menu back; `-ShowConfigs` prints the list and exits.
- If zapret is already running and media answers through it, it is left alone. `-RestartZapret` restarts it anyway.
- A zapret installed as a Windows service is not touched: restart the service yourself if you want another config.

## Where it looks for zapret

In this order, first match wins:

1. `-ZapretDir`, if you passed it;
2. the folder where this script lives;
3. its parent folder;
4. `%USERPROFILE%\zapret`, `C:\zapret`, `D:\zapret`, `C:\dis`, `D:\dis`.

A folder counts as a zapret folder when it contains `bin\winws.exe`, `winws.exe` or `service.bat`. Configs are picked as: the one that worked last time, then `general.bat`, then any `general*.bat`, then the rest; up to 5 are tried. `service.bat`, installers and helper scripts are skipped.

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
- no changes to DNS settings, firewall, proxy, routing or the registry;
- zapret itself is not modified — the script only starts the config you already have;
- other sites, LAN names and `cdn.discordapp.com` are not affected.

## Limitations

- The addresses are Cloudflare anycast IPs and can rotate. If media breaks again months later, run the script again — it re-probes.
- **Does not work with a VPN or TUN tunnel enabled.** The pinned addresses are reached directly through your ISP; inside a tunnel they are not available, and zapret itself also does not work through a VPN. The script checks this itself: if the default route goes through a tunnel it stops with exit code `3` and writes nothing. A tunnel that is up but does not carry the default route (split tunneling) is fine and only gets a note. `-IgnoreVpn` forces a run.
- If the block covers every address in the range, no `hosts` entry can help: this method is done, use a tunnel or a proxy for Discord instead.
- If the block is by name (not by address), the pins are not the cure either — another zapret config or a tunnel is. The script tells these two cases apart and says which one you hit.
- The fix is per hostname and per machine. It is not a VPN and does not hide traffic.
- IPv6-only networks that resolve the CDN over IPv6 are out of scope: the block pins IPv4 addresses.

## Troubleshooting

**"All Discord media hosts answer — the pins are fine, hosts left as is"** — the script checked all three hosts through the running bypass and each one responded, so it left `hosts` alone on purpose. That is the normal state on the second and later runs. If Discord still shows broken images, close it completely (tray icon too) and open it again: a running client keeps its old addresses until restart. To re-probe and re-pin anyway, run with `-Force`. With a VPN on, this check can also pass while Discord still fails.

**"VPN is on: … Nothing was changed." (exit code `3`)** — the VPN carries all traffic, so the fixed addresses are unreachable. Turn the VPN off and run the file again, send only Discord through the tunnel (split tunneling), or pass `-IgnoreVpn` if you know the tunnel does not carry Discord traffic.

**"No address answered"** — followed by one of two explanations:

- *"every secure connection to media.discordapp.net is cut off"* — the block is by name: DPI kills the handshake whatever the address. Changing addresses cannot fix it. Try other zapret configs (`-ShowConfigs`, then `-Config "general (ALT...).bat"`); if none work, the way out is a tunnel or a proxy for Discord.
- *"None of them accepted a connection at all"* — the addresses themselves are dropped or slowed to a standstill. No config helps either; the way out is a tunnel for Discord only (VPN with split tunneling) or a proxy.

In both cases `hosts` is left unchanged on purpose: no dead address is pinned. The gray `Details:` line keeps the technical fact, useful when you report the problem.

**"Could not write hosts"** — usually Microsoft Defender *Controlled folder access*. Allow the change for a minute, or add `powershell.exe` as an allowed app.

**The block was written but images still fail** — close Discord completely (tray icon too) and open it again; a running client only re-resolves hostnames on restart.

**zapret is already running under a different config** — if media answers through it, it is left alone; if not, the script restarts it with the next config. `-RestartZapret` forces a restart, `-Config` pins one config.

## Versioning and releases

This is a versioned project, not a loose set of scripts.

- The version follows **Semantic Versioning** (`MAJOR.MINOR.PATCH`) and lives in one place: `$AppVersion` at the top of `fix-discord-media.ps1`. Run `fix-discord-media.bat -Version` to print it.
- Every change is written down in [CHANGELOG.md](CHANGELOG.md) under `Added` / `Changed` / `Fixed` / `Removed`.
- Every release is a git tag `v<version>` and a GitHub release whose `discord-media-fix.zip` contains exactly the three working files.
- Release checklist: bump `$AppVersion` → add a CHANGELOG entry → commit → tag `v<version>` → publish the release with the archive.

The current release is **v1.4.0**.

## License

MIT. Do whatever you want, no warranty. See [LICENSE](LICENSE).

---

## Русский

Однокликовый фикс для случая, когда **zapret уже запущен, а картинки в Discord всё равно не грузятся** — «Не удалось загрузить изображение», пустые аватарки, нет стикеров, эмодзи и вложений, при этом текст и голос работают.

Скрипт проверяет, что трафик не уходит в VPN, поднимает ваш конфиг zapret (если `winws.exe` не запущен), при необходимости сам перезапускает его со следующим конфигом, проверяет адреса Cloudflare, которые обслуживают медиа-CDN Discord, оставляет только те, что реально отвечают, и прописывает их в `hosts` Windows — в отдельном помеченном блоке. Потом перезапускает Discord.

> **Это одноразовый фикс.** Запустить нужно один раз — и всё. Дальше запускайте zapret как раньше (`general.bat`, `service.bat` или ярлык) и открывайте Discord как обычно. Этот файл нужен снова только если картинки опять отвалились. Он **не** запускает Discord и **не** является ежедневным шагом. Подробнее — ниже, в разделе «Каждый день».

### Быстрый старт

**Проще всего:** откройте [страницу релизов](https://github.com/TestSoulja/discord-media-fix/releases/latest), скачайте `discord-media-fix.zip`, распакуйте — и переходите к пункту 2. В архиве только три нужных файла, так что при копировании в сборку ничего не перезапишется.

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
2. Подождите 10–60 секунд: скрипт запустит zapret, проверит медиа-CDN и сам переключится на другой конфиг, если через первый ничего не проходит. Вопросов не задаёт.
3. Discord перезапустится сам, если пины изменились. Картинки загрузятся.

**Это и была одноразовая часть.** Закреплённые адреса остаются в `hosts` после перезагрузок. Дальше запускайте zapret как раньше — `general.bat`, `service.bat` или ярлыком — и открывайте Discord как обычно. Этот файл нужен снова только если картинки опять отвалились: он заново проверит адреса и перепишет блок. Свёрнутое окно zapret не закрывайте: закрыли — обход выключился.

Если включён VPN, скрипт остановится до любых изменений и объяснит почему: через туннель закреплённые адреса недоступны. Выключите VPN или исключите `*.discordapp.net` из туннеля.

### Каждый день — этот файл не запускает Discord

`fix-discord-media.bat` запускает **обход zapret**, а не Discord, и **не обязателен каждый день**. Сам Discord открывается как обычно — ярлыком или из трея.

После первого запуска адреса лежат в `hosts`: они переживают перезагрузку и работают при любом способе запуска zapret. Поэтому привычный порядок не меняется:

1. Запускаете zapret как раньше (`general.bat`, `service.bat` или ярлык).
2. Открываете Discord как обычно.

`fix-discord-media.bat` нужен снова только если картинки опять отвалились (адреса Cloudflare сменились) — он заново проверит и перепишет `hosts`. Запускать его каждый день тоже можно, вреда нет: поднимет обход, если тот не запущен, увидит, что пины живы, и ничего не изменит.

Если всё в порядке, он так и скажет:

```
All Discord media hosts answer - the pins are fine, hosts left as is.
The bypass is up and the pins are fine - Discord is ready.
This file is not a Discord launcher: open Discord from its usual shortcut.
```

> **VPN должен быть выключен.** С включённым VPN или туннелем (например, Happ в TUN-режиме) фикс не работает: трафик уходит через туннель, закреплённые адреса прямого подключения недоступны — картинки снова отвалятся. Выключите VPN или исключите `*.discordapp.net` из туннеля.

**Не хотите ничего копировать в сборку?** Держите файлы где угодно и запускайте:

```bat
fix-discord-media.bat -ZapretDir "C:\путь\к\zapret"
```

В обычных местах папка находится сама, так что на большинстве машин этот аргумент не нужен.

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
fix-discord-media.bat -NoZapret                           :: только пиннинг, zapret не трогать
fix-discord-media.bat -Force -NoRestart                   :: прописать и не перезапускать Discord
fix-discord-media.bat -IgnoreVpn                          :: запустить даже при активном VPN
```

### Выбор конфига

Выбирать руками ничего не нужно: скрипт запускает конфиг, который сработал в прошлый раз (или `general.bat`), и переходит к следующему только если через него медиа-хосты не отвечают.

```
Config 1/5: general.bat
Starting the bypass: general.bat
This config works - keeping it.
```

- Конфиг, который реально сработал, запоминается в `%LOCALAPPDATA%\discord-media-fix\last-config.txt` и в следующий раз пробуется первым.
- Порядок: запомненный конфиг, затем `general.bat`, затем остальные `general*`, затем все прочие. Пробуется максимум 5.
- Перебор прекращается, если TCP 443 вообще не соединяется с CDN: это не лечится другой стратегией desync.
- `-Config "имя.bat"` — строго этот конфиг, без переключения.
- `-Prompt` — вернуть старое меню с номерами; `-ShowConfigs` — показать список и выйти.
- Если zapret уже запущен и медиа через него работает, его не трогают. `-RestartZapret` перезапускает принудительно.
- zapret, установленный службой Windows, не трогается: перезапустите службу сами, если нужен другой конфиг.

### Где скрипт ищет zapret

По порядку, что найдётся первым: `-ZapretDir`; папка самого скрипта; её родитель; `%USERPROFILE%\zapret`, `C:\zapret`, `D:\zapret`, `C:\dis`, `D:\dis`. Папка считается сборкой zapret, если в ней есть `bin\winws.exe`, `winws.exe` или `service.bat`. Конфиг выбирается так: сработавший в прошлый раз, затем `general.bat`, затем любой `general*.bat`, затем остальные; пробуется не больше 5. Служебные вроде `service.bat` пропускаются.

### Что именно меняется

Только этот блок в конце `C:\Windows\System32\drivers\etc\hosts`:

```
# >>> discord-media-pin (auto) >>>
162.159.141.232 media.discordapp.net
... 12 строк: 3 хоста x 4 адреса ...
# <<< discord-media-pin (auto) <<<
```

Перед каждой записью делается `hosts.bak-дата-время` (хранятся 5 последних), атрибут «только чтение» и кодировка файла сохраняются, повторный запуск заменяет блок, а не дублирует. DNS, фаервол, прокси, маршруты и реестр не трогаются, конфиги zapret и `service.bat` не изменяются; остальные сайты и `cdn.discordapp.com` не затрагиваются.

### Ограничения

- Адреса Cloudflare могут меняться — просто запустите файл ещё раз, он всё перепроверит.
- **Не работает при включённом VPN/TUN.** Адреса закреплены для прямого подключения через провайдера; внутри туннеля они недоступны, да и zapret с VPN не работает. Скрипт проверяет это сам: если default route идёт в туннель — выходит с кодом `3` и ничего не пишет. Туннель, который просто поднят, но трафик через него не идёт (split tunneling), не мешает — будет только пометка в консоли. `-IgnoreVpn` запускает вопреки проверке.
- Если сеть режет весь диапазон, `hosts` не спасёт: нужен туннель или прокси для Discord.
- Если блок по имени, а не по адресу, пины тоже не лекарство: нужен другой конфиг zapret или туннель. Скрипт различает эти случаи и говорит, какой именно у вас.
- Это не VPN и не сокрытие трафика, а локальная таблица адресов.
- Закрепляются IPv4-адреса.

### Если не сработало

- **«VPN is on: … Nothing was changed.» (код выхода `3`)** — VPN несёт весь трафик, закреплённые адреса недоступны. Выключите VPN и запустите снова, заворачивайте в туннель только Discord (split tunneling), либо добавьте `-IgnoreVpn`, если точно знаете, что Discord в туннель не попадает.
- **«No address answered»** — дальше одно из двух объяснений:
  - *«every secure connection to media.discordapp.net is cut off»* — блок по имени: DPI рвёт рукопожатие на любом адресе, сменой адресов это не лечится. Пробуйте другие конфиги (`-ShowConfigs`, затем `-Config "general (ALT...).bat"`); если ни один не берёт — выход только туннель или прокси для Discord.
  - *«None of them accepted a connection at all»* — режут сами адреса (или душат так, что соединение не встаёт). Конфиги тоже не помогут: нужен туннель только для Discord (VPN со split tunneling) или прокси.
  В обоих случаях `hosts` намеренно не меняется: мёртвые адреса не пишутся. Техническая деталь осталась в серой строке `Details:` — её удобно приложить, если сообщаете о проблеме.
- **«All Discord media hosts answer — the pins are fine, hosts left as is»** — скрипт проверил все три хоста через работающий обход, каждый ответил, поэтому `hosts` он намеренно не трогал. Это нормальное состояние при втором и последующих запусках. Если в Discord картинки всё равно битые — закройте его полностью (включая иконку в трее) и откройте снова: работающий клиент держит старые адреса до перезапуска. Перепроверить и перепинить принудительно — запуск с `-Force`. При включённом VPN эта проверка тоже может пройти, хотя Discord будет ломаться.
- **«Could not write hosts»** — чаще всего Defender *Controlled folder access*: разрешите изменение на минуту.
- **Блок записался, но картинок нет** — полностью закройте Discord (включая иконку в трее) и откройте снова.

### Версии и релизы

Проект версионируется по-настоящему.

- Версия по **Semantic Versioning** (`MAJOR.MINOR.PATCH`) хранится в одном месте — `$AppVersion` в начале `fix-discord-media.ps1`. Показать её: `fix-discord-media.bat -Version`.
- Все изменения записываются в [CHANGELOG.md](CHANGELOG.md) в разделах «Добавлено / Изменено / Исправлено / Удалено».
- Каждый релиз — это тег `v<версия>` и релиз на GitHub, в архиве которого ровно три рабочих файла.
- Порядок выпуска: поднять `$AppVersion` → добавить запись в CHANGELOG → коммит → тег `v<версия>` → опубликовать релиз с архивом.

Текущий релиз — **v1.4.0**.
