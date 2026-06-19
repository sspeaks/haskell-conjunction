# Revision history for haskell-conjunction

## 0.1.0.0 -- YYYY-mm-dd

* First version. Released on an unsuspecting world.
* Add `conjunction-screen` executable: daily LEO close-approach screening that
  runs after the Space-Track ingest and stores conjunctions within 5 km (time of
  closest approach, miss distance, relative speed, TEME state, and geodetic
  positions) in the `conjunction_runs` and `conjunctions` tables.
* Implement both the raw all-pairs CM-COMBO algorithm (validation oracle) and
  the optimized spatial-hash screen (production path), with a test suite that
  asserts the two agree.
* Screen in parallel across CPU cores (concurrent propagation and refinement,
  sparked per-time-step pairwise screening) while remaining deterministic; the
  `conjunction-screen` executable defaults to all cores via the threaded RTS.
* Add `conjunction-notify` executable: after the daily screen, recompute which
  stored conjunctions are naked-eye-visible from a configured observer over the
  next-day window and push an alert per new event to an ntfy topic, with a
  `conjunction_notifications` de-duplication table and NixOS service/timer wiring.
  The visibility math (`Conjunction.Visibility`) mirrors the web client's, so the
  notified events also appear in the existing "Visible conjunctions" list.
