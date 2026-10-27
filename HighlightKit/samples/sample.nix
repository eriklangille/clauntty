# Dev shell for rtach
{ pkgs ? import <nixpkgs> { } }:

let
  zig = pkgs.zig_0_16;
in
pkgs.mkShell {
  name = "rtach-dev";
  packages = [ zig pkgs.bun pkgs.git ];
  shellHook = ''
    echo "zig ${zig.version}"
  '';
  ZIG_GLOBAL_CACHE_DIR = "/tmp/zig-cache";
  doCheck = true;
}
