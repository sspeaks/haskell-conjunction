{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = inputs@{ self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs { inherit system; };
          package = import ./default.nix { inherit pkgs; };
          devShell = import ./shell.nix { inherit pkgs; };
          postgresGui = pkgs.writeShellApplication {
            name = "postgregui";
            text = ''
              pgweb=${pkgs.pgweb}/bin/pgweb
              database_url='postgres:///spacetrack-ingest?host=/run/postgresql&user=spacetrack-ingest&sslmode=disable'

              if [ "$(${pkgs.coreutils}/bin/id -un)" = "spacetrack-ingest" ]; then
                exec "$pgweb" --readonly --url "$database_url" "$@"
              fi

              if [ -x /run/wrappers/bin/sudo ]; then
                sudo_bin=/run/wrappers/bin/sudo
              else
                sudo_bin="$(command -v sudo || true)"
              fi

              if [ -z "$sudo_bin" ]; then
                printf 'postgregui: sudo is required to run pgweb as spacetrack-ingest\n' >&2
                exit 127
              fi

              exec "$sudo_bin" -u spacetrack-ingest "$pgweb" --readonly --url "$database_url" "$@"
            '';
          };
        in
        {
          packages = {
            default = package;
            spacetrack-leo-ingest = package;
            conjunction-screen = package;
            postgregui = postgresGui;
            postgres-gui = postgresGui;
          };
          apps = {
            default = {
              type = "app";
              program = "${package}/bin/spacetrack-leo-ingest";
            };
            spacetrack-leo-ingest = {
              type = "app";
              program = "${package}/bin/spacetrack-leo-ingest";
            };
            conjunction-screen = {
              type = "app";
              program = "${package}/bin/conjunction-screen";
            };
            postgregui = {
              type = "app";
              program = "${postgresGui}/bin/postgregui";
            };
            postgres-gui = {
              type = "app";
              program = "${postgresGui}/bin/postgregui";
            };
          };
          devShells.default = devShell;
          formatter = pkgs.nixpkgs-fmt;

          # Compatibility aliases for older flake callers.
          defaultPackage = package;
          devShell = devShell;
        }) // {
      nixosModules.spacetrack-leo-ingest = import ./nix/modules/spacetrack-leo-ingest.nix { inherit self; };
    };
}
