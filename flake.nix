{
  description = "json2dir implemented in Nix";
  inputs.nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/0.1";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
      forPkgs = function: eachSystem (system: function nixpkgs.legacyPackages.${system});
    in
    {
      lib = import ./lib.nix;
      overlays.default = final: _prev: {
        json2dir = final.callPackage ./default.nix { };
      };
      packages = forPkgs (pkgs: {
        default = pkgs.callPackage ./default.nix { };
        json2dir = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        example = self.lib.mkTree {
          inherit pkgs;
          name = "json2dir-example";
          tree = self.lib.fromFile ./example-tree.json;
        };
      });
      apps = eachSystem (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/json2dir";
        };
      });
      checks = forPkgs (pkgs: {
        library =
          assert import ./tests/lib.nix;
          pkgs.runCommand "json2dir-library-tests" { } ''touch "$out"'';
        cli =
          pkgs.runCommand "json2dir-cli-tests"
            {
              nativeBuildInputs = [
                pkgs.python3
                pkgs.coreutils
              ];
            }
            ''
              python3 ${./tests/cli.py} ${self.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/json2dir
              touch "$out"
            '';
        tree = pkgs.runCommand "json2dir-tree-tests" { } ''
          tree=${self.packages.${pkgs.stdenv.hostPlatform.system}.example}
          test "$(cat "$tree/greeting")" = 'Hello, world!'
          printf 'Content.\n' > expected
          cmp expected "$tree/dir/subfile"
          test -d "$tree/dir/subdir"
          test "$(readlink "$tree/symlink")" = 'target path'
          test -x "$tree/script"
          touch "$out"
        '';
        context =
          let
            reference = pkgs.writeText "json2dir-reference" "referenced content";
            tree = self.lib.mkTree {
              inherit pkgs;
              name = "json2dir-context-tree";
              tree = {
                link = [
                  "link"
                  "${reference}"
                ];
                path = "${reference}";
              };
            };
          in
          pkgs.runCommand "json2dir-context-tests" { } ''
            test "$(cat ${tree}/link)" = 'referenced content'
            test "$(cat ${tree}/path)" = '${reference}'
            touch "$out"
          '';
      });
      devShells = forPkgs (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            pkgs.nix
            pkgs.python3
            pkgs.nixfmt
            pkgs.shellcheck
          ];
        };
      });
      formatter = forPkgs (pkgs: pkgs.nixfmt);
    };
}
