#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Exercise client writes and failure handling without constructing another runtime."""

import json
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import tomllib
import unittest


REPO = Path(__file__).resolve().parents[1]
TOOL = Path(sys.argv.pop(1)).resolve()


class InstallerClientTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="beam-install-clients-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = dict(
            os.environ,
            HOME=str(self.home),
            CODEX_HOME=str(self.root / "codex"),
            CLAUDE_HOME=str(self.root / "claude"),
            PI_CODING_AGENT_DIR=str(self.root / "pi"),
            OPENCODE_CONFIG_DIR=str(self.root / "opencode"),
            VIBE_HOME=str(self.root / "vibe"),
            BEAM_AGY_HOME=str(self.root / "agy"),
            BEAM_INSTALL_ROOT=str(self.root / "runtime"),
            BEAM_BIN_HOME=str(self.root / "bin"),
            BEAM_CLAUDE_MCP_CONFIG=str(self.home / ".claude.json"),
            BEAM_TEST_CONSTRUCTION_TOOL=str(TOOL),
            BEAM_TEST_MCP_STUB_LOG=str(self.root / "claude.log"),
        )
        self.env.pop("CLAUDE_CONFIG_DIR", None)

    def run_installer(self, script, *args, reply=None, **env):
        argv = ["bash", "-c", """
. scripts/install-beam.sh
construction_tool="$BEAM_TEST_CONSTRUCTION_TOOL"
dont_ask=1
""" + script, "installer-test", *args]
        options = dict(cwd=REPO, env={**self.env, **env}, capture_output=True, text=True, timeout=20)
        if reply is None:
            return subprocess.run(argv, **options)
        master, slave = pty.openpty()
        try:
            os.write(master, reply.encode())
            return subprocess.run(argv, stdin=slave, **options)
        finally:
            os.close(slave)
            os.close(master)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def assert_failure(self, result, diagnostic):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(diagnostic, result.stderr)

    def assert_no_config_stage(self, config):
        self.assertEqual(list(config.parent.glob(f"{config.name}.lean-beam-*")), [])

    def test_skill_partial_copy_preserves_each_client_install(self):
        for flag, skills_home in [
            ("--codex", Path(self.env["CODEX_HOME"]) / "skills"),
            ("--claude", Path(self.env["CLAUDE_HOME"]) / "skills"),
            ("--pi", Path(self.env["PI_CODING_AGENT_DIR"]) / "skills"),
            ("--opencode", Path(self.env["OPENCODE_CONFIG_DIR"]) / "skills"),
            ("--vibe", Path(self.env["VIBE_HOME"]) / "skills"),
            ("--agy", Path(self.env["BEAM_AGY_HOME"]) / ".gemini/config/skills"),
        ]:
            with self.subTest(client=flag):
                self.check_skill_failure(flag, skills_home, """
cp() {
  printf 'partial copy\n' >"${3%/}/SKILL.md"
  return 47
}
""", "could not stage lean-beam skill")

    def test_skill_publish_failure_restores_previous_directory(self):
        self.check_skill_failure("--codex", Path(self.env["CODEX_HOME"]) / "skills", """
mv() {
  case "$*" in
    *'/previous/'*) command mv "$@" ;;
    *'.staging-'*) return 48 ;;
    *) command mv "$@" ;;
  esac
}
""", "could not publish lean-beam skill")

    def check_skill_failure(self, flag, skills_home, injection, diagnostic):
        target = skills_home / "lean-beam"
        target.mkdir(parents=True)
        (target / "SKILL.md").write_text("previous working skill\n")
        (target / ".lean-beam-skill").write_text("previous marker\n")
        result = self.run_installer("""
prepare_install_environment() {
  mkdir -p "$install_root"
}
prepare_install_version() { rmdir "$1"; }
publish_runtime() { :; }
print_install_summary() { printf 'Install Complete\n'; }
trap 'printf "recorded skills=%s\n" "${installed_skill_targets[*]:-none}"' EXIT
""" + injection + """
main --dont-ask "$@"
""", flag)
        self.assert_failure(result, diagnostic)
        self.assertNotIn("Install Complete", result.stdout)
        self.assertIn("recorded skills=none", result.stdout)
        self.assertEqual((target / "SKILL.md").read_text(), "previous working skill\n")
        self.assertEqual((target / ".lean-beam-skill").read_text(), "previous marker\n")
        self.assertEqual(list(target.parent.iterdir()), [target])

    def test_claude_config_dir_refused_before_approval(self):
        for value in (str(self.root / "native-claude"), ""):
            for config_arg in ([], ["--claude-mcp-config", str(self.root / "custom/.claude.json")]):
                with self.subTest(value=value, config_arg=config_arg):
                    result = self.run_installer("""
dont_ask=0
parse_args --claude-mcp "$@"
approve_requested_writes
""", *config_arg, reply="y\n", CLAUDE_CONFIG_DIR=value)
                    self.assert_failure(result, "CLAUDE_CONFIG_DIR is set; unset it")
                    self.assertNotIn("Write Locations", result.stdout + result.stderr)
                    self.assertEqual(list(self.home.iterdir()), [])
                    self.assertFalse((self.root / "native-claude").exists())
                    self.assertFalse((self.root / "custom").exists())

    def test_claude_add_or_remove_failure_preserves_config(self):
        for operation in ("add", "remove"):
            with self.subTest(operation=operation):
                config = self.home / ".claude.json"
                config.write_text('{"mcpServers":{"lean-beam":{"command":"/old","env":{"KEY":"value"}},'
                                  '"other":{"command":"/unrelated"}},"otherSettings":true}\n')
                config.chmod(0o640)
                original = config.read_bytes()
                result = self.run_installer("""
. tests/lib/install-fixtures.sh
beam_install_setup_mcp_cli_stubs "$HOME/stubs" "$BEAM_TEST_MCP_STUB_LOG"
export PATH="$HOME/stubs:$PATH"
trap 'printf "registrations=%s\n" "${registered_mcp_targets[*]:-none}"' EXIT
register_claude_mcp_server
""", BEAM_TEST_FAIL_CLAUDE_MCP=operation)
                self.assert_failure(result, f"Claude Code MCP {operation} failed for lean-beam (exit 73)")
                self.assertIn(f"fixture Claude MCP {operation} failure", result.stderr)
                self.assertIn("registrations=none", result.stdout)
                calls = (self.root / "claude.log").read_text()
                self.assertIn("|remove|--scope|user|lean-beam", calls)
                self.assertEqual("|add|--scope|user|lean-beam" in calls, operation == "add")
                self.assertEqual(config.read_bytes(), original)
                self.assertEqual(config.stat().st_mode & 0o777, 0o640)
                self.assert_no_config_stage(config)

    def test_claude_successfully_replaces_existing_user_registration(self):
        config = self.home / ".claude.json"
        config.write_text('{"mcpServers":{"lean-beam":{"command":"/old"},"other":{"command":"/keep"}}}')
        result = self.run_installer("""
. tests/lib/install-fixtures.sh
beam_install_setup_mcp_cli_stubs "$HOME/stubs" "$BEAM_TEST_MCP_STUB_LOG"
export PATH="$HOME/stubs:$PATH"
register_claude_mcp_server
printf '%s\n' "${registered_mcp_targets[*]}"
""")
        self.assert_success(result)
        self.assertIn("Claude Code: lean-beam", result.stdout)
        servers = json.loads(config.read_bytes())["mcpServers"]
        self.assertEqual(servers["lean-beam"]["command"], f"{self.root}/bin/lean-beam-mcp")
        self.assertEqual(servers["other"]["command"], "/keep")
        self.assert_no_config_stage(config)

    def set_config(self, client, content):
        config = Path(self.env[f"{client.upper()}_HOME"]) / "config.toml"
        config.parent.mkdir(exist_ok=True)
        config.write_bytes(content.encode())
        return config

    def test_codex_matches_exact_keys_and_preserves_comments(self):
        other = '[mcp_servers."lean - beam"]\nsupports_parallel_tool_calls = false\n'
        for header in ("[mcp_servers.lean-beam]", '[ "mcp_servers" . "lean-beam" ]',
                       "[ mcp_servers . 'lean-beam' ]"):
            with self.subTest(header=header):
                original = (other + f'{header} # keep header\n'
                            '  "supports_parallel_tool_calls" \t= false # keep setting\n'
                            '[mcp_servers.lean-beam.env]\nsupports_parallel_tool_calls = "keep"\n')
                original = original.replace("\n", "\r\n")
                config = self.set_config("codex", original)
                result = self.run_installer("set_codex_parallel_tool_calls")
                self.assert_success(result)
                expected = original.replace("false # keep setting", "true # keep setting")
                self.assertEqual(config.read_bytes(), expected.encode())
                self.assert_no_config_stage(config)

    def test_codex_requires_the_exact_target_table(self):
        original = '[mcp_servers."lean - beam"]\nsupports_parallel_tool_calls = false\n'
        config = self.set_config("codex", original)
        result = self.run_installer("set_codex_parallel_tool_calls")
        self.assert_failure(result, "lacks the lean-beam server table")
        self.assertEqual(config.read_bytes(), original.encode())
        self.assert_no_config_stage(config)

    def test_vibe_replaces_literal_and_escaped_names(self):
        unrelated = '[[mcp_servers]]\nname = "another"\nenv = { TOKEN = "other-test-token" }\n\n'
        target = (
            "[[ mcp_servers ]] # old table\n"
            "   'name' \t= 'lean-beam' # literal name\n"
            'command = ["old"]\n\n'
            '[[ "mcp_servers" ]]\n'
            'name = "lean\\u002dbeam" # escaped name\n'
        )
        tail = '\n[tools]\nexample = true\n'
        config = self.set_config("vibe", unrelated + target + tail)
        result = self.run_installer("register_vibe_mcp_server")
        self.assert_success(result)
        updated = config.read_text()
        self.assertTrue(updated.startswith(unrelated))
        self.assertTrue(updated.endswith(tail))
        servers = tomllib.loads(updated)["mcp_servers"]
        self.assertEqual([server["name"] for server in servers], ["another", "lean-beam"])
        self.assertEqual(servers[1]["command"], [f"{self.root}/bin/lean-beam-mcp"])
        self.assertEqual(servers[1]["args"], [])
        self.assertNotIn("Proposed Mistral Vibe", result.stderr)
        self.assert_no_config_stage(config)

        result = self.run_installer("mcp_toolset=core\nregister_vibe_mcp_server")
        self.assert_success(result)
        servers = tomllib.loads(config.read_text())["mcp_servers"]
        self.assertEqual(servers[1]["args"], ["--toolset", "core"])
        self.assert_no_config_stage(config)

    def test_vibe_rejects_unsupported_or_invalid_config(self):
        for original, diagnostic in [
            ('[[mcp_servers]]\nname = """lean-beam"""\n', "single-line name"),
            ('[[mcp_servers]]\ncommand = ["missing-name"]\n', "must have a string name"),
            ('[[mcp_servers]\nname = "lean-beam"\n', "invalid TOML"),
            ('[[mcp_servers]]\nname = "lean-beam"\nname = "duplicate"\n', "invalid TOML"),
            ('[[mcp_servers]]\nname = "lean-beam"\n[mcp_servers.env]\nTOKEN = "test-token"\n',
             "subtable is unsupported"),
        ]:
            with self.subTest(diagnostic=diagnostic):
                config = self.set_config("vibe", original)
                result = self.run_installer("register_vibe_mcp_server")
                self.assert_failure(result, diagnostic)
                self.assertNotIn("test-token", result.stderr)
                self.assertEqual(config.read_bytes(), original.encode())
                self.assert_no_config_stage(config)

    def test_vibe_interactive_diff_is_secret_safe_and_precedes_approval(self):
        original = ('[[mcp_servers]]\nname = "unrelated-server"\nenv = { TOKEN = "other-secret" }\n'
                    '[[mcp_servers]]\nname = "lean-beam" # private-comment\n'
                    'command = ["old-secret"]\nenv = { TOKEN = "target-secret" }\n')
        config = self.set_config("vibe", original)
        script = """
dont_ask=0
register_vibe_mcp=1
approve_current_write_locations
register_vibe_mcp_server
"""
        result = self.run_installer(script, reply="n\n")
        self.assert_failure(result, "cancelled before: register lean-beam MCP server")
        self.assertIn("--- Current Mistral Vibe lean-beam block (redacted)", result.stderr)
        self.assertIn("+++ Proposed Mistral Vibe lean-beam block", result.stderr)
        self.assertIn("-command = <redacted>", result.stderr)
        self.assertIn(f'+command = ["{self.root}/bin/lean-beam-mcp"]', result.stderr)
        self.assertLess(result.stderr.index("+++ Proposed"), result.stderr.index("Allow this edit?"))
        for secret in ("unrelated-server", "other-secret", "private-comment", "old-secret", "target-secret"):
            self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertEqual(config.read_bytes(), original.encode())
        self.assert_no_config_stage(config)

    def test_toml_move_failure_leaves_config_and_cleans_stage(self):
        for client, cmd, original in [
            ("codex", "set_codex_parallel_tool_calls",
             '[mcp_servers.lean-beam]\nsupports_parallel_tool_calls = false\n'),
            ("vibe", "register_vibe_mcp_server", '[[mcp_servers]]\nname = "lean-beam"\n'),
        ]:
            with self.subTest(client=client):
                config = self.set_config(client, original)
                result = self.run_installer("mv() { return 49; }\n" + cmd)
                self.assert_failure(result, "could not publish MCP config")
                self.assertEqual(config.read_bytes(), original.encode())
                self.assert_no_config_stage(config)


if __name__ == "__main__":
    unittest.main()
