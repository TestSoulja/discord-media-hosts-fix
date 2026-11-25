# Backlog

Known gaps, written down so they are not lost. Nothing here has a date: each
item is done when it is done, and every change still has to pass the test suite
and the release checks.

## Tests

1. **Guard that the `.bat` keeps the VPN choice alive.** The menu appears only
   when the entry point sets `DISCORD_MEDIA_FIX_MENU`. A test asserts the menu
   text, but nothing asserts that the `.bat` still sets the variable.

## Probing

2. **The candidate range is still a guess.** `162.159.128-141.{232,233}` plus the
   resolver answer covers the networks seen so far. A user report from a range
   outside it would be the moment to ask DoH for the same name instead of
   widening the hardcoded list again.
3. **The sequential fallback is slow on old curl builds.** Without `--parallel`
   (curl older than 7.66, Windows 10 1803-1909) a wide sweep probes every
   candidate one at a time, so a network where little answers can take minutes
   instead of the ~1 minute the README names for a current build. The README
   says so; a report from such a machine would decide whether the fallback needs
   its own shorter limit.
4. **The post-write check uses the default resolver path only.** It asks
   `https://<name>/` and accepts any answer except `403`/`421`. A CDN that
   answers `403` on `/` on a healthy network would fail the run; nothing seen so
   far does that (Discord answers `404` for `/`). If a report says "everything
   was fine before 1.10.0", this check is the first suspect: the probe records
   the code, so the report names it.

## Documentation

The antivirus documentation gaps (Russian safety list, quarantined `.ps1`, the
precondition of the interceptor line, the indirect WinDivert detection, why
`SecurityCenter2` is not queried) are closed in 1.10.0. There is no separate
1.9.2 release: the `.bat` bytes change in 1.10.0 anyway, and shipping one
documentation release plus one behaviour release back to back would only make
the changelog longer.
