#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""CLI process-boundary regressions, using the same installed runtime as the fast suite."""

import json
import os
import selectors
import shlex
import signal
from pathlib import Path
import subprocess
import tempfile
import unittest

from installation_fixture import stage

REPO = Path(__file__).resolve().parents[1]


class CliErrorsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="beam-cli-errors-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name).resolve()
        installation = Path(os.environ.get("BEAM_TEST_INSTALLATION", cls.root / "installation"))
        if "BEAM_TEST_INSTALLATION" not in os.environ:
            stage(installation)
        cls.installation = installation.resolve()
        cls.cli = installation / "libexec" / ("beam-cli.exe" if os.name == "nt" else "beam-cli")
        cls.fixture = REPO / ".lake/build/bin" / ("beam-cli-daemon-test.exe" if os.name == "nt" else "beam-cli-daemon-test")
        cls.env = dict(os.environ, BEAM_PROGRESS="0")
        cls.env.pop("BEAM_SESSION_ROOT", None)
        cls.env.pop("BEAM_REQUEST_ID", None)

    def invoke(self, *args, executable=None, timeout=15, input=None, env=None):
        return subprocess.run([str(executable or self.cli), *map(str, args)], cwd=self.root,
                              env=self.env if env is None else env, text=True, input=input,
                              capture_output=True, timeout=timeout)

    def assert_public_error_data(self, value, path=()):
        """Reject schema drift in actual CLI failures, not just projection fixtures."""
        if isinstance(value, dict):
            for key, item in value.items():
                self.assertNotEqual(key, "projection_error", (path, value))
                self.assertNotRegex(key, r"[A-Z]", (path, key))
                if key in {"original_data", "observed_response", "operation_response", "helper_error"}:
                    continue
                if path == ("operation_outcome",) and key == "error":
                    continue
                self.assert_public_error_data(item, path + (key,))
        elif isinstance(value, list):
            for item in value:
                self.assert_public_error_data(item, path)

    def failure(self, result, code, exit_code):
        self.assertEqual(result.returncode, exit_code, result.stderr)
        response = json.loads(result.stdout)  # Reject duplicate JSON and partial human stdout.
        self.assertIs(response["ok"], False)
        self.assertEqual(response["error"]["code"], code, response)
        self.assert_public_error_data(response["error"].get("data"))
        self.assertNotIn("uncaught exception:", result.stderr)
        self.assertEqual(sum(line.startswith(("beam:", "beam[")) for line in result.stderr.splitlines()), 1)
        return response["error"]

    def test_help_and_version_succeed(self):
        for args in [("-h",), ("--help",), ("help",), ("--version",), ("version",)]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout)

    def test_human_command_errors_do_not_emit_json(self):
        for args in [("prune", "--unknown"), ("-h", "--unknown"), ("help", "--unknown"), ("version", "--unknown")]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertIn("beam:", result.stderr)
        for command in ["-h", "--help", "--version"]:
            result = self.invoke("--root", self.root / "missing", command)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertIn("beam:", result.stderr)
        record = self.installation / "manifest.json"
        contents = record.read_bytes()
        try:
            record.write_text("invalid installation record")
            result = self.invoke("--version")
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            self.assertIn("beam:", result.stderr)
        finally:
            record.write_bytes(contents)

    def test_probe_text_does_not_select_failure_output(self):
        result = self.invoke("run-at", "Main.lean", "invalid-version", "0", "0", "--", "doctor", "--json")
        self.failure(result, "invalidParams", 2)

    def test_json_output_is_compact_by_default_and_pretty_on_request(self):
        compact = self.invoke("--root", self.root, "status")
        pretty = self.invoke("--pretty", "--root", self.root, "status")
        self.assertEqual(compact.returncode, 0, compact.stderr)
        self.assertEqual(pretty.returncode, 0, pretty.stderr)
        self.assertEqual(compact.stdout.count("\n"), 1, compact.stdout)
        self.assertGreater(pretty.stdout.count("\n"), 1, pretty.stdout)
        compact_value = json.loads(compact.stdout)
        pretty_value = json.loads(pretty.stdout)
        self.assertEqual(compact_value, pretty_value)

        def object_key_order(value):
            if isinstance(value, dict):
                return tuple((key, object_key_order(item)) for key, item in value.items())
            if isinstance(value, list):
                return tuple(object_key_order(item) for item in value)
            return None

        self.assertEqual(object_key_order(compact_value), object_key_order(pretty_value))

    def test_pretty_format_applies_to_error_responses(self):
        compact = self.invoke("--root", self.root, "sync")
        pretty = self.invoke("--pretty", "--root", self.root, "sync")
        compact_error = self.failure(compact, "invalidParams", 2)
        pretty_error = self.failure(pretty, "invalidParams", 2)
        self.assertEqual(compact.stdout.count("\n"), 1, compact.stdout)
        self.assertGreater(pretty.stdout.count("\n"), 1, pretty.stdout)
        self.assertEqual(compact_error, pretty_error)

    def test_pretty_format_survives_global_option_parse_failures(self):
        cases = [
            (("--pretty", "--root"), ("--root",), "--root requires PATH"),
            (("--root", self.root, "--pretty", "--session-dir", "relative-session"),
             ("--root", self.root, "--session-dir", "relative-session"),
             "--session-dir requires an absolute path"),
        ]
        for pretty_args, compact_args, detail in cases:
            with self.subTest(args=pretty_args):
                pretty = self.invoke(*pretty_args)
                compact = self.invoke(*compact_args)
                pretty_error = self.failure(pretty, "invalidParams", 2)
                compact_error = self.failure(compact, "invalidParams", 2)
                self.assertIn(detail, pretty_error["message"])
                self.assertEqual(pretty_error, compact_error)
                self.assertGreater(pretty.stdout.count("\n"), 1, pretty.stdout)
                self.assertEqual(compact.stdout.count("\n"), 1, compact.stdout)

    def test_misplaced_pretty_explains_global_option_placement(self):
        for args in [("sync", "Main.lean", "--pretty"), ("sync", "--pretty")]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                error = self.failure(result, "invalidParams", 2)
                self.assertIn("global JSON formatting option", error["message"])
                self.assertIn("place it before the command", error["message"])
                self.assertIn("lean-beam --pretty sync ...", error["message"])

    def test_usage_is_short_and_names_command(self):
        for args, detail in [((), "a command is required"), (("synk",), "synk"),
                             (("sync",), "sync"), (("hover", "Main.lean"), "hover"),
                             (("--root",), "--root"), (("--session-dir",), "--session-dir"),
                             (("recover", "--wrong"), "--wrong"),
                             (("feedback-report", "--input"), "--input"),
                             (("feedback-report", "--unknown"), "--unknown")]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                error = self.failure(result, "invalidParams", 2)
                self.assertIn(detail, error["message"])
                self.assertLess(len(result.stderr), 600)

    def test_bad_numbers_and_enums_precede_project_selection(self):
        for args, detail in [
            (("hover", "Main.lean", "1", "-1", "0"), "-1"),
            (("run-at", "Main.lean", "one", "0", "0", "#check 1"), "one"),
            (("todo", "Main.lean", "1", "0", "0", "1", "0", "--kind", "alien"), "alien"),
            (("goals", "unknown", "Main.lean", "1", "0", "0"), "unknown"),
        ]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertIn(detail, self.failure(result, "invalidParams", 2)["message"])
                self.assertIn("usage:", result.stderr)

    def test_root_file_and_text_file_have_input_context(self):
        root_file = self.root / "root-file"
        root_file.write_text("not a workspace")
        result = self.invoke("--root", root_file, "status")
        error = self.failure(result, "invalidParams", 2)
        self.assertIn("workspace root is not a directory", error["message"])
        self.assertIn(str(root_file), error["message"])
        missing = self.root / "missing-text"
        result = self.invoke("run-at", "Main.lean", "1", "0", "0", "--text-file", missing)
        error = self.failure(result, "invalidParams", 2)
        self.assertIn("--text-file", error["message"])
        self.assertIn(str(missing), error["message"])

    def test_missing_root_has_concise_wording(self):
        missing = self.root / "missing-workspace"
        result = self.invoke("--root", missing, "status")
        error = self.failure(result, "invalidParams", 2)
        self.assertEqual(error["message"], f"workspace root does not exist: {missing}")
        self.assertEqual(result.stderr.splitlines(), [f"beam: {error['message']}"])

    @unittest.skipIf(os.name == "nt", "POSIX symbolic link fixture")
    def test_root_loop_is_not_reported_as_missing(self):
        loop = self.root / "root-loop"
        loop.symlink_to(loop)
        self.addCleanup(loop.unlink)
        result = self.invoke("--root", loop, "status")
        self.assertEqual(self.failure(result, "invalidParams", 2)["message"],
                         f"workspace root cannot be resolved: {loop}")

    @unittest.skipIf(os.name == "nt" or getattr(os, "geteuid", lambda: 0)() == 0,
                     "requires POSIX permissions and an unprivileged process")
    def test_unreadable_root_ancestor_is_not_reported_as_missing(self):
        ancestor = self.root / "unreadable-root-ancestor"
        ancestor.mkdir()
        self.addCleanup(ancestor.rmdir)
        requested = ancestor / "workspace"
        requested.mkdir()
        self.addCleanup(requested.rmdir)
        # Cleanup order restores access before removing the child.
        self.addCleanup(ancestor.chmod, 0o700)
        ancestor.chmod(0)
        result = self.invoke("--root", requested, "status")
        self.assertEqual(self.failure(result, "invalidParams", 2)["message"],
                         f"permission denied while resolving workspace root: {requested}")

    def test_named_input_directories_are_usage_errors(self):
        for option, args in self.named_input_commands(self.root):
            with self.subTest(option=option):
                error = self.failure(self.invoke(*args), "invalidParams", 2)
                self.assertIn("requires a regular file", error["message"])
                self.assertEqual(error["data"]["argument"]["field"], option)
        self.assertFalse((self.root / ".beam").exists())

    def named_input_commands(self, path):
        return [("--text-file", ("run-at", "Main.lean", "1", "0", "0", "--text-file", path)),
                ("--handle-file", ("run-with", "Main.lean", "--handle-file", path, "simp"))]

    def test_named_input_missing_and_unreadable_files_are_usage_errors(self):
        for option, args in self.named_input_commands(self.root / "missing-named-input"):
            with self.subTest(option=option, kind="missing"):
                error = self.failure(self.invoke(*args), "invalidParams", 2)
                self.assertEqual(error["data"]["argument"]["field"], option)
        if os.name != "nt" and os.geteuid() != 0:
            target = self.root / "unreadable-named-input"
            target.write_text("{}")
            self.addCleanup(target.unlink)
            self.addCleanup(target.chmod, 0o600)
            target.chmod(0)
            for option, args in self.named_input_commands(target):
                with self.subTest(option=option, kind="unreadable"):
                    error = self.failure(self.invoke(*args), "invalidParams", 2)
                    self.assertIn("cannot read", error["message"])
        self.assertFalse((self.root / ".beam").exists())

    @unittest.skipIf(os.name == "nt", "POSIX special-file fixture")
    def test_unwritten_fifos_and_devices_are_rejected_before_read(self):
        fifo = self.root / "unwritten-input-fifo"
        os.mkfifo(fifo)
        self.addCleanup(fifo.unlink)
        for path in (fifo, Path("/dev/null")):
            for option, args in self.named_input_commands(path):
                with self.subTest(option=option, path=path):
                    error = self.failure(self.invoke(*args, timeout=3), "invalidParams", 2)
                    self.assertIn("requires a regular file", error["message"])
        self.assertFalse((self.root / ".beam").exists())

    @unittest.skipIf(os.name == "nt", "POSIX symbolic-link fixture")
    def test_named_input_loops_are_usage_errors_and_regular_symlinks_are_admitted(self):
        loop = self.root / "input-loop"
        loop.symlink_to(loop)
        self.addCleanup(loop.unlink)
        for option, args in self.named_input_commands(loop):
            with self.subTest(option=option):
                error = self.failure(self.invoke(*args), "invalidParams", 2)
                self.assertIn("cannot resolve", error["message"])
        target = self.root / "regular-input"
        target.write_text("{}")
        self.addCleanup(target.unlink)
        link = self.root / "regular-input-link"
        link.symlink_to(target)
        self.addCleanup(link.unlink)
        text = self.invoke("--root", self.root, *self.named_input_commands(link)[0][1])
        self.assertIn("Lean", self.failure(text, "invalidParams", 2)["message"])
        handle = self.invoke(*self.named_input_commands(link)[1][1])
        self.assertIn("invalid handle payload", self.failure(handle, "invalidParams", 2)["message"])

    def test_stdin_and_handle_dash_remain_streaming_inputs(self):
        text = self.invoke("--root", self.root, "run-at", "Main.lean", "1", "0", "0", "--stdin", input="#check Nat")
        self.assertIn("Lean", self.failure(text, "invalidParams", 2)["message"])
        handle = self.invoke("run-with", "Main.lean", "-", "simp", input="{}")
        self.assertIn("invalid handle payload", self.failure(handle, "invalidParams", 2)["message"])

    def test_large_local_argument_echo_is_bounded_with_field_and_omitted_length(self):
        for character, preview in [("x", "x" * 128), ("\x1b", r"\u001b" * 128)]:
            with self.subTest(character=repr(character)):
                value = character * 100000
                result = self.invoke("hover", "Main.lean", value, "0", "0")
                error = self.failure(result, "invalidParams", 2)
                self.assertEqual(error["data"]["argument"],
                                 {"field": "version", "preview": preview, "omitted_chars": len(value) - 128})
                self.assertIn("99872 characters omitted", error["message"])
                self.assertIn("99872 characters omitted", result.stderr)
                self.assertLess(len(result.stdout), 4096)
                self.assertLess(len(result.stderr), 2048)

    @unittest.skipIf(os.name == "nt" or signal.getsignal(signal.SIGINT) == signal.SIG_IGN,
                     "requires an inherited default POSIX SIGINT disposition")
    def test_pending_input_sigint_uses_inherited_disposition_before_dispatch(self):
        for kind in ("text", "handle"):
            with self.subTest(kind=kind):
                process = subprocess.Popen([str(self.fixture), "--cli-error", "pre-input", kind],
                                           cwd=self.root, env=self.env, text=True,
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    with selectors.DefaultSelector() as ready:
                        ready.register(process.stderr, selectors.EVENT_READ)
                        self.assertTrue(ready.select(timeout=5), "input fixture never became ready")
                        self.assertEqual(process.stderr.readline(), "fixture-input-ready\n")
                    process.send_signal(signal.SIGINT)
                    self.assertEqual(process.wait(timeout=5), -signal.SIGINT)
                    process.stdin.close()
                    process.stdin = None
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertEqual(stdout, "")
                    self.assertEqual(stderr, "")
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                    for stream in (process.stdin, process.stdout, process.stderr):
                        if stream is not None:
                            stream.close()
        self.assertFalse((self.root / ".beam").exists())

    def test_local_argument_control_characters_are_visible_escapes(self):
        value = "Ω-bad\n\r\t\x1b[31m\x7f\u0085"
        result = self.invoke("hover", "Main.lean", value, "0", "0")
        error = self.failure(result, "invalidParams", 2)
        for control in ("\n", "\r", "\t", "\x1b", "\x7f", "\u0085"):
            self.assertNotIn(control, error["message"])
            if control != "\n":
                self.assertNotIn(control, result.stderr)
        self.assertIn(r"\u001b", result.stderr)
        self.assertIn("Ω-bad", error["message"])
        self.assertEqual(len(result.stderr.splitlines()), 2)

    @unittest.skipIf(os.name == "nt", "POSIX unusual path and shell syntax fixture")
    def test_control_bearing_remedy_is_exact_in_json_and_labelled_on_stderr(self):
        project = self.root / "project Ω 'space\nwith-escape\x1b[31m"
        project.mkdir()
        self.addCleanup(project.rmdir)
        result = self.invoke("--root", project, "stats")
        error = self.failure(result, "noLiveSession", 3)
        command = error["data"]["remedy_command"]
        self.assertEqual(shlex.split(command), ["lean-beam", "--root", str(project),
                                               "--session-dir", str(project / ".beam"), "serve"])
        self.assertIn("\n", command)
        self.assertIn("\x1b", command)
        self.assertNotIn("\x1b", result.stderr)
        self.assertEqual(len(result.stderr.splitlines()), 2)
        self.assertIn("remedy (escaped display; exact command in error.data.remedy_command)", result.stderr)
        self.assertIn(r"\n", result.stderr)
        self.assertIn(r"\u001b", result.stderr)
        self.assertEqual(subprocess.run(["bash", "-n", "-c", command], capture_output=True).returncode, 0)
        self.assertFalse((project / ".beam").exists())

    def test_invalid_handle_has_one_usage_response(self):
        result = self.invoke("run-with", "Main.lean", "{invalid", "simp")
        self.assertIn("handle", self.failure(result, "invalidParams", 2)["message"])

    def test_no_live_owner_has_distinct_exit_and_exact_remedy(self):
        result = self.invoke("--root", self.root, "stats")
        error = self.failure(result, "noLiveSession", 3)
        command = f"lean-beam --root '{self.root}' --session-dir '{self.root / '.beam'}' serve"
        self.assertEqual(error["data"]["remedy_command"], command)
        self.assertEqual(result.stderr.splitlines()[-1], command)
        self.assertFalse((self.root / ".beam").exists())

    def test_absent_status_and_stop_still_succeed(self):
        for command in ("status", "stop"):
            result = self.invoke("--root", self.root, command)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIs(json.loads(result.stdout)["ok"], True)
            self.assertFalse((self.root / ".beam").exists())

    def remedy_project(self, parent):
        project = parent / "project ' with spaces"
        project.mkdir(mode=0o700)
        manifest = json.loads((self.installation / "manifest.json").read_text())
        compiler = Path(manifest["components"]["targets"][0]["lean"]).resolve()
        (project / "lean-toolchain").write_text(str(compiler.parent.parent) + "\n")
        (project / "lakefile.toml").write_text('name = "remedy_fixture"\n')
        return project

    def descriptor_fixture(self, project):
        return {
            "schemaVersion": 5, "lifecycle": "live", "daemonId": "fixture-generation",
            "capability": "fixture-capability", "pid": 999999999, "ownerPid": 999999999,
            "port": 1, "configHash": "different-recorded-configuration",
            "daemonBin": "fixture-daemon", "installationRoot": str(self.installation),
            "startedAt": "fixture", "workspace": {
                "workspaceId": "beam-cli-project", "root": str(project),
                "leanCmd": "fixture-lean", "plugin": "fixture-plugin",
                "toolchain": "fixture-toolchain", "bundleId": "fixture-bundle",
            },
        }

    def session_snapshot(self, control):
        return {str(path.relative_to(control)):
                ("link", os.readlink(path)) if path.is_symlink() else
                ("directory", None) if path.is_dir() else ("file", path.read_bytes())
                for path in control.rglob("*")}

    def assert_descriptor_context(self, error, project, control):
        data = error["data"]
        self.assertEqual(data["root"], str(project))
        self.assertEqual(data["session_dir"], str(control))
        self.assertEqual(data["descriptor_path"], str(control / "beam-daemon.json"))
        self.assertIn(str(control / "beam-daemon.json"), error["message"])
        self.assertIn("all other producers", data["recovery_precondition"])
        self.assertNotIn("generation", data)
        self.assertNotIn("remedy_command", data)
        self.assertNotIn("recover --generation", error["message"])

    def test_configuration_mismatch_remedy_stops_original_owner_before_restart(self):
        with tempfile.TemporaryDirectory(prefix="beam-remedy-") as directory:
            parent = Path(directory).resolve()
            project = self.remedy_project(parent)
            control = parent / "session ' with spaces"
            control.mkdir(mode=0o700)
            descriptor = control / "beam-daemon.json"
            descriptor.write_text(json.dumps(self.descriptor_fixture(project)))
            before = self.session_snapshot(control)
            result = self.invoke("--root", project, "--session-dir", control, "stats")
            error = self.failure(result, "setupError", 1)
            data = error["data"]
            self.assertEqual(shlex.split(data["remedy_command"]),
                             [str(self.installation / "bin" / ("lean-beam.exe" if os.name == "nt" else "lean-beam")),
                              "--root", str(project), "--session-dir", str(control), "stop"])
            self.assertEqual(result.stderr.splitlines()[-1], data["remedy_command"])
            self.assertEqual(data["generation"], "fixture-generation")
            self.assertEqual(data["installation_root"], str(self.installation))
            self.assertEqual(data["root"], str(project))
            self.assertEqual(data["session_dir"], str(control))
            self.assertEqual(data["recorded_config_hash"], "different-recorded-configuration")
            self.assertNotEqual(data["requested_config_hash"], data["recorded_config_hash"])
            self.assertIn("original Beam installation", data["recovery_precondition"])
            self.assertIn("all other producers", data["recovery_precondition"])
            self.assertIn("before starting", error["message"])
            self.assertIn("If the owning installation's executable no longer exists", error["message"])
            self.assertNotIn("toolchain changed", error["message"])
            self.assertEqual(self.session_snapshot(control), before)

    def test_undecodable_descriptor_remedies_keep_exact_selection_and_bytes(self):
        for selection in ["default", "explicit", "environment"]:
            for contents in ['{"schemaVersion":999}', '{', '{}']:
                with self.subTest(selection=selection, contents=contents), \
                        tempfile.TemporaryDirectory(prefix="beam-remedy-") as directory:
                    parent = Path(directory).resolve()
                    project = self.remedy_project(parent)
                    env = dict(self.env)
                    selectors = []
                    control = project / ".beam"
                    if selection == "explicit":
                        control = parent / "session ' with spaces"
                        selectors = ["--session-dir", control]
                    elif selection == "environment":
                        env["BEAM_SESSION_ROOT"] = str(parent / "external ' sessions")
                        status = self.invoke("--root", project, "status", env=env)
                        self.assertEqual(status.returncode, 0, status.stderr)
                        control = Path(json.loads(status.stdout)["result"]["session_dir"])
                        self.assertFalse(control.exists())
                    control.mkdir(mode=0o700, parents=True)
                    (control / "beam-daemon.json").write_text(contents)
                    (control / "lock").write_text("fixture lock sentinel")
                    before = self.session_snapshot(control)
                    for command in [("stats",), ("serve",), ("stop",),
                                    ("recover", "--generation", "fixture-generation")]:
                        with self.subTest(command=command):
                            result = self.invoke("--root", project, *selectors, *command, env=env)
                            code = "setupError" if command[0] == "recover" else "sessionRecoveryRequired"
                            error = self.failure(result, code, 1)
                            self.assert_descriptor_context(error, project, control)
                            self.assertIn("archive this exact descriptor", error["message"])
                            self.assertEqual(self.session_snapshot(control), before)

    def test_configuration_mismatch_quotes_the_owning_executable(self):
        with tempfile.TemporaryDirectory(prefix="beam-remedy-") as directory:
            parent = Path(directory).resolve()
            project = self.remedy_project(parent)
            control = parent / "session"
            control.mkdir(mode=0o700)
            entry = self.descriptor_fixture(project)
            owner = parent / "old ' installation with spaces"
            entry["installationRoot"] = str(owner)
            (control / "beam-daemon.json").write_text(json.dumps(entry))
            error = self.failure(self.invoke("--root", project, "--session-dir", control, "stats"),
                                 "setupError", 1)
            executable = owner / "bin" / ("lean-beam.exe" if os.name == "nt" else "lean-beam")
            self.assertEqual(shlex.split(error["data"]["remedy_command"]),
                             [str(executable), "--root", str(project), "--session-dir", str(control), "stop"])

    def test_unconfirmed_shutdown_suggests_status_and_preserves_descriptor(self):
        with tempfile.TemporaryDirectory(prefix="beam-remedy-") as directory:
            parent = Path(directory).resolve()
            project = self.remedy_project(parent)
            control = parent / "session"
            control.mkdir(mode=0o700)
            entry = self.descriptor_fixture(project)
            entry["lifecycle"] = "draining"
            (control / "beam-daemon.json").write_text(json.dumps(entry))
            (control / "lock").write_text("fixture lock sentinel")
            before = self.session_snapshot(control)
            status = self.invoke("--root", project, "--session-dir", control, "status")
            self.assertEqual(status.returncode, 0, status.stderr)
            self.assertEqual(json.loads(status.stdout)["result"]["state"], "shutdownUnconfirmed")
            for command in ["stats", "serve", "stop"]:
                with self.subTest(command=command):
                    error = self.failure(self.invoke("--root", project, "--session-dir", control, command),
                                         "sessionShutdownUnconfirmed", 1)
                    remedy = shlex.split(error["data"]["remedy_command"])
                    self.assertEqual(remedy[-1], "status")
                    recovery = shlex.split(error["data"]["recovery_command"])
                    self.assertEqual(recovery[-3:], ["recover", "--generation", entry["daemonId"]])
                    self.assertEqual(recovery[:-3], remedy[:-1])
                    self.assertEqual(error["data"]["generation"], entry["daemonId"])
                    self.assertNotIn("recover --generation", error["message"])
                    self.assertEqual(self.session_snapshot(control), before)

    def test_foreign_recover_validates_generation_before_ownership_remedy(self):
        with tempfile.TemporaryDirectory(prefix="beam-remedy-") as directory:
            parent = Path(directory).resolve()
            project = self.remedy_project(parent)
            control = parent / "session"
            control.mkdir(mode=0o700)
            entry = self.descriptor_fixture(project)
            entry["daemonId"] = "recorded ' generation"
            owner = parent / "old ' installation"
            entry["installationRoot"] = str(owner)
            descriptor = control / "beam-daemon.json"
            descriptor.write_text(json.dumps(entry))
            (control / "lock").write_text("fixture lock sentinel")
            before = self.session_snapshot(control)
            requested = "requested ' generation"
            error = self.failure(self.invoke("--root", project, "--session-dir", control,
                                             "recover", "--generation", requested),
                                 "invalidParams", 2)
            self.assertEqual(error["data"]["generation"], entry["daemonId"])
            self.assertIn("does not match recorded generation", error["message"])
            self.assertNotIn("remedyCommand", error["data"])
            self.assertEqual(self.session_snapshot(control), before)

            requested = entry["daemonId"]
            error = self.failure(self.invoke("--root", project, "--session-dir", control,
                                             "recover", "--generation", requested),
                                 "sessionInstallationMismatch", 1)
            executable = owner / "bin" / ("lean-beam.exe" if os.name == "nt" else "lean-beam")
            self.assertEqual(shlex.split(error["data"]["remedy_command"]),
                             [str(executable), "--root", str(project), "--session-dir", str(control),
                              "recover", "--generation", requested])
            self.assertEqual(self.session_snapshot(control), before)

    def test_nonregular_descriptor_recovery_keeps_exact_path_and_preserves_leaf(self):
        for kind in ["directory"] + (["symlink"] if os.name != "nt" else []):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(prefix="beam-remedy-") as directory:
                parent = Path(directory).resolve()
                project = self.remedy_project(parent)
                control = parent / "session ' with spaces"
                control.mkdir(mode=0o700)
                descriptor = control / "beam-daemon.json"
                if kind == "directory":
                    descriptor.mkdir()
                    (descriptor / "keep").write_text("evidence")
                else:
                    target = parent / "linked-descriptor"
                    target.write_text("do not follow")
                    descriptor.symlink_to(target)
                (control / "lock").write_text("fixture lock sentinel")
                before = self.session_snapshot(control)
                for command in [("stats",), ("recover", "--generation", "fixture-generation")]:
                    result = self.invoke("--root", project, "--session-dir", control, *command)
                    code = "setupError" if command[0] == "recover" else "sessionRecoveryRequired"
                    self.assert_descriptor_context(self.failure(result, code, 1), project, control)
                    self.assertEqual(self.session_snapshot(control), before)
                if kind == "symlink":
                    self.assertEqual(target.read_text(), "do not follow")

    def test_doctor_diagnostics_preserve_structured_recovery_failure(self):
        for kind in ["invalid", "configuration-mismatch"]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(prefix="beam-remedy-") as directory:
                parent = Path(directory).resolve()
                project = self.remedy_project(parent)
                control = parent / "session ' with spaces"
                control.mkdir(mode=0o700)
                contents = "{}" if kind == "invalid" else json.dumps(self.descriptor_fixture(project))
                (control / "beam-daemon.json").write_text(contents)
                before = self.session_snapshot(control)
                result = self.invoke("--cli-error", "doctor-lookup", project, control,
                                     executable=self.fixture)
                code = "sessionRecoveryRequired" if kind == "invalid" else "setupError"
                error = self.failure(result, code, 1)
                data = error["data"]
                if kind == "invalid":
                    self.assert_descriptor_context(error, project, control)
                else:
                    self.assertEqual(data["generation"], "fixture-generation")
                    self.assertEqual(shlex.split(data["remedy_command"]),
                                     [str(self.installation / "bin" / ("lean-beam.exe" if os.name == "nt" else "lean-beam")),
                              "--root", str(project), "--session-dir", str(control), "stop"])
                    self.assertEqual(result.stderr.splitlines()[-1], data["remedy_command"])
                    self.assertIn("all other producers", data["recovery_precondition"])
                self.assertIn(f"registry: {control / 'beam-daemon.json'}", data["diagnostics"])
                self.assertEqual(self.session_snapshot(control), before)

    @unittest.skipIf(os.name == "nt", "POSIX mode observation")
    def test_unsafe_directory_is_rejected_without_repair(self):
        session = self.root / "unsafe"
        session.mkdir(mode=0o755)
        session.chmod(0o755)
        result = self.invoke("--root", self.root, "--session-dir", session, "status")
        error = self.failure(result, "setupError", 1)
        self.assertIn("expected 0700", error["message"])
        self.assertEqual(session.stat().st_mode & 0o777, 0o755)
        self.assertEqual(list(session.iterdir()), [])

    def test_unexpected_io_fault_stays_internal(self):
        result = self.invoke("--cli-error", "internal", executable=self.fixture)
        self.assertEqual(self.failure(result, "internalError", 1)["message"], "fixture unexpected fault")

    def test_input_file_io_classification(self):
        for kind, code, exit_code in [("missing", "invalidParams", 2),
                                      ("permission", "invalidParams", 2),
                                      ("eio", "internalError", 1),
                                      ("resources", "internalError", 1)]:
            with self.subTest(kind=kind):
                result = self.invoke("--cli-error", "input-io", kind, executable=self.fixture)
                error = self.failure(result, code, exit_code)
                self.assertIn("--text-file", error["message"])
                self.assertIn("fixture-input", error["message"])

    def test_broker_failure_code_and_data_survive(self):
        result = self.invoke("--cli-error", "broker", executable=self.fixture)
        self.assertEqual(self.failure(result, "fileChanged", 1)["data"], {"original_data": {"version": 7}})
        response = json.loads(result.stdout)
        self.assertEqual(response["client_request_id"], "fixture-request")
        self.assertEqual(response["error"]["document_progress"], {"updates": 9, "done": False})

    def test_semantic_failure_is_a_completed_response(self):
        result = self.invoke("--cli-error", "semantic", executable=self.fixture)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"ok": True, "result": {"success": False}})


if __name__ == "__main__":
    unittest.main()
