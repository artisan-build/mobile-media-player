# Workflow: mobile-media-player (artisan-build fork)

Our fork of NativePHP/mobile-media-player (MIT). Exists to add background audio + lock-screen / Now Playing
controls, which upstream lacks, for the Fawn Fox Fables app (proof of concept, Ed 2026-10-27). Offered upstream
later; we switch back to upstream when NativePHP tags it.

## Phase & mode

- phase: proof of concept. Commit straight to `main`, push, no PRs. Keep the change shaped the way upstream would
  want it (their API style, no Fawn Fox specifics) so it can be offered back as is.
- Versions: tag `<upstream base>.<n>` (e.g. `1.0.2.1`) so ours sort above the base and below upstream's next release.
- The package name stays `nativephp/mobile-media-player`. Never rename it.
- Excluded from the fleet dependency-bump sweep: the only consumer is fawnfoxfables-app.

## Agent-role constraints

- none.
