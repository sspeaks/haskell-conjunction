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
