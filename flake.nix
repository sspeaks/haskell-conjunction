{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = inputs@{ self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        package = import ./default.nix { inherit pkgs; };
        devShell = import ./shell.nix { inherit pkgs; };
      in
      {
        packages = {
          default = package;
          spacetrack-leo-ingest = package;
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
