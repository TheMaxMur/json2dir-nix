# json2dir in Nix

A Nix port of [alurm/json2dir](https://github.com/alurm/json2dir). JSON parsing,
validation, traversal, and command generation are implemented in `lib.nix`
using only Nix builtins. A small shell launcher supplies stdin and executes the
generated filesystem operations; Nix evaluation cannot write arbitrary files.
There is no Rust, Scheme, Python, or jq runtime dependency.

```sh
# With Nix installed, run straight from this checkout:
cd /path/to/output
/path/to/json2dir-nix/json2dir < /path/to/example-tree.json

# Build or run the packaged command (includes Nix and coreutils):
nix build /path/to/json2dir-nix
nix run /path/to/json2dir-nix < /path/to/example-tree.json
```

The CLI accepts no arguments. It reads JSON from stdin, writes the tree into
the current directory, and returns 0 on success or 1 on failure. Errors go to
stderr.

## Format

```json
{
  "greeting": "Hello, world!",
  "dir": {
    "subfile": "Content.\n",
    "subdir": {}
  },
  "symlink": ["link", "target path"],
  "script": ["script", "#!/bin/sh\necho Howdy!"]
}
```

| JSON value | Filesystem entry |
| --- | --- |
| Object | Directory, populated recursively |
| String | File containing exactly that UTF-8 text |
| `["link", "target"]` | Symlink to the given target |
| `["script", "content"]` | File with all three execute bits added |

The root must be an object. Numbers, booleans, null, malformed arrays, and
unknown tags are rejected. Keys must have one normal relative POSIX path
component. Empty names, `.`, `..`, absolute paths, `./foo`, and `foo/bar` are
rejected. As in the original, trailing separators and interior `.` are
normalized: `{"dir//./": {}}` creates `dir`. Use nested objects for subdirectories.

## Nix library

Importing `lib.nix` requires no nixpkgs. The flake exports the same API as `lib`.

```nix
let
  json2dir = import ./lib.nix;
in
json2dir.mkTree {
  inherit pkgs;
  name = "my-config";
  tree = {
    ".config".git.config = ''
      [user]
      name = Example
    '';
    bin.hello = [ "script" "#!/bin/sh\necho hello\n" ];
  };
}
```

`mkTree` returns a derivation containing the tree in `$out`, including empty
directories, symlinks, and executable files. It uses `pkgs.runCommand` for the
filesystem operations. To build the bundled example:

```sh
nix build .#example --out-link result-example
```

The library also exposes:

- `fromJSON text`: parse and validate a JSON string; return the tree.
- `fromFile path`: read, parse, and validate a JSON file; return the tree.
- `validate tree`: validate a native Nix attribute set; return it unchanged.
- `toShell tree`: return a shell script that writes a validated tree into the
  current directory. Run it with a POSIX shell and standard Unix tools.
- `mkTree { pkgs, tree, name ? "json2dir-tree" }`: build an immutable store tree.

Native Nix strings retain their store context, so interpolated package paths
in `mkTree` become build dependencies. The flake also provides a default
overlay exposing `pkgs.json2dir`.

## Compatibility and limits

Keys are processed in lexical order; duplicate JSON keys use the last value.
Existing files and symlinks are unlinked before replacement without modifying
symlink targets. Existing directories are reused and unrelated entries remain.
A real directory cannot be replaced with a file, script, or symlink. CLI file
permissions follow the current umask; scripts additionally receive bits `0111`.
Store builds follow Nix's immutable-store permission rules.

Two deliberate differences from the Rust version:

- The whole tree is validated before modifying any destination entries.
  Invalid JSON or invalid nodes leave the destination unchanged. Filesystem
  errors during execution can still leave a partially applied tree.
- Nix strings cannot contain NUL bytes. JSON strings with `\u0000` are rejected
  by `builtins.fromJSON`, including in file contents. Literal text `\\u0000`
  is preserved. JSON nesting limits and parser diagnostics follow Nix rather
  than serde_json.

The CLI uses impure evaluation solely to read its temporary stdin file and
does not copy input into the Nix store. Store builds, including `mkTree`, put
contents into the store as usual. The implementation targets macOS and Linux;
concurrent filesystem changes and symlink races are not guarded against.

## Checks

```sh
nix eval --file tests/lib.nix
python3 tests/cli.py ./json2dir
nix flake check
nix fmt
```

Python is used only by the black-box tests. The suite covers invalid input,
literal bytes and shell metacharacters, every replacement combination, umasks,
large stdin input, and 100 deterministic generated trees. Flake checks also
exercise the native library and the generated store tree.

The original was inspected at commit `b2072fb5515a603024c123297b27dcaabfdf098a`
on 2026-10-06. Its ISC license and attribution are retained in `LICENSE`.
