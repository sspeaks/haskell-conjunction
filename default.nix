{ pkgs, ... }:
let src = builtins.path { path = ./.; name = "source"; };
in
pkgs.haskellPackages.callCabal2nix "haskell-conjunction" src { }
