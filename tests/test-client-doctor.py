#!/usr/bin/env python3
"""Read-only client inspection through the public wrapper, under isolated client homes."""

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

from installation_fixture import stage


REPO = Path(__file__).resolve().parent.parent


class ClientDoctorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if "BEAM_TEST_INSTALLATION" in os.environ:
            cls.installation = Path(os.environ["BEAM_TEST_INSTALLATION"]).resolve()
        else:
            temporary = tempfile.TemporaryDirectory(prefix="beam-client-doctor-installation-")
            cls.addClassCleanup(temporary.cleanup)
            cls.installation = Path(temporary.name).resolve()
            stage(cls.installation)
        cls.wrapper = cls.installation / "bin/lean-beam"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="beam-client-doctor-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.workspace = self.root / "workspace"
        self.home.mkdir()
        self.workspace.mkdir()
        (self.workspace / ".git").mkdir()
        self.env = os.environ.copy()
        for key in (
            "BEAM_HOME", "CODEX_HOME", "CLAUDE_HOME", "CLAUDE_CONFIG_DIR", "BEAM_CLAUDE_MCP_CONFIG",
            "PI_CODING_AGENT_DIR", "XDG_CONFIG_HOME", "OPENCODE_CONFIG_DIR",
            "OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "VIBE_HOME",
        ):
            self.env.pop(key, None)
        self.env["HOME"] = str(self.home)
        # Even a --version or mcp list invocation would leave this marker.
        self.executable = self.root / "bin with spaces" / "lean-beam-mcp"
        self.marker = self.root / "unexpected-execution"
        self.write(self.executable, f"#!/bin/sh\ntouch '{self.marker}'\nexit 99\n")
        self.executable.chmod(0o755)
        sentinel_bin = self.root / "client-sentinels"
        for name in ["codex", "claude", "pi", "opencode", "vibe", "lean", "lake", "elan"]:
            sentinel = sentinel_bin / name
            self.write(sentinel, self.executable.read_text())
            sentinel.chmod(0o755)
        self.env["PATH"] = str(sentinel_bin) + os.pathsep + self.env["PATH"]

    @staticmethod
    def write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def json_file(self, path, data):
        self.write(path, json.dumps(data))

    def snapshot(self):
        result = {}
        for path in sorted(self.root.rglob("*")):
            metadata = path.lstat()
            content = None
            if stat.S_ISLNK(metadata.st_mode):
                content = os.readlink(path)
            elif stat.S_ISREG(metadata.st_mode):
                content = hashlib.sha256(path.read_bytes()).hexdigest()
            # Reads may update atime; creation, modification, permissions, and content must not change.
            result[str(path.relative_to(self.root))] = (
                metadata.st_mode, metadata.st_mtime_ns, content,
            )
        return result

    def run_doctor(self, *args, expected=0, as_json=True, global_args=()):
        before = self.snapshot()
        command = [str(self.wrapper), *global_args, "doctor", "clients", *args]
        if as_json:
            command.append("--json")
        result = subprocess.run(
            command, cwd=self.workspace, env=self.env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, expected, (result.stdout, result.stderr))
        self.assertEqual(before, self.snapshot(), "doctor changed inspected files or created state")
        self.assertFalse(self.marker.exists(), "doctor launched the configured executable")
        if as_json:
            self.assertEqual(result.stderr, "")
            report = json.loads(result.stdout)
            self.assertEqual(report["kind"], "clientInspection")
            return report
        return result

    @staticmethod
    def findings(report, client=None):
        return [
            item for entry in report["clients"]
            if client is None or entry["client"] == client
            for item in entry["findings"]
        ]

    def has_code(self, report, code, status=None):
        self.assertTrue(any(
            item["code"] == code and (status is None or item["status"] == status)
            for item in self.findings(report)
        ), report)

    def codex_config(self, command=None, extra=""):
        self.write(self.home / ".codex" / "config.toml", (
            "[mcp_servers.'lean-beam']\n"
            f"command = {json.dumps(str(command or self.executable))}\n"
            "supports_parallel_tool_calls = true\n" + extra
        ))

    def test_empty_discovery_and_explicit_optional_integrations(self):
        self.assertEqual(self.run_doctor()["clients"], [])
        report = self.run_doctor("pi")
        self.has_code(report, "mcp.notApplicable", "notConfigured")
        self.has_code(report, "skill.notConfigured", "notConfigured")

    def test_empty_discovery_asks_for_the_users_client(self):
        report = self.run_doctor()
        self.assertEqual(report["clients"], [])
        self.assertIn("lean-beam doctor clients codex --verbose", report["remediation"])
        for args in [(), ("--verbose",)]:
            text = self.run_doctor(*args, as_json=False).stdout
            self.assertIn(report["remediation"], text)
            self.assertIn(str(self.workspace), text)
            self.assertNotIn("codex: not configured", text)
            self.assertNotIn("claude: not configured", text)

    def test_missing_mcp_has_optional_manual_setup_reminders(self):
        self.write(self.home / ".codex/skills/lean-beam/SKILL.md", "Lean skill\n")
        for client, command in [("codex", "codex mcp add lean-beam"),
                                ("claude", "claude mcp add --scope user lean-beam"),
                                ("opencode", "opencode mcp add"),
                                ("vibe", "[[mcp_servers]]")]:
            with self.subTest(client=client):
                report = self.run_doctor(client)
                finding = next(f for f in self.findings(report) if f["code"] == "mcp.notConfigured")
                self.assertEqual(finding["status"], "notConfigured")
                self.assertIn(command, finding["remediation"])
                self.assertIn("docs/SETUP.md#mcp-setup", finding["remediation"])
                for args in [(client,), (client, "--verbose")]:
                    text = self.run_doctor(*args, as_json=False).stdout
                    self.assertIn(finding["remediation"], text)
                    for source in report["clients"][0]["sources"]:
                        if "--verbose" in args:
                            self.assertIn(source["path"], text)
                        else:
                            self.assertNotIn(source["path"], text)
        discovered = self.run_doctor()
        self.assertEqual([c["client"] for c in discovered["clients"]], ["codex"])
        self.assertNotIn("remediation", discovered)
        self.assertIn("codex mcp add lean-beam", self.run_doctor(as_json=False).stdout)

    def test_missing_skill_has_optional_setup_reminder_without_mcp_repair(self):
        self.codex_config()
        report = self.run_doctor("codex")
        finding = next(f for f in self.findings(report) if f["code"] == "skill.notConfigured")
        self.assertEqual(finding["status"], "notConfigured")
        self.assertIn("complete skills/lean-beam directory", finding["remediation"])
        self.assertIn("docs/SETUP.md#install-the-lean-skill-manually", finding["remediation"])
        for args in [("codex",), ("codex", "--verbose")]:
            text = self.run_doctor(*args, as_json=False).stdout
            self.assertIn(finding["remediation"], text)
            self.assertNotIn("codex mcp add", text)
            for source in report["clients"][0]["sources"]:
                if "--verbose" in args:
                    self.assertIn(source["path"], text)
                else:
                    self.assertNotIn(source["path"], text)
        compact = self.run_doctor("codex", as_json=False).stdout
        self.assertIn("Setup reminder:", compact)
        self.assertIn("0 errors, 0 unverified checks, 0 recommendations, 1 setup reminder.", compact)

    def test_explicit_file_reminder_stays_within_the_selected_scope(self):
        self.codex_config()
        selected = self.root / "selected.toml"
        self.write(selected, "")
        report = self.run_doctor("codex", "--config", str(selected))
        finding = next(f for f in self.findings(report) if f["code"] == "mcp.notConfigured")
        self.assertIn("this file", finding["remediation"])
        self.assertNotIn("codex mcp add", finding["remediation"])
        self.assertEqual(report["clients"][0]["skill"], "outOfScope")
        self.assertEqual([s["path"] for s in report["clients"][0]["sources"]], [str(selected)])
        text = self.run_doctor("codex", "--config", str(selected), as_json=False).stdout
        self.assertIn(finding["remediation"], text)
        self.assertNotIn(str(selected), text)
        self.assertIn("Use --verbose for inspected paths", text)
        self.assertNotIn(str(self.home / ".codex/config.toml"), text)
        self.assertNotIn("#install-the-lean-skill-manually", text)
        pi = self.run_doctor("pi")
        mcp = next(f for f in self.findings(pi) if f["code"] == "mcp.notApplicable")
        self.assertIsNone(mcp.get("remediation"))

    def test_empty_pi_summary_does_not_claim_an_integration(self):
        report = self.run_doctor("pi")
        self.assertEqual(report["clients"][0]["mcp"], "notApplicable")
        self.assertEqual(report["clients"][0]["skill"], "notConfigured")
        text = self.run_doctor("pi", as_json=False).stdout
        self.assertIn("pi: not configured", text)
        self.assertNotIn("CLI skill integration", text)
        self.assertIn("Pi's CLI workflow", text)
        self.assertNotIn("optional for mcp", text.lower())
        self.assertNotIn("MCP-only", text)
        self.assertIn("1 setup reminder.", text)

    def test_explicit_settings_scope_does_not_claim_skills_are_absent(self):
        config = self.root / "settings.json"
        self.json_file(config, {})
        report = self.run_doctor("pi", "--config", str(config))
        self.assertEqual(report["clients"][0]["skill"], "outOfScope")
        text = self.run_doctor("pi", "--config", str(config), as_json=False).stdout
        self.assertIn("pi: checked", text)
        self.assertIn("skills outside selected scope", text)
        self.assertNotIn("pi: not configured", text)

    def test_failed_config_inspection_is_not_absence(self):
        config = self.home / ".codex/config.toml"
        self.write(config, "[broken\n")
        report = self.run_doctor("codex", expected=1)
        self.assertEqual(report["clients"][0]["mcp"], "error")
        self.assertNotIn("mcp.notConfigured", {f["code"] for f in self.findings(report)})
        text = self.run_doctor("codex", expected=1, as_json=False).stdout
        self.assertIn("MCP config needs attention", text)
        self.assertNotIn("MCP not configured", text)
        config.unlink()
        config.symlink_to(self.root / "missing.toml")
        report = self.run_doctor("codex", expected=2)
        self.assertEqual(report["clients"][0]["mcp"], "unverified")
        self.assertNotIn("mcp.notConfigured", {f["code"] for f in self.findings(report)})

    def test_failed_skill_inspection_is_not_absence(self):
        skill = self.home / ".pi/agent/skills/lean-beam/SKILL.md"
        self.write(skill, "")
        report = self.run_doctor("pi", expected=1)
        self.assertEqual(report["clients"][0]["skill"], "error")
        text = self.run_doctor("pi", expected=1, as_json=False).stdout
        self.assertIn("Lean skill needs attention", text)
        self.assertNotIn("Lean skill not found", text)
        skill.unlink()
        skill.symlink_to(self.root / "missing-skill")
        report = self.run_doctor("pi", expected=2)
        self.assertEqual(report["clients"][0]["skill"], "unverified")

    def test_opencode_disabled_only_entry_is_known_disabled(self):
        self.json_file(self.workspace / "opencode.json", {"mcp": {"lean-beam": {"enabled": False}}})
        report = self.run_doctor("opencode", expected=1)
        self.has_code(report, "mcp.disabled", "error")
        self.assertNotIn("config.partial", {f["code"] for f in self.findings(report)})

    def test_inline_opencode_override_prevents_claiming_absence(self):
        self.env["OPENCODE_CONFIG_CONTENT"] = "{}"
        report = self.run_doctor("opencode", expected=2)
        self.assertEqual(report["clients"][0]["mcp"], "unverified")
        self.assertNotIn("mcp.notConfigured", {f["code"] for f in self.findings(report)})

    def test_explicit_opencode_file_ignores_inline_configuration(self):
        selected = self.root / "selected.json"
        self.env["OPENCODE_CONFIG_CONTENT"] = '{"secret":"DOCTOR_SECRET_SENTINEL"}'
        for executable, expected in [(self.executable, 0), (self.root / "missing/lean-beam-mcp", 1)]:
            with self.subTest(executable=executable):
                self.json_file(selected, {"mcp": {"lean-beam": {
                    "type": "local", "command": [str(executable)]}}})
                report = self.run_doctor("opencode", "--config", str(selected), expected=expected)
                self.has_code(report, "launch.file" if expected == 0 else "launch.missing",
                              "ok" if expected == 0 else "error")
                self.assertNotIn("config.inlineOverride", {f["code"] for f in self.findings(report)})
                self.assertEqual([s["path"] for s in report["clients"][0]["sources"]], [str(selected)])
                self.assertEqual(report["clients"][0]["skill"], "outOfScope")
                self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))

    def test_opencode_home_directory_overrides_global_registration(self):
        self.json_file(self.home / ".config/opencode/opencode.json", {"mcp": {
            "lean-beam": {"type": "local", "command": [str(self.executable)]}}})
        override = self.home / ".opencode/opencode.json"
        self.json_file(override, {"mcp": {"lean-beam": {"enabled": False}}})
        report = self.run_doctor("opencode", expected=1)
        self.has_code(report, "mcp.disabled", "error")
        self.assertIn(str(override), [s["path"] for s in report["clients"][0]["sources"]])
        self.assertEqual(report["clients"][0]["mcp"], "error")

    def test_opencode_config_json_precedes_standard_global_files(self):
        global_home = self.home / ".config/opencode"
        self.json_file(global_home / "config.json", {"mcp": {
            "lean-beam": {"type": "local", "command": [str(self.executable)]}}})
        self.has_code(self.run_doctor("opencode"), "launch.file", "ok")
        self.json_file(global_home / "opencode.json", {"mcp": {"lean-beam": {"enabled": False}}})
        self.has_code(self.run_doctor("opencode", expected=1), "mcp.disabled", "error")

    def test_global_and_alias_tool_policies_remain_unverified(self):
        global_config = self.home / ".config/opencode/opencode.json"
        self.json_file(self.workspace / "opencode.json", {"mcp": {
            "proofs": {"type": "local", "command": [str(self.executable)]}}})
        for policy in [{"permission": "deny"}, {"permission": {"*": "deny"}},
                       {"permission": {"proofs_*": "deny"}},
                       {"tools": {"proofs_*": False}}, {"disabled_tools": ["proofs_run"]}]:
            with self.subTest(policy=policy):
                self.json_file(global_config, policy)
                report = self.run_doctor("opencode", expected=2)
                self.has_code(report, "policy.notEvaluated", "unknown")
                self.assertEqual(report["clients"][0]["mcp"], "unverified")
        self.json_file(global_config, {"permission": {"bash": "deny"}})
        self.assertEqual(self.run_doctor("opencode")["clients"][0]["mcp"], "checked")
        self.json_file(global_config, {"permission": {"bash": {"*": "deny"}}})
        self.assertEqual(self.run_doctor("opencode")["clients"][0]["mcp"], "checked")
        for alias, tool_prefix in [("proofs.v1", "proofs_v1"), ("proofs.β", "proofs__"),
                                   ("proofs😀", "proofs__")]:
            with self.subTest(alias=alias):
                self.json_file(self.workspace / "opencode.json", {"mcp": {
                    alias: {"type": "local", "command": [str(self.executable)]}}})
                self.json_file(global_config, {"permission": {tool_prefix + "_beam_run_at": "deny"}})
                report = self.run_doctor("opencode", expected=2)
                self.has_code(report, "policy.notEvaluated", "unknown")
                self.assertEqual(report["clients"][0]["mcp"], "unverified")

    def test_nested_skill_policies_remain_unverified(self):
        skill = self.home / ".agents/skills/lean-beam/SKILL.md"
        self.write(skill, "Lean skill\n")
        self.codex_config()
        config = self.home / ".codex/config.toml"
        self.write(config, config.read_text() + "\n[[skills.config]]\n"
                   f"path={json.dumps(str(skill))}\nenabled=false\n")
        report = self.run_doctor("codex", expected=2)
        self.has_code(report, "policy.notEvaluated", "unknown")
        self.has_code(report, "skill.readable", "ok")
        self.assertEqual(report["clients"][0]["skill"], "unverified")
        self.assertEqual(report["clients"][0]["mcp"], "checked")
        self.write(self.home / ".config/opencode/skills/lean-beam/SKILL.md", "Lean skill\n")
        self.json_file(self.home / ".config/opencode/opencode.json", {
            "mcp": {"lean-beam": {"type": "local", "command": [str(self.executable)]}},
            "permission": {"skill": {"lean-beam": "deny"}}})
        report = self.run_doctor("opencode", expected=2)
        self.has_code(report, "policy.notEvaluated", "unknown")
        self.has_code(report, "skill.readable", "ok")
        self.assertEqual(report["clients"][0]["skill"], "unverified")
        self.assertEqual(report["clients"][0]["mcp"], "checked")

        for permission in ["deny", {"*": "deny"}]:
            with self.subTest(permission=permission):
                self.json_file(self.home / ".config/opencode/opencode.json", {"permission": permission})
                report = self.run_doctor("opencode", expected=2)
                self.has_code(report, "policy.notEvaluated", "unknown")
                self.assertEqual(report["clients"][0]["skill"], "unverified")
                self.assertEqual(report["clients"][0]["mcp"], "notConfigured")

    def test_vibe_allow_list_can_exclude_beam_without_naming_it(self):
        config = self.home / ".vibe/config.toml"
        for tools, expected in [(["read_file", "skill"], 2), ([], 0)]:
            with self.subTest(tools=tools):
                self.write(config, f"enabled_tools={json.dumps(tools)}\n"
                           "[[mcp_servers]]\nname='lean-beam'\ntransport='stdio'\n"
                           f"command=[{json.dumps(str(self.executable))}]\n")
                report = self.run_doctor("vibe", expected=expected)
                if tools:
                    self.has_code(report, "policy.notEvaluated", "unknown")
                    self.assertEqual(report["clients"][0]["mcp"], "unverified")
                else:
                    self.assertEqual(report["clients"][0]["mcp"], "checked")

    def test_vibe_arrays_and_tokenized_strings(self):
        config = self.home / ".vibe/config.toml"
        def write_command(command, args=()):
            self.write(config, "[[mcp_servers]]\nname='proofs'\ntransport='stdio'\n"
                       f"command={json.dumps(command)}\nargs={json.dumps(list(args))}\n")
        write_command([str(self.executable)])
        self.assertEqual(self.run_doctor("vibe")["clients"][0]["mcp"], "checked")
        for command, args in [([str(self.executable), "DOCTOR_SECRET_SENTINEL"], []),
                              ([str(self.executable)], ["DOCTOR_SECRET_SENTINEL"])]:
            with self.subTest(command=command, args=args):
                write_command(command, args)
                report = self.run_doctor("vibe", expected=2)
                self.has_code(report, "launch.arguments", "unknown")
                self.has_code(report, "launch.file", "ok")
                self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))
        for command in [str(self.executable), '"' + str(self.executable) + '"',
                        str(self.executable) + " --extra"]:
            with self.subTest(command=command):
                write_command(command)
                report = self.run_doctor("vibe", expected=2)
                self.has_code(report, "launch.commandSyntax", "unknown")
                self.assertNotIn("launch.file", {f["code"] for f in self.findings(report)})
        plain = self.root / "lean-beam-mcp"
        self.write(plain, "must not execute\n")
        plain.chmod(0o700)
        write_command(str(plain))
        self.has_code(self.run_doctor("vibe"), "launch.file", "ok")

    def test_vibe_discovers_nearest_parent_config_across_git_boundary(self):
        self.write(self.home / ".vibe/config.toml", "[[mcp_servers]]\nname='lean-beam'\n"
                   f"transport='stdio'\ncommand=[{json.dumps(str(self.executable))}]\n")
        parent_config = self.workspace / ".vibe/config.toml"
        self.write(parent_config, "[[mcp_servers]]\nname='lean-beam'\ntransport='stdio'\n"
                   f"command=[{json.dumps(str(self.executable))}]\ndisabled=true\n")
        child = self.workspace / "src"
        (child / ".git").mkdir(parents=True)
        report = self.run_doctor("vibe", global_args=("--root", str(child)), expected=2)
        self.has_code(report, "config.layers", "unknown")
        self.assertEqual(report["clients"][0]["mcp"], "unverified")
        self.assertIn(str(parent_config), [s["path"] for s in report["clients"][0]["sources"]])
        nearest = child / ".vibe/config.toml"
        self.write(nearest, "mcp_servers=[]\n")
        report = self.run_doctor("vibe", global_args=("--root", str(child)), expected=2)
        paths = [s["path"] for s in report["clients"][0]["sources"]]
        self.assertIn(str(nearest), paths)
        self.assertNotIn(str(parent_config), paths)

    def test_vibe_project_discovery_stops_before_user_home(self):
        self.write(self.home / ".vibe/config.toml", "[[mcp_servers]]\nname='lean-beam'\n"
                   f"transport='stdio'\ncommand=[{json.dumps(str(self.executable))}]\n")
        outside = self.root / ".vibe/config.toml"
        self.write(outside, "[[mcp_servers]]\nname='lean-beam'\ndisabled=true\n")
        project = self.home / "project/src"
        project.mkdir(parents=True)
        report = self.run_doctor("vibe", global_args=("--root", str(project)))
        self.assertEqual(report["clients"][0]["mcp"], "checked")
        self.assertNotIn(str(outside), [s["path"] for s in report["clients"][0]["sources"]])

    def test_vibe_home_is_canonical_before_ancestor_discovery(self):
        actual = self.home / "custom-vibe"
        self.write(actual / "config.toml", "[[mcp_servers]]\nname='lean-beam'\ntransport='stdio'\n"
                   f"command=[{json.dumps(str(self.executable))}]\n")
        old = self.home / ".vibe/config.toml"
        self.write(old, "not valid TOML!\n")
        alias = self.root / "vibe-link"
        alias.symlink_to(actual, target_is_directory=True)
        unused = self.home / "unused"
        unused.mkdir()
        workspace = self.home / "project/src"
        workspace.mkdir(parents=True)
        for home in [alias, unused / ".." / "custom-vibe"]:
            with self.subTest(home=home):
                self.env["VIBE_HOME"] = str(home)
                report = self.run_doctor("vibe", global_args=("--root", str(workspace)))
                self.assertEqual(report["clients"][0]["mcp"], "checked")
                self.assertNotIn(str(old), [s["path"] for s in report["clients"][0]["sources"]])

    def test_successful_checks_do_not_erase_unverified_selection(self):
        self.codex_config()
        config = self.home / ".codex/config.toml"
        self.write(config, 'profile = "alternate"\n' + config.read_text())
        report = self.run_doctor("codex", expected=2)
        self.has_code(report, "launch.file", "ok")
        self.assertEqual(report["clients"][0]["mcp"], "unverified")
        self.write(self.home / ".agents/skills/lean-beam/SKILL.md", "Lean skill\n")
        broken = self.home / ".codex/skills/lean-beam/SKILL.md"
        broken.parent.mkdir(parents=True)
        broken.symlink_to(self.root / "missing-skill")
        report = self.run_doctor("codex", expected=2)
        self.has_code(report, "skill.readable", "ok")
        self.assertEqual(report["clients"][0]["skill"], "unverified")

    def test_codex_project_override_retains_a_beam_alias(self):
        self.write(self.home / ".codex/config.toml", "[mcp_servers.proofs]\n"
                   f"command={json.dumps(str(self.executable))}\nsupports_parallel_tool_calls=true\n")
        project = self.workspace / ".codex/config.toml"
        self.write(project, "[mcp_servers.proofs]\nenabled=false\n")
        report = self.run_doctor("codex", expected=2)
        self.has_code(report, "config.layers", "unknown")
        self.assertEqual(report["clients"][0]["mcp"], "unverified")
        self.assertNotIn("launch.file", {f["code"] for f in self.findings(report)})
        self.write(project, "[mcp_servers.other]\nenabled=false\n")
        self.assertEqual(self.run_doctor("codex")["clients"][0]["mcp"], "checked")

    def test_opencode_source_validation_precedes_merging(self):
        user = self.home / ".config/opencode/opencode.json"
        project = self.workspace / "opencode.json"
        self.json_file(user, {"mcp": {"proofs": {
            "type": "local", "command": [str(self.executable)]}}})
        for entry in [{"command": [str(self.executable)]},
                      {"type": "local", "command": [str(self.executable)], "cwd": 7},
                      {"type": "local", "command": [str(self.executable)],
                       "environment": {"DOCTOR_SECRET_SENTINEL": 7}}]:
            with self.subTest(entry=entry):
                self.json_file(project, {"mcp": {"proofs": entry}})
                report = self.run_doctor("opencode", expected=1)
                self.has_code(report, "mcp.invalidEntry", "error")
                self.assertEqual(report["clients"][0]["mcp"], "error")
                self.assertNotIn("launch.file", {f["code"] for f in self.findings(report)})
                self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))
        # A valid empty array is a complete source, but cannot inherit a usable command.
        self.json_file(project, {"mcp": {"proofs": {
            "type": "local", "command": [], "enabled": True}}})
        report = self.run_doctor("opencode", expected=1)
        self.has_code(report, "mcp.invalidEntry", "error")
        self.assertNotIn("launch.file", {f["code"] for f in self.findings(report)})
        # The client accepts this through its enabled-override branch and discards command.
        self.json_file(project, {"mcp": {"proofs": {
            "enabled": True, "command": ["/missing/lean-beam-mcp"]}}})
        report = self.run_doctor("opencode")
        launch = next(f for f in self.findings(report) if f["code"] == "launch.file")
        self.assertEqual(launch["source"], str(user))

    def test_opencode_disabled_field_uses_client_precedence(self):
        config = self.home / ".config/opencode/opencode.json"
        for flags, expected in [({"disabled": True}, 1), ({"disabled": False}, 0),
                                ({"disabled": True, "enabled": True}, 0)]:
            with self.subTest(flags=flags):
                self.json_file(config, {"mcp": {"lean-beam": {
                    "type": "local", "command": [str(self.executable)], **flags}}})
                report = self.run_doctor("opencode", expected=expected)
                self.assertEqual(report["clients"][0]["mcp"], "error" if expected else "checked")
                if expected: self.has_code(report, "mcp.disabled", "error")

    def test_vibe_global_mcp_switch(self):
        config = self.home / ".vibe/config.toml"
        entry = "[[mcp_servers]]\nname='lean-beam'\ntransport='stdio'\n" + \
            f"command=[{json.dumps(str(self.executable))}]\n"
        self.write(config, "enable_mcp=false\n" + entry)
        report = self.run_doctor("vibe", expected=1)
        self.has_code(report, "mcp.disabled", "error")
        self.assertEqual(report["clients"][0]["mcp"], "error")
        self.write(config, "enable_mcp=true\n" + entry)
        self.assertEqual(self.run_doctor("vibe")["clients"][0]["mcp"], "checked")
        self.write(config, "enable_mcp=false\n" + entry)
        self.write(self.workspace / ".vibe/config.toml", "enable_mcp=true\n")
        report = self.run_doctor("vibe", expected=2)
        self.has_code(report, "policy.notEvaluated", "unknown")
        self.assertEqual(report["clients"][0]["mcp"], "unverified")

    def test_claude_skill_policies_do_not_poison_mcp_state(self):
        self.write(self.home / ".claude/skills/lean-beam/SKILL.md", "Lean skill\n")
        self.json_file(self.home / ".claude.json", {"mcpServers": {
            "proofs": {"command": str(self.executable)}}})
        settings = self.home / ".claude/settings.json"
        for policy in [{"permissions": {"deny": ["Skill(lean-beam)"]}},
                       {"permissions": {"deny": ["Skill"]}},
                       {"skillOverrides": {"lean-beam": "off"}}]:
            with self.subTest(policy=policy):
                self.json_file(settings, policy)
                report = self.run_doctor("claude", expected=2)
                self.has_code(report, "policy.notEvaluated", "unknown")
                self.assertEqual(report["clients"][0]["skill"], "unverified")
                self.assertEqual(report["clients"][0]["mcp"], "checked")
        self.json_file(settings, {"permissions": {"deny": ["Skill", "mcp__proofs__beam_run_at"]}})
        report = self.run_doctor("claude", expected=2)
        self.assertEqual(report["clients"][0]["skill"], "unverified")
        self.assertEqual(report["clients"][0]["mcp"], "unverified")
        self.json_file(settings, {"permissions": {"deny": ["Read"]},
                                  "skillOverrides": {"other-skill": "off"}})
        report = self.run_doctor("claude")
        self.assertEqual(report["clients"][0]["skill"], "checked")
        self.assertEqual(report["clients"][0]["mcp"], "checked")

    def test_vibe_normalized_aliases_in_tool_policy(self):
        config = self.home / ".vibe/config.toml"
        for name, normalized in [("proofs.v1", "proofs_v1"), ("__proofs.v1--", "proofs_v1"),
                                 ("proofs😀", "proofs"), ("p" * 257, "p" * 256)]:
            with self.subTest(name=name):
                self.write(config, f"disabled_tools={json.dumps([normalized + '_lean_run_at'])}\n"
                           f"[[mcp_servers]]\nname={json.dumps(name, ensure_ascii=False)}\ntransport='stdio'\n"
                           f"command=[{json.dumps(str(self.executable))}]\n")
                report = self.run_doctor("vibe", expected=2)
                self.has_code(report, "policy.notEvaluated", "unknown")
                self.assertEqual(report["clients"][0]["mcp"], "unverified")

    def test_installer_shapes_for_all_five_clients(self):
        self.codex_config()
        self.json_file(self.home / ".claude.json", {
            "mcpServers": {"lean-beam": {"command": str(self.executable), "args": []}},
        })
        self.write(self.home / ".vibe" / "config.toml", (
            "[[mcp_servers]]\nname = 'lean-beam'\ntransport = 'stdio'\n"
            f"command = [{json.dumps(str(self.executable))}]\nargs = []\ntool_timeout_sec = 600\n"
        ))
        self.write(self.home / ".config" / "opencode" / "opencode.jsonc", (
            "// OpenCode accepts comments and trailing commas.\n"
            '{"mcp": {"lean-beam": {"type": "local", "command": ['
            + json.dumps(str(self.executable)) + ',], "enabled": true,},},}\n'
        ))
        for target in [".codex", ".claude", ".pi/agent", ".config/opencode", ".vibe"]:
            self.write(self.home / target / "skills" / "lean-beam" / "SKILL.md", "A Lean skill.\n")
        report = self.run_doctor()
        self.assertEqual({entry["client"] for entry in report["clients"]}, {
            "codex", "claude", "pi", "opencode", "vibe",
        })
        for client in ["codex", "claude", "opencode", "vibe"]:
            self.assertIn("launch.file", {item["code"] for item in self.findings(report, client)})
        self.assertFalse(any(item["status"] in ["error", "unknown"] for item in self.findings(report)))

    def test_all_installer_home_overrides(self):
        targets = {
            "codex": ("CODEX_HOME", "codex", "config.toml"),
            "claude": ("CLAUDE_HOME", "claude", "settings.json"),
            "pi": ("PI_CODING_AGENT_DIR", "pi", "settings.json"),
            "opencode": ("OPENCODE_CONFIG_DIR", "opencode", "opencode.json"),
            "vibe": ("VIBE_HOME", "vibe", "config.toml"),
        }
        for client, (env_name, dirname, filename) in targets.items():
            directory = self.root / "custom homes" / dirname
            self.env[env_name] = str(directory)
            self.write(directory / "skills" / "lean-beam" / "SKILL.md", "Lean skill\n")
            self.write(directory / filename, "" if filename.endswith("toml") else "{}")
            report = self.run_doctor(client)
            self.has_code(report, "skill.readable", "ok")
            paths = {source["path"] for source in report["clients"][0]["sources"]}
            self.assertIn(str(directory / filename), paths)
        config = self.root / "claude override" / ".claude.json"
        self.env["BEAM_CLAUDE_MCP_CONFIG"] = str(config)
        self.json_file(config, {"mcpServers": {"lean-beam": {"command": str(self.executable)}}})
        self.has_code(self.run_doctor("claude"), "launch.file", "ok")

    def test_missing_executable_and_non_executable(self):
        self.codex_config(self.root / "missing" / "lean-beam-mcp")
        self.has_code(self.run_doctor("codex", expected=1), "launch.missing", "error")
        self.codex_config()
        self.executable.chmod(0o644)
        self.has_code(self.run_doctor("codex", expected=1), "launch.notExecutable", "error")

    def test_disabled_and_invalid_types(self):
        self.codex_config(extra="enabled = false\n")
        self.has_code(self.run_doctor("codex", expected=1), "mcp.disabled", "error")
        self.codex_config(extra="args = [42]\n")
        self.has_code(self.run_doctor("codex", expected=1), "mcp.invalidEntry", "error")

    def test_relative_and_dynamic_commands_are_unknown(self):
        for command in ["lean-beam-mcp", "./lean-beam-mcp", "${BEAM_PATH}"]:
            self.codex_config(command)
            report = self.run_doctor("codex", expected=2)
            self.assertTrue(any(item["status"] == "unknown" for item in self.findings(report)))

    def test_parallel_setting_is_advisory(self):
        self.write(self.home / ".codex" / "config.toml", (
            f"[mcp_servers.lean-beam]\ncommand = {json.dumps(str(self.executable))}\n"
        ))
        self.has_code(self.run_doctor("codex"), "codex.parallelCalls", "warning")

    def test_layered_partial_overrides_cannot_report_launch_success(self):
        self.codex_config(self.root / "missing" / "lean-beam-mcp")
        self.write(self.workspace / ".codex" / "config.toml", (
            "[mcp_servers.lean-beam]\nenabled = true\n"
        ))
        report = self.run_doctor("codex", expected=2)
        self.has_code(report, "config.layers", "unknown")
        self.assertNotIn("launch.file", {item["code"] for item in self.findings(report)})
        self.assertNotIn("launch.missing", {item["code"] for item in self.findings(report)})

    def test_claude_local_scope_shadows_broken_user_entry(self):
        self.json_file(self.home / ".claude.json", {
            "mcpServers": {"lean-beam": {"command": "/missing/lean-beam-mcp"}},
            "projects": {str(self.workspace): {
                "mcpServers": {"lean-beam": {"command": str(self.executable)}},
            }},
        })
        self.has_code(self.run_doctor("claude"), "launch.file", "ok")

    def test_claude_disabled_workspace(self):
        self.json_file(self.home / ".claude.json", {
            "mcpServers": {"lean-beam": {"command": str(self.executable)}},
            "projects": {str(self.workspace): {"disabledMcpServers": ["lean-beam"]}},
        })
        self.has_code(self.run_doctor("claude", expected=1), "mcp.disabled", "error")

    def test_claude_local_alias_does_not_hide_another_user_server(self):
        self.json_file(self.home / ".claude.json", {
            "mcpServers": {"lean-beam": {"command": "/missing/lean-beam-mcp"}},
            "projects": {str(self.workspace): {
                "mcpServers": {"beam-local": {"command": str(self.executable)}},
            }},
        })
        report = self.run_doctor("claude", expected=1)
        self.has_code(report, "launch.missing", "error")
        self.has_code(report, "launch.file", "ok")

    def test_claude_disabled_alias_is_not_checked_as_healthy(self):
        self.json_file(self.home / ".claude.json", {
            "mcpServers": {"beam-alias": {"command": str(self.executable)}},
            "projects": {str(self.workspace): {"disabledMcpServers": ["beam-alias"]}},
        })
        report = self.run_doctor("claude", expected=1)
        self.has_code(report, "mcp.disabled", "error")
        self.assertNotIn("launch.file", {f["code"] for f in self.findings(report)})

    def test_claude_project_alias_does_not_prevent_checking_user_registration(self):
        self.json_file(self.home / ".claude.json", {
            "mcpServers": {"lean-beam": {"command": str(self.executable)}},
        })
        self.json_file(self.workspace / ".mcp.json", {
            "mcpServers": {"beam-project": {"command": "/missing/lean-beam-mcp"}},
        })
        report = self.run_doctor("claude", expected=2)
        self.has_code(report, "config.layers", "unknown")
        self.has_code(report, "launch.file", "ok")
        self.assertNotIn("launch.missing", {f["code"] for f in self.findings(report)})

    def test_claude_scope_precedence_replaces_whole_entries(self):
        self.json_file(self.home / ".claude.json", {
            "mcpServers": {"lean-beam": {"command": "/missing/lean-beam-mcp", "args": [42]}},
        })
        self.json_file(self.workspace / ".mcp.json", {
            "mcpServers": {"lean-beam": {"command": str(self.executable)}},
        })
        report = self.run_doctor("claude", expected=2)
        self.has_code(report, "mcp.definition", "ok")
        self.assertNotIn("mcp.invalidEntry", {f["code"] for f in self.findings(report)})
        self.json_file(self.home / ".claude.json", {
            "mcpServers": {"lean-beam": {"command": "/missing/lean-beam-mcp", "args": [42]}},
            "projects": {str(self.workspace): {
                "mcpServers": {"lean-beam": {"command": str(self.executable)}},
            }},
        })
        self.has_code(self.run_doctor("claude"), "launch.file", "ok")

    def test_claude_project_rejection_does_not_disable_user_or_local_scope(self):
        self.json_file(self.home / ".claude/settings.json", {
            "disabledMcpjsonServers": ["lean-beam"],
        })
        config = self.home / ".claude.json"
        self.json_file(config, {"mcpServers": {"lean-beam": {"command": str(self.executable)}}})
        self.has_code(self.run_doctor("claude"), "launch.file", "ok")
        self.json_file(self.workspace / ".mcp.json", {
            "mcpServers": {"lean-beam": {"command": "/missing/lean-beam-mcp"}},
        })
        self.json_file(config, {"projects": {str(self.workspace): {
            "mcpServers": {"lean-beam": {"command": str(self.executable)}},
        }}})
        self.has_code(self.run_doctor("claude"), "launch.file", "ok")
        self.json_file(config, {})
        self.has_code(self.run_doctor("claude", expected=1), "mcp.disabled", "error")

    def test_claude_malformed_local_alias_does_not_fall_back_to_user(self):
        self.json_file(self.home / ".claude.json", {
            "mcpServers": {"beam-alias": {"command": str(self.executable)}},
            "projects": {str(self.workspace): {"mcpServers": {"beam-alias": None}}},
        })
        report = self.run_doctor("claude", expected=2)
        self.has_code(report, "config.entryShape", "unknown")
        self.assertNotIn("launch.file", {f["code"] for f in self.findings(report)})

    def test_claude_malformed_policy_lists_are_unverified_and_private(self):
        for setting in [None, "DOCTOR_SECRET_SENTINEL", {}, ["lean-beam", 7]]:
            for project_only in [False, True]:
                with self.subTest(setting=setting, project_only=project_only):
                    self.json_file(self.home / ".claude.json", {
                        "mcpServers": {"lean-beam": {"command": str(self.executable)}},
                        "projects": {str(self.workspace): {} if project_only else {"disabledMcpServers": setting}},
                    })
                    self.json_file(self.home / ".claude/settings.json", {
                        "disabledMcpjsonServers": setting,
                    } if project_only else {})
                    report = self.run_doctor("claude", expected=2)
                    self.has_code(report, "config.policyShape", "unknown")
                    self.assertEqual(report["clients"][0]["mcp"], "unverified")
                    self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))

    def test_changed_server_and_launch_field_types_are_private(self):
        config = self.home / ".claude.json"
        for value in [None, False, 7, [], "DOCTOR_SECRET_SENTINEL"]:
            with self.subTest(value=value):
                self.json_file(config, {"mcpServers": {"lean-beam": value}})
                report = self.run_doctor("claude", expected=2)
                self.has_code(report, "config.entryShape", "unknown")
                self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))
        for field, value in [
            ("command", ["DOCTOR_SECRET_SENTINEL"]), ("args", ["DOCTOR_SECRET_SENTINEL", 7]),
            ("env", {"SECRET": {"token": "DOCTOR_SECRET_SENTINEL"}}), ("enabled", "DOCTOR_SECRET_SENTINEL"),
        ]:
            with self.subTest(field=field):
                self.json_file(config, {"mcpServers": {"lean-beam": {"command": str(self.executable), field: value}}})
                report = self.run_doctor("claude", expected=1)
                self.has_code(report, "mcp.invalidEntry", "error")
                self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))

    def test_config_shape_changes_preserve_other_clients_and_recover(self):
        self.codex_config()
        config = self.home / ".claude.json"
        for value, expected, code in [
            ({"mcpServers": {"lean-beam": {"command": str(self.executable)}}}, 0, "launch.file"),
            ({"mcpServers": ["DOCTOR_SECRET_SENTINEL"]}, 2, "config.shape"),
            ("{broken DOCTOR_SECRET_SENTINEL", 1, "config.syntax"),
            ({"mcpServers": {"lean-beam": {"command": str(self.executable)}}}, 0, "launch.file"),
        ]:
            with self.subTest(expected=expected):
                if isinstance(value, str):
                    self.write(config, value)
                else:
                    self.json_file(config, value)
                report = self.run_doctor(expected=expected)
                self.assertEqual({c["client"] for c in report["clients"]}, {"codex", "claude"})
                self.assertEqual(report["clients"][0]["mcp"], "checked")
                self.assertIn(code, {f["code"] for f in self.findings(report, "claude")})
                self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))

    def test_unsupported_containers_are_unverified_across_clients(self):
        for client, filename, content in [
            ("codex", "config.toml", 'mcp_servers = "DOCTOR_SECRET_SENTINEL"'),
            ("claude", "config.json", '{"projects": []}'),
            ("pi", "config.json", '[]'),
            ("opencode", "config.json", '{"mcp": []}'),
            ("vibe", "config.toml", 'mcp_servers = "DOCTOR_SECRET_SENTINEL"'),
        ]:
            with self.subTest(client=client):
                config = self.root / filename
                self.write(config, content)
                report = self.run_doctor(client, "--config", str(config), expected=2)
                self.has_code(report, "config.shape", "unknown")
                self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))
                self.assertNotIn("mcp.notConfigured", {f["code"] for f in self.findings(report)})

    def test_invalid_utf8_is_unverified_and_does_not_hide_other_clients(self):
        self.codex_config()
        config = self.home / ".claude.json"
        config.write_bytes(b'\xffDOCTOR_SECRET_SENTINEL')
        report = self.run_doctor(expected=2)
        self.has_code(report, "file.unreadable", "unknown")
        self.assertEqual({c["client"] for c in report["clients"]}, {"codex", "claude"})
        self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))

    def test_opencode_partial_override_and_inline_config(self):
        self.json_file(self.home / ".config/opencode/opencode.json", {
            "mcp": {"lean-beam": {"type": "local", "command": [str(self.executable)]}},
        })
        self.json_file(self.workspace / "opencode.json", {"mcp": {"lean-beam": {"enabled": False}}})
        self.has_code(self.run_doctor("opencode", expected=1), "mcp.disabled", "error")
        self.env["OPENCODE_CONFIG_CONTENT"] = '{"apiKey":"DOCTOR_SECRET_SENTINEL"}'
        report = self.run_doctor("opencode", expected=2)
        self.has_code(report, "config.inlineOverride", "unknown")
        self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))

    def test_pi_custom_skill_sources_are_unknown(self):
        self.json_file(self.home / ".pi/agent/settings.json", {"skills": ["!/custom/lean-beam"]})
        self.has_code(self.run_doctor("pi", expected=2), "skills.customSources", "unknown")

    def test_compact_and_verbose_output(self):
        self.codex_config()
        self.write(self.home / ".codex/skills/lean-beam/SKILL.md", "Lean skill\n")
        compact = self.run_doctor("codex", as_json=False).stdout
        self.assertIn("codex: checked — MCP config checked; Lean skill found", compact)
        self.assertIn("0 errors, 0 unverified checks, 0 recommendations, 0 setup reminders.", compact)
        self.assertNotIn(str(self.home), compact)
        self.assertNotIn("[launch.file]", compact)
        verbose = self.run_doctor("codex", "--verbose", as_json=False).stdout
        self.assertIn("[launch.file]", verbose)
        self.assertIn(str(self.home / ".codex/config.toml"), verbose)
        self.codex_config(self.root / "missing/lean-beam-mcp")
        compact = self.run_doctor("codex", expected=1, as_json=False).stdout
        self.assertIn("codex: needs attention", compact)
        self.assertIn("Update the registration", compact)
        self.assertIn(str(self.home / ".codex/config.toml"), compact)
        self.run_doctor("codex", "--json", "--verbose", expected=2, as_json=False)

    def test_pi_cached_packages_without_skills_are_not_unknown(self):
        settings = self.home / ".pi/agent/settings.json"
        self.json_file(settings, {"packages": ["npm:@example/pi-tools@1.2.3"]})
        manifest = self.home / ".pi/agent/npm/node_modules/@example/pi-tools/package.json"
        self.json_file(manifest, {"pi": {"extensions": ["index.ts"]}})
        report = self.run_doctor("pi")
        self.has_code(report, "pi.packages", "ok")
        self.assertNotIn("skills.customSources", {f["code"] for f in self.findings(report)})
        self.json_file(manifest, {"pi": {"skills": ["skills"]}})
        self.has_code(self.run_doctor("pi", expected=2), "skills.customSources", "unknown")
        self.json_file(manifest, {"pi": {"skills": []}})
        self.run_doctor("pi")
        manifest.unlink()
        self.has_code(self.run_doctor("pi", expected=2), "skills.customSources", "unknown")
        self.json_file(settings, {"packages": [{"source": "npm:unavailable", "skills": []}]})
        self.run_doctor("pi")
        self.json_file(settings, {"packages": [{"source": "npm:unavailable", "skills": [], "autoload": False}]})
        self.has_code(self.run_doctor("pi", expected=2), "skills.customSources", "unknown")

    def test_pi_local_package_and_explicit_scope(self):
        settings = self.home / ".pi/agent/settings.json"
        self.json_file(settings, {"packages": ["./my-package"]})
        manifest = settings.parent / "my-package/package.json"
        self.json_file(manifest, {"pi": {"themes": ["themes"]}})
        self.run_doctor("pi")
        report = self.run_doctor("pi", "--config", str(settings), expected=2)
        self.assertEqual([s["path"] for s in report["clients"][0]["sources"]], [str(settings)])
        self.json_file(manifest, {"no_pi_manifest": True})
        self.has_code(self.run_doctor("pi", expected=2), "skills.customSources", "unknown")

    def test_opencode_merges_aliases_and_tracks_command_source(self):
        user = self.home / ".config/opencode/opencode.json"
        project = self.workspace / "opencode.json"
        self.json_file(user, {"mcp": {"beam-alias": {
            "type": "local", "command": [str(self.executable)],
        }}})
        self.json_file(project, {"mcp": {"beam-alias": {"enabled": True}}})
        report = self.run_doctor("opencode")
        launch = next(f for f in self.findings(report) if f["code"] == "launch.file")
        self.assertEqual(launch["source"], str(user))
        self.json_file(user, {"mcp": {"lean-beam": {"type": "local", "command": ["/missing/lean-beam-mcp"]}}})
        self.json_file(project, {"mcp": {"lean-beam": {"command": [str(self.executable)]}}})
        self.has_code(self.run_doctor("opencode", expected=1), "mcp.invalidEntry", "error")
        self.json_file(project, {"mcp": {"lean-beam": {
            "type": "local", "command": [str(self.executable), "arg"]}}})
        self.has_code(self.run_doctor("opencode", expected=2), "launch.arguments", "unknown")

    def test_opencode_inherited_partial_entry_remains_unknown(self):
        self.json_file(self.workspace / "opencode.json", {"mcp": {"lean-beam": {"enabled": True}}})
        self.has_code(self.run_doctor("opencode", expected=2), "config.partial", "unknown")

    def test_opencode_changed_alias_shape_is_not_reported_absent(self):
        self.json_file(self.home / ".config/opencode/opencode.json", {
            "mcp": {"beam-alias": {"type": "local", "command": [str(self.executable)]}},
        })
        for override, expected, code in [
            (None, 2, "config.entryShape"), (False, 2, "config.entryShape"),
            ([], 2, "config.entryShape"), ("DOCTOR_SECRET_SENTINEL", 2, "config.entryShape"),
            ({"command": None}, 1, "mcp.invalidEntry"),
            ({"command": ["DOCTOR_SECRET_SENTINEL", 7]}, 1, "mcp.invalidEntry"),
            ({"command": ["other-mcp"]}, 1, "mcp.invalidEntry"),
        ]:
            with self.subTest(override=override):
                self.json_file(self.workspace / "opencode.json", {"mcp": {"beam-alias": override}})
                report = self.run_doctor("opencode", expected=expected)
                self.has_code(report, code)
                self.assertNotIn("mcp.notConfigured", {f["code"] for f in self.findings(report)})
                self.assertNotIn("launch.file", {f["code"] for f in self.findings(report)})
                self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))

    def test_opencode_distinct_server_names_are_independent(self):
        self.json_file(self.workspace / "opencode.json", {"mcp": {
            name: {"type": "local", "command": [str(self.executable)]}
            for name in ["lean-beam", "beam-alias"]
        }})
        report = self.run_doctor("opencode")
        self.assertEqual(sum(f["code"] == "launch.file" for f in self.findings(report)), 2)

    def test_opencode_multiple_project_candidates_remain_unknown(self):
        self.json_file(self.workspace / "opencode.json", {"mcp": {"lean-beam": {
            "type": "local", "command": [str(self.executable)],
        }}})
        nested = self.workspace / "nested"
        nested.mkdir()
        self.json_file(nested / "opencode.json", {"mcp": {"lean-beam": {"enabled": True}}})
        previous = self.workspace
        self.workspace = nested
        try:
            self.has_code(self.run_doctor("opencode", expected=2), "config.layers", "unknown")
        finally:
            self.workspace = previous

    def test_jsonc_preserves_strings_and_rejects_missing_values(self):
        config = self.home / ".config/opencode/opencode.jsonc"
        self.write(config, r'{"description":"https://example.org/*not a comment*/", "mcp":{},}')
        self.run_doctor("opencode")
        self.write(config, '{' + ' ' * (512 * 1024) + '"mcp": {}}')
        self.run_doctor("opencode")
        for text in ['{"mcp": [,]}', '{"mcp":,}', '{"mcp": {}} /* unterminated']:
            self.write(config, text)
            self.has_code(self.run_doctor("opencode", expected=1), "config.syntax", "error")

    def test_malformed_configs_do_not_disclose_secrets(self):
        self.write(self.home / ".codex/config.toml", 'secret="DOCTOR_SECRET_SENTINEL"\n[bad\n')
        report = self.run_doctor("codex", expected=1)
        self.has_code(report, "config.syntax", "error")
        self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))
        text = self.run_doctor("codex", expected=1, as_json=False)
        self.assertNotIn("DOCTOR_SECRET_SENTINEL", text.stdout + text.stderr)
        self.codex_config(self.root / "DOCTOR_SECRET_SENTINEL" / "lean-beam-mcp")
        report = self.run_doctor("codex", expected=1)
        self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))

    def test_symlinked_configs_and_dangling_links(self):
        config = self.home / ".codex/config.toml"
        real_config = self.root / "dotfiles" / "codex.toml"
        self.write(real_config, f"[mcp_servers.lean-beam]\ncommand={json.dumps(str(self.executable))}\n")
        config.parent.mkdir()
        config.symlink_to(real_config)
        self.has_code(self.run_doctor("codex"), "launch.file", "ok")
        real_config.unlink()
        self.has_code(self.run_doctor("codex", expected=2), "file.unreadable", "unknown")

    def test_directories_special_files_and_read_limit(self):
        config = self.home / ".codex/config.toml"
        config.mkdir(parents=True)
        self.has_code(self.run_doctor("codex", expected=1), "file.notRegular", "error")
        config.rmdir()
        os.mkfifo(config)
        self.has_code(self.run_doctor("codex", expected=1), "file.notRegular", "error")
        config.unlink()
        self.write(config, "#" * (1024 * 1024 + 1))
        self.has_code(self.run_doctor("codex", expected=2), "file.tooLarge", "unknown")

    def test_explicit_file_and_missing_file(self):
        self.codex_config(self.root / "missing/lean-beam-mcp")
        explicit = self.root / "explicit.toml"
        self.write(explicit, f"[mcp_servers.lean-beam]\ncommand={json.dumps(str(self.executable))}\n")
        report = self.run_doctor("codex", "--config", str(explicit))
        self.has_code(report, "launch.file", "ok")
        self.assertEqual(report["scope"], "explicitConfigFile")
        self.assertEqual([source["path"] for source in report["clients"][0]["sources"]], [str(explicit)])
        self.has_code(self.run_doctor("codex", "--config", str(self.root / "absent"), expected=1),
                      "config.missing", "error")

    def test_explicit_root_does_not_require_a_lean_project(self):
        self.codex_config()
        before = self.snapshot()
        result = subprocess.run(
            [str(self.wrapper), "--root", str(self.workspace), "doctor", "clients", "codex", "--json"],
            cwd=self.root, env=self.env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["workspace"], str(self.workspace))
        self.assertEqual(before, self.snapshot())

    def test_cli_usage_has_diagnostic_exit_status(self):
        for args in [("unknown-client",), ("--config", "/tmp/config"), ("pi", "codex"),
                     ("codex", "--config"), ("codex", "--config", "--json"),
                     ("codex", "--config", "--verbose"), ("codex", "--config", "")]:
            result = self.run_doctor(*args, expected=2, as_json=False)
            failure = json.loads(result.stdout)
            self.assertFalse(failure["ok"])
            self.assertEqual(failure["error"]["code"], "invalidParams")
            self.assertNotIn("kind", failure)
            self.assertEqual(result.stderr.count("usage: lean-beam"), 1, result.stderr)
            self.assertNotIn("usage:", failure["error"]["message"])
            if args[:2] == ("codex", "--config"):
                self.assertEqual(failure["error"]["message"], "--config requires a file path.")

    def test_option_like_config_filename_can_use_a_relative_path(self):
        self.write(self.workspace / "--json", "")
        report = self.run_doctor("codex", "--config", "./--json")
        self.assertEqual(report["scope"], "explicitConfigFile")
        self.has_code(report, "mcp.notConfigured", "notConfigured")

    def test_json_formats_preserve_report_and_diagnostic_status(self):
        for contents, status in [(None, 0), ("malformed = [", 1),
                                 ("[mcp_servers.lean-beam]\ncommand = 'custom-launcher'\n", 2)]:
            with self.subTest(status=status):
                if contents is not None:
                    self.write(self.home / ".codex/config.toml", contents)
                compact = self.run_doctor("codex", "--json", expected=status, as_json=False)
                pretty = self.run_doctor("codex", "--json", expected=status, as_json=False,
                                         global_args=("--pretty",))
                self.assertEqual(compact.stderr, "")
                self.assertEqual(pretty.stderr, "")
                self.assertEqual(json.loads(compact.stdout), json.loads(pretty.stdout))
                self.assertEqual(json.loads(pretty.stdout)["kind"], "clientInspection")
                self.assertEqual(compact.stdout.count("\n"), 1)
                self.assertGreater(pretty.stdout.count("\n"), 1)
                self.assertEqual(json.loads(compact.stdout, object_pairs_hook=list),
                                 json.loads(pretty.stdout, object_pairs_hook=list))

    def test_pretty_errors_remain_separate_from_completed_inspections(self):
        for args in [("codex", "--json", "--verbose"), ("--pretty",)]:
            with self.subTest(args=args):
                compact = self.run_doctor(*args, expected=2, as_json=False)
                pretty = self.run_doctor(*args, expected=2, as_json=False,
                                         global_args=("--pretty",))
                failure = json.loads(pretty.stdout)
                self.assertEqual(failure, json.loads(compact.stdout))
                self.assertFalse(failure["ok"])
                self.assertEqual(failure["error"]["code"], "invalidParams")
                self.assertNotIn("kind", failure)
                self.assertEqual(compact.stdout.count("\n"), 1)
                self.assertGreater(pretty.stdout.count("\n"), 1)

    def test_failed_report_write_or_flush_never_appends_another_json(self):
        fixture = REPO / ".lake/build/bin/beam-cli-daemon-test"
        for severity in [0, 1, 2]:
            for stream in ["stdout-fails", "stdout-flush-fails"]:
                for format in ["compact", "pretty"]:
                    with self.subTest(severity=severity, stream=stream, format=format):
                        result = subprocess.run(
                            [str(fixture), "--client-report-output", str(severity), stream, format],
                            cwd=self.workspace, env=self.env, text=True, capture_output=True, timeout=15,
                        )
                        self.assertEqual(result.returncode, max(1, severity), result.stderr)
                        self.assertIn("fixture response write attempts: 1", result.stderr)
                        self.assertNotIn('"ok": false', result.stdout)
                        if stream == "stdout-flush-fails":
                            self.assertEqual(json.loads(result.stdout)["kind"], "clientInspection")
                        else:
                            self.assertTrue(result.stdout.startswith("{"), result.stdout)
                            self.assertEqual(len(result.stdout), 12)

    def test_pi_agent_skills_locations(self):
        self.write(self.workspace / ".agents/skills/lean-beam/SKILL.md", "Lean skill\n")
        self.has_code(self.run_doctor("pi"), "skill.readable", "ok")

    def test_duplicate_vibe_entries_are_errors(self):
        entry = ("[[mcp_servers]]\nname = 'lean-beam'\ntransport = 'stdio'\n"
                 f"command = [{json.dumps(str(self.executable))}]\n")
        self.write(self.home / ".vibe/config.toml", entry + entry)
        self.has_code(self.run_doctor("vibe", expected=1), "mcp.duplicate", "error")

    def test_vibe_requires_a_server_name(self):
        self.write(self.home / ".vibe/config.toml", (
            "[[mcp_servers]]\ntransport = 'stdio'\n"
            f"command = [{json.dumps(str(self.executable))}]\n"
        ))
        self.has_code(self.run_doctor("vibe", expected=1), "mcp.invalidEntry", "error")

    def test_vibe_disabled_registration_is_not_checked_as_healthy(self):
        config = self.home / ".vibe/config.toml"
        entry = ("[[mcp_servers]]\nname = 'lean-beam'\ntransport = 'stdio'\n"
                 f"command = [{json.dumps(str(self.executable))}]\n")
        self.write(config, entry + "disabled = true\n")
        report = self.run_doctor("vibe", expected=1)
        self.has_code(report, "mcp.disabled", "error")
        self.assertNotIn("launch.file", {f["code"] for f in self.findings(report)})
        self.write(config, entry + "disabled = false\n")
        self.has_code(self.run_doctor("vibe"), "launch.file", "ok")
        self.write(config, entry + "disabled = 'not a boolean'\n")
        self.has_code(self.run_doctor("vibe", expected=1), "mcp.invalidEntry", "error")

    def test_vibe_distinct_aliases_are_not_duplicate_names(self):
        self.write(self.home / ".vibe/config.toml", "\n".join(
            f"[[mcp_servers]]\nname={json.dumps(name)}\ntransport='stdio'\n"
            f"command=[{json.dumps(str(self.executable))}]\n"
            for name in ["lean-beam", "another-beam"]
        ))
        report = self.run_doctor("vibe", expected=2)
        self.has_code(report, "config.layers", "unknown")
        self.assertNotIn("mcp.duplicate", {item["code"] for item in self.findings(report)})
        self.assertEqual({item["key"] for item in self.findings(report)
                          if item["code"] == "mcp.definition"},
                         {"mcp_servers[lean-beam]", "mcp_servers[another-beam]"})

    def test_vibe_empty_project_collection_leaves_selection_unknown(self):
        self.write(self.home / ".vibe/config.toml", (
            "[[mcp_servers]]\nname = 'lean-beam'\ntransport = 'stdio'\n"
            f"command = [{json.dumps(str(self.executable))}]\n"
        ))
        self.write(self.workspace / ".vibe/config.toml", "mcp_servers = []\n")
        self.has_code(self.run_doctor("vibe", expected=2), "config.layers", "unknown")

    def test_toml_duplicate_keys_and_inline_vibe_entries(self):
        self.codex_config(extra="command = 'DOCTOR_SECRET_SENTINEL'\n")
        report = self.run_doctor("codex", expected=1)
        self.has_code(report, "config.syntax", "error")
        self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))
        self.write(self.home / ".vibe/config.toml", (
            "mcp_servers = [{name='lean-beam', transport='stdio', command=["
            + json.dumps(str(self.executable)) + "]}]\n"
        ))
        self.has_code(self.run_doctor("vibe"), "launch.file", "ok")

    def test_launch_arguments_and_environment_values_are_never_rendered(self):
        self.codex_config(extra='args = ["DOCTOR_SECRET_SENTINEL"]\n'
                          'env = {TOKEN="ANOTHER_SECRET_SENTINEL"}\n')
        report = self.run_doctor("codex", expected=2)
        self.has_code(report, "launch.arguments", "unknown")
        self.has_code(report, "launch.overrides", "unknown")
        self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))
        self.assertNotIn("ANOTHER_SECRET_SENTINEL", json.dumps(report))

    def test_relative_client_home_does_not_read_an_assumed_directory(self):
        self.env["PI_CODING_AGENT_DIR"] = "relative-agent-home"
        self.has_code(self.run_doctor("pi", expected=1), "location.relative", "error")

    def test_native_claude_home_override_is_explicitly_unverified(self):
        self.env["CLAUDE_CONFIG_DIR"] = str(self.root / "native-claude")
        self.has_code(self.run_doctor("claude", expected=2), "config.clientHome", "unknown")

    def test_opencode_xdg_and_custom_config_paths(self):
        self.env["XDG_CONFIG_HOME"] = str(self.root / "xdg")
        self.json_file(self.root / "xdg/opencode/opencode.json", {
            "mcp": {"lean-beam": {"type": "local", "command": [str(self.executable)]}},
        })
        self.has_code(self.run_doctor("opencode"), "launch.file", "ok")
        custom = self.root / "custom-opencode.json"
        self.env["OPENCODE_CONFIG"] = str(custom)
        self.json_file(custom, {"mcp": {"lean-beam": {"enabled": False}}})
        self.has_code(self.run_doctor("opencode", expected=1), "mcp.disabled", "error")

    def test_pinned_installation_metadata_is_independent_of_current(self):
        install = self.root / "install"
        self.write(install / ".lean-beam-install-root", f"schema=1\nowner=lean-beam\nroot={install}\n")
        runtimes = []
        for payload in ["1" * 64, "2" * 64]:
            runtime = install / "versions" / payload
            executable = runtime / "bin/lean-beam-mcp"
            self.write(executable, self.executable.read_text())
            executable.chmod(0o755)
            manifest = json.loads((self.installation / "manifest.json").read_text())
            manifest["payloadHash"] = payload
            self.json_file(runtime / "manifest.json", manifest)
            runtimes.append(runtime)
        current = install / "current"
        current.symlink_to(runtimes[0])
        self.codex_config(current / "bin/lean-beam-mcp")
        self.has_code(self.run_doctor("codex"), "runtime.metadata", "ok")
        self.codex_config(runtimes[0] / "bin/lean-beam-mcp")
        current.unlink()
        current.symlink_to(runtimes[1])
        self.has_code(self.run_doctor("codex"), "runtime.metadata", "ok")
        manifest = runtimes[1] / "manifest.json"
        valid_manifest = manifest.read_bytes()
        for contents in [b" " * (1024 * 1024 + 1), b"\xffDOCTOR_SECRET_SENTINEL"]:
            with self.subTest(current_manifest=contents[:1]):
                manifest.write_bytes(contents)
                report = self.run_doctor("codex")
                self.has_code(report, "runtime.metadata", "ok")
                self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))
        manifest.write_bytes(valid_manifest)
        pinned_manifest = runtimes[0] / "manifest.json"
        valid_pinned = pinned_manifest.read_bytes()
        for contents in [b" " * (1024 * 1024 + 1), b"\xffDOCTOR_SECRET_SENTINEL"]:
            pinned_manifest.write_bytes(contents)
            report = self.run_doctor("codex", expected=2)
            self.has_code(report, "runtime.unreadable", "unknown")
            self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))
        pinned_manifest.write_bytes(valid_pinned)
        current.unlink()
        self.has_code(self.run_doctor("codex"), "runtime.metadata", "ok")
        self.write(current, "invalid current selection")
        self.has_code(self.run_doctor("codex"), "runtime.metadata", "ok")
        current.unlink()
        current.symlink_to(runtimes[1])
        self.write(runtimes[1] / "manifest.json", "{}")
        self.has_code(self.run_doctor("codex"), "runtime.metadata", "ok")
        current.unlink()
        current.symlink_to(runtimes[0])
        self.write(runtimes[0] / "manifest.json", '{"secret":"DOCTOR_SECRET_SENTINEL"}')
        report = self.run_doctor("codex", expected=1)
        self.has_code(report, "runtime.invalid", "error")
        self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))


if __name__ == "__main__":
    unittest.main()
