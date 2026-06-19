# Conjunction screening service

After the Space-Track ingest refreshes `leo_gp_current`, the `conjunction-screen`
executable screens the active LEO catalog for close approaches over the next 24
hours and stores every conjunction within 5 km — together with its time of
closest approach, miss distance, relative speed, both objects' TEME state, and
geodetic positions — in PostgreSQL.

Two algorithms are implemented. The **optimized** spatial-hash screen is the
production path. The **raw CM-COMBO** all-pairs screen (Healy 1995) is the
validation oracle. Both share the same propagation, candidate reduction, and
time-of-closest-approach refinement, so they produce identical results; this is
asserted by the `conjunction-tests` suite. The algorithm survey that motivated
this design is in [`what-papers-are-there-out-there-for-efficiently-co.md`](./what-papers-are-there-out-there-for-efficiently-co.md).

The stored conjunctions can also drive phone notifications: see
[`conjunction-notify.md`](./conjunction-notify.md) for the `conjunction-notify`
executable, which alerts a configured observer (via ntfy) about the
naked-eye-visible conjunctions coming up in the next-day window.

## Parallelism

CM-COMBO is, in Healy's original paper, a parallel algorithm — the pairwise
distance comparisons are distributed across processors. This implementation
keeps that property on modern multi-core hardware:

- **Propagation** of each object across the time grid runs concurrently
  (`Control.Concurrent.Async`), bounded to the capability count. Each object has
  its own SGP4 record and output buffers, so the short `unsafe` FFI calls are
  thread-safe across capabilities.
- **Candidate generation** parallelizes the per-time-step pairwise screen with
  deterministic sparks (`Control.Parallel.Strategies`): each time step is an
  independent task, mirroring Healy's distribution of the comparisons.
- **Refinement** of candidate pairs likewise runs concurrently.

All three helpers are order-preserving, so parallelism never changes the
detected conjunctions — the `conjunction-tests` suite runs under `-N` (all
cores) and still asserts exact raw/optimized agreement. The `conjunction-screen`
executable is built with `-threaded -with-rtsopts=-N`, so it uses every
available core by default; override with `+RTS -Nk`.

## How it works

1. **Read catalog.** Every active object in `leo_gp_current` with usable TLE
   lines is loaded and its SGP4 record initialized. Objects SGP4 rejects are
   skipped.
2. **Time grid.** An absolute-UTC grid is built from the run time across the
   window (default 24 h) at the coarse step (default 60 s). Each object is
   batch-propagated to TEME positions/velocities at every grid time; a sample
   that errors is treated as the object being absent at that time.
3. **Coarse candidate gate.** A coarse threshold is derived so no sub-5 km
   approach is missed between samples even for the fastest head-on encounter:

   ```
   coarse = threshold_km + rel_vel_max_kms * (step_seconds / 2)
   ```

   With the defaults this is `5 + 15.6 * 30 = 473 km`. Override it with
   `--coarse-threshold-km`.
4. **Candidate generation** (the only step that differs between algorithms):
   - *Raw CM-COMBO:* at each time step every present pair is tested with a
     Cartesian coordinate sieve. `O(N^2 * T)`.
   - *Optimized:* at each time step objects are bucketed into a uniform spatial
     hash whose cell size equals the coarse threshold; only the 3x3x3 cell
     neighborhood is examined, and a conservative ephemeris radial-band check
     (the orbital-characteristic prefilter) rejects pairs whose altitude bands
     cannot come within the coarse threshold. `O(N * T)`.

   Both candidate-completeness properties guarantee the two algorithms emit the
   same within-coarse samples.
5. **Refinement.** Each candidate pair is re-propagated at the fine step
   (default 1 s) across the bracket window; the minimum-distance fine sample
   gives the true time of closest approach, miss distance, and relative
   velocity. Only approaches within the final threshold are emitted.
6. **Persist.** A `conjunction_runs` row records the run and its parameters; the
   surviving events are written to `conjunctions`.

## Modes

| Mode | Behavior |
|------|----------|
| `optimized` (default) | Run the optimized screen and persist results. Production path. |
| `raw` | Run the raw CM-COMBO screen and persist results. Quadratic; intended for small catalogs or manual checks. |
| `validate` | Run both on a bounded subset (`--validate-limit`, default 500), report agreement, persist nothing, and exit non-zero on disagreement. |

## Schema

`conjunction_runs` — one row per screening run:

| Column | Notes |
|--------|-------|
| `run_id` | identity primary key |
| `screen_date` | UTC date of the window start |
| `algorithm` | `optimized` or `raw` |
| `started_at`, `finished_at` | run timestamps |
| `status` | `running`, `success`, or `failed` |
| `window_hours`, `step_seconds`, `threshold_km`, `coarse_threshold_km` | parameters used |
| `object_count`, `conjunction_count` | result counts |
| `error_message` | populated on failure |

`conjunctions` — one row per detected close approach (objects in canonical
ascending-NORAD-id order, `UNIQUE (run_id, norad_cat_id_a, norad_cat_id_b)`):

| Column group | Columns |
|--------------|---------|
| Identity | `conjunction_id`, `run_id`, `screen_date` |
| Pair | `norad_cat_id_a`, `norad_cat_id_b`, `object_name_a`, `object_name_b` |
| Approach | `tca`, `miss_distance_km`, `relative_speed_kms` |
| Object A | `a_teme_x_km`/`y`/`z`, `a_vel_x_kms`/`y`/`z`, `a_lat_deg`, `a_lon_deg`, `a_alt_km` |
| Object B | `b_teme_x_km`/`y`/`z`, `b_vel_x_kms`/`y`/`z`, `b_lat_deg`, `b_lon_deg`, `b_alt_km` |
| Midpoint | `mid_lat_deg`, `mid_lon_deg`, `mid_alt_km` |

Runs are kept as history keyed by `run_id`; the latest successful run for a
`screen_date` is the current result for that day.

## Runtime command

```sh
conjunction-screen \
  --database-host /run/postgresql \
  --database-name spacetrack-ingest \
  --database-user spacetrack-ingest \
  --mode optimized
```

Key options (see `conjunction-screen --help` for the full list):

- `--window-hours` (default `24`), `--step-seconds` (default `60`)
- `--threshold-km` (default `5`), `--coarse-threshold-km` (default derived)
- `--rel-vel-max-kms` (default `15.6`), `--refine-step-seconds` (default `1`)
- `--mode optimized|raw|validate`, `--validate-limit`
- `--skip-if-computed-today` for scheduled jobs
- the same database connection options as `spacetrack-leo-ingest`

## NixOS module

The `spacetrack-leo-ingest` NixOS module runs the screen automatically after a
successful ingest. It provisions two systemd services,
`spacetrack-conjunction-screen` (manual) and
`spacetrack-conjunction-screen-if-needed` (guarded by `--skip-if-computed-today`),
ordered after the ingest and PostgreSQL. The guarded screen is pulled in by the
ingest catch-up flow, so a single timer drives ingest then screening each day.

```nix
services.spacetrack-leo-ingest = {
  enable = true;
  # ... ingest options ...

  conjunction.enable = true;        # default
  conjunction.mode = "optimized";   # default
  conjunction.extraArgs = [ "--window-hours" "24" ];
};
```

Set `conjunction.enable = false` to disable automatic screening.

## Validation

`cabal test conjunction-tests` builds fixtures from the canonical ISS test TLE
and asserts that the raw and optimized algorithms agree exactly, that duplicate
objects conjunct at zero distance, that a small mean-anomaly nudge is a sub-5 km
near miss, and that band-separated objects never conjunct. Use `--mode validate`
to run the same comparison against the live catalog.
