# Backlog

Known gaps, written down so they are not lost. Nothing here has a date: each
item is done when it is done, and every change still has to pass the test suite
and the release checks.

## Probing

1. **The candidate range is still a guess.** `162.159.128-141.{232,233}` plus the
   resolver answer covers the networks seen so far. A user report from a range
   outside it would be the moment to ask DoH for the same name instead of
   widening the hardcoded list again.
2. **The sequential fallback is slow on old curl builds.** Without `--parallel`
   (curl older than 7.66, Windows 10 1803-1909) a wide sweep probes every
   candidate one at a time. Measured on the filtered network in development:
   58 s with `--parallel`, about five minutes without it, for the same 28
   addresses. The README says so; a report from such a machine would decide
   whether the fallback needs its own shorter limit.
3. **The post-write check uses the default resolver path only.** It asks
   `https://<name>/` and accepts any answer except `403`/`421`. A CDN that
   answers `403` on `/` on a healthy network would fail the run; nothing seen so
   far does that (Discord answers `404` for `/`). If a report says "everything
   was fine before 1.10.0", this check is the first suspect: the probe records
   the code, so the report names it.

## Documentation

The antivirus documentation gaps (Russian safety list, quarantined `.ps1`, the
precondition of the interceptor line, the indirect WinDivert detection, why
`SecurityCenter2` is not queried) are closed in 1.10.0, together with the guard
that the entry point still enables the VPN menu. There is no separate 1.9.2
release: the `.bat` bytes change in 1.10.0 anyway, and shipping one
documentation release plus one behaviour release back to back would only make
the changelog longer.
