# Space-Track LEO ingest service

This project exposes a `spacetrack-leo-ingest` executable and a NixOS module at
`nixosModules.spacetrack-leo-ingest`.

The service fetches current Space-Track `gp` records with `PERIAPSIS < 2000 km`
and stores only the latest active record per `NORAD_CAT_ID` in PostgreSQL. It
uses JSON as canonical input so future catalog numbers and Alpha-5 edge cases do
not depend on fixed-width TLE parsing.

## NixOS module usage

The module provisions a local PostgreSQL database by default when enabled:

```nix
{
  imports = [
    inputs.haskell-conjunction.nixosModules.spacetrack-leo-ingest
  ];

  sops.secrets.spacetrack-username = {
    owner = "spacetrack-ingest";
    group = "spacetrack-ingest";
  };

  sops.secrets.spacetrack-password = {
    owner = "spacetrack-ingest";
    group = "spacetrack-ingest";
  };

  services.spacetrack-leo-ingest = {
    enable = true;
    spacetrack.usernameFile = config.sops.secrets.spacetrack-username.path;
    spacetrack.passwordFile = config.sops.secrets.spacetrack-password.path;

    database.local.enable = true;
    database.local.user = "spacetrack-ingest";
  };
}
```

With local database mode enabled, the module sets:

- `services.postgresql.enable = true`
- `services.postgresql.ensureDatabases = [ database.local.name ]`
- `services.postgresql.ensureUsers` for the service database role
- systemd ordering so the ingest service runs after PostgreSQL

The default connection uses the PostgreSQL Unix socket at `/run/postgresql` and
does not require a database password. The local database name defaults to the
local database user (`spacetrack-ingest`) so NixOS can assign ownership with
`ensureDBOwnership`.

The Space-Track GP query is built into the executable. Set
`services.spacetrack-leo-ingest.queryUrl` only when you need to override the
default LEO-crossing query.

The regular timer uses `Persistent = true`, so missed calendar runs are caught
when the machine is next on. The module also enables a guarded catch-up timer by
default: `spacetrack-leo-ingest-catch-up.timer` runs after boot and hourly while
the machine is on, but the executable exits before contacting Space-Track if a
successful run already finished during the current local day.

## External database override

Use an external database only when local provisioning is disabled:

```nix
{
  sops.secrets.spacetrack-db-url = {
    owner = "spacetrack-ingest";
    group = "spacetrack-ingest";
  };

  services.spacetrack-leo-ingest = {
    database.local.enable = false;
    databaseUrlFile = config.sops.secrets.spacetrack-db-url.path;
  };
}
```

Prefer `databaseUrlFile` over `databaseUrl` when the connection string contains
credentials.

## Runtime command

The executable can be run directly:

```sh
spacetrack-leo-ingest \
  --spacetrack-username-file /run/secrets/spacetrack-username \
  --spacetrack-password-file /run/secrets/spacetrack-password \
  --database-host /run/postgresql \
  --database-name spacetrack-ingest \
  --database-user spacetrack-ingest
```

Use `--dry-run` to fetch and validate data without mutating the database.
Use `--skip-if-success-today` for catch-up jobs that should avoid a second
Space-Track request after the day's ingest has already succeeded.
