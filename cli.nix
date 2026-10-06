{ jsonFile }:
let
  json2dir = import ./lib.nix;
in
json2dir.toShell (json2dir.fromFile jsonFile)
