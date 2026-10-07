import json
import os
import plistlib
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import deploy
from deploy import (
    DeployError,
    State,
    blocking_changes,
    bump_pubspec_text,
    channel_notes_problem,
    check_release_env,
    parse_env_text,
    parse_pubspec_version,
    previous_release_tag,
    release_files,
    resolve_msstore_pricing,
    resolve_phases,
    set_msstore_release_notes,
    store_artifact_names,
)


def make_context(state: State, phases: list[str], env: dict | None = None, **args) -> deploy.Context:
    defaults = {"dry_run": False, "yes": True, "submit": False}
    defaults.update(args)
    return deploy.Context(
        args=SimpleNamespace(**defaults),
        env=env or {},
        state=state,
        phases=phases,
    )


def completed(stdout: str = "", returncode: int = 0) -> SimpleNamespace:
    return SimpleNamespace(returncode=returncode, stdout=stdout)


class TempRootTest(unittest.TestCase):
    """Points the script's repository root and deploy directory at a temp dir."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        patches = [
            mock.patch.object(deploy, "ROOT", self.root),
            mock.patch.object(deploy, "DEPLOY_DIR", self.root / "build/deploy"),
            mock.patch.object(deploy, "STATE_PATH", self.root / "build/deploy/state.json"),
            mock.patch.object(deploy, "ARTIFACTS_DIR", self.root / "build/deploy/artifacts"),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.addCleanup(self._tmp.cleanup)

    def write(self, relpath: str, text: str) -> Path:
        path = self.root / relpath
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path


class ParseEnvTextTest(unittest.TestCase):
    def test_parses_values_and_skips_comments_and_blanks(self) -> None:
        text = """\
# Play
PLAY_TRACK=alpha

export TOKEN=abc123
NOT A VALID LINE
"""
        values = parse_env_text(text)
        self.assertEqual(values, {"PLAY_TRACK": "alpha", "TOKEN": "abc123"})

    def test_strips_matching_quotes(self) -> None:
        values = parse_env_text("A=\"quoted value\"\nB='single'\nC=un\"quoted\n")
        self.assertEqual(values["A"], "quoted value")
        self.assertEqual(values["B"], "single")
        self.assertEqual(values["C"], 'un"quoted')

    def test_expands_references_to_earlier_keys(self) -> None:
        text = (
            "KEYS=/Users/me/keys\n"
            "APP_STORE_CONNECT_API_KEY_KEY_FILEPATH=${KEYS}/AuthKey_ABC.p8\n"
        )
        values = parse_env_text(text)
        self.assertEqual(
            values["APP_STORE_CONNECT_API_KEY_KEY_FILEPATH"], "/Users/me/keys/AuthKey_ABC.p8"
        )

    def test_expands_from_base_environment(self) -> None:
        values = parse_env_text("A=${HOME_LIKE}/sub\n", {"HOME_LIKE": "/base"})
        self.assertEqual(values["A"], "/base/sub")

    def test_unknown_reference_expands_empty(self) -> None:
        self.assertEqual(parse_env_text("A=${MISSING}x\n")["A"], "x")

    def test_single_quotes_suppress_expansion(self) -> None:
        values = parse_env_text("A='${NOPE}'\n", {"NOPE": "value"})
        self.assertEqual(values["A"], "${NOPE}")


class LoadEnvFileTest(unittest.TestCase):
    def test_file_values_override_stale_ambient_release_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text(
                "PLAY_TRACK=alpha\n"
                "MSSTORE_APP_ID=9P9DVTKZ3SB9\n"
                "MSSTORE_PRICE_ID=Tier1052\n",
                encoding="utf-8",
            )
            ambient = {
                "PLAY_TRACK": "production",
                "MSSTORE_APP_ID": "9NSTALE00000",
                "MSSTORE_PRICE_ID": "Base",
            }
            with (
                mock.patch.object(deploy, "ROOT", root),
                mock.patch.dict(os.environ, ambient, clear=True),
            ):
                loaded = deploy.load_env_file()

        self.assertEqual(loaded["PLAY_TRACK"], "alpha")
        self.assertEqual(loaded["MSSTORE_APP_ID"], "9P9DVTKZ3SB9")
        self.assertEqual(loaded["MSSTORE_PRICE_ID"], "Tier1052")


class GoogleRequestTest(unittest.TestCase):
    def test_requests_use_client_retry_policy(self) -> None:
        request = mock.Mock()
        request.execute.return_value = {"ok": True}

        self.assertEqual(deploy._execute_google_request(request), {"ok": True})

        request.execute.assert_called_once_with(num_retries=5)

    def test_resumable_upload_retries_every_chunk(self) -> None:
        status = mock.Mock()
        status.progress.return_value = 0.5
        request = mock.Mock()
        request.next_chunk.side_effect = [(status, None), (None, {"versionCode": 2})]

        response = deploy._execute_resumable_google_upload(request, "play")

        self.assertEqual(response, {"versionCode": 2})
        self.assertEqual(request.next_chunk.call_count, 2)
        request.next_chunk.assert_called_with(num_retries=5)


class AppleUploadTest(unittest.TestCase):
    ENV = {
        "APP_STORE_CONNECT_API_KEY_KEY_ID": "KEY1234567",
        "APP_STORE_CONNECT_API_KEY_ISSUER_ID": "issuer",
        "APP_STORE_CONNECT_API_KEY_KEY_FILEPATH": "/keys/AuthKey_KEY1234567.p8",
    }

    def _context(self) -> deploy.Context:
        return make_context(State(version="1.1.0", build_number=2), ["ios"], dict(self.ENV))

    def test_upload_uses_altool_with_api_key_and_key_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ipa = Path(tmp) / "Runner.ipa"
            ipa.write_bytes(b"ipa")
            with mock.patch.object(deploy, "run") as run_command:
                deploy._upload_ipa(self._context(), ipa)

        run_command.assert_called_once_with(
            [
                "xcrun",
                "altool",
                "--upload-app",
                "--type",
                "ios",
                "-f",
                str(ipa),
                "--apiKey",
                "KEY1234567",
                "--apiIssuer",
                "issuer",
                "--p8-file-path",
                "/keys/AuthKey_KEY1234567.p8",
            ]
        )

    @staticmethod
    def _write_ipa(path: Path, version: str, build: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        info = plistlib.dumps({"CFBundleShortVersionString": version, "CFBundleVersion": build})
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Payload/Runner.app/Info.plist", info)

    def _run_phase(self, export: tuple[str, str] | None, stale: bool = True):
        """phase_ios with a build/ios/ipa holding an older export, where the build exports `export` or nothing."""
        ctx = self._context()
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        ipa_dir = tmp / "build/ios/ipa"
        if stale:
            self._write_ipa(ipa_dir / "ompanion.ipa", "1.0.0", "1")

        def build(_cmd):
            # flutter build ipa exits 0 even when the export fails.
            self.assertFalse(ipa_dir.exists(), "the previous export is removed before the build")
            if export is not None:
                self._write_ipa(ipa_dir / "ompanion.ipa", *export)

        with (
            mock.patch.object(deploy, "IPA_DIR", ipa_dir),
            mock.patch.object(deploy, "_asc_has_uploaded_build", return_value=False),
            mock.patch.object(deploy, "run", side_effect=build) as run_command,
            mock.patch.object(deploy, "_upload_ipa") as upload,
        ):
            try:
                deploy.phase_ios(ctx)
            finally:
                run_command.assert_called_once_with(
                    ["flutter", "build", "ipa", "--release", "--dart-define=OMPANION_CHANNEL=appstore"]
                )
        return ctx, upload, ipa_dir / "ompanion.ipa"

    def test_builds_the_appstore_channel_and_uploads_its_ipa(self) -> None:
        ctx, upload, ipa = self._run_phase(("1.1.0", "2"))
        upload.assert_called_once_with(ctx, ipa)

    def test_a_failed_export_never_uploads_the_previous_ipa(self) -> None:
        with self.assertRaisesRegex(deploy.DeployError, "exported no IPA"):
            self._run_phase(None)

    def test_an_ipa_of_another_build_is_refused(self) -> None:
        with self.assertRaisesRegex(deploy.DeployError, "is 1.1.0\\+1, not 1.1.0\\+2"):
            self._run_phase(("1.1.0", "1"), stale=False)

    def test_ios_resume_skips_an_already_uploaded_build(self) -> None:
        ctx = self._context()
        with (
            mock.patch.object(deploy, "_asc_has_uploaded_build", return_value=True) as has_build,
            mock.patch.object(deploy, "run") as run_command,
        ):
            deploy.phase_ios(ctx)

        has_build.assert_called_once_with(ctx)
        run_command.assert_not_called()


class ParsePubspecVersionTest(unittest.TestCase):
    def test_ignores_duplicate_nested_version_keys(self) -> None:
        contents = """\
name: example
dependencies:
  first:
    version: 9.9.9+999
version: 2.8.0+119
metadata:
  version: malformed
"""
        self.assertEqual(parse_pubspec_version(contents), ("2.8.0+119", "119"))

    def test_rejects_malformed_versions(self) -> None:
        for value in ("2.8", "2.8.0", "02.8.0+1", "2.8.0+build.1"):
            with self.subTest(value=value), self.assertRaises(DeployError):
                parse_pubspec_version(f"version: {value}\n")

    def test_rejects_missing_top_level_version(self) -> None:
        contents = """\
name: example
dependency:
  version: 2.8.0+119
"""
        with self.assertRaisesRegex(DeployError, "found 0"):
            parse_pubspec_version(contents)

    def test_accepts_numeric_build_metadata(self) -> None:
        self.assertEqual(
            parse_pubspec_version("version: 10.20.30+0007 # release build\n"),
            ("10.20.30+0007", "0007"),
        )


class BumpPubspecTextTest(unittest.TestCase):
    PUBSPEC = """\
name: ompanion
description: A client for omp.
version: 1.0.0+1
environment:
  sdk: ">=3.12.0 <4.0.0"
dependencies:
  some_package:
    version: 9.9.9+999
"""

    def test_replaces_only_the_top_level_version(self) -> None:
        result = bump_pubspec_text(self.PUBSPEC, "1.1.0", 2)
        self.assertIn("version: 1.1.0+2\n", result)
        self.assertIn("    version: 9.9.9+999\n", result)
        self.assertNotIn("1.0.0+1", result)
        self.assertEqual(result.count("\n"), self.PUBSPEC.count("\n"))

    def test_rejects_pubspec_without_version(self) -> None:
        with self.assertRaises(DeployError):
            bump_pubspec_text("name: ompanion\n", "1.1.0", 2)


class ResolvePhasesTest(unittest.TestCase):
    def test_default_selects_all_phases_in_release_order(self) -> None:
        self.assertEqual(
            resolve_phases(None, None),
            [
                "preflight",
                "changelog",
                "bump",
                "farm_start",
                "ios",
                "asc",
                "farm_wait",
                "play",
                "release",
                "msstore",
                "publish",
            ],
        )

    def test_only_keeps_preflight_and_canonical_order(self) -> None:
        self.assertEqual(
            resolve_phases(["msstore", "play"], None),
            ["preflight", "play", "msstore"],
        )
        self.assertEqual(
            resolve_phases(["publish", "play", "farm_wait"], None),
            ["preflight", "farm_wait", "play", "publish"],
        )

    def test_skip_removes_phases(self) -> None:
        selected = resolve_phases(None, ["ios", "asc"])
        self.assertNotIn("ios", selected)
        self.assertNotIn("asc", selected)
        self.assertIn("play", selected)

    def test_preflight_can_be_skipped_explicitly(self) -> None:
        self.assertEqual(resolve_phases(["release"], ["preflight"]), ["release"])

    def test_unknown_phase_raises(self) -> None:
        for name in ("appstore", "amazon", "tvos"):
            with self.subTest(name=name), self.assertRaises(DeployError):
                resolve_phases([name], None)
        with self.assertRaises(DeployError):
            resolve_phases(None, ["nope"])


class ReleaseFilesTest(unittest.TestCase):
    def test_names_each_channel_file(self) -> None:
        self.assertEqual(
            release_files("1.1.0", 2),
            {
                "github": "store/release-notes/1.1.0.md",
                "play": "android/fastlane/metadata/android/en-US/changelogs/2.txt",
                "appstore": "ios/fastlane/metadata/en-US/release_notes.txt",
                "msstore": "store/microsoft/release_notes.txt",
            },
        )


class PreviousReleaseTagTest(unittest.TestCase):
    def test_takes_the_highest_tag_below_the_release(self) -> None:
        tags = ["0.9.0", "1.0.0", "1.0.1", "1.2.0", "1.1.0"]
        self.assertEqual(previous_release_tag(tags, "1.1.0"), "1.0.1")

    def test_compares_numerically(self) -> None:
        self.assertEqual(previous_release_tag(["1.9.0", "1.10.0"], "1.11.0"), "1.10.0")

    def test_ignores_tags_that_are_not_bare_semver(self) -> None:
        tags = ["v1.0.5", "1.0.6-rc1", "latest", "1.0.0"]
        self.assertEqual(previous_release_tag(tags, "1.1.0"), "1.0.0")

    def test_first_release_has_none(self) -> None:
        self.assertIsNone(previous_release_tag([], "1.0.0"))
        self.assertIsNone(previous_release_tag(["1.1.0", "2.0.0"], "1.1.0"))


class ChannelNotesProblemTest(unittest.TestCase):
    def test_keeps_a_file_that_is_new_since_the_last_release(self) -> None:
        self.assertIsNone(channel_notes_problem("Fixes\n", None, 500))

    def test_keeps_a_file_changed_since_the_last_release(self) -> None:
        self.assertIsNone(channel_notes_problem("New notes\n", "Old notes\n", 500))

    def test_regenerates_a_file_unchanged_since_the_last_release(self) -> None:
        self.assertEqual(
            channel_notes_problem("Old notes\n\n", "Old notes\n", 500),
            "unchanged since the last release",
        )

    def test_regenerates_a_changed_file_over_its_limit(self) -> None:
        problem = channel_notes_problem("x" * 501 + "\n", "old", 500)
        self.assertEqual(problem, "501/500 chars, over the limit")

    def test_limit_counts_the_stripped_text(self) -> None:
        self.assertIsNone(channel_notes_problem("x" * 500 + "\n\n", None, 500))

    def test_regenerates_a_missing_or_empty_file(self) -> None:
        self.assertEqual(channel_notes_problem(None, None, 500), "missing")
        self.assertEqual(channel_notes_problem(" \n", None, 500), "empty")


class ChangelogPhaseTest(TempRootTest):
    FILES = release_files("1.1.0", 2)

    def setUp(self) -> None:
        super().setUp()
        self.write(self.FILES["github"], "## Fixes\n- Everything\n")
        self.released = {
            self.FILES["appstore"]: "1.0.0 What's New\n",
            self.FILES["msstore"]: "1.0.0 What's new\n",
        }
        self.write(self.FILES["appstore"], "1.1.0 What's New, by hand\n")
        self.write(self.FILES["msstore"], "1.0.0 What's new\n")

    def fake_run(self, cmd, **_kwargs):
        if cmd[:2] == ["git", "fetch"]:
            return completed()
        if cmd == ["git", "tag", "-l"]:
            return completed("0.9.0\n1.0.0\n1.2.0\n")
        if cmd[:2] == ["git", "show"]:
            tag, _, relpath = cmd[2].partition(":")
            self.assertEqual(tag, "1.0.0")
            if relpath in self.released:
                return completed(self.released[relpath])
            return completed(returncode=128)
        raise AssertionError(f"unexpected command {cmd}")

    def _context(self, **args) -> deploy.Context:
        notes = args.pop("notes", str(self.root / self.FILES["github"]))
        return make_context(
            State(version="1.1.0", build_number=2), ["changelog"], notes=notes, **args
        )

    def test_keeps_edited_files_and_generates_the_rest(self) -> None:
        with (
            mock.patch.object(deploy, "run", side_effect=self.fake_run) as run_command,
            mock.patch.object(
                deploy, "generate_channel_notes", side_effect=lambda _n, platform, _l: f"for {platform}"
            ) as generate,
        ):
            deploy.phase_changelog(self._context())

        self.assertIn(mock.call(["git", "fetch", "--tags", "origin"]), run_command.call_args_list)
        self.assertEqual(
            [call.args[1] for call in generate.call_args_list], ["Android", "Windows"]
        )
        self.assertEqual(
            (self.root / self.FILES["play"]).read_text(encoding="utf-8"), "for Android\n"
        )
        self.assertEqual(
            (self.root / self.FILES["msstore"]).read_text(encoding="utf-8"), "for Windows\n"
        )
        self.assertEqual(
            (self.root / self.FILES["appstore"]).read_text(encoding="utf-8"),
            "1.1.0 What's New, by hand\n",
        )

    def test_copies_other_raw_notes_to_the_github_file(self) -> None:
        raw = self.write("elsewhere.md", "## Other notes\n")
        with (
            mock.patch.object(deploy, "run", side_effect=self.fake_run),
            mock.patch.object(deploy, "generate_channel_notes", return_value="generated"),
        ):
            deploy.phase_changelog(self._context(notes=str(raw)))

        self.assertEqual(
            (self.root / self.FILES["github"]).read_text(encoding="utf-8"), "## Other notes\n"
        )

    def test_dry_run_writes_nothing_and_calls_no_model(self) -> None:
        with (
            mock.patch.object(deploy, "run", side_effect=self.fake_run) as run_command,
            mock.patch.object(deploy, "generate_channel_notes") as generate,
        ):
            deploy.phase_changelog(self._context(dry_run=True))

        generate.assert_not_called()
        self.assertNotIn(mock.call(["git", "fetch", "--tags", "origin"]), run_command.call_args_list)
        self.assertFalse((self.root / self.FILES["play"]).exists())
        self.assertEqual(
            (self.root / self.FILES["msstore"]).read_text(encoding="utf-8"), "1.0.0 What's new\n"
        )


class BlockingChangesTest(unittest.TestCase):
    def test_release_files_and_untracked_files_never_block(self) -> None:
        porcelain = (
            " M ios/fastlane/metadata/en-US/release_notes.txt\n"
            " M lib/main.dart\n"
            "M  store/microsoft/release_notes.txt\n"
            "?? store/release-notes/\n"
            " M pubspec.yaml\n"
        )
        self.assertEqual(
            blocking_changes(porcelain, set(release_files("1.1.0", 2).values())),
            [" M lib/main.dart", " M pubspec.yaml"],
        )


class BumpPhaseTest(TempRootTest):
    PATHS = ["pubspec.yaml", *release_files("1.1.0", 2).values()]

    def _run(self, staged: str):
        def fake_run(cmd, **_kwargs):
            if cmd[:3] == ["git", "diff", "--cached"]:
                return completed(staged)
            if cmd == ["git", "rev-parse", "HEAD"]:
                return completed("abc123\n")
            return completed()

        return fake_run

    def test_commits_pubspec_with_the_notes_files_then_pushes(self) -> None:
        self.write("pubspec.yaml", "name: ompanion\nversion: 1.0.0+1\n")
        state = State(version="1.1.0", build_number=2)
        with (
            mock.patch.object(deploy, "run", side_effect=self._run("pubspec.yaml\n")) as run_command,
            mock.patch.object(state, "save"),
        ):
            deploy.phase_bump(make_context(state, ["bump"]))

        commands = [call.args[0] for call in run_command.call_args_list]
        self.assertIn(["git", "add", "--", *self.PATHS], commands)
        self.assertIn(["git", "commit", "-m", "chore(release): 1.1.0", "--", *self.PATHS], commands)
        self.assertEqual(commands[-2], ["git", "push", "origin", "main"])
        self.assertLess(
            commands.index(["git", "add", "--", *self.PATHS]),
            commands.index(["git", "commit", "-m", "chore(release): 1.1.0", "--", *self.PATHS]),
        )
        self.assertEqual(
            (self.root / "pubspec.yaml").read_text(encoding="utf-8"),
            "name: ompanion\nversion: 1.1.0+2\n",
        )
        self.assertEqual(state.data["release_sha"], "abc123")

    def test_resume_after_the_commit_only_pushes(self) -> None:
        self.write("pubspec.yaml", "version: 1.1.0+2\n")
        state = State(version="1.1.0", build_number=2)
        with (
            mock.patch.object(deploy, "run", side_effect=self._run("")) as run_command,
            mock.patch.object(state, "save"),
        ):
            deploy.phase_bump(make_context(state, ["bump"]))

        commands = [call.args[0] for call in run_command.call_args_list]
        self.assertFalse(any(command[:2] == ["git", "commit"] for command in commands))
        self.assertIn(["git", "push", "origin", "main"], commands)


class BuildFarmTest(TempRootTest):
    def test_start_passes_release_tag_and_records_only_the_new_run(self) -> None:
        state = State(version="1.1.0", build_number=2)
        state.data["release_sha"] = "abc123"
        responses = [
            completed(json.dumps([{"databaseId": 10}])),
            completed(),
            completed(
                json.dumps(
                    [
                        {
                            "databaseId": 12,
                            "displayTitle": "Build abc123",
                            "headSha": "abc123",
                            "status": "completed",
                            "createdAt": "2026-10-06T00:00:01Z",
                        },
                        {
                            "databaseId": 11,
                            "displayTitle": "Release 1.1.0",
                            "headSha": "abc123",
                            "status": "completed",
                            "createdAt": "2026-10-06T00:00:00Z",
                        },
                        {
                            "databaseId": 10,
                            "headSha": "abc123",
                            "status": "completed",
                            "createdAt": "2026-10-05T00:00:00Z",
                        },
                    ]
                )
            ),
        ]
        with (
            mock.patch.object(deploy, "run", side_effect=responses) as run_command,
            mock.patch.object(deploy.time, "sleep"),
            mock.patch.object(state, "save"),
        ):
            deploy.phase_farm_start(make_context(state, ["farm_start"]))

        dispatch = run_command.call_args_list[1].args[0]
        self.assertEqual(dispatch[:4], ["gh", "workflow", "run", "build.yml"])
        self.assertIn("release_tag=1.1.0", dispatch)
        self.assertEqual(state.data["farm_run_id"], 11)

    def test_start_resumes_discovery_without_dispatching_twice(self) -> None:
        state = State(version="1.1.0", build_number=2)
        state.data.update(
            {
                "release_sha": "abc123",
                "farm_dispatch": {"headSha": "abc123", "previousRunIds": [10]},
            }
        )
        response = completed(
            json.dumps(
                [
                    {
                        "databaseId": 11,
                        "displayTitle": "Release 1.1.0",
                        "headSha": "abc123",
                        "status": "queued",
                        "createdAt": "2026-10-06T00:00:00Z",
                    }
                ]
            )
        )
        with (
            mock.patch.object(deploy, "run", return_value=response) as run_command,
            mock.patch.object(deploy.time, "sleep"),
            mock.patch.object(state, "save"),
        ):
            deploy.phase_farm_start(make_context(state, ["farm_start"]))

        run_command.assert_called_once()
        self.assertEqual(run_command.call_args.args[0][:4], ["gh", "run", "list", "--workflow"])
        self.assertEqual(state.data["farm_run_id"], 11)
        self.assertNotIn("farm_dispatch", state.data)

    @staticmethod
    def _run_view(title: str) -> SimpleNamespace:
        return completed(
            json.dumps(
                {
                    "status": "completed",
                    "conclusion": "success",
                    "displayTitle": title,
                    "headSha": "0123456789abcdef",
                }
            )
        )

    def test_wait_downloads_both_store_artifacts_of_the_built_commit(self) -> None:
        state = State(version="1.1.0", build_number=2)
        state.data["farm_run_id"] = 11
        responses = [self._run_view("Release 1.1.0"), completed(), completed()]
        with mock.patch.object(deploy, "run", side_effect=responses) as run_command:
            deploy.phase_farm_wait(make_context(state, ["farm_wait"]))

        downloads = [call.args[0] for call in run_command.call_args_list[1:]]
        artifacts = deploy.ARTIFACTS_DIR
        self.assertEqual(
            downloads,
            [
                ["gh", "run", "download", "11", "--name", "ompanion-android-aab-0123456",
                 "--dir", str(artifacts / "android-aab")],
                ["gh", "run", "download", "11", "--name", "ompanion-windows-msix-0123456",
                 "--dir", str(artifacts / "windows-msix")],
            ],
        )

    def test_wait_refuses_a_run_that_is_not_this_release(self) -> None:
        state = State(version="1.1.0", build_number=2)
        state.data["farm_run_id"] = 11
        with mock.patch.object(
            deploy, "run", return_value=self._run_view("Build 0123456789abcdef")
        ) as run_command:
            with self.assertRaisesRegex(DeployError, "debug-signed"):
                deploy.phase_farm_wait(make_context(state, ["farm_wait"]))

        run_command.assert_called_once()


class StoreArtifactNamesTest(unittest.TestCase):
    def test_uses_the_workflows_seven_character_sha(self) -> None:
        self.assertEqual(
            store_artifact_names("0123456789abcdef"),
            {
                "android-aab": "ompanion-android-aab-0123456",
                "windows-msix": "ompanion-windows-msix-0123456",
            },
        )


class GitHubReleaseTest(TempRootTest):
    def setUp(self) -> None:
        super().setUp()
        self.notes = self.write("store/release-notes/1.1.0.md", "Release notes\n")

    @staticmethod
    def _context() -> deploy.Context:
        state = State(version="1.1.0", build_number=2)
        state.data["release_sha"] = "abc123"
        return make_context(state, ["release"])

    @staticmethod
    def _release_info(assets: set[str]) -> SimpleNamespace:
        return completed(
            json.dumps(
                {
                    "isDraft": True,
                    "targetCommitish": "abc123",
                    "assets": [{"name": name} for name in sorted(assets)],
                }
            )
        )

    def test_expects_the_seven_files_the_workflow_attaches(self) -> None:
        self.assertEqual(
            deploy.RELEASE_ASSET_NAMES,
            {
                "appcast.xml",
                "ompanion-android.apk",
                "ompanion-ios.ipa",
                "ompanion-macos.dmg",
                "ompanion-windows-x64.zip",
                "ompanion-linux-x64.zip",
                "ompanion-linux-x64.flatpak",
            },
        )

    def test_verifies_workflow_assets_then_attaches_notes(self) -> None:
        responses = [self._release_info(set(deploy.RELEASE_ASSET_NAMES)), completed()]
        with mock.patch.object(deploy, "run", side_effect=responses) as run_command:
            deploy.phase_release(self._context())

        edit = run_command.call_args_list[1].args[0]
        self.assertEqual(edit[:4], ["gh", "release", "edit", "1.1.0"])
        self.assertIn(str(self.notes), edit)

    def test_rejects_incomplete_draft_before_editing(self) -> None:
        assets = set(deploy.RELEASE_ASSET_NAMES)
        assets.remove("ompanion-macos.dmg")
        with mock.patch.object(
            deploy, "run", return_value=self._release_info(assets)
        ) as run_command:
            with self.assertRaisesRegex(DeployError, "ompanion-macos.dmg"):
                deploy.phase_release(self._context())

        run_command.assert_called_once()

    def test_rejects_a_draft_carrying_a_store_bundle(self) -> None:
        assets = {*deploy.RELEASE_ASSET_NAMES, "ompanion-android.aab"}
        with mock.patch.object(deploy, "run", return_value=self._release_info(assets)):
            with self.assertRaisesRegex(DeployError, "unexpected: ompanion-android.aab"):
                deploy.phase_release(self._context())


class StateTest(TempRootTest):
    def test_round_trip(self) -> None:
        state = State(version="1.1.0", build_number=2)
        state.data["farm_run_id"] = 42
        state.mark_done("changelog")
        loaded = State.load()
        self.assertIsNotNone(loaded)
        self.assertEqual(loaded.version, "1.1.0")
        self.assertEqual(loaded.build_number, 2)
        self.assertEqual(loaded.done, ["changelog"])
        self.assertEqual(loaded.data, {"farm_run_id": 42})

    def test_mark_done_is_idempotent(self) -> None:
        state = State(version="1.1.0", build_number=2)
        state.mark_done("play")
        state.mark_done("play")
        self.assertEqual(State.load().done, ["play"])

    def test_load_returns_none_without_file(self) -> None:
        self.assertIsNone(State.load())


class InitializeStateTest(TempRootTest):
    def setUp(self) -> None:
        super().setUp()
        self.write("pubspec.yaml", "version: 1.0.0+1\n")

    @staticmethod
    def _args(*, dry_run: bool) -> SimpleNamespace:
        return SimpleNamespace(version="1.1.0", build_number=None, fresh=True, dry_run=dry_run)

    def _write_previous_release(self) -> Path:
        State(version="1.0.0", build_number=1, done=["publish"]).save()
        return self.write("build/deploy/artifacts/android-aab/ompanion-android.aab", "old bundle")

    def test_fresh_release_removes_state_and_downloaded_artifacts(self) -> None:
        old_bundle = self._write_previous_release()

        state = deploy.initialize_state(self._args(dry_run=False))

        self.assertEqual((state.version, state.build_number), ("1.1.0", 2))
        self.assertFalse(old_bundle.exists())
        self.assertEqual(State.load(), state)

    def test_dry_run_fresh_release_preserves_existing_outputs(self) -> None:
        old_bundle = self._write_previous_release()

        state = deploy.initialize_state(self._args(dry_run=True))

        self.assertEqual((state.version, state.build_number), ("1.1.0", 2))
        self.assertEqual(old_bundle.read_text(encoding="utf-8"), "old bundle")
        self.assertEqual(State.load().version, "1.0.0")


class DeferredPhaseTest(TempRootTest):
    def test_deferred_phase_remains_pending_and_notes_default_to_the_github_file(self) -> None:
        state = State(version="1.1.0", build_number=2)
        args = SimpleNamespace(only=["publish"], skip=None, notes=None, dry_run=False)

        def defer(_ctx) -> None:
            raise deploy.PhaseDeferred

        with (
            mock.patch.object(deploy, "load_env_file", return_value={}),
            mock.patch.object(deploy, "initialize_state", return_value=state),
            mock.patch.dict(deploy.PHASE_FUNCTIONS, {"preflight": lambda _ctx: None, "publish": defer}),
            mock.patch.object(deploy, "print_summary"),
        ):
            self.assertEqual(deploy.cmd_release(args), 0)

        loaded = State.load()
        self.assertNotIn("publish", loaded.done)
        self.assertEqual(loaded.data["notes"], str(self.root / "store/release-notes/1.1.0.md"))

    def test_publish_decline_defers_phase(self) -> None:
        ctx = make_context(State(version="1.1.0", build_number=2), ["publish"], yes=False)

        with mock.patch.object(deploy.Context, "confirm", return_value=False):
            with self.assertRaises(deploy.PhaseDeferred):
                deploy.phase_publish(ctx)

    def test_publish_marks_the_release_latest(self) -> None:
        ctx = make_context(State(version="1.1.0", build_number=2), ["publish"])

        with mock.patch.object(deploy, "run") as run_command:
            deploy.phase_publish(ctx)

        run_command.assert_called_once_with(
            ["gh", "release", "edit", "1.1.0", "--draft=false", "--latest"]
        )


class AscPhaseTest(TempRootTest):
    def setUp(self) -> None:
        super().setUp()
        self.write("ios/fastlane/metadata/en-US/release_notes.txt", "What's New\n")
        patches = {
            "AscClient": mock.patch.object(deploy, "AscClient"),
            "wait": mock.patch.object(deploy, "_asc_wait_for_build", return_value="build-2"),
            "version": mock.patch.object(deploy, "_asc_ensure_version", return_value="version-1"),
            "whats_new": mock.patch.object(deploy, "_asc_set_whats_new"),
            "submit": mock.patch.object(deploy, "_asc_submit_for_review"),
        }
        self.mocks = {}
        for name, patch in patches.items():
            self.mocks[name] = patch.start()
            self.addCleanup(patch.stop)

    def _context(self, **args) -> deploy.Context:
        return make_context(State(version="1.1.0", build_number=2), ["ios", "asc"], **args)

    def test_attaches_the_build_with_whats_new_and_does_not_submit_by_default(self) -> None:
        with mock.patch.object(deploy.Context, "confirm") as confirm:
            deploy.phase_asc(self._context())

        self.mocks["whats_new"].assert_called_once_with(
            self.mocks["AscClient"].return_value, "version-1", "What's New"
        )
        confirm.assert_not_called()
        self.mocks["submit"].assert_not_called()

    def test_submit_waits_for_the_demo_server_confirmation(self) -> None:
        with mock.patch.object(deploy.Context, "confirm", return_value=False):
            with self.assertRaises(deploy.PhaseDeferred):
                deploy.phase_asc(self._context(submit=True, yes=False))

        self.mocks["submit"].assert_not_called()

    def test_submit_after_confirmation(self) -> None:
        with mock.patch.object(deploy.Context, "confirm", return_value=True):
            deploy.phase_asc(self._context(submit=True))

        self.mocks["submit"].assert_called_once_with(
            self.mocks["AscClient"].return_value, "version-1"
        )


class SplitPhaseListsTest(unittest.TestCase):
    def test_splits_commas_and_repeats(self) -> None:
        self.assertEqual(
            deploy._split_phase_lists(["play,msstore", "ios"]),
            ["play", "msstore", "ios"],
        )

    def test_none_passthrough(self) -> None:
        self.assertIsNone(deploy._split_phase_lists(None))
        self.assertIsNone(deploy._split_phase_lists([]))


class CheckReleaseEnvTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.key = Path(self._tmp.name) / "key"
        self.key.write_text("{}", encoding="utf-8")

    def test_phases_that_are_not_pending_need_nothing(self) -> None:
        check_release_env({}, {"changelog", "bump", "release", "publish"})

    def test_play_needs_a_track(self) -> None:
        with self.assertRaisesRegex(DeployError, "PLAY_TRACK.*alpha.*production"):
            check_release_env({"PLAY_JSON_KEY_PATH": str(self.key)}, {"play"})

    def test_play_needs_the_key_file(self) -> None:
        env = {"PLAY_JSON_KEY_PATH": str(self.key) + ".missing", "PLAY_TRACK": "alpha"}
        with self.assertRaisesRegex(DeployError, "PLAY_JSON_KEY_PATH"):
            check_release_env(env, {"play"})
        check_release_env({"PLAY_JSON_KEY_PATH": str(self.key), "PLAY_TRACK": "alpha"}, {"play"})

    def test_app_store_needs_the_fastlane_api_key_names(self) -> None:
        for pending in ({"ios"}, {"asc"}):
            with self.subTest(pending=pending):
                with self.assertRaisesRegex(DeployError, "APP_STORE_CONNECT_API_KEY_ISSUER_ID"):
                    check_release_env(
                        {
                            "APP_STORE_CONNECT_API_KEY_KEY_ID": "KEY",
                            "APP_STORE_CONNECT_API_KEY_KEY_FILEPATH": str(self.key),
                        },
                        pending,
                    )

    def _msstore_env(self, **overrides) -> dict[str, str]:
        env = {
            "MSSTORE_TENANT_ID": "tenant",
            "MSSTORE_CLIENT_ID": "client",
            "MSSTORE_CLIENT_SECRET": "secret",
            "MSSTORE_APP_ID": "9P9DVTKZ3SB9",
            "MSSTORE_PRICE_ID": "Tier1052",
        }
        env.update(overrides)
        return env

    def test_msstore_needs_ompanions_product_and_a_price_tier(self) -> None:
        check_release_env(self._msstore_env(), {"msstore"})
        with self.assertRaisesRegex(DeployError, "9P9DVTKZ3SB9"):
            check_release_env(self._msstore_env(MSSTORE_APP_ID="9NBLGGH4R315"), {"msstore"})
        with self.assertRaisesRegex(DeployError, "MSSTORE_PRICE_ID"):
            check_release_env(self._msstore_env(MSSTORE_PRICE_ID=""), {"msstore"})
        with self.assertRaisesRegex(DeployError, "MSSTORE_PRICE_ID"):
            check_release_env(self._msstore_env(MSSTORE_PRICE_ID="Base"), {"msstore"})


class ResolveMsstorePricingTest(unittest.TestCase):
    def test_pins_the_configured_tier_and_drops_the_read_only_advanced_flag(self) -> None:
        submission = {
            "pricing": {
                "trialPeriod": "NoFreeTrial",
                "marketSpecificPricings": {"LB": "NotAvailable"},
                "sales": [],
                "priceId": "Base",
                "isAdvancedPricingModel": True,
            }
        }
        self.assertEqual(resolve_msstore_pricing(submission, "Tier1052"), "Tier1052")
        self.assertEqual(
            submission["pricing"],
            {
                "trialPeriod": "NoFreeTrial",
                "marketSpecificPricings": {"LB": "NotAvailable"},
                "sales": [],
                "priceId": "Tier1052",
            },
        )

    def test_refuses_every_price_id_but_a_tier(self) -> None:
        for price_id in ("Base", "Free", "", "1052"):
            submission = {"pricing": {"priceId": "Base", "isAdvancedPricingModel": True}}
            with self.subTest(price_id=price_id):
                with self.assertRaisesRegex(DeployError, "MSSTORE_PRICE_ID"):
                    resolve_msstore_pricing(submission, price_id)
                self.assertEqual(
                    submission["pricing"], {"priceId": "Base", "isAdvancedPricingModel": True}
                )

    def test_missing_pricing_never_submits_a_priceless_submission(self) -> None:
        submission: dict = {}
        resolve_msstore_pricing(submission, "Tier1052")
        self.assertEqual(submission["pricing"], {"priceId": "Tier1052"})


class MsstoreReleaseNotesTest(unittest.TestCase):
    def test_sets_whats_new_on_the_en_us_listing(self) -> None:
        submission = {
            "listings": {
                "en-us": {"baseListing": {"description": "ompanion", "releaseNotes": "old"}},
            }
        }
        set_msstore_release_notes(submission, "new")
        self.assertEqual(
            submission["listings"]["en-us"]["baseListing"],
            {"description": "ompanion", "releaseNotes": "new"},
        )

    def test_matches_the_language_case_insensitively(self) -> None:
        submission = {"listings": {"en-US": {"baseListing": {}}}}
        set_msstore_release_notes(submission, "new")
        self.assertEqual(submission["listings"]["en-US"]["baseListing"]["releaseNotes"], "new")

    def test_refuses_a_submission_without_an_en_us_listing(self) -> None:
        for submission in ({}, {"listings": {"de-de": {"baseListing": {}}}}):
            with self.subTest(submission=submission), self.assertRaises(DeployError):
                set_msstore_release_notes(submission, "new")


if __name__ == "__main__":
    unittest.main()
