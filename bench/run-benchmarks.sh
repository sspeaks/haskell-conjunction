#!/usr/bin/env sh
set -eu

ITERATIONS="${1:-10000}"
WORKLOAD="${2:-bench/workload.tsv}"
MODE="${3:-all}"
BUILD_DIR="${BENCH_BUILD_DIR:-dist-newstyle/bench}"
CXX="${CXX:-g++}"
BENCH_CXXFLAGS="${BENCH_CXXFLAGS:--O2 -std=c++14}"
CPP_BENCH="$BUILD_DIR/direct-sgp4-bench"
CPP_BUILD_LOG="$BUILD_DIR/direct-sgp4-bench.build.log"

mkdir -p "$BUILD_DIR"

cabal build bench:sgp4-hs-bench --enable-optimization=2
HS_BENCH="$(cabal list-bin bench:sgp4-hs-bench --enable-optimization=2)"

# Intentionally split BENCH_CXXFLAGS so callers can pass multiple compiler flags.
if ! "$CXX" $BENCH_CXXFLAGS \
    -I sgp4/cpp/SGP4/SGP4 \
    bench/direct_sgp4_bench.cpp \
    sgp4/cpp/SGP4/SGP4/SGP4.cpp \
    -o "$CPP_BENCH" \
    2>"$CPP_BUILD_LOG"; then
    cat "$CPP_BUILD_LOG" >&2
    exit 1
fi

run_mode() {
    mode="$1"
    printf '%s\n' "--- Haskell wrapper ($mode) ---"
    "$HS_BENCH" "$ITERATIONS" "$WORKLOAD" "$mode"

    printf '%s\n' "--- Direct C++ ($mode) ---"
    "$CPP_BENCH" "$ITERATIONS" "$WORKLOAD" "$mode"
}

case "$MODE" in
    all)
        run_mode end-to-end
        run_mode propagation-only
        ;;
    end-to-end|propagation-only)
        run_mode "$MODE"
        ;;
    *)
        printf 'invalid mode: %s\nusage: bench/run-benchmarks.sh [iterations] [workload-path] [all|end-to-end|propagation-only]\n' "$MODE" >&2
        exit 1
        ;;
esac
