{
  lib,
  writeShellApplication,
  nix,
  coreutils,
  runtimeShell,
}:
let
  evaluator = builtins.toFile "json2dir-cli.nix" ''
    { jsonFile }:
    let json2dir = import ${./lib.nix};
    in json2dir.toShell (json2dir.fromFile jsonFile)
  '';
in
writeShellApplication {
  name = "json2dir";
  runtimeInputs = [
    nix
    coreutils
  ];
  text = ''
    export JSON2DIR_EVALUATOR=${evaluator}
    export JSON2DIR_NIX=${nix}/bin/nix
    export JSON2DIR_SHELL=${runtimeShell}
    ${builtins.replaceStrings [ "#!/bin/sh\n" ] [ "" ] (builtins.readFile ./json2dir)}
  '';
  meta = {
    description = "Convert JSON objects to directory trees using the Nix language";
    license = lib.licenses.isc;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "json2dir";
  };
}
