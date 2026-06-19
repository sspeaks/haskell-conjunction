# Conjunction notifications (ntfy)

The `conjunction-notify` executable turns the conjunctions the screener already
stores into push notifications for a single configured observer. After the daily
screen runs, it recomputes which already-screened conjunctions are
**naked-eye visible** from the observer's location over the next-day window and
POSTs a short alert to an [ntfy](https://ntfy.sh) topic. Subscribe to that topic
on your phone (the ntfy app, or any ntfy client) to be alerted when a visible
conjunction is coming up.

The web app is unchanged: when you open it and enter the same latitude/longitude,
the same conjunction appears in the existing **Visible conjunctions** list. The
notifier and the browser deliberately use the same thresholds, magnitudes, frames,
and Sun model, so the notifier never alerts about a conjunction that would not also
appear in that list.

## How it works

1. **Read the current run.** The conjunctions of the latest successful screening
   run whose time of closest approach (TCA) falls in `[now, now + window-hours]`
   are read straight from the `conjunctions` table. No SGP4 re-propagation is
   needed — the screener already stores both objects' TEME state vectors and
   geodetic positions at TCA, exactly the values the browser uses as `conj.a.teme`.
2. **Decide visibility.** For each conjunction, `Conjunction.Visibility`
   (a port of `web/src/cesium/visibility.ts` and `web/src/cesium/solar.ts`)
   evaluates both objects at TCA: it requires the observer to be dark
   (Sun below `--sun-max-elevation-deg`), the higher object to clear
   `--min-elevation-deg`, and at least one object to be sunlit (outside Earth's
   cylindrical shadow). The brighter (minimum) apparent magnitude must be at least
   as bright as `--magnitude-cutoff`. Magnitudes come from the same
   `Brightness.resolveStdMag` the API uses, so server and browser agree.
3. **De-duplicate.** Each newly visible conjunction is checked against the
   `conjunction_notifications` table (keyed by conjunction id and `--watch-label`).
   Already-notified conjunctions are skipped.
4. **Publish.** A concise message (object pair, TCA and lead time, peak elevation
   and compass bearing, magnitude, miss distance) is POSTed to
   `<ntfy-server>/<ntfy-topic>`. On success the conjunction is recorded as notified.
   A failed publish is logged and skipped so one bad send never blocks the rest;
   database errors are fatal.

Because each daily run screens the *following* UTC day and the notifier runs
hourly with a rolling `[now, now + 24h]` window plus the de-duplication table,
every visible conjunction is notified exactly once, roughly a day ahead, as it
first enters the window.

## Running manually

```
conjunction-notify \
  --observer-lat 47.62 --observer-lon=-122.35 \
  --ntfy-topic my-secret-conjunctions \
  --dry-run
```

`--dry-run` prints the alerts that would be sent (and does not record them), which
is the easiest way to confirm the notifier's visible set matches the browser's
**Visible conjunctions** list for the same latitude/longitude.

Notable flags (see `--help` for the full list):

- `--observer-lat`, `--observer-lon`, `--observer-height-km` — observer location.
- `--window-hours` (24), `--min-elevation-deg` (10), `--sun-max-elevation-deg`
  (-6), `--magnitude-cutoff` (6.5) — visibility thresholds, identical to the web
  defaults. Pass negative values with `=`, e.g. `--sun-max-elevation-deg=-6`.
- `--ntfy-server` (`https://ntfy.sh`), `--ntfy-topic` (required),
  `--ntfy-token-file`, `--ntfy-priority`, `--ntfy-title`, `--ntfy-tags`.
- `--watch-label` — de-duplication key; defaults to the topic.
- The database selection flags (`--database-url[-file]` /
  `--database-host|name|user`) match `conjunction-screen`.

## NixOS

The NixOS module wires a `conjunction-notify` systemd service and timer next to
the screener. Enable it under `services.spacetrack-leo-ingest.notify`:

```nix
services.spacetrack-leo-ingest.notify = {
  enable = true;
  observer = { latDeg = 47.62; lonDeg = -122.35; };
  ntfy = {
    topic = "my-secret-conjunctions";
    # tokenFile = config.sops.secrets.ntfy-token.path;   # for protected topics
    # server = "https://ntfy.example.org";               # self-hosted ntfy
  };
};
```

The service is ordered after the screener so a fresh screen is picked up promptly,
runs on an hourly timer (`notify.onCalendar`, default `"hourly"`) plus after boot,
and only emits its unit when `notify.enable = true`. It makes outbound POSTs only,
so no firewall change is required. The token is read from a file
(`notify.ntfy.tokenFile`), never passed on the command line, matching the
Space-Track secret pattern.

## Data and rollback

The notifier adds one table, `conjunction_notifications` (conjunction id, watch
label, sent timestamp; unique on `(conjunction_id, watch)`), created idempotently
on startup. Send-then-record is at-least-once: a crash between the POST and the
insert may, rarely, re-send a single alert.

The feature is opt-in and isolated. Disable it by setting
`services.spacetrack-leo-ingest.notify.enable = false` (no unit is emitted) — no
rebuild of unrelated components. Removing the feature leaves the
`conjunction_notifications` table orphaned but inert; drop it manually with
`DROP TABLE conjunction_notifications;` if desired. No existing tables are
altered.

## Parity note

The server's visibility decision and the browser's can differ very slightly on
borderline events (elevation near 10°, magnitude near 6.5) because they run
different code (Haskell vs. satellite.js). This is mitigated by sharing identical
thresholds, magnitudes, GMST/frame transforms, and an exact port of the
low-precision (~0.01°) Sun model. The notifier additionally applies the
magnitude cutoff that the web panel exposes but does not itself filter on, so the
notified set is always a subset of the browser's **Visible conjunctions** list.
