# Conjunction Visualizer — frontend

React + Resium (CesiumJS) + Vite app that visualizes the satellite catalog,
orbits, and conjunction events from `haskell-conjunction`.

## Quickstart

```sh
npm install
npm run dev      # http://localhost:5173 (proxies /api to http://localhost:8080)
```

Run the `conjunction-api` backend on port 8080 first (see
[`../docs/visualizer.md`](../docs/visualizer.md) for the full guide, production
single-binary deploy, configuration, and feature list).

## Scripts

- `npm run dev` — Vite dev server with HMR
- `npm run build` — type-check + production build into `dist/`
- `npm run preview` — preview the production build
- `npm run typecheck` — `tsc --noEmit`

## Configuration

Copy `.env.example` to `.env` and adjust as needed:

- `VITE_CESIUM_ION_TOKEN` — optional ion token (token-free without it)
- `VITE_API_TARGET` — dev proxy target (default `http://localhost:8080`)
- `VITE_MAX_SATS` — cap rendered satellites (0 = whole catalog)
