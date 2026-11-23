# Discord media fix for Windows (zapret + hosts)

One-click fix for the situation when you already run **zapret** (DPI bypass), but Discord still **does not load images** — "Failed to load image", empty avatars, no stickers, emoji or attachments, while text and voice work normally.

The script starts your zapret config if it is not running, probes Cloudflare addresses that serve the Discord media CDN, keeps the ones that actually answer, pins them in the Windows `hosts` file inside a marked block, and restarts Discord.

* [Русское описание — ниже](#русский)

---

## Quick start

**Easiest way:** open the [Releases page](https://github.com/TestSoulja/discord-media-fix/releases/latest), download `discord-media-fix.zip`, unpack it — and go to step 2.

**1. What to download** (three files):

| File | What it is |
|---|---|
| `fix-discord-media.bat` | the file you double-click |
| `fix-discord-media.ps1` | the actual logic — must sit next to the `.bat` |
| `remove-pins.bat` | undo, if you ever need it |

All three are in this repository. Do not download only the `.bat`: it needs the `.ps1` in the same folder.

**2. Where to put them:** into your zapret folder — the one that contains `service.bat` and `bin\winws.exe`. Put all three files there, next to `general.bat`:

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
2. If zapret is not running, pick a config from the list (number + Enter).
3. Wait 10–30 seconds while it probes addresses.
4. Discord restarts by itself. Images load.

You only do this once. After that, **start zapret with this same file** instead of `general.bat`: it starts the same config and refreshes the pinned addresses. Discord itself starts as usual, from its normal shortcut — no special launch needed. Keep the minimized zapret window open: closing it stops the bypass.

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

1. Finds your zapret folder and your config (`general.bat`, `general (ALT11).bat`, …).
2. If `winws.exe` is not running, starts that config and waits for it.
3. Checks whether Discord media already loads. If it does, stops there (use `-Force` to pin anyway).
4. Probes a shortlist of Cloudflare edge addresses, then scans the wider range, keeping up to 4 that answer.
5. Writes them into `hosts`, once per hostname — 12 lines in a marked block.
6. Flushes the DNS cache and restarts the Discord client that was running (Stable / PTB / Canary / Development).

If no address answers, nothing is written and the script exits with code `2`. It never pins a dead address, and it never edits zapret's configs, lists or `service.bat`.

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
| `-Force` | pin even if Discord media already loads here |
| `-DryRun` | print the resulting `hosts`, change nothing |
| `-NoRestart` | do not touch the Discord client |
| `-NoZapret` | do not look for or start zapret, only pin hosts |
| `-ZapretDir <path>` | zapret folder (auto-detected when omitted) |
| `-Config <name>` | start this config and skip the menu, for example `"general (ALT11).bat"` |
| `-RestartZapret` | stop the running `winws.exe` and start the chosen config |
| `-ShowConfigs` | list configs found in the zapret folder and exit |
| `-Prompt` | always show the config menu, even when input looks redirected |
| `-NoPrompt` | never show the menu, just use the default / remembered config |
| `-HostsFile <path>` | alternate `hosts` file (for testing) |
| `-Hosts <name...>` | hostnames to pin (default: the three Discord media hosts) |
| `-ExtraIPs <ip...>` | additional candidate addresses to probe first |

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

When `winws.exe` is not running yet, the script lists every config it found and asks which one to start:

```
Configs found:
  [1] general (ALT.1).bat
  [2] general (ALT11).bat
  [3] general.bat   <- default

Which zapret config should be started?
Enter = the default, q = cancel
  Number: _
```

- Enter uses the default; `q` cancels and changes nothing.
- The choice is remembered in `%LOCALAPPDATA%\discord-media-fix\last-config.txt`, so the next run offers it as the default.
- `-Config "name.bat"` skips the menu entirely.
- If zapret is already running, the script reuses it and does not ask. Add `-RestartZapret` to stop it and start the config you picked.
- `-ShowConfigs` prints the same numbered list and exits without doing anything.

## Where it looks for zapret

In this order, first match wins:

1. `-ZapretDir`, if you passed it;
2. the folder where this script lives;
3. its parent folder;
4. `%USERPROFILE%\zapret`, `C:\zapret`, `D:\zapret`, `C:\dis`, `D:\dis`.

A folder counts as a zapret folder when it contains `bin\winws.exe`, `winws.exe` or `service.bat`. Configs are picked as: the one you chose last time, then `general.bat`, then any `general*.bat`, then the first other `.bat`. `service.bat`, installers and helper scripts are skipped.

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
- **Does not work with a VPN or TUN tunnel enabled.** The pinned addresses are reached directly through your ISP; inside a tunnel they are not available. zapret itself also does not work through a VPN.
- If the block covers every address in the range, no `hosts` entry can help: this method is done, use a full VPN for Discord instead.
- The fix is per hostname and per machine. It is not a VPN and does not hide traffic.
- IPv6-only networks that resolve the CDN over IPv6 are out of scope: the block pins IPv4 addresses.

## Troubleshooting

**"No address answered"** — zapret is not actually up, or the network drops TLS to the whole Cloudflare range. Check the zapret window, try another config with `-Config`, or use a VPN.

**"Could not write hosts"** — usually Microsoft Defender *Controlled folder access*. Allow the change for a minute, or add `powershell.exe` as an allowed app.

**The block was written but images still fail** — close Discord completely (tray icon too) and open it again; a running client only re-resolves hostnames on restart.

**zapret is already running under a different config** — the script reuses the running `winws.exe` and does not touch it. Stop it first if you want a different config started.

## License

MIT. Do whatever you want, no warranty. See [LICENSE](LICENSE).

---

## Русский

Однокликовый фикс для случая, когда **zapret уже запущен, а картинки в Discord всё равно не грузятся** — «Не удалось загрузить изображение», пустые аватарки, нет стикеров, эмодзи и вложений, при этом текст и голос работают.

Скрипт поднимает ваш конфиг zapret (если `winws.exe` не запущен), проверяет адреса Cloudflare, которые обслуживают медиа-CDN Discord, оставляет только те, что реально отвечают, и прописывает их в `hosts` Windows — в отдельном помеченном блоке. Потом перезапускает Discord.

### Быстрый старт

**Проще всего:** откройте [страницу релизов](https://github.com/TestSoulja/discord-media-fix/releases/latest), скачайте `discord-media-fix.zip`, распакуйте — и переходите к пункту 2.

**1. Что скачать** — три файла:

| Файл | Это что |
|---|---|
| `fix-discord-media.bat` | по нему вы кликаете |
| `fix-discord-media.ps1` | сама логика, должен лежать рядом с `.bat` |
| `remove-pins.bat` | откат, если понадобится |

Скачивать один `.bat` нельзя: без `.ps1` в той же папке он не заработает.

**2. Куда положить:** в папку своей сборки zapret — ту, где лежат `service.bat` и `bin\winws.exe`. Все три файла рядом с `general.bat`:

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
2. Если zapret не запущен, выберите конфиг из списка (номер + Enter).
3. Подождите 10–30 секунд, пока проверяются адреса.
4. Discord перезапустится сам. Картинки загрузятся.

Делается один раз. Дальше **запускайте zapret этим же файлом**, а не `general.bat`: он поднимает тот же конфиг и обновляет закреплённые адреса. Сам Discord открывается как обычно, ярлыком — специально через батник его запускать не нужно. Свёрнутое окно zapret не закрывайте: закрыли — обход выключился.

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
fix-discord-media.bat -Config "general (ALT11).bat"       :: запускать конкретный конфиг
fix-discord-media.bat -NoZapret                           :: только пиннинг, zapret не трогать
fix-discord-media.bat -Force -NoRestart                   :: прописать и не перезапускать Discord
```

### Выбор конфига

Когда `winws.exe` ещё не запущен, скрипт показывает все найденные конфиги и спрашивает, какой запускать:

```
Configs found:
  [1] general (ALT.1).bat
  [2] general (ALT11).bat
  [3] general.bat   <- default

Which zapret config should be started?
Enter = the default, q = cancel
  Number: _
```

- Enter — взять конфиг по умолчанию, `q` — отменить, ничего не меняя.
- Выбор запоминается в `%LOCALAPPDATA%\discord-media-fix\last-config.txt`, и в следующий раз он предлагается как конфиг по умолчанию.
- `-Config "имя.bat"` — пропустить меню.
- Если zapret уже запущен, скрипт его не трогает и не спрашивает. Добавьте `-RestartZapret`, чтобы остановить текущий и запустить выбранный.
- `-ShowConfigs` — показать нумерованный список и выйти.
- `-NoPrompt` — никогда не спрашивать (для скриптов и автоматизации), `-Prompt` — спрашивать всегда.

### Где скрипт ищет zapret

По порядку, что найдётся первым: `-ZapretDir`; папка самого скрипта; её родитель; `%USERPROFILE%\zapret`, `C:\zapret`, `D:\zapret`, `C:\dis`, `D:\dis`. Папка считается сборкой zapret, если в ней есть `bin\winws.exe`, `winws.exe` или `service.bat`. Конфиг выбирается так: `general.bat`, затем любой `general*.bat`, затем первый попавшийся `.bat` (служебные вроде `service.bat` пропускаются).

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
- **Не работает при включённом VPN/TUN.** Адреса закреплены для прямого подключения через провайдера; внутри туннеля они недоступны, да и zapret с VPN не работает.
- Если сеть режет весь диапазон, `hosts` не спасёт: нужен полноценный VPN для Discord.
- Это не VPN и не сокрытие трафика, а локальная таблица адресов.
- Закрепляются IPv4-адреса.

### Если не сработало

- **«No address answered»** — zapret не поднялся или сеть режет весь диапазон. Проверьте окно zapret, попробуйте другой конфиг через `-Config` либо VPN.
- **«Could not write hosts»** — чаще всего Defender *Controlled folder access*: разрешите изменение на минуту.
- **Блок записался, но картинок нет** — полностью закройте Discord (включая иконку в трее) и откройте снова.
