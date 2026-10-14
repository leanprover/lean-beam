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


REPO = Path(__file__).resolve().parent.parent
WRAPPER = REPO / "scripts" / "lean-beam"


class ClientDoctorTest(unittest.TestCase):
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
        for name in ["codex", "claude", "pi", "opencode", "vibe", "lean", "lake", "elan", "coq-lsp"]:
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

    def run_doctor(self, *args, expected=0, as_json=True):
        before = self.snapshot()
        command = [str(WRAPPER), "doctor", "clients", *args]
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
            return json.loads(result.stdout)
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

    def test_empty_pi_summary_does_not_claim_an_integration(self):
        report = self.run_doctor("pi")
        self.assertEqual(report["clients"][0]["mcp"], "notApplicable")
        self.assertEqual(report["clients"][0]["skill"], "notConfigured")
        text = self.run_doctor("pi", as_json=False).stdout
        self.assertIn("pi: not configured", text)
        self.assertNotIn("CLI skill integration", text)

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

    def test_installer_shapes_for_all_five_clients(self):
        self.codex_config()
        self.json_file(self.home / ".claude.json", {
            "mcpServers": {"lean-beam": {"command": str(self.executable), "args": []}},
        })
        self.write(self.home / ".vibe" / "config.toml", (
            "[[mcp_servers]]\nname = 'lean-beam'\ntransport = 'stdio'\n"
            f"command = {json.dumps(str(self.executable))}\nargs = []\ntool_timeout_sec = 600\n"
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
        self.assertIn("0 errors, 0 unverified checks, 0 recommendations.", compact)
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
        self.has_code(self.run_doctor("opencode"), "launch.file", "ok")
        self.json_file(project, {"mcp": {"lean-beam": {"command": [str(self.executable), "arg"]}}})
        self.has_code(self.run_doctor("opencode", expected=2), "launch.arguments", "unknown")

    def test_opencode_inherited_partial_entry_remains_unknown(self):
        self.json_file(self.workspace / "opencode.json", {"mcp": {"lean-beam": {"enabled": True}}})
        self.has_code(self.run_doctor("opencode", expected=2), "config.partial", "unknown")

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
            [str(WRAPPER), "--root", str(self.workspace), "doctor", "clients", "codex", "--json"],
            cwd=self.root, env=self.env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["workspace"], str(self.workspace))
        self.assertEqual(before, self.snapshot())

    def test_cli_usage_has_diagnostic_exit_status(self):
        for args in [("unknown-client",), ("--config", "/tmp/config"), ("pi", "codex")]:
            result = self.run_doctor(*args, expected=2, as_json=False)
            self.assertEqual(result.stdout, "")
            self.assertTrue(result.stderr)

    def test_pi_agent_skills_locations(self):
        self.write(self.workspace / ".agents/skills/lean-beam/SKILL.md", "Lean skill\n")
        self.has_code(self.run_doctor("pi"), "skill.readable", "ok")

    def test_duplicate_vibe_entries_are_errors(self):
        entry = ("[[mcp_servers]]\nname = 'lean-beam'\ntransport = 'stdio'\n"
                 f"command = {json.dumps(str(self.executable))}\n")
        self.write(self.home / ".vibe/config.toml", entry + entry)
        self.has_code(self.run_doctor("vibe", expected=1), "mcp.duplicate", "error")

    def test_vibe_requires_a_server_name(self):
        self.write(self.home / ".vibe/config.toml", (
            "[[mcp_servers]]\ntransport = 'stdio'\n"
            f"command = {json.dumps(str(self.executable))}\n"
        ))
        self.has_code(self.run_doctor("vibe", expected=1), "mcp.invalidEntry", "error")

    def test_vibe_distinct_aliases_are_not_duplicate_names(self):
        self.write(self.home / ".vibe/config.toml", "\n".join(
            f"[[mcp_servers]]\nname={json.dumps(name)}\ntransport='stdio'\n"
            f"command={json.dumps(str(self.executable))}\n"
            for name in ["lean-beam", "another-beam"]
        ))
        report = self.run_doctor("vibe", expected=2)
        self.has_code(report, "config.layers", "unknown")
        self.assertNotIn("mcp.duplicate", {item["code"] for item in self.findings(report)})

    def test_vibe_empty_project_collection_leaves_selection_unknown(self):
        self.write(self.home / ".vibe/config.toml", (
            "[[mcp_servers]]\nname = 'lean-beam'\ntransport = 'stdio'\n"
            f"command = {json.dumps(str(self.executable))}\n"
        ))
        self.write(self.workspace / ".vibe/config.toml", "mcp_servers = []\n")
        self.has_code(self.run_doctor("vibe", expected=2), "config.layers", "unknown")

    def test_toml_duplicate_keys_and_inline_vibe_entries(self):
        self.codex_config(extra="command = 'DOCTOR_SECRET_SENTINEL'\n")
        report = self.run_doctor("codex", expected=1)
        self.has_code(report, "config.syntax", "error")
        self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))
        self.write(self.home / ".vibe/config.toml", (
            "mcp_servers = [{name='lean-beam', transport='stdio', command="
            + json.dumps(str(self.executable)) + "}]\n"
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

    def test_installed_runtime_metadata_and_current_link(self):
        install = self.root / "install"
        self.write(install / ".lean-beam-install-root", f"schema=1\nowner=lean-beam\nroot={install}\n")
        runtimes = []
        for payload in ["first", "second"]:
            runtime = install / "versions" / payload
            executable = runtime / "bin/lean-beam-mcp"
            self.write(executable, self.executable.read_text())
            executable.chmod(0o755)
            manifest = subprocess.run(
                [str(WRAPPER), "install-manifest", payload, "-", "leanprover/lean4:v4.35.0"],
                cwd=self.workspace, env=self.env, capture_output=True, text=True, check=True, timeout=15,
            )
            self.write(runtime / "manifest.json", manifest.stdout)
            runtimes.append(runtime)
        current = install / "current"
        current.symlink_to(runtimes[0])
        self.codex_config(current / "bin/lean-beam-mcp")
        self.has_code(self.run_doctor("codex"), "runtime.metadata", "ok")
        self.codex_config(runtimes[0] / "bin/lean-beam-mcp")
        current.unlink()
        current.symlink_to(runtimes[1])
        self.has_code(self.run_doctor("codex"), "runtime.superseded", "warning")
        current.unlink()
        self.has_code(self.run_doctor("codex", expected=1), "runtime.currentMissing", "error")
        self.write(current, "invalid current selection")
        self.has_code(self.run_doctor("codex", expected=1), "runtime.currentInvalid", "error")
        current.unlink()
        current.symlink_to(runtimes[1])
        self.write(runtimes[1] / "manifest.json", "{}")
        self.has_code(self.run_doctor("codex", expected=1), "runtime.currentInvalid", "error")
        current.unlink()
        current.symlink_to(runtimes[0])
        self.write(runtimes[0] / "manifest.json", '{"secret":"DOCTOR_SECRET_SENTINEL"}')
        report = self.run_doctor("codex", expected=1)
        self.has_code(report, "runtime.invalid", "error")
        self.assertNotIn("DOCTOR_SECRET_SENTINEL", json.dumps(report))


if __name__ == "__main__":
    unittest.main()
