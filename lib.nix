# Conversion and validation use only Nix builtins; nixpkgs is needed only by mkTree.
let
  inherit (builtins)
    attrNames
    concatStringsSep
    deepSeq
    elemAt
    filter
    fromJSON
    isAttrs
    isList
    isString
    length
    map
    replaceStrings
    split
    substring
    throw
    toJSON
    ;

  quote = text: "'" + replaceStrings [ "'" ] [ "'\\''" ] text + "'";
  fail = context: message: throw "json2dir: ${message} at ${toJSON context}";

  # Rust's POSIX Path::components ignores trailing slashes and interior '.'.
  component =
    context: name:
    let
      parts = filter (part: isString part && part != "" && part != ".") (split "/" name);
      startsWithDot = name == "." || substring 0 2 name == "./";
    in
    if name == "" then
      fail context "the key ${toJSON name} must have exactly one path component"
    else if substring 0 1 name == "/" || startsWithDot then
      fail context "the key ${toJSON name} is not a normal relative path component"
    else if length parts != 1 then
      fail context "the key ${toJSON name} must have exactly one path component"
    else if elemAt parts 0 == ".." then
      fail context "the key ${toJSON name} is not a normal relative path component"
    else
      elemAt parts 0;

  walk =
    context: tree:
    map (
      name:
      let
        path = "${context}/${component context name}";
        value = tree.${name};
      in
      if isAttrs value then
        {
          kind = "directory";
          inherit path;
          children = walk path value;
        }
      else if isString value then
        {
          kind = "file";
          inherit path;
          payload = value;
        }
      else if isList value then
        if length value != 2 || !isString (elemAt value 0) || !isString (elemAt value 1) then
          fail path "expected an array of the form [type, payload], both strings"
        else if
          !(builtins.elem (elemAt value 0) [
            "link"
            "script"
          ])
        then
          fail path "expected an array tag of either \"link\" or \"script\""
        else
          {
            kind = elemAt value 0;
            inherit path;
            payload = elemAt value 1;
          }
      else
        fail path "expected an object, a string, or a [type, payload] array"
    ) (attrNames tree);

  nodes =
    tree:
    if !isAttrs tree then
      fail "." "expected the provided JSON to be an object"
    else
      let
        result = walk "." tree;
      in
      deepSeq result result;

  render =
    entries:
    concatStringsSep "\n" (
      map (
        entry:
        let
          path = quote entry.path;
        in
        "_json2dir_remove ${path}\n"
        + (
          if entry.kind == "directory" then
            "_json2dir_directory ${path}\n${render entry.children}"
          else
            "_json2dir_${entry.kind} ${path} ${quote entry.payload}"
        )
      ) entries
    );

  # All input is single-quoted data. printf's format is constant, so neither
  # shell expansion nor backslash/percent interpretation can alter file bytes.
  helpers = ''
    set -eu
    _json2dir_error() {
      printf 'Error: couldn\047t create %s at %s.\n' "$1" "$2" >&2
      exit 1
    }
    _json2dir_remove() {
      rm -f -- "$1" 2>/dev/null || :
    }
    _json2dir_directory() {
      if [ ! -d "$1" ]; then
        mkdir -- "$1" || _json2dir_error directory "$1"
      fi
      # The original enters even empty directories, so require search access.
      (cd -- "$1") || _json2dir_error directory "$1"
    }
    _json2dir_file() {
      printf '%s' "$2" > "$1" || _json2dir_error file "$1"
    }
    _json2dir_script() {
      printf '%s' "$2" > "$1" || _json2dir_error script "$1"
      chmod a+x "$1" || _json2dir_error script "$1"
    }
    _json2dir_link() {
      # ln normally puts a link *inside* an existing destination directory.
      if [ -d "$1" ]; then
        _json2dir_error symlink "$1"
      fi
      ln -s -- "$2" "$1" || _json2dir_error symlink "$1"
    }
  '';

  validate = tree: deepSeq (nodes tree) tree;
  toShell = tree: helpers + render (nodes tree) + "\n";
in
{
  inherit validate toShell;
  fromJSON = text: validate (fromJSON text);
  fromFile = path: validate (fromJSON (builtins.readFile path));

  mkTree =
    {
      pkgs,
      tree,
      name ? "json2dir-tree",
    }:
    pkgs.runCommand name { } ''
      mkdir -p "$out"
      cd "$out"
      ${toShell tree}
    '';
}
