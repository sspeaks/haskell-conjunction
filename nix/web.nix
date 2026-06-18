{ pkgs }:

# Builds the conjunction visualization frontend (web/) into a static bundle.
# The output is the Vite `dist/` directory, suitable for `conjunction-api
# --static-dir`.
pkgs.buildNpmPackage {
  pname = "conjunction-web";
  version = "0.1.0";

  # Exclude node_modules/dist so the source hash is stable and small.
  src = pkgs.lib.cleanSourceWith {
    src = ../web;
    filter =
      path: _type:
      let
        base = baseNameOf path;
      in
      base != "node_modules" && base != "dist";
  };

  # Replace with the hash printed by the first build attempt
  # (or run: prefetch-npm-deps web/package-lock.json).
  npmDepsHash = "sha256-AvzjBU0XHxHAElAYxUmJgiEuQGdroJ5rJ9QsmxYughM=";

  nodejs = pkgs.nodejs_22;

  # `npm run build` (tsc -b && vite build) emits to dist/.
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r dist/. $out/
    runHook postInstall
  '';

  # We only want the built static assets, not an installed npm package.
  dontNpmInstall = true;
}
