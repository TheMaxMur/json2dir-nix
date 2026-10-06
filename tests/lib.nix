let
  lib = import ../lib.nix;
  accepts = value: (builtins.tryEval (builtins.deepSeq (lib.toShell value) true)).success;
  valid = [
    { }
    { file = ""; }
    { file = "Привет 🌍\n\n"; }
    {
      dir = {
        nested = { };
        file = "text";
      };
    }
    {
      link = [
        "link"
        "../target"
      ];
      script = [
        "script"
        "#!/bin/sh\n"
      ];
    }
    {
      "dir//./" = {
        file = "trailing separators";
      };
    }
    {
      "-option" = "value";
      "a'b\n\"$(`x`)" = "'; $(touch injected); %s\\n";
    }
  ];
  invalid = [
    null
    true
    false
    0
    1.5
    ""
    [ ]
    { "" = ""; }
    { "." = ""; }
    { ".." = ""; }
    { "/" = ""; }
    { "/abs" = ""; }
    { "./foo" = ""; }
    { "foo/bar" = ""; }
    { "foo/../bar" = ""; }
    { file = null; }
    { file = true; }
    { file = 3; }
    { file = [ ]; }
    { file = [ "link" ]; }
    {
      file = [
        "link"
        "target"
        "extra"
      ];
    }
    {
      file = [
        "unknown"
        "text"
      ];
    }
    {
      file = [
        1
        "text"
      ];
    }
    {
      file = [
        "script"
        { }
      ];
    }
    {
      deep = {
        nested = {
          "../outside" = "text";
        };
      };
    }
    {
      a = "valid first";
      z = {
        bad = false;
      };
    }
  ];
  parsed = lib.fromJSON ''{"a":"first","a":"last","dir":{},"script":["script","x"]}'';
in
assert builtins.all accepts valid;
assert builtins.all (value: !accepts value) invalid;
assert parsed.a == "last";
assert
  lib.fromFile ../example-tree.json == builtins.fromJSON (builtins.readFile ../example-tree.json);
assert lib.validate { a = "preserved"; } == { a = "preserved"; };
true
