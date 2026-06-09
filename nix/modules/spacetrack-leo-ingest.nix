{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.spacetrack-leo-ingest;
  inherit (lib) mkEnableOption mkIf mkOption optional optionalAttrs optionals types;

  packageForSystem =
    self.packages.${pkgs.stdenv.hostPlatform.system}.spacetrack-leo-ingest
      or self.packages.${pkgs.stdenv.hostPlatform.system}.default;

  databaseArgs =
    if cfg.database.local.enable then [
      "--database-host"
      cfg.database.local.host
      "--database-name"
      cfg.database.local.name
      "--database-user"
      cfg.database.local.user
    ] else if cfg.databaseUrlFile != null then [
      "--database-url-file"
      cfg.databaseUrlFile
    ] else [
      "--database-url"
      cfg.databaseUrl
    ];

  commandArgs = [
    "--spacetrack-username-file"
    cfg.spacetrack.usernameFile
    "--spacetrack-password-file"
    cfg.spacetrack.passwordFile
    "--request-timeout-seconds"
    (toString cfg.requestTimeoutSec)
    "--max-retries"
    (toString cfg.maxRetries)
    "--throttle-per-minute"
    (toString cfg.throttle.perMinute)
    "--throttle-per-hour"
    (toString cfg.throttle.perHour)
    "--throttle-min-spacing-seconds"
    (toString cfg.throttle.minSpacingSec)
  ] ++ optionals (cfg.queryUrl != null) [
    "--query-url"
    cfg.queryUrl
  ] ++ databaseArgs ++ cfg.extraArgs;

  guardedCommandArgs = commandArgs ++ [ "--skip-if-success-today" ];

  serviceConfig = {
    Type = "oneshot";
    User = cfg.user;
    Group = cfg.group;
    StateDirectory = "spacetrack-leo-ingest";
    WorkingDirectory = cfg.dataDir;
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    ReadWritePaths = [ cfg.dataDir ];
  };

  serviceOrdering = {
    after = [ "network-online.target" ] ++ optional cfg.database.local.enable "postgresql.service";
    wants = [ "network-online.target" ];
    requires = optional cfg.database.local.enable "postgresql.service";
  };
in
{
  options.services.spacetrack-leo-ingest = {
    enable = mkEnableOption "Space-Track LEO-crossing GP ingest service";

    package = mkOption {
      type = types.package;
      default = packageForSystem;
      defaultText = "self.packages.<system>.spacetrack-leo-ingest";
      description = "Package providing the spacetrack-leo-ingest executable.";
    };

    user = mkOption {
      type = types.str;
      default = "spacetrack-ingest";
      description = "System user used to run the ingest service.";
    };

    group = mkOption {
      type = types.str;
      default = "spacetrack-ingest";
      description = "System group used to run the ingest service.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/spacetrack-leo-ingest";
      description = "State directory for the ingest service.";
    };

    database.local.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Provision a local PostgreSQL database and user for the ingest service.";
    };

    database.local.name = mkOption {
      type = types.str;
      default = cfg.database.local.user;
      defaultText = "config.services.spacetrack-leo-ingest.database.local.user";
      description = "Local PostgreSQL database name. Defaults to the local database user because NixOS PostgreSQL ownership assertions require them to match when ensureDBOwnership is used.";
    };

    database.local.user = mkOption {
      type = types.str;
      default = cfg.user;
      defaultText = "config.services.spacetrack-leo-ingest.user";
      description = "Local PostgreSQL role used by the ingest service.";
    };

    database.local.host = mkOption {
      type = types.str;
      default = "/run/postgresql";
      description = "PostgreSQL Unix socket directory for the locally provisioned database.";
    };

    databaseUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "External PostgreSQL connection string. Prefer databaseUrlFile for secret-bearing URLs.";
    };

    databaseUrlFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to a file containing an external PostgreSQL connection string.";
    };

    spacetrack.usernameFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to a file containing the Space-Track username. Compatible with config.sops.secrets.<name>.path.";
    };

    spacetrack.passwordFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to a file containing the Space-Track password. Compatible with config.sops.secrets.<name>.path.";
    };

    queryUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      defaultText = "null";
      description = "Optional Space-Track GP query URL override. When unset, the executable uses its built-in LEO-crossing query.";
    };

    catchUp.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Run a guarded catch-up timer after boot and periodically while the machine is on.";
    };

    catchUp.onBootSec = mkOption {
      type = types.str;
      default = "5min";
      description = "Delay after boot before running the guarded catch-up service.";
    };

    catchUp.onCalendar = mkOption {
      type = types.nullOr types.str;
      default = "hourly";
      description = "Optional calendar schedule for guarded catch-up checks while the machine is on.";
    };

    catchUp.randomizedDelaySec = mkOption {
      type = types.str;
      default = "5min";
      description = "RandomizedDelaySec for the guarded catch-up timer.";
    };

    requestTimeoutSec = mkOption {
      type = types.ints.positive;
      default = 180;
      description = "HTTP request timeout in seconds.";
    };

    maxRetries = mkOption {
      type = types.ints.unsigned;
      default = 5;
      description = "Maximum retries for transient Space-Track request failures.";
    };

    throttle.perMinute = mkOption {
      type = types.ints.positive;
      default = 25;
      description = "Proactive per-minute Space-Track request cap.";
    };

    throttle.perHour = mkOption {
      type = types.ints.positive;
      default = 270;
      description = "Proactive per-hour Space-Track request cap.";
    };

    throttle.minSpacingSec = mkOption {
      type = types.float;
      default = 2.5;
      description = "Minimum spacing between Space-Track requests.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional command-line arguments passed to spacetrack-leo-ingest.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.spacetrack.usernameFile != null;
        message = "services.spacetrack-leo-ingest.spacetrack.usernameFile must be set.";
      }
      {
        assertion = cfg.spacetrack.passwordFile != null;
        message = "services.spacetrack-leo-ingest.spacetrack.passwordFile must be set.";
      }
      {
        assertion = cfg.database.local.enable || cfg.databaseUrl != null || cfg.databaseUrlFile != null;
        message = "Set database.local.enable = true or provide databaseUrl/databaseUrlFile.";
      }
    ];

    users.groups.${cfg.group} = { };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
    };

    services.postgresql = mkIf cfg.database.local.enable {
      enable = true;
      ensureDatabases = [ cfg.database.local.name ];
      ensureUsers = [
        {
          name = cfg.database.local.user;
          ensureDBOwnership = true;
        }
      ];
    };

    systemd.services.spacetrack-leo-ingest =
      {
        description = "Fetch latest Space-Track LEO-crossing GP records";
        wantedBy = [ ];
        inherit (serviceOrdering) after wants requires;
        script = "exec ${cfg.package}/bin/spacetrack-leo-ingest ${lib.escapeShellArgs commandArgs}";
        serviceConfig = serviceConfig;
      };

    systemd.services.spacetrack-leo-ingest-if-needed = {
      description = "Fetch latest Space-Track LEO-crossing GP records if today has not run";
      wantedBy = [ ];
      inherit (serviceOrdering) after wants requires;
      script = "exec ${cfg.package}/bin/spacetrack-leo-ingest ${lib.escapeShellArgs guardedCommandArgs}";
      serviceConfig = serviceConfig;
    };

    systemd.timers.spacetrack-leo-ingest-catch-up = mkIf cfg.catchUp.enable {
      description = "Catch up Space-Track LEO ingest after boot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        Unit = "spacetrack-leo-ingest-if-needed.service";
        OnBootSec = cfg.catchUp.onBootSec;
        RandomizedDelaySec = cfg.catchUp.randomizedDelaySec;
        Persistent = true;
      } // optionalAttrs (cfg.catchUp.onCalendar != null) {
        OnCalendar = cfg.catchUp.onCalendar;
      };
    };
  };
}
