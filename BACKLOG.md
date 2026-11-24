# Backlog

Known gaps, written down so they are not lost. Nothing here has a date: each
item is done when it is done, and every change still has to pass the test suite
and the release checks.

## Antivirus and local security products

Found while reviewing the antivirus story end to end (v1.9.1). The behaviour is
already right — the script never changes antivirus settings, exclusions or
threat history, and never reads its state (see "What exactly is changed on the
machine" in `README.md`). What is missing is documentation, plus one message in
the entry point.

1. **The Russian safety list is shorter than the English one.** In `README.md`,
   under "Что скрипт **не** делает", there is no bullet about the antivirus or
   firewall. The English list has it: no exclusions, no settings, no reading of
   its logs — only the certificate a site presents.
2. **A `.ps1` deleted by an antivirus is not explained anywhere.** The most
   common real case: the archive is unpacked and `fix-discord-media.ps1`
   disappears. The `.bat` says only `fix-discord-media.ps1 is missing next to
   this file`. Add one line about the quarantine and restoring the file — in
   `fix-discord-media.bat` and in both README troubleshooting lists.
3. **The interceptor line has a precondition.** The "HTTPS here is signed by …"
   report needs a site that actually answers over HTTPS (`discord.com`,
   `example.com`). If HTTPS is blocked entirely, the line cannot appear, and the
   docs do not say so.
4. **A WinDivert block is detected indirectly only.** An antivirus blocking the
   driver surfaces as "winws.exe did not appear" or as a refused connection;
   there is no direct check, and the docs do not say that either.
5. **Why the script does not read antivirus state.** A `SecurityCenter2` query
   once reported two ghost Kaspersky entries on a machine where the product had
   been removed. One sentence next to the safety bullet keeps someone from
   "improving" the script by adding that query back.

Planned as a documentation release (1.9.2) plus the two `.bat` lines: the
shipped bytes change, so it is a release, not an in-place edit.

## Tests

6. **Guard that the `.bat` keeps the VPN choice alive.** The menu appears only
   when the entry point sets `DISCORD_MEDIA_FIX_MENU`. A test asserts the menu
   text, but nothing asserts that the `.bat` still sets the variable.
