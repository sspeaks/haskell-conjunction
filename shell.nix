{ pkgs, ... }:
pkgs.haskellPackages.shellFor {
  packages = hpkgs: [
    (import ./default.nix { inherit pkgs; })
  ];
  nativeBuildInputs = (with pkgs; [
    gcc
    pkg-config
    postgresql
  ]) ++ (with pkgs.haskellPackages; [
    haskell-language-server
    cabal-install
    stylish-haskell
  ]);
}
