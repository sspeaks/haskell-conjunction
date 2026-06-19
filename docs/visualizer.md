# Conjunction Visualizer

A CesiumJS + React web application that visualizes the satellite catalog, orbits,
and conjunction events produced by this project. It is served by a small Haskell
read-only API (`conjunction-api`) that reads the same PostgreSQL database the
ingest/screener write to.

## Components

| Part | Location | Role |
|------|----------|------|
| `conjunction-api` | `api/` (cabal executable) | Read-only JSON API; also serves the built frontend in production |
| `web/` | `web/` | React + Resium (CesiumJS) + Vite frontend |

## API endpoints

- `GET /api/health` — liveness
- `GET /api/satellites` — every active catalog object with TLE lines + parsed
  elements, plus brightness fields (`rcsM2`, `rcsSize`, `stdMag`) joined from the
  CelesTrak SATCAT and used by the visibility predictor
- `GET /api/conjunctions?limit=N&date=YYYY-MM-DD` — events, closest miss first
- `GET /api/conjunctions/:id` — one event
- `GET /api/runs` — recent screening runs

All responses are JSON and gzip-compressed.

## Running in development

Two processes.

**1. The API** (must be able to reach PostgreSQL). In the NixOS deployment the
database uses peer authentication over the `/run/postgresql` socket as the
`spacetrack-ingest` user, so run the API as that user:

```sh
nix develop
cabal build conjunction-api
sudo -u spacetrack-ingest "$(cabal list-bin conjunction-api)" \
  --port 8080 \
  --database-host /run/postgresql \
  --database-name spacetrack-ingest \
  --database-user spacetrack-ingest
```

Alternatively pass a full libpq string:
`--database-url 'postgres:///spacetrack-ingest?host=/run/postgresql&user=spacetrack-ingest&sslmode=disable'`,
or a file containing one with `--database-url-file PATH`.

**2. The frontend dev server** (proxies `/api` to `http://localhost:8080`):

```sh
cd web
npm install
npm run dev          # http://localhost:5173
```

## Running in production (single binary)

Build the frontend once, then let the API serve it:

```sh
cd web && npm install && npm run build && cd ..
cabal build conjunction-api
sudo -u spacetrack-ingest "$(cabal list-bin conjunction-api)" \
  --port 8080 --static-dir web/dist \
  --database-host /run/postgresql \
  --database-name spacetrack-ingest \
  --database-user spacetrack-ingest
# open http://localhost:8080
```

Non-`/api` paths are served from `web/dist` (with a single-page-app fallback to
`index.html`); the API lives under `/api`.

You can also launch it via the flake app:

```sh
nix run .#conjunction-api -- --port 8080 --static-dir web/dist \
  --database-host /run/postgresql --database-name spacetrack-ingest --database-user spacetrack-ingest
```

## Hosting on NixOS

The flake's `nixosModules.spacetrack-leo-ingest` (the same module that runs the
ingest + screener) now also provides a long-running **`conjunction-api`** systemd
service, and the flake exposes a prebuilt frontend package (`conjunction-web`).
The service runs as the `spacetrack-ingest` user and reads the same local
PostgreSQL over the `/run/postgresql` socket (peer auth), so no extra database
wiring is needed.

Minimal host configuration (add to your existing `services.spacetrack-leo-ingest`
block):

```nix
services.spacetrack-leo-ingest = {
  enable = true;
  spacetrack.usernameFile = config.sops.secrets.spacetrack-username.path;
  spacetrack.passwordFile = config.sops.secrets.spacetrack-password.path;

  # Visualization server:
  api.enable = true;
  api.openFirewall = true;   # exposes api.port (default 8080) on all interfaces
};
```

`nixos-rebuild switch` then builds the frontend (`conjunction-web`) and starts the
`conjunction-api.service` on port 8080, serving the web app and the JSON API from
one process. It is ordered after `postgresql.service` and restarts on failure.

**Module options** (under `services.spacetrack-leo-ingest.api`):

| Option | Default | Purpose |
|--------|---------|---------|
| `api.enable` | `false` | Enable the visualization server |
| `api.port` | `8080` | Listen port (binds all interfaces) |
| `api.openFirewall` | `false` | Open `api.port` in the firewall |
| `api.webRoot` | `conjunction-web` package | Static frontend directory to serve |
| `api.package` | the project package | Package providing `conjunction-api` |
| `api.extraArgs` | `[ ]` | Extra flags, e.g. `[ "--allowed-origin" "https://…" ]` |

**Behind nginx with TLS** (recommended for public hosting — keep
`api.openFirewall = false`):

```nix
services.spacetrack-leo-ingest.api = {
  enable = true;
  openFirewall = false;   # only nginx is exposed
};

services.nginx = {
  enable = true;
  recommendedProxySettings = true;
  recommendedTlsSettings = true;
  recommendedGzipSettings = true;
  virtualHosts."conjunctions.example.com" = {
    enableACME = true;
    forceSSL = true;
    locations."/".proxyPass = "http://127.0.0.1:8080";
  };
};

security.acme = {
  acceptTerms = true;
  defaults.email = "you@example.com";
};

networking.firewall.allowedTCPPorts = [ 80 443 ];
```

The API binds `0.0.0.0:8080`; with the firewall closed, only the local nginx
reaches `127.0.0.1:8080` while the public listens on 80/443.

## Configuration

**API flags:** `--port`, `--static-dir`, `--database-url`, `--database-url-file`,
`--database-host`, `--database-name`, `--database-user`. The API is read-only and
allows any origin (CORS `Access-Control-Allow-Origin: *`), so the Vite dev server
can call it cross-origin with no extra configuration.

**Frontend env** (`web/.env`, see `web/.env.example`):
- `VITE_CESIUM_ION_TOKEN` — optional; enables Cesium ion terrain/imagery. Omit to
  run token-free (flat ellipsoid + bundled Natural Earth II imagery).
- `VITE_API_TARGET` — dev proxy target (default `http://localhost:8080`).
- `VITE_MAX_SATS` — cap the number of satellites rendered (0 = whole catalog).

## Features

- **3D globe** of the full active catalog as a GPU-batched point cloud, colored by
  orbit regime (LEO / MEO / GEO / HEO), time-animated with SGP4 via `satellite.js`.
- **Scene modes**: built-in 3D / 2D / Columbus switcher.
- **Object inspection**: click any object for NORAD id, type, inclination,
  eccentricity, period, and altitudes.
- **Conjunction list** (closest first). Selecting one opens the **theater**: the
  camera flies to the time of closest approach, both objects get animated orbit
  trails, a live miss-distance line + kilometre readout connects them, and the
  clock ramps into slow motion near TCA.
- **Encounter inset**: the RTN/RIC relative geometry (radial / in-track /
  cross-track) and a B-plane-style miss plot with threshold rings, computed from
  the stored TEME state vectors.
- **Analytics drawer**: miss-distance histogram, relative-speed-vs-miss risk
  scatter (click a point to open it in the theater), conjunctions-by-altitude
  shell, and a most-involved-objects leaderboard.
- **Visible from your location**: enter a latitude/longitude (or use browser
  geolocation, or click the globe) to predict which satellites and conjunction
  events are observable with the naked eye over the next N hours. A Web Worker
  applies the standard visual-visibility tests — above the horizon (≥10°),
  observer in darkness (sun below −6°), and satellite sunlit (Earth-shadow test)
  — and ranks passes by estimated apparent magnitude. Each pass row shows the
  satellite name, an optional `naked-eye` badge, and a number to its right: the
  estimated peak (brightest) apparent visual magnitude during the pass, to one
  decimal place (lower = brighter); the `naked-eye` badge appears only when that
  magnitude is ≤ 4. Selecting a pass draws the
  above-horizon arc, an observer marker, and the peak line of sight, and jumps
  the clock to the pass. Brightness is estimated from a resolved standard
  magnitude (CelesTrak SATCAT RCS + a hardcoded bright-object table such as
  ISS / CSS / Hubble); thresholds (window, min elevation, sun depression, magnitude
  cutoff) are adjustable in the panel.

## Notes

- The orbital data is deterministic miss-distance geometry: there is no
  probability of collision (Pc) or covariance, so the encounter plot shows the
  nominal miss point rather than a probability ellipse.
- CesiumJS itself is ~5 MB (loaded once); the satellite catalog payload is
  gzip-compressed (~3 MB over the wire).

## Troubleshooting

**Assets return `400 Bad Request` in the browser (but `curl` works).** Vite tags
the built `<script>`/`<link>` with `crossorigin`, so browsers fetch those assets
in CORS mode with an `Origin` header. If the server's CORS policy does not allow
that origin it rejects the request with 400 — and because `curl` sends no
`Origin`, it never reproduces. The server now allows any origin
(`Access-Control-Allow-Origin: *`), which fixes this; make sure you are running a
build that includes that change (`nixos-rebuild switch`, then hard-refresh once).

**A redeploy doesn't seem to take effect.** Hashed `/assets/*` files are served
`immutable`, but `index.html` is served `no-cache` so new asset hashes are always
picked up. If you previously ran a build that cached `index.html` aggressively,
hard-refresh once (Ctrl+Shift+R) or clear site data.

The server also raises Warp's max request-header length to 1 MB so a large shared
`localhost` cookie jar (cookies are shared across all `localhost` ports) cannot
trip the default header cap.

