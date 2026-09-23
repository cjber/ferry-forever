"""Regression tests for Lua expression-list expansion, using only the standard library."""

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("lint_multivalue", Path(__file__).parents[1] / "tools/lint_multivalue.py")
LINT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = LINT
SPEC.loader.exec_module(LINT)
PACK_SPEC = importlib.util.spec_from_file_location("pack_nav", Path(__file__).parents[1] / "tools/pack_nav.py")
PACK = importlib.util.module_from_spec(PACK_SPEC)
PACK_SPEC.loader.exec_module(PACK)


class CoverageTests(unittest.TestCase):
    def test_oversized_runtime_file_is_rejected(self):
        checker = Path(__file__).parents[1] / "tools/typecheck_coverage.py"
        with tempfile.TemporaryDirectory(prefix="spf-coverage-") as directory:
            root = Path(directory)
            (root / ".luarc.json").write_text(
                json.dumps(
                    {
                        "workspace.useGitIgnore": False,
                        "workspace.preloadFileSize": 30000,
                        "workspace.maxPreload": 10000,
                    }
                )
            )
            (root / "Addon.toc").write_text("Map.lua\n")
            with (root / "Map.lua").open("w") as output:
                output.truncate(10 * 1024 * 1024 + 1)
            result = subprocess.run(
                [sys.executable, str(checker)], cwd=root, capture_output=True, text=True, check=False
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("hard 10 MiB limit: Map.lua", result.stderr)

    def test_packing_preserves_all_fields_and_is_repeatable(self):
        source = "ShortestPathForeverPathData[1] = {\n\tcells = 4,\n"
        source += "".join(f'\t{field} = {{\n\t\t[1] = "' + "a" * 250 + '",\n\t},\n' for field in ("grid", "floor"))
        source += "}\n"
        with tempfile.TemporaryDirectory(prefix="spf-pack-") as directory:
            root = Path(directory)
            path = root / "Nav1.lua"
            path.write_text(source)
            toc = root / "ShortestPathForever_Nav1.toc"
            toc.write_text("## LoadOnDemand: 1\n\nNav1.lua\n")
            PACK.write_map(path, 500)
            once = {file.name: file.read_text() for file in root.iterdir()}
            self.assertIn("Nav1_floor.lua", once)
            self.assertIn("\tfloor = {},", once["Nav1.lua"])
            PACK.write_map(path, 500)
            self.assertEqual(once, {file.name: file.read_text() for file in root.iterdir()})
            # Rejoining for a larger limit must recover the original source exactly.
            PACK.write_map(path)
            self.assertEqual(path.read_text(), source)
            self.assertFalse((root / "Nav1_floor.lua").exists())


class MultivalueTests(unittest.TestCase):
    def test_expansion(self):
        for source in (
            "f(select(2, UnitClass(u)))",
            "obj:f(1, select(2, g()))",
            "local t = { 1, select(2, g()), }",
            "local t = { key = 1; select(2, g()); }",
            "return 1, select(2, g())",
            "return\n select(2, g())\nend",  # Wrapped in a block below.
        ):
            with self.subTest(source=source):
                if source.endswith("end"):
                    source = "do " + source
                self.assertEqual(len(LINT.lint(source)), 1)

    def test_single_result_contexts(self):
        for source in (
            "f((select(2, g())))",
            "f(select(2, g()), 1)",
            "local t = { select(2, g()), 1 }",
            "local t = { key = select(2, g()) }",
            "return (select(2, g()))",
            "return select(2, g()), 1",
            "local x, y = select(2, g())",
            "f(select(2, g()).field)",
            "f(select(2, g())[1])",
            "f(select(2, g()) + 1)",
            "f(not select(2, g()))",
            "f(lib.select(2, g()))",
            "f(lib:select(2, g()))",
        ):
            with self.subTest(source=source):
                self.assertEqual(LINT.lint(source), [])

    def test_lexical_boundaries(self):
        source = r"""-- f(select(2, g()))
local s = "f(select(2, g())) \\\""
local t = 'f(select(2, g())) \\ '
local u = [==[ f(select(2, g())) ]=] ]==]
--[=[ f(select(2, g())) ]=]
local v = 2.5e-3 + 0xff + .5
f(select -- ignored delimiter: )
(2, g()))
"""
        self.assertEqual(LINT.lint(source), [(7, "last call argument")])

    def test_nested_functions_and_blocks(self):
        source = """local function run(...)
if true then
    f(function() return select(2, ...) end)
elseif false then
    repeat f(select(2, g())) until ready
else
    for k, v in pairs({}) do local x = { select(2, g()) } end
end
while ready do ready = false end
end
function object.method:call() return 1 end
"""
        self.assertEqual(len(LINT.lint(source)), 3)

    def test_reason_is_required_and_scoped(self):
        for source in (
            "f(select(2, g())) -- multi-value: forward both coordinates",
            "return select(2, g()); -- multi-value: forward the tail",
            "local t = {select(2, g())} -- multi-value: retain all results",
        ):
            self.assertEqual(LINT.lint(source), [])
        for source in (
            "f(select(2, g())) -- multi-value:",
            "f(select(2, g())) -- multi-value:   ",
            "-- multi-value: unrelated\nf(select(2, g()))",
            'local s = "-- multi-value: fake"; f(select(2, g()))',
            "f(select(2, g())) --[=[ multi-value: fake ]=]",
        ):
            self.assertEqual(len(LINT.lint(source)), 1)

    def test_bad_input_fails_closed(self):
        for source in ("f(select(2, g())", "local s = 'oops", "--[=[oops", "end", "local = 1"):
            with self.subTest(source=source), self.assertRaises(ValueError):
                LINT.lint(source)


def write_strict_fixture(root, fixture):
    config = json.loads((root / ".luarc.json").read_text())
    config["workspace.library"] = [str(root / library) for library in config["workspace.library"]]
    # Real namespace exports and generated headers must keep their type information too.
    for source in root.glob("*.lua"):
        shutil.copy2(source, fixture / source.name)
    for source in [root / "types", root / "Data", *root.glob("ShortestPathForever_Nav*")]:
        shutil.copytree(source, fixture / source.name)
    for name, mistake in (("Data/Routes.lua", "ns.Routes[241].period = false"),):
        with (fixture / name).open("a") as output:
            output.write("\n" + mistake + "\n")
    for map_id in (0, 1, 2991):
        path = fixture / f"ShortestPathForever_Nav{map_id}/Nav{map_id}.lua"
        path.write_text(path.read_text().replace("\tcells = 67,", '\tcells = "bad",'))
    path = fixture / "ShortestPathForever_Nav1/Nav1_floor.lua"
    path.write_text(path.read_text().replace(".floor = {", ".floor = { false,", 1))
    (fixture / ".luarc.json").write_text(json.dumps(config))
    (fixture / "probe.lua").write_text("""
C_ClassColor.GetClassColor("MAGE", 1)
C_ClassColor.GetClassColor(false)
C_ClassColor.GetClassColor()
MissingForeverGlobal()
---@class ProbeFrame : Frame
local frame = CreateFrame("Frame")
frame.MissingField()
---@type Frame?
local maybe
maybe:Show()
---@type number
local value = "bad"
---@return number
local function badReturn() return "bad" end
---@return number
local function noReturn() print("missing") end
---@return number
local function extraReturn() return 1, 2 end
local changing = 1
changing = "bad"
local unused = 1
print(value, badReturn(), noReturn(), extraReturn(), changing)
---@class SPFNamespace
local ns = select(2, ...)
ns.Model.FormatCountdown("bad")
ns.NoSuchExport()
""")


class LuaLSGateTests(unittest.TestCase):
    def test_clean_report_and_information_diagnostic(self):
        reporter = Path(__file__).parents[1] / "tools/typecheck_report.py"
        with tempfile.TemporaryDirectory(prefix="spf-typecheck-") as directory:
            root = Path(directory)
            report = root / "diagnostics.json"
            missing = subprocess.run(
                [sys.executable, str(reporter), str(report)], capture_output=True, text=True, check=False
            )
            self.assertEqual(missing.returncode, 1)
            for payload in (
                [],
                {},
                {
                    (root / "probe.lua").as_uri(): [
                        {
                            "code": "unused-local",
                            "severity": 3,
                            "message": "Unused local.",
                            "range": {"start": {"line": 2}},
                        }
                    ]
                },
            ):
                report.write_text(json.dumps(payload))
                result = subprocess.run(
                    [sys.executable, str(reporter), str(report)],
                    cwd=root,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, int(bool(payload)), result.stderr)
                if payload:
                    self.assertIn("probe.lua:3: unused-local: Unused local.", result.stdout)

    def test_strict_diagnostics_are_active(self):
        root = Path(__file__).parents[1]
        with tempfile.TemporaryDirectory(prefix="spf-typecheck-") as directory:
            fixture = Path(directory)
            write_strict_fixture(root, fixture)
            report = fixture / "diagnostics.json"
            result = subprocess.run(
                [
                    "lua-language-server",
                    "--check",
                    str(fixture),
                    "--checklevel=Information",
                    "--check_format=json",
                    f"--check_out_path={report}",
                    f"--logpath={fixture / 'log'}",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertTrue(report.exists(), result.stdout + result.stderr)
            diagnostics_by_file = json.loads(report.read_text())
            codes = {d["code"] for d in diagnostics_by_file[(fixture / "probe.lua").as_uri()]}
            expected = {
                "param-type-mismatch",
                "redundant-parameter",
                "missing-parameter",
                "undefined-field",
                "undefined-global",
                "need-check-nil",
                "assign-type-mismatch",
                "return-type-mismatch",
                "cast-local-type",
                "redundant-return-value",
                "missing-return",
                "unused-local",
            }
            self.assertFalse(expected - codes, f"LuaLS stopped reporting: {sorted(expected - codes)}")
            printer = subprocess.run(
                [sys.executable, str(root / "tools/typecheck_report.py"), str(report)],
                cwd=fixture,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(printer.returncode, 1)
            self.assertIn("probe.lua:2: redundant-parameter:", printer.stdout)
            self.assertIn("Undefined field `NoSuchExport`", printer.stdout)
            self.assertIn("probe.lua:26: param-type-mismatch:", printer.stdout)
            for name in (
                "Data/Routes.lua",
                "ShortestPathForever_Nav0/Nav0.lua",
                "ShortestPathForever_Nav1/Nav1.lua",
                "ShortestPathForever_Nav1/Nav1_floor.lua",
                "ShortestPathForever_Nav2991/Nav2991.lua",
            ):
                codes = {d["code"] for d in diagnostics_by_file.get((fixture / name).as_uri(), [])}
                self.assertIn("assign-type-mismatch", codes, f"Types lost or file skipped: {name}")


if __name__ == "__main__":
    unittest.main()
