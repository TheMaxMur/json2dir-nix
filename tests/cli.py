#!/usr/bin/env python3
"""Black-box checks; Python is a test dependency only."""
import json
import os
from pathlib import Path
import random
import stat
import subprocess
import sys
import tempfile
import unittest


COMMAND = str(Path(sys.argv.pop(1)).resolve())


def run(root, data, args=(), mask=0o022):
    if not isinstance(data, bytes):
        data = json.dumps(data, ensure_ascii=False).encode()
    return subprocess.run(
        [COMMAND, *args], input=data, cwd=root, capture_output=True,
        preexec_fn=lambda: os.umask(mask),
    )


def snapshot(root):
    result = {}
    for entry in sorted(root.iterdir()):
        mode = entry.lstat().st_mode
        if stat.S_ISLNK(mode):
            result[entry.name] = ["link", os.readlink(entry)]
        elif stat.S_ISDIR(mode):
            result[entry.name] = snapshot(entry)
        else:
            text = entry.read_bytes().decode()
            result[entry.name] = ["script", text] if mode & 0o111 else text
    return result


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="json2dir-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def success(self, data, **kwargs):
        process = run(self.root, data, **kwargs)
        self.assertEqual(process.returncode, 0, process.stderr.decode(errors="replace"))
        self.assertEqual(process.stdout, b"")
        return process

    def test_example(self):
        tree = {
            "greeting": "Hello, world!",
            "dir": {"subfile": "Content.\n", "subdir": {}},
            "symlink": ["link", "target path"],
            "script": ["script", "#!/bin/sh\necho Howdy!"],
        }
        self.success(tree)
        self.assertEqual(snapshot(self.root), tree)

    def test_literal_bytes_and_names(self):
        tree = {
            "-option": "",
            "'\"$(`touch injected`)\n": "'; $(touch injected); `touch injected`; %s\\n\n\n",
            "unicode-Привет-🌍": "Привет 🌍\t\r\n\b\f\u0001",
            "back\\slash": "\\u0000 is literal, as is ${builtins.abort \"oops\"}",
            "script": ["script", "#!/bin/sh\nprintf '%s' '$HOME'\n\n"],
            "link": ["link", "-strange ' target\n"],
        }
        self.success(tree)
        self.assertEqual(snapshot(self.root), tree)
        self.assertFalse((self.root / "injected").exists())

    def test_duplicate_keys_and_components(self):
        self.success(b'{"a":"first","a":"last","dir//./":{"file":"text"}}')
        self.assertEqual(snapshot(self.root), {"a": "last", "dir": {"file": "text"}})

    def test_invalid_input_does_not_mutate(self):
        invalid = [
            b"", b"f", b"{} {}", b'{"x":"\xff"}', b'{"x":"\\ud800"}',
            b'{"x":"\\udc00"}', b'{"x":"before\\u0000after"}',
            b'{"x":"raw\x00nul"}', b'{"x":"raw\nnewline"}',
            b'{"x":1,}', b'{"x":NaN}', b'{"x":Infinity}',
            b'// comment\n{}', b'{"x":1e1000}',
            None, False, True, 1, 1.5, "root", [],
        ]
        for name in ["", ".", "..", "/", "/absolute", "./foo", "foo/bar", "foo/../x"]:
            invalid.append({name: "bad"})
        for value in [None, True, 1, [], ["link"], ["link", "x", "y"],
                      ["other", "x"], [1, "x"], ["script", {}]]:
            invalid.append({"a": "new", "z": {"bad": value}})
        (self.root / "a").write_text("old")
        for data in invalid:
            with self.subTest(data=data):
                process = run(self.root, data)
                self.assertEqual(process.returncode, 1)
                self.assertTrue(process.stderr)
                self.assertEqual(snapshot(self.root), {"a": "old"})

    def test_arguments(self):
        for args in [("--help",), ("file.json",), ("a", "b")]:
            with self.subTest(args=args):
                process = run(self.root, {}, args=args)
                self.assertEqual(process.returncode, 1)
                self.assertIn(b"Usage:", process.stderr)
                self.assertEqual(snapshot(self.root), {})

    def test_replacement_matrix(self):
        for old in ["missing", "file", "script", "link", "directory"]:
            for new in ["file", "script", "link", "directory"]:
                with self.subTest(old=old, new=new), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    target = root / "target"
                    target.mkdir()
                    (target / "untouched").write_text("safe")
                    entry = root / "entry"
                    if old in ("file", "script"):
                        entry.write_text("old")
                        entry.chmod(0o755 if old == "script" else 0o644)
                    elif old == "link":
                        entry.symlink_to("target")
                    elif old == "directory":
                        entry.mkdir()
                        (entry / "stale").write_text("keep")
                    value = {
                        "file": "new",
                        "script": ["script", "new"],
                        "link": ["link", "target"],
                        "directory": {"child": "new"},
                    }[new]
                    process = run(root, {"entry": value})
                    if old == "directory" and new != "directory":
                        self.assertEqual(process.returncode, 1)
                        self.assertEqual(snapshot(entry), {"stale": "keep"})
                    else:
                        self.assertEqual(process.returncode, 0, process.stderr)
                        expected = {"child": "new", "stale": "keep"} if old == new == "directory" else value
                        self.assertEqual(snapshot(root)["entry"], expected)
                    self.assertEqual(snapshot(target), {"untouched": "safe"})

    def test_dangling_symlink_replacement(self):
        (self.root / "file").symlink_to("missing")
        self.success({"file": "new"})
        self.assertFalse((self.root / "file").is_symlink())
        self.assertEqual((self.root / "file").read_bytes(), b"new")
        self.assertFalse((self.root / "missing").exists())

    def test_umask(self):
        for mask in [0o022, 0o077, 0o027, 0o777]:
            with self.subTest(mask=oct(mask)), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                archive = {"file": "x", "script": ["script", "x"]}
                if mask != 0o777:
                    archive["dir"] = {}
                process = run(root, archive, mask=mask)
                self.assertEqual(process.returncode, 0, process.stderr)
                expected_modes = [("file", 0o666 & ~mask), ("script", (0o666 & ~mask) | 0o111)]
                if mask != 0o777:
                    expected_modes.append(("dir", 0o777 & ~mask))
                for name, expected in expected_modes:
                    self.assertEqual(stat.S_IMODE((root / name).stat().st_mode), expected)

    @unittest.skipIf(os.geteuid() == 0, "root bypasses directory permission checks")
    def test_unsearchable_empty_directory(self):
        entry = self.root / "dir"
        entry.mkdir()
        entry.chmod(0o600)
        self.addCleanup(lambda: entry.chmod(0o700))
        process = run(self.root, {"dir": {}})
        self.assertEqual(process.returncode, 1)
        self.assertIn(b"./dir", process.stderr)

    def test_large_content(self):
        # Larger than common per-argument limits; stdin must not become argv.
        content = "Привет ' $() %s\\n\n" * 20000
        self.success({"large": content})
        self.assertEqual((self.root / "large").read_bytes(), content.encode())

    def test_generated_trees(self):
        rng = random.Random(20261006)

        def tree(depth=0):
            result = {}
            for index in range(rng.randrange(5)):
                name = f"entry-{index}-" + rng.choice(["x", "'", "\n", "Привет", "$()`"])
                choice = rng.randrange(4 if depth < 4 else 3)
                text = rng.choice(["", "hello\n\n", "' $() %s\\n", "🌍"])
                result[name] = [text, ["script", text], ["link", "../target '"], None][choice]
                if choice == 3:
                    result[name] = tree(depth + 1)
            return result

        for index in range(100):
            archive = tree()
            with self.subTest(index=index), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                process = run(root, archive)
                self.assertEqual(process.returncode, 0, process.stderr)
                self.assertEqual(snapshot(root), archive)


if __name__ == "__main__":
    unittest.main()
