"""tests/test-jsonio.py

Pins scripts/lib/jsonio.py -- the stdlib jq replacement. python3 is already
spawned on every hook fire and is a hard dependency; jq was a second one, and
on Windows the only supported way to get it was a separate winget install. Every
runtime use of jq in this project is a small JSON read or write, so it is
replaced by this module rather than kept as a dependency.

The `set` half also removes a real defect it inherits from: the writers it
replaces were `cat` heredocs interpolating shell values straight into JSON,
which a session id containing a quote would have corrupted.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JSONIO = ROOT / "scripts" / "lib" / "jsonio.py"


def run(args, stdin_text=None):
    return subprocess.run([sys.executable, str(JSONIO), *args],
                          input=stdin_text, capture_output=True, text=True)


class GetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = Path(self.tmp) / "doc.json"
        self.path.write_text(json.dumps({
            "session_id": "abc-123",
            "turns": 7,
            "flag": True,
            "nested": {"inner": "deep"},
            "nothing": None,
        }), encoding="utf-8")

    def test_string_value_is_printed_raw(self):
        out = run(["get", str(self.path), "session_id"])
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout, "abc-123\n")

    def test_number_and_bool_print_as_json(self):
        out = run(["get", str(self.path), "turns", "flag"])
        self.assertEqual(out.stdout, "7\ntrue\n")

    def test_missing_and_null_keys_print_an_empty_line_each(self):
        # One line per key, always: the bash callers read N values with N reads,
        # so a missing key must consume its line rather than shift the rest.
        out = run(["get", str(self.path), "absent", "nothing", "session_id"])
        self.assertEqual(out.returncode, 0)
        self.assertEqual(out.stdout, "\n\nabc-123\n")

    def test_nested_key_via_dots(self):
        out = run(["get", str(self.path), "nested.inner"])
        self.assertEqual(out.stdout, "deep\n")

    def test_reads_stdin_with_dash(self):
        out = run(["get", "-", "session_id"], stdin_text='{"session_id":"from-stdin"}')
        self.assertEqual(out.stdout, "from-stdin\n")

    def test_malformed_json_exits_3(self):
        out = run(["get", "-", "session_id"], stdin_text="{not json")
        self.assertEqual(out.returncode, 3)

    def test_missing_file_exits_3(self):
        out = run(["get", str(Path(self.tmp) / "nope.json"), "k"])
        self.assertEqual(out.returncode, 3)


class SetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = Path(self.tmp) / "state.json"

    def test_creates_file_at_0600(self):
        out = run(["set", str(self.path), "session_id=abc"])
        self.assertEqual(out.returncode, 0, out.stderr)
        probe = Path(self.tmp) / "probe"
        probe.write_text("x")
        os.chmod(probe, 0o600)
        if oct(probe.stat().st_mode)[-3:] != "600":
            self.skipTest("filesystem does not enforce chmod (probed)")
        self.assertEqual(oct(self.path.stat().st_mode)[-3:], "600")

    def test_round_trips_values_containing_quotes_and_newlines(self):
        hostile = 'he said "hi"\nand a newline'
        run(["set", str(self.path), "note=" + hostile])
        self.assertEqual(json.loads(self.path.read_text())["note"], hostile)

    def test_json_prefixed_values_are_typed(self):
        run(["set", str(self.path), "n=json:5", "b=json:true", "s=5"])
        obj = json.loads(self.path.read_text())
        self.assertEqual(obj["n"], 5)
        self.assertIs(obj["b"], True)
        self.assertEqual(obj["s"], "5")

    def test_preserves_existing_keys(self):
        self.path.write_text(json.dumps({"keep": "me"}), encoding="utf-8")
        run(["set", str(self.path), "add=new"])
        obj = json.loads(self.path.read_text())
        self.assertEqual(obj, {"keep": "me", "add": "new"})

    def test_nested_key_via_dots(self):
        run(["set", str(self.path), "a.b=deep"])
        self.assertEqual(json.loads(self.path.read_text())["a"]["b"], "deep")

    def test_leaves_no_temp_residue(self):
        run(["set", str(self.path), "k=v"])
        self.assertEqual([p.name for p in Path(self.tmp).iterdir()], ["state.json"])

    def test_unparseable_existing_file_exits_3_and_is_not_clobbered(self):
        self.path.write_text("{not json", encoding="utf-8")
        out = run(["set", str(self.path), "k=v"])
        self.assertEqual(out.returncode, 3)
        self.assertEqual(self.path.read_text(), "{not json")


class KeysTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = Path(self.tmp) / "usage.json"

    def test_prints_top_level_keys_one_per_line(self):
        self.path.write_text(json.dumps({"b": 1, "a": 2}), encoding="utf-8")
        out = run(["keys", str(self.path)])
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(sorted(out.stdout.split()), ["a", "b"])

    def test_non_object_exits_3(self):
        self.path.write_text("[1,2]", encoding="utf-8")
        self.assertEqual(run(["keys", str(self.path)]).returncode, 3)

    def test_missing_file_is_empty_and_exits_0(self):
        # A store with no .usage.json yet is not an error: the callers this
        # replaces used `jq ... 2>/dev/null` and iterated zero times.
        out = run(["keys", str(Path(self.tmp) / "absent.json")])
        self.assertEqual(out.returncode, 0)
        self.assertEqual(out.stdout, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
