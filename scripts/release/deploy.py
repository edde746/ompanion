#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "requests>=2.31",
#   "google-api-python-client>=2.100",
#   "google-auth>=2.23",
#   "PyJWT>=2.8",
#   "cryptography>=42",
# ]
# ///
"""ompanion store release pipeline, ported from Plezy's scripts/release/deploy.py.

One command releases to every channel:

    uv run scripts/release/deploy.py release --version 1.1.0

Phases (in order):
    preflight   check tools, credentials and git state
    changelog   write the per-store release notes: keep a file changed since the
                last release tag, generate the others from the raw notes with the
                claude CLI
    bump        set pubspec.yaml to <version>+<build>, commit it with the four
                notes files as `chore(release): <version>`, push main
    farm_start  run .github/workflows/build.yml with release_tag=<version>; its
                release job drafts the GitHub release once all five builds pass
    ios         flutter build ipa (appstore channel), upload the IPA to App Store
                Connect
    asc         wait for the build, set What's New, attach the build to the
                version (submit for review with --submit)
    farm_wait   wait for the build workflow, download the Play bundle and the
                Microsoft Store package it built
    play        upload the CI-built bundle through the Play Developer API and
                release it on PLAY_TRACK
    release     check the workflow's draft release and set its notes
    msstore     submit the msixbundle through the Microsoft Store Submission API
    publish     publish the draft and mark it latest: installed Mac apps update
                from the appcast on the latest release

State is checkpointed to build/deploy/state.json, next to the downloaded
artifacts; a failed run resumes where it stopped (`release` again, optionally
with --only/--skip). `--dry-run` prints every external action without
performing any.

Release notes are committed files, one per channel:
    store/release-notes/<version>.md        GitHub release body: the raw notes
                                            (--notes defaults to this file)
    android/fastlane/metadata/android/en-US/changelogs/<build>.txt
                                            Play, 500 characters
    ios/fastlane/metadata/en-US/release_notes.txt
                                            App Store What's New, 4000 characters
    store/microsoft/release_notes.txt       Microsoft Store What's new, 1500
                                            characters
The build number is pubspec.yaml's plus one unless --build-number is given.

Credentials come from .env at the repository root (gitignored; the fastlane
lanes read the same file):
    PLAY_JSON_KEY_PATH                       Play service-account JSON key file
    PLAY_TRACK                               Play track id to release on: the
                                             closed-testing track from Play
                                             Console (`alpha` for the default
                                             closed track), `production` once
                                             production access is granted
    APP_STORE_CONNECT_API_KEY_KEY_ID / _ISSUER_ID / _KEY_FILEPATH
                                             App Store Connect team API key (.p8)
    MSSTORE_TENANT_ID / MSSTORE_CLIENT_ID / MSSTORE_CLIENT_SECRET
                                             Azure AD app linked to Partner
                                             Center (the one Plezy uses: same
                                             account)
    MSSTORE_APP_ID                           9P9DVTKZ3SB9
    MSSTORE_PRICE_ID                         Store price tier every submission
                                             keeps (see the Store caveat)
GitHub auth comes from the `gh` CLI login. The IPA is signed by the Xcode
account's distribution certificate (team G88U5B5783, pinned in
ios/Runner.xcodeproj).

Play caveat: the bundle comes from the build workflow, not from this Mac. A
release run refuses to start without the four Android signing secrets, so the
bundle of a successful `Release <version>` run is signed with the upload key;
farm_wait downloads from no other run.

Microsoft Store caveat: the Submission API reports priceId "Base" for a price
set in Partner Center's current pricing UI and rejects it on PUT, and a
submission sent without a priceId publishes as free (Plezy 2.19.1 shipped at $0
that way). So MSSTORE_PRICE_ID is required, must be a TierNNNN id, and the
phase checks the tier the API stored before committing. Tier1012 to Tier1102 are
0.99 to 9.99 USD in steps of 0.10 USD (Microsoft's table in msstore-cli#175), so
ompanion's 4.99 USD is Tier1052. The Submission API also needs one submission of
the app completed in Partner Center first.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

DEPLOY_DIR = ROOT / "build" / "deploy"
STATE_PATH = DEPLOY_DIR / "state.json"
ARTIFACTS_DIR = DEPLOY_DIR / "artifacts"

REPO = "edde746/ompanion"
PLAY_PACKAGE = "com.edde746.ompanion"
APP_STORE_APP_ID = "6816667970"
MSSTORE_APP_ID = "9P9DVTKZ3SB9"

PHASES = [
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
]

# channel -> (claude platform description, hard character limit)
CHANNEL_SPECS = {
    "play": ("Android", 500),
    "appstore": ("iOS (iPhone and iPad)", 4000),
    "msstore": ("Windows", 1500),
}

ASC_API_BASE = "https://api.appstoreconnect.apple.com/v1"
MSSTORE_API_BASE = "https://manage.devcenter.microsoft.com/v1.0/my/applications"

ASC_KEY_ENV = [
    "APP_STORE_CONNECT_API_KEY_KEY_ID",
    "APP_STORE_CONNECT_API_KEY_ISSUER_ID",
    "APP_STORE_CONNECT_API_KEY_KEY_FILEPATH",
]
MSSTORE_ENV = [
    "MSSTORE_TENANT_ID",
    "MSSTORE_CLIENT_ID",
    "MSSTORE_CLIENT_SECRET",
    "MSSTORE_APP_ID",
    "MSSTORE_PRICE_ID",
]

# What build.yml's release job attaches to the draft: every file the run's
# builds upload except the two store bundles, seven in all.
RELEASE_ASSET_NAMES = frozenset(
    {
        "appcast.xml",
        "ompanion-android.apk",
        "ompanion-ios.ipa",
        "ompanion-macos.dmg",
        "ompanion-windows-x64.zip",
        "ompanion-linux-x64.zip",
        "ompanion-linux-x64.flatpak",
    }
)

# artifacts/<directory> -> (build.yml artifact name prefix, file inside it)
STORE_ARTIFACTS = {
    "android-aab": ("ompanion-android-aab", "ompanion-android.aab"),
    "windows-msix": ("ompanion-windows-msix", "ompanion-windows.msixbundle"),
}


class DeployError(Exception):
    """Fatal, user-actionable pipeline failure."""


class PhaseDeferred(Exception):
    """A phase intentionally left pending for a later resume."""


# ---------------------------------------------------------------------------
# Pure helpers (unit-tested in test_deploy.py)
# ---------------------------------------------------------------------------


def parse_env_text(text: str, base: dict[str, str] | None = None) -> dict[str, str]:
    """Parse .env content: KEY=VALUE lines, comments, quotes, ${VAR} expansion.

    Expansion resolves against earlier keys in the same file first, then
    ``base``. Unknown references expand to the empty string, matching shell
    behavior when sourcing the file.
    """
    base = base or {}
    values: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            quote = value[0]
            value = value[1:-1]
        else:
            quote = None
        if quote != "'":
            value = re.sub(
                r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}",
                lambda m: values.get(m.group(1), base.get(m.group(1), "")),
                value,
            )
        values[key] = value
    return values


_TOP_LEVEL_VERSION = re.compile(r"^version:[ \t]*(.*)$")
_PUBSPEC_VERSION = re.compile(
    r"(?P<version>"
    r"(?:0|[1-9][0-9]*)\."
    r"(?:0|[1-9][0-9]*)\."
    r"(?:0|[1-9][0-9]*)\+"
    r"(?P<build>[0-9]+)"
    r")"
)


def parse_pubspec_version(contents: str) -> tuple[str, str]:
    """The top-level `version: x.y.z+build` of a pubspec, and its build number."""
    values = []
    for line in contents.splitlines():
        match = _TOP_LEVEL_VERSION.match(line)
        if match:
            values.append(re.sub(r"[ \t]+#.*$", "", match.group(1)).strip())
    if len(values) != 1:
        raise DeployError(f"expected one top-level 'version:' field, found {len(values)}")
    match = _PUBSPEC_VERSION.fullmatch(values[0])
    if not match:
        raise DeployError(
            "top-level version must use major.minor.patch+numeric-build syntax; "
            f"got {values[0]!r}"
        )
    return match.group("version"), match.group("build")


def bump_pubspec_text(text: str, new_version: str, new_build: int) -> str:
    """Replace the single top-level version line, validating both sides."""
    parse_pubspec_version(text)  # raises on malformed/missing version
    replacement = f"version: {new_version}+{new_build}"
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    replaced = False
    for line in lines:
        if not replaced and re.match(r"^version:[ \t]", line):
            newline = "\n" if line.endswith("\n") else ""
            out.append(replacement + newline)
            replaced = True
        else:
            out.append(line)
    if not replaced:
        raise DeployError("pubspec.yaml has no top-level version line")
    result = "".join(out)
    parse_pubspec_version(result)
    return result


def release_files(version: str, build_number: int) -> dict[str, str]:
    """Each channel's committed release notes file, relative to the repository root."""
    return {
        "github": f"store/release-notes/{version}.md",
        "play": f"android/fastlane/metadata/android/en-US/changelogs/{build_number}.txt",
        "appstore": "ios/fastlane/metadata/en-US/release_notes.txt",
        "msstore": "store/microsoft/release_notes.txt",
    }


def _semver_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def previous_release_tag(tags: list[str], version: str) -> str | None:
    """The highest bare-semver tag below ``version``, or None for a first release."""
    target = _semver_key(version)
    earlier = [
        tag
        for tag in tags
        if re.fullmatch(r"\d+\.\d+\.\d+", tag) and _semver_key(tag) < target
    ]
    return max(earlier, key=_semver_key, default=None)


def channel_notes_problem(current: str | None, released: str | None, limit: int) -> str | None:
    """Why a channel's notes file must be regenerated, or None to keep it.

    ``current`` is the working-tree text (None: no file), ``released`` the text
    at the last release tag (None: the file is new since then).
    """
    if current is None:
        return "missing"
    text = current.strip()
    if not text:
        return "empty"
    if len(text) > limit:
        return f"{len(text)}/{limit} chars, over the limit"
    if released is not None and text == released.strip():
        return "unchanged since the last release"
    return None


def blocking_changes(porcelain: str, release_paths: set[str]) -> list[str]:
    """Tracked changes that would stay out of, or leak into, the release commit.

    The notes files are expected to be edited before a release; the bump phase
    commits them, so they never block it. Untracked files never do either.
    """
    return [
        line
        for line in porcelain.splitlines()
        if line and not line.startswith("??") and line[3:] not in release_paths
    ]


def store_artifact_names(head_sha: str) -> dict[str, str]:
    """build.yml's store artifact names for a run of ``head_sha``.

    The workflow suffixes ${GITHUB_SHA::7}, not git's --short abbreviation,
    which grows past seven characters once a prefix is ambiguous.
    """
    return {
        directory: f"{prefix}-{head_sha[:7]}"
        for directory, (prefix, _) in STORE_ARTIFACTS.items()
    }


def resolve_phases(only: list[str] | None, skip: list[str] | None) -> list[str]:
    """Select phases in canonical order; preflight rides along unless skipped."""
    only = only or []
    skip = skip or []
    for name in [*only, *skip]:
        if name not in PHASES:
            raise DeployError(f"unknown phase {name!r}; valid: {', '.join(PHASES)}")
    selected = []
    for phase in PHASES:
        if only and phase not in only and phase != "preflight":
            continue
        if phase in skip:
            continue
        selected.append(phase)
    return selected


def check_msstore_price_id(price_id: str) -> None:
    """Refuse every priceId but a real tier.

    The ingestion API echoes priceId "Base" for a base price set through
    Partner Center's current pricing UI, then rejects it on PUT ("'Base' is not
    a valid PriceId for base price"). Dropping priceId is worse: the PUT
    defaults the submission to Free, which is how Plezy 2.19.1 published at $0.
    "Free" itself would publish this paid app for nothing.
    """
    if not re.fullmatch(r"Tier\d+", price_id):
        raise DeployError(
            f"msstore: MSSTORE_PRICE_ID must be a price tier id such as Tier1052; got "
            f"{price_id!r}. Read the tier for 4.99 USD from Partner Center -> Pricing and "
            "availability -> view conversion table"
        )


def resolve_msstore_pricing(submission: dict, price_id: str) -> str:
    """Pin a cloned Store submission's base price to the configured tier.

    isAdvancedPricingModel is read-only; it describes which tier table the
    account has, not the price, and is dropped rather than echoed back.
    """
    check_msstore_price_id(price_id)
    pricing = submission.get("pricing")
    if not isinstance(pricing, dict):
        pricing = {}
        submission["pricing"] = pricing
    pricing.pop("isAdvancedPricingModel", None)
    pricing["priceId"] = price_id
    return price_id


def set_msstore_release_notes(submission: dict, text: str) -> None:
    """Put ``text`` in the en-us listing's What's new of a cloned submission."""
    listings = submission.get("listings")
    if isinstance(listings, dict):
        for language, listing in listings.items():
            if language.lower() == "en-us" and isinstance(listing.get("baseListing"), dict):
                listing["baseListing"]["releaseNotes"] = text
                return
    raise DeployError(
        "msstore: the cloned submission has no en-us listing to put the release notes in; "
        "check the Store listing in Partner Center"
    )


def check_release_env(env: dict[str, str], pending: set[str]) -> None:
    """Fail before anything runs when a pending phase lacks its credentials."""
    if "play" in pending:
        require_env(env, ["PLAY_JSON_KEY_PATH"], "play")
        if not env.get("PLAY_TRACK"):
            raise DeployError(
                "play: set PLAY_TRACK in .env to the track to release on: the closed-testing "
                "track id from Play Console (alpha for the default closed track), or "
                "production once production access is granted"
            )
        key_path = Path(env["PLAY_JSON_KEY_PATH"]).expanduser()
        if not key_path.is_file():
            raise DeployError(f"PLAY_JSON_KEY_PATH does not exist: {key_path}")
    if pending & {"ios", "asc"}:
        require_env(env, ASC_KEY_ENV, "app store connect")
        key_path = Path(env["APP_STORE_CONNECT_API_KEY_KEY_FILEPATH"]).expanduser()
        if not key_path.is_file():
            raise DeployError(f"APP_STORE_CONNECT_API_KEY_KEY_FILEPATH does not exist: {key_path}")
    if "msstore" in pending:
        require_env(env, MSSTORE_ENV, "msstore")
        if env["MSSTORE_APP_ID"] != MSSTORE_APP_ID:
            raise DeployError(
                f"msstore: MSSTORE_APP_ID must be {MSSTORE_APP_ID}; got {env['MSSTORE_APP_ID']!r}"
            )
        check_msstore_price_id(env["MSSTORE_PRICE_ID"])


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------


@dataclass
class State:
    version: str = ""
    build_number: int = 0
    done: list[str] = field(default_factory=list)
    data: dict = field(default_factory=dict)

    @classmethod
    def load(cls) -> "State | None":
        if not STATE_PATH.is_file():
            return None
        raw = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        return cls(
            version=raw.get("version", ""),
            build_number=raw.get("build_number", 0),
            done=raw.get("done", []),
            data=raw.get("data", {}),
        )

    def save(self) -> None:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        STATE_PATH.write_text(
            json.dumps(
                {
                    "version": self.version,
                    "build_number": self.build_number,
                    "done": self.done,
                    "data": self.data,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    def mark_done(self, phase: str) -> None:
        if phase not in self.done:
            self.done.append(phase)
        self.save()


@dataclass
class Context:
    args: argparse.Namespace
    env: dict[str, str]
    state: State
    phases: list[str]

    @property
    def dry_run(self) -> bool:
        return bool(self.args.dry_run)

    @property
    def version(self) -> str:
        return self.state.version

    @property
    def tag(self) -> str:
        return self.state.version

    @property
    def build_number(self) -> int:
        return self.state.build_number

    @property
    def files(self) -> dict[str, str]:
        return release_files(self.version, self.build_number)

    def confirm(self, prompt: str) -> bool:
        if self.args.yes:
            log(f"--yes: auto-confirming: {prompt}")
            return True
        if not sys.stdin.isatty():
            raise DeployError(
                f"interactive confirmation required ({prompt!r}) but stdin is not a "
                "TTY; rerun interactively or pass --yes"
            )
        answer = input(f"{prompt} [y/N] ").strip().lower()
        return answer in ("y", "yes")


# ---------------------------------------------------------------------------
# Process / logging helpers
# ---------------------------------------------------------------------------


def log(message: str) -> None:
    print(f"\033[1m==>\033[0m {message}", flush=True)


def run(
    cmd: list[str],
    *,
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
    check: bool = True,
    capture: bool = False,
    input_text: str | None = None,
    echo: bool = True,
) -> subprocess.CompletedProcess:
    if echo:
        print(f"    $ {shlex.join(cmd)}", flush=True)
    merged_env = {**os.environ, **(env or {})}
    result = subprocess.run(
        cmd,
        cwd=cwd,
        env=merged_env,
        input=input_text,
        capture_output=capture,
        text=True,
    )
    if check and result.returncode != 0:
        detail = ""
        if capture:
            detail = "\n" + (result.stderr or result.stdout or "").strip()
        raise DeployError(f"command failed ({result.returncode}): {shlex.join(cmd)}{detail}")
    return result


def dry_guard(ctx: Context, description: str) -> bool:
    """True when the action must be skipped because of --dry-run."""
    if ctx.dry_run:
        log(f"[dry-run] would {description}")
        return True
    return False


def require_env(env: dict[str, str], keys: list[str], purpose: str) -> None:
    missing = [k for k in keys if not env.get(k)]
    if missing:
        raise DeployError(f"{purpose}: missing environment values: {', '.join(missing)}")


def require_tool(name: str, hint: str = "") -> None:
    if shutil.which(name) is None:
        suffix = f" ({hint})" if hint else ""
        raise DeployError(f"required tool not found on PATH: {name}{suffix}")


def load_env_file() -> dict[str, str]:
    env_path = ROOT / ".env"
    if not env_path.is_file():
        raise DeployError(f".env not found at {env_path}")
    values = parse_env_text(env_path.read_text(encoding="utf-8"), dict(os.environ))
    # The checked release configuration is authoritative. Ambient variables can
    # otherwise invisibly retain stale credentials or tracks between runs.
    os.environ.update(values)
    return dict(os.environ)


def git_output(args: list[str]) -> str:
    return run(["git", *args], capture=True, echo=False).stdout.strip()


def read_pubspec_build() -> int:
    _, build = parse_pubspec_version((ROOT / "pubspec.yaml").read_text(encoding="utf-8"))
    return int(build)


# ---------------------------------------------------------------------------
# Phase: preflight
# ---------------------------------------------------------------------------


def phase_preflight(ctx: Context) -> None:
    # Requirements are checked only for phases that will actually run this
    # invocation; a resume after e.g. `bump` must not re-demand its inputs.
    pending = set(ctx.phases) - set(ctx.state.done)

    require_tool("git")
    branch = git_output(["branch", "--show-current"])
    if branch != "main":
        raise DeployError(f"releases run from main; current branch is {branch!r}")

    # Not git_output: stripping would eat the first line's leading status column.
    porcelain = run(["git", "status", "--porcelain"], capture=True, echo=False).stdout
    dirty = blocking_changes(porcelain, set(ctx.files.values()))
    if dirty and "bump" in pending and not ctx.dry_run:
        raise DeployError(
            "tracked files have uncommitted changes; commit or stash before releasing:\n  "
            + "\n  ".join(dirty)
        )

    if not re.fullmatch(r"\d+\.\d+\.\d+", ctx.version):
        raise DeployError(f"version must be semver (e.g. 1.1.0); got {ctx.version!r}")

    tag_exists = bool(git_output(["tag", "-l", ctx.tag]))
    if tag_exists and {"bump", "release"} <= pending:
        raise DeployError(
            f"tag {ctx.tag} already exists; pick a new version, or drop the "
            "release phase for a store-only push that reuses it"
        )

    if "ios" in pending:
        require_tool("flutter")
        require_tool("xcodebuild", "Xcode command line tools")
        require_tool("xcrun", "Xcode command line tools")
    if pending & {"farm_start", "farm_wait", "release", "publish"}:
        require_tool("gh", "GitHub CLI")
        run(["gh", "auth", "status"], capture=True, echo=False)
    if "changelog" in pending:
        if not ctx.dry_run:
            require_tool("claude", "used to generate per-channel changelogs")
        if not Path(ctx.args.notes).is_file():
            raise DeployError(
                f"notes file not found: {ctx.args.notes}; write the raw release notes there "
                "or pass --notes"
            )

    check_release_env(ctx.env, pending)
    log("preflight OK")


# ---------------------------------------------------------------------------
# Phase: changelog
# ---------------------------------------------------------------------------

CHANGELOG_PROMPT = (
    "Below is a changelog for a cross-platform Flutter app (iOS, Android, macOS, "
    "Linux, Windows). Return ONLY the entries relevant to the given platform. "
    "Keep the same format (section headers + bullet points). If a section has no "
    "relevant entries, omit it entirely. If an entry is not platform-specific, "
    "include it. You MUST stay under the character limit. Aggressively drop less "
    "important entries and consolidate similar ones to fit. Count your output "
    "characters before responding. Output nothing else."
)


def generate_channel_notes(notes_text: str, platform: str, limit: int) -> str:
    # Retries ask for progressively less than the real limit: models routinely
    # land a few characters over an exact target, so build in headroom.
    target = limit
    previous_length = 0
    for attempt in (1, 2, 3):
        prompt = f"{CHANGELOG_PROMPT} Platform: {platform}. Max {target} characters."
        if previous_length:
            prompt += (
                f" Your previous attempt was {previous_length} characters, which is "
                "OVER the limit. Cut aggressively; dropping entries is better than "
                "exceeding the limit."
            )
        result = run(
            ["claude", "--print", prompt],
            input_text=notes_text,
            capture=True,
            echo=False,
        )
        text = result.stdout.strip()
        if len(text) <= limit:
            return text
        previous_length = len(text)
        target = max(int(limit * 0.85), limit - 200)
        log(f"changelog for {platform!r} is {len(text)}/{limit} chars; retrying with target {target}")
    raise DeployError(
        f"changelog for {platform!r} still exceeds {limit} chars after retries; "
        "write the file by hand and rerun (a file changed since the last release is kept)"
    )


def _file_at_tag(tag: str, relpath: str) -> str | None:
    result = run(["git", "show", f"{tag}:{relpath}"], capture=True, check=False, echo=False)
    return result.stdout if result.returncode == 0 else None


def phase_changelog(ctx: Context) -> None:
    files = ctx.files
    raw = Path(ctx.args.notes)
    notes_text = raw.read_text(encoding="utf-8")

    github = ROOT / files["github"]
    if raw.resolve() != github.resolve() and not dry_guard(ctx, f"copy {raw} to {files['github']}"):
        github.parent.mkdir(parents=True, exist_ok=True)
        github.write_text(notes_text, encoding="utf-8")

    # Publishing a release creates its tag on GitHub, not in this clone.
    if not dry_guard(ctx, "fetch tags from origin"):
        run(["git", "fetch", "--tags", "origin"])
    tag = previous_release_tag(git_output(["tag", "-l"]).splitlines(), ctx.version)
    if tag:
        log(f"changelog: comparing the store notes with release {tag}")
    else:
        log("changelog: no earlier release tag; every existing notes file counts as new")

    for channel, (platform, limit) in CHANNEL_SPECS.items():
        relpath = files[channel]
        path = ROOT / relpath
        current = path.read_text(encoding="utf-8") if path.is_file() else None
        released = _file_at_tag(tag, relpath) if tag else None
        problem = channel_notes_problem(current, released, limit)
        if problem is None:
            log(f"changelog: keeping {relpath} ({len(current.strip())}/{limit} chars)")
            continue
        if dry_guard(ctx, f"generate {relpath} ({problem}) from {raw} via claude"):
            continue
        text = generate_channel_notes(notes_text, platform, limit)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text + "\n", encoding="utf-8")
        log(f"changelog: wrote {relpath} ({problem}; now {len(text)}/{limit} chars)")


# ---------------------------------------------------------------------------
# Phase: bump
# ---------------------------------------------------------------------------


def phase_bump(ctx: Context) -> None:
    """Bump pubspec, commit it with the notes files, and push main.

    The build workflow drafts the release only after every platform build
    succeeds; publishing the draft creates the tag. Store-only pushes can reuse
    an existing tag by omitting the farm and GitHub release phases.
    """
    pubspec = ROOT / "pubspec.yaml"
    text = pubspec.read_text(encoding="utf-8")
    current_full, _ = parse_pubspec_version(text)
    target_full = f"{ctx.version}+{ctx.build_number}"
    paths = ["pubspec.yaml", *ctx.files.values()]
    message = f"chore(release): {ctx.version}"
    if dry_guard(
        ctx,
        f"bump pubspec {current_full} -> {target_full}, commit {', '.join(paths)} as "
        f"{message!r}, push main",
    ):
        return
    if current_full == target_full:
        log(f"bump: pubspec already at {target_full}")
    else:
        pubspec.write_text(bump_pubspec_text(text, ctx.version, ctx.build_number), encoding="utf-8")
    # A pathspec commit takes only these paths and never sweeps in unrelated
    # staged work; new notes files must be added first or the pathspec misses.
    run(["git", "add", "--", *paths])
    if git_output(["diff", "--cached", "--name-only", "--", *paths]):
        run(["git", "commit", "-m", message, "--", *paths])
    else:
        log("bump: pubspec and notes already committed")
    run(["git", "push", "origin", "main"])
    ctx.state.data["release_sha"] = git_output(["rev-parse", "HEAD"])
    ctx.state.save()


# ---------------------------------------------------------------------------
# Phases: farm_start / farm_wait (GitHub Actions build farm)
# ---------------------------------------------------------------------------


def phase_farm_start(ctx: Context) -> None:
    if dry_guard(ctx, f"run build.yml on main with release_tag={ctx.tag} and record the run id"):
        return
    head = ctx.state.data.get("release_sha") or git_output(["rev-parse", "HEAD"])
    dispatch = ctx.state.data.get("farm_dispatch")
    if isinstance(dispatch, dict) and dispatch.get("headSha") == head:
        previous_ids = set(dispatch.get("previousRunIds", []))
        log("farm: resuming run discovery after an interrupted dispatch")
    else:
        previous = run(
            [
                "gh",
                "run",
                "list",
                "--workflow",
                "build.yml",
                "--branch",
                "main",
                "--limit",
                "20",
                "--json",
                "databaseId",
            ],
            capture=True,
            echo=False,
        )
        previous_ids = {
            entry["databaseId"] for entry in json.loads(previous.stdout or "[]")
        }
        ctx.state.data["farm_dispatch"] = {
            "headSha": head,
            "previousRunIds": sorted(previous_ids),
        }
        ctx.state.save()
        run(
            [
                "gh",
                "workflow",
                "run",
                "build.yml",
                "--ref",
                "main",
                "--field",
                f"release_tag={ctx.tag}",
            ]
        )
    log("farm: waiting for the workflow run to appear")
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        time.sleep(10)
        result = run(
            [
                "gh",
                "run",
                "list",
                "--workflow",
                "build.yml",
                "--branch",
                "main",
                "--limit",
                "20",
                "--json",
                "databaseId,displayTitle,headSha,status,createdAt",
            ],
            capture=True,
            echo=False,
        )
        runs = json.loads(result.stdout or "[]")
        for entry in runs:
            if (
                entry["databaseId"] not in previous_ids
                and entry["headSha"] == head
                and entry.get("displayTitle") == f"Release {ctx.tag}"
            ):
                ctx.state.data["farm_run_id"] = entry["databaseId"]
                ctx.state.data.pop("farm_dispatch", None)
                ctx.state.save()
                log(f"farm: run {entry['databaseId']} started")
                return
    ctx.state.data.pop("farm_dispatch", None)
    ctx.state.save()
    raise DeployError(
        "farm: build.yml run did not appear within 3 minutes; "
        "dispatch marker cleared, so rerunning farm_start is safe"
    )


def phase_farm_wait(ctx: Context) -> None:
    if dry_guard(
        ctx,
        "wait for build.yml, download the Play bundle and the Microsoft Store package to "
        f"{ARTIFACTS_DIR}",
    ):
        return
    run_id = ctx.state.data.get("farm_run_id")
    if not run_id:
        raise DeployError("farm_wait: no farm_run_id in state; run farm_start first")
    log(f"farm: waiting for run {run_id} (this takes a while)")
    while True:
        result = run(
            [
                "gh",
                "run",
                "view",
                str(run_id),
                "--json",
                "status,conclusion,displayTitle,headSha",
            ],
            capture=True,
            echo=False,
        )
        info = json.loads(result.stdout)
        # Only a release run's "Check the release" demands all four Android
        # signing secrets; any other run may build a debug-signed bundle.
        if info.get("displayTitle") != f"Release {ctx.tag}":
            raise DeployError(
                f"farm: run {run_id} is {info.get('displayTitle')!r}, not 'Release {ctx.tag}'; "
                "its Play bundle may be debug-signed"
            )
        if info["status"] == "completed":
            if info["conclusion"] != "success":
                raise DeployError(
                    f"farm: run {run_id} concluded {info['conclusion']!r}; "
                    f"see https://github.com/{REPO}/actions/runs/{run_id}"
                )
            break
        time.sleep(30)
    if ARTIFACTS_DIR.exists():
        shutil.rmtree(ARTIFACTS_DIR)
    for directory, artifact in store_artifact_names(info["headSha"]).items():
        target = ARTIFACTS_DIR / directory
        target.mkdir(parents=True)
        run(["gh", "run", "download", str(run_id), "--name", artifact, "--dir", str(target)])
    log(f"farm: the draft release holds the build; store packages downloaded to {ARTIFACTS_DIR}")


def store_artifact_path(directory: str) -> Path:
    return ARTIFACTS_DIR / directory / STORE_ARTIFACTS[directory][1]


# ---------------------------------------------------------------------------
# Phase: play
# ---------------------------------------------------------------------------


def _execute_google_request(request):
    return request.execute(num_retries=5)


def _execute_resumable_google_upload(request, label: str):
    # next_chunk retries HTTP status failures but raises on a dropped connection.
    # Calling it again after a raise asks the server how much it holds and
    # resumes there, or returns the finished resource when the last chunk
    # landed before the response was lost (Play closed the socket that way
    # after accepting Plezy's 2.21.0 bundle).
    response = None
    transport_failures = 0
    while response is None:
        try:
            status, response = request.next_chunk(num_retries=5)
        except (ConnectionError, TimeoutError) as error:
            transport_failures += 1
            if transport_failures > 5:
                raise
            log(f"{label}: upload connection lost ({error!r}); resuming")
            time.sleep(2**transport_failures)
            continue
        if status:
            log(f"{label}: upload {status.progress():.0%}")
    return response


def _play_publisher(ctx: Context):
    from google.oauth2 import service_account  # noqa: PLC0415
    from googleapiclient.discovery import build as gapi_build  # noqa: PLC0415

    info = json.loads(
        Path(ctx.env["PLAY_JSON_KEY_PATH"]).expanduser().read_text(encoding="utf-8")
    )
    credentials = service_account.Credentials.from_service_account_info(
        info, scopes=["https://www.googleapis.com/auth/androidpublisher"]
    )
    # build_http() takes its read timeout from the socket default, else 60 s, and
    # Play processes a large bundle for longer than that after the last chunk:
    # the upload is accepted but the response read times out and the edit is lost.
    previous_timeout = socket.getdefaulttimeout()
    socket.setdefaulttimeout(1800)
    try:
        return gapi_build(
            "androidpublisher", "v3", credentials=credentials, cache_discovery=False
        )
    finally:
        socket.setdefaulttimeout(previous_timeout)


def _play_pending_edit(ctx: Context, edits) -> str | None:
    """The recorded edit id when it is still open and already holds this build."""
    from googleapiclient.errors import HttpError  # noqa: PLC0415

    edit_id = ctx.state.data.get("play_pending_edit_id")
    if not edit_id:
        return None
    try:
        _execute_google_request(edits.get(packageName=PLAY_PACKAGE, editId=edit_id))
        bundles = _execute_google_request(
            edits.bundles().list(packageName=PLAY_PACKAGE, editId=edit_id)
        ).get("bundles", [])
    except HttpError as error:
        log(f"play: recorded edit {edit_id} is gone ({error.status_code}); starting over")
        bundles = None
    if bundles is not None and any(b.get("versionCode") == ctx.build_number for b in bundles):
        return str(edit_id)
    if bundles is not None:
        log(f"play: recorded edit {edit_id} holds no versionCode {ctx.build_number}; starting over")
    ctx.state.data.pop("play_pending_edit_id", None)
    ctx.state.save()
    return None


def phase_play(ctx: Context) -> None:
    track = ctx.env.get("PLAY_TRACK", "")
    aab = store_artifact_path("android-aab")
    notes = ctx.files["play"]
    if dry_guard(
        ctx,
        f"upload {aab} to Play ({PLAY_PACKAGE}) and release versionCode {ctx.build_number} "
        f"on the {track!r} track as completed, notes from {notes}",
    ):
        return

    from googleapiclient.errors import HttpError  # noqa: PLC0415
    from googleapiclient.http import MediaFileUpload  # noqa: PLC0415

    edits = _play_publisher(ctx).edits()
    edit_id = _play_pending_edit(ctx, edits)
    if edit_id:
        log(f"play: resuming edit {edit_id}, which already holds versionCode {ctx.build_number}")
        version_code = ctx.build_number
    else:
        if not aab.is_file():
            raise DeployError(f"play: bundle not found at {aab}; run farm_wait first")
        edit_id = _execute_google_request(edits.insert(packageName=PLAY_PACKAGE, body={}))["id"]
        log(f"play: created edit {edit_id}")
        # Recorded before the upload so a run that dies after Play accepted the
        # bundle resumes this edit instead of re-uploading.
        ctx.state.data["play_pending_edit_id"] = edit_id
        ctx.state.save()
        upload = edits.bundles().upload(
            packageName=PLAY_PACKAGE,
            editId=edit_id,
            media_body=MediaFileUpload(
                str(aab),
                mimetype="application/octet-stream",
                chunksize=10 * 1024 * 1024,
                resumable=True,
            ),
        )
        uploaded = _execute_resumable_google_upload(upload, "play")
        version_code = uploaded["versionCode"]
        if version_code != ctx.build_number:
            raise DeployError(
                f"play: uploaded versionCode {version_code} != expected {ctx.build_number}"
            )
    release_notes = (ROOT / notes).read_text(encoding="utf-8").strip()
    _execute_google_request(
        edits.tracks().update(
            packageName=PLAY_PACKAGE,
            editId=edit_id,
            track=track,
            body={
                "releases": [
                    {
                        "name": ctx.version,
                        "versionCodes": [str(version_code)],
                        "status": "completed",
                        "releaseNotes": [{"language": "en-US", "text": release_notes}],
                    }
                ]
            },
        )
    )

    def requires_manual_review_send(error: Exception) -> bool:
        return "changesNotSentForReview" in str(error)

    try:
        _execute_google_request(edits.validate(packageName=PLAY_PACKAGE, editId=edit_id))
    except HttpError as error:
        if not requires_manual_review_send(error):
            raise
        log("play: validate blocked; this app state requires a manual review send")
    try:
        _execute_google_request(edits.commit(packageName=PLAY_PACKAGE, editId=edit_id))
        log(f"play: committed versionCode {version_code} on {track!r} (sent for review)")
    except HttpError as error:
        if not requires_manual_review_send(error):
            raise
        _execute_google_request(
            edits.commit(
                packageName=PLAY_PACKAGE,
                editId=edit_id,
                changesNotSentForReview=True,
            )
        )
        log(
            f"play: committed versionCode {version_code} on {track!r} WITHOUT sending "
            "for review (Play refused automatic submission for this app's current "
            "state); open the Play Console and press 'Send for review'"
        )
    ctx.state.data.pop("play_pending_edit_id", None)
    ctx.state.save()


# ---------------------------------------------------------------------------
# Phase: ios (build + upload to App Store Connect)
# ---------------------------------------------------------------------------


IPA_DIR = ROOT / "build/ios/ipa"


def _find_single_ipa(directory: Path, label: str) -> Path:
    ipas = sorted(directory.rglob("*.ipa")) if directory.is_dir() else []
    if len(ipas) != 1:
        raise DeployError(f"{label}: expected one exported IPA in {directory}, found {len(ipas)}")
    return ipas[0]


def ipa_version(ipa: Path) -> tuple[str, str]:
    """CFBundleShortVersionString and CFBundleVersion of the app inside an IPA."""
    import plistlib  # noqa: PLC0415

    with zipfile.ZipFile(ipa) as archive:
        names = [n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(names) != 1:
            raise DeployError(f"ios: {ipa} holds {len(names)} app Info.plist files, not one")
        info = plistlib.loads(archive.read(names[0]))
    return str(info.get("CFBundleShortVersionString", "")), str(info.get("CFBundleVersion", ""))


def _upload_ipa(ctx: Context, ipa: Path) -> None:
    if not ipa.is_file():
        raise DeployError(f"ios: IPA not found at {ipa}")
    run(
        [
            "xcrun",
            "altool",
            "--upload-app",
            "--type",
            "ios",
            "-f",
            str(ipa),
            "--apiKey",
            ctx.env["APP_STORE_CONNECT_API_KEY_KEY_ID"],
            "--apiIssuer",
            ctx.env["APP_STORE_CONNECT_API_KEY_ISSUER_ID"],
            # The .env key path is fastlane's; without it altool only searches
            # its private_keys directories for AuthKey_<id>.p8.
            "--p8-file-path",
            str(Path(ctx.env["APP_STORE_CONNECT_API_KEY_KEY_FILEPATH"]).expanduser()),
        ]
    )
    log(f"ios: uploaded {ipa.name} to App Store Connect")


def phase_ios(ctx: Context) -> None:
    if dry_guard(
        ctx,
        "flutter build ipa --release --dart-define=OMPANION_CHANNEL=appstore, upload the "
        "IPA to App Store Connect",
    ):
        return
    if _asc_has_uploaded_build(ctx):
        log(f"ios: App Store Connect already has build {ctx.build_number}; skipping upload")
        return
    # flutter build ipa exits 0 when only the export fails (no Xcode account to sign with) and leaves the last
    # export in build/ios/ipa: 1.1.0's first run uploaded 1.0.0's IPA that way. So the old export goes first, and
    # the new one must carry this release's version and build number.
    if IPA_DIR.exists():
        shutil.rmtree(IPA_DIR)
    run(["flutter", "build", "ipa", "--release", "--dart-define=OMPANION_CHANNEL=appstore"])
    if not IPA_DIR.is_dir() or not any(IPA_DIR.rglob("*.ipa")):
        raise DeployError(
            "ios: flutter build ipa exported no IPA (its errors are above). It signs through the Apple ID signed in "
            "to Xcode (Settings -> Accounts) with team G88U5B5783's cloud-managed distribution certificate"
        )
    ipa = _find_single_ipa(IPA_DIR, "ios")
    expected = (ctx.version, str(ctx.build_number))
    if ipa_version(ipa) != expected:
        raise DeployError(f"ios: {ipa} is {'+'.join(ipa_version(ipa))}, not {'+'.join(expected)}")
    _upload_ipa(ctx, ipa)


# ---------------------------------------------------------------------------
# Phase: asc (App Store Connect metadata)
# ---------------------------------------------------------------------------


class AscClient:
    def __init__(self, env: dict[str, str]):
        self.env = env
        self._token = ""
        self._token_expiry = 0.0

    def token(self) -> str:
        import jwt  # noqa: PLC0415

        now = time.time()
        if not self._token or now > self._token_expiry - 60:
            key = (
                Path(self.env["APP_STORE_CONNECT_API_KEY_KEY_FILEPATH"])
                .expanduser()
                .read_text(encoding="utf-8")
            )
            self._token_expiry = now + 1200
            self._token = jwt.encode(
                {
                    "iss": self.env["APP_STORE_CONNECT_API_KEY_ISSUER_ID"],
                    "iat": int(now) - 30,
                    "exp": int(self._token_expiry),
                    "aud": "appstoreconnect-v1",
                },
                key,
                algorithm="ES256",
                headers={"kid": self.env["APP_STORE_CONNECT_API_KEY_KEY_ID"]},
            )
        return self._token

    def request(self, method: str, path: str, **kwargs):
        import requests  # noqa: PLC0415

        response = requests.request(
            method,
            f"{ASC_API_BASE}{path}",
            headers={"Authorization": f"Bearer {self.token()}"},
            timeout=120,
            **kwargs,
        )
        if response.status_code >= 400:
            raise DeployError(
                f"asc: {method} {path} failed ({response.status_code}): {response.text[:800]}"
            )
        return response


def _asc_builds_path(build_number: int) -> str:
    return (
        f"/builds?filter[app]={APP_STORE_APP_ID}&filter[version]={build_number}"
        "&filter[preReleaseVersion.platform]=IOS&sort=-uploadedDate&limit=1"
    )


def _asc_has_uploaded_build(ctx: Context) -> bool:
    client = AscClient(ctx.env)
    return bool(client.request("GET", _asc_builds_path(ctx.build_number)).json()["data"])


def _asc_wait_for_build(client: AscClient, build_number: int) -> str:
    log(f"asc: waiting for iOS build {build_number} to finish processing")
    deadline = time.monotonic() + 45 * 60
    while time.monotonic() < deadline:
        data = client.request("GET", _asc_builds_path(build_number)).json()["data"]
        if data:
            state = data[0]["attributes"]["processingState"]
            if state == "VALID":
                return data[0]["id"]
            if state in ("FAILED", "INVALID"):
                raise DeployError(f"asc: iOS build {build_number} processing state {state}")
        time.sleep(30)
    raise DeployError(f"asc: timed out waiting for iOS build {build_number}")


def _asc_ensure_version(client: AscClient, version: str) -> str:
    data = client.request(
        "GET",
        f"/apps/{APP_STORE_APP_ID}/appStoreVersions?filter[versionString]={version}"
        "&filter[platform]=IOS&limit=1",
    ).json()["data"]
    if data:
        return data[0]["id"]
    created = client.request(
        "POST",
        "/appStoreVersions",
        json={
            "data": {
                "type": "appStoreVersions",
                "attributes": {"platform": "IOS", "versionString": version},
                "relationships": {"app": {"data": {"type": "apps", "id": APP_STORE_APP_ID}}},
            }
        },
    ).json()["data"]
    log(f"asc: created iOS version {version}")
    return created["id"]


def _asc_set_whats_new(client: AscClient, version_id: str, whats_new: str) -> None:
    localizations = client.request(
        "GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=50"
    ).json()["data"]
    targets = [l for l in localizations if l["attributes"]["locale"] == "en-US"] or localizations
    if not targets:
        raise DeployError("asc: version has no localizations; create one in ASC first")
    for localization in targets:
        client.request(
            "PATCH",
            f"/appStoreVersionLocalizations/{localization['id']}",
            json={
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": localization["id"],
                    "attributes": {"whatsNew": whats_new},
                }
            },
        )


def _asc_submit_for_review(client: AscClient, version_id: str) -> None:
    submission = client.request(
        "POST",
        "/reviewSubmissions",
        json={
            "data": {
                "type": "reviewSubmissions",
                "attributes": {"platform": "IOS"},
                "relationships": {"app": {"data": {"type": "apps", "id": APP_STORE_APP_ID}}},
            }
        },
    ).json()["data"]
    client.request(
        "POST",
        "/reviewSubmissionItems",
        json={
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {
                        "data": {"type": "reviewSubmissions", "id": submission["id"]}
                    },
                    "appStoreVersion": {
                        "data": {"type": "appStoreVersions", "id": version_id}
                    },
                },
            }
        },
    )
    client.request(
        "PATCH",
        f"/reviewSubmissions/{submission['id']}",
        json={
            "data": {
                "type": "reviewSubmissions",
                "id": submission["id"],
                "attributes": {"submitted": True},
            }
        },
    )
    log("asc: iOS version submitted for review")


def phase_asc(ctx: Context) -> None:
    if "ios" not in set(ctx.phases) | set(ctx.state.done):
        log("asc: the ios phase is not selected; nothing to do")
        return
    notes = ctx.files["appstore"]
    action = f"wait for iOS build {ctx.build_number}, set What's New from {notes}, attach the build"
    if ctx.args.submit:
        action += ", confirm the review demo server is reset and verified, submit for review"
    if dry_guard(ctx, action):
        return

    whats_new = (ROOT / notes).read_text(encoding="utf-8").strip()
    client = AscClient(ctx.env)
    build_id = _asc_wait_for_build(client, ctx.build_number)
    version_id = _asc_ensure_version(client, ctx.version)
    _asc_set_whats_new(client, version_id, whats_new)
    client.request(
        "PATCH",
        f"/appStoreVersions/{version_id}/relationships/build",
        json={"data": {"type": "builds", "id": build_id}},
    )
    log(f"asc: iOS version {ctx.version} ready with build {ctx.build_number} attached")
    if not ctx.args.submit:
        log("asc: not submitted (pass --submit to submit for review)")
        return
    print(
        "\n  App Review signs in to the demo server for the whole review window\n"
        "  (store/README.md, App Store step 11). Before submitting:\n"
        "    ssh root@217.160.119.181 ompanion-demo-reset\n"
        "    dart run store/review-demo/verify/verify.dart --host 217.160.119.181\n"
        "  (with REVIEW_PASSWORD from store/review-demo/.env; store/review-demo/README.md,\n"
        "  Commands), and check that the OpenRouter key has credit left.\n"
    )
    if not ctx.confirm("Demo server reset and verified? Submit for review now?"):
        log("asc: not submitted; rerun `release --submit` once the demo server is ready")
        raise PhaseDeferred
    _asc_submit_for_review(client, version_id)


# ---------------------------------------------------------------------------
# Phase: release (GitHub)
# ---------------------------------------------------------------------------


def phase_release(ctx: Context) -> None:
    body = ctx.files["github"]
    if dry_guard(ctx, f"check draft release {ctx.tag}'s assets and set its notes from {body}"):
        return
    result = run(
        [
            "gh",
            "release",
            "view",
            ctx.tag,
            "--json",
            "isDraft,targetCommitish,assets",
        ],
        capture=True,
        check=False,
        echo=False,
    )
    if result.returncode != 0:
        raise DeployError(
            f"release: build workflow did not create draft {ctx.tag}; "
            f"inspect run {ctx.state.data.get('farm_run_id', 'unknown')}"
        )
    info = json.loads(result.stdout)
    if not info.get("isDraft"):
        raise DeployError(f"release: {ctx.tag} exists but is not a draft")

    expected_sha = ctx.state.data.get("release_sha")
    if expected_sha and info.get("targetCommitish") != expected_sha:
        raise DeployError(
            f"release: {ctx.tag} targets {info.get('targetCommitish')}, expected {expected_sha}"
        )

    actual_assets = {asset["name"] for asset in info.get("assets", [])}
    if actual_assets != RELEASE_ASSET_NAMES:
        missing = sorted(RELEASE_ASSET_NAMES - actual_assets)
        unexpected = sorted(actual_assets - RELEASE_ASSET_NAMES)
        details = []
        if missing:
            details.append("missing: " + ", ".join(missing))
        if unexpected:
            details.append("unexpected: " + ", ".join(unexpected))
        raise DeployError("release: draft asset set is invalid (" + "; ".join(details) + ")")

    if not (ROOT / body).is_file():
        raise DeployError(f"release: notes not found at {body}")
    run(
        [
            "gh",
            "release",
            "edit",
            ctx.tag,
            "--title",
            ctx.version,
            "--notes-file",
            str(ROOT / body),
        ]
    )
    log(f"release: verified draft {ctx.tag} with {len(actual_assets)} assets")


# ---------------------------------------------------------------------------
# Phase: msstore
# ---------------------------------------------------------------------------

MSSTORE_TERMINAL_OK = {"PreProcessing", "Certification", "Publishing", "Published", "Release"}


def _msstore_token(env: dict[str, str]) -> str:
    import requests  # noqa: PLC0415

    response = requests.post(
        f"https://login.microsoftonline.com/{env['MSSTORE_TENANT_ID']}/oauth2/token",
        data={
            "grant_type": "client_credentials",
            "client_id": env["MSSTORE_CLIENT_ID"],
            "client_secret": env["MSSTORE_CLIENT_SECRET"],
            "resource": "https://manage.devcenter.microsoft.com",
        },
        timeout=60,
    )
    if response.status_code != 200:
        raise DeployError(f"msstore: token request failed ({response.status_code})")
    return response.json()["access_token"]


def phase_msstore(ctx: Context) -> None:
    bundle = store_artifact_path("windows-msix")
    notes = ctx.files["msstore"]
    if dry_guard(
        ctx,
        f"create a Store submission for {ctx.env.get('MSSTORE_APP_ID')}, replace its package "
        f"with {bundle}, set What's new from {notes}, pin the price to "
        f"{ctx.env.get('MSSTORE_PRICE_ID')}, commit it",
    ):
        return
    if not bundle.is_file():
        raise DeployError(f"msstore: msixbundle not found at {bundle}; run farm_wait first")
    release_notes = (ROOT / notes).read_text(encoding="utf-8").strip()

    import requests  # noqa: PLC0415

    app_id = ctx.env["MSSTORE_APP_ID"]
    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {_msstore_token(ctx.env)}"
    base = f"{MSSTORE_API_BASE}/{app_id}"

    def api(method: str, path: str = "", **kwargs):
        response = session.request(method, f"{base}{path}", timeout=300, **kwargs)
        if response.status_code >= 400:
            raise DeployError(
                f"msstore: {method} {path or '/'} failed ({response.status_code}): "
                f"{response.text[:800]}"
            )
        return response

    app = api("GET").json()
    pending = app.get("pendingApplicationSubmission")
    if pending:
        if not ctx.args.msstore_replace_pending:
            raise DeployError(
                f"msstore: a pending submission exists ({pending['id']}); inspect it in "
                "Partner Center, or rerun with --msstore-replace-pending to delete it"
            )
        api("DELETE", f"/submissions/{pending['id']}")
        log(f"msstore: deleted pending submission {pending['id']}")

    submission = api("POST", "/submissions").json()
    submission_id = submission["id"]
    log(f"msstore: created submission {submission_id} (cloned from last published)")

    if not isinstance(submission.get("applicationPackages"), list):
        submission["applicationPackages"] = []
    for package in submission["applicationPackages"]:
        package["fileStatus"] = "PendingDelete"
    submission["applicationPackages"].append(
        {
            "fileName": bundle.name,
            "fileStatus": "PendingUpload",
            "minimumDirectXVersion": "None",
            "minimumSystemRam": "None",
        }
    )
    try:
        set_msstore_release_notes(submission, release_notes)
        price_id = resolve_msstore_pricing(submission, ctx.env["MSSTORE_PRICE_ID"])
    except DeployError:
        api("DELETE", f"/submissions/{submission_id}")
        log(f"msstore: deleted submission {submission_id}; nothing was uploaded")
        raise
    log(f"msstore: base price pinned to {price_id}")

    upload_zip = DEPLOY_DIR / "msstore-upload.zip"
    with zipfile.ZipFile(upload_zip, "w", zipfile.ZIP_STORED) as archive:
        archive.write(bundle, bundle.name)
    log(f"msstore: uploading {upload_zip.stat().st_size / 1e6:.0f} MB package zip")
    with upload_zip.open("rb") as handle:
        blob = requests.put(
            submission["fileUploadUrl"].replace("+", "%2B"),
            data=handle,
            headers={"x-ms-blob-type": "BlockBlob"},
            timeout=3600,
        )
    if blob.status_code >= 400:
        raise DeployError(f"msstore: blob upload failed ({blob.status_code})")

    updated = api("PUT", f"/submissions/{submission_id}", json=submission).json()
    stored_price_id = (updated.get("pricing") or {}).get("priceId")
    if stored_price_id != price_id:
        api("DELETE", f"/submissions/{submission_id}")
        raise DeployError(
            f"msstore: the API stored priceId {stored_price_id!r} instead of "
            f"{price_id!r}; deleted submission {submission_id} instead of "
            "committing a price change"
        )
    api("POST", f"/submissions/{submission_id}/commit")
    log("msstore: committed; polling status")

    deadline = time.monotonic() + 30 * 60
    while time.monotonic() < deadline:
        status = api("GET", f"/submissions/{submission_id}/status").json()
        current = status.get("status", "")
        if current == "CommitFailed":
            raise DeployError(
                "msstore: commit failed: "
                + json.dumps(status.get("statusDetails", {}), indent=2)[:1500]
            )
        if current in MSSTORE_TERMINAL_OK:
            log(f"msstore: submission {submission_id} accepted (status: {current})")
            ctx.state.data["msstore_submission_id"] = submission_id
            ctx.state.save()
            return
        time.sleep(30)
    raise DeployError("msstore: timed out waiting for the submission to leave commit")


# ---------------------------------------------------------------------------
# Phase: publish
# ---------------------------------------------------------------------------


def phase_publish(ctx: Context) -> None:
    if dry_guard(ctx, f"publish GitHub release {ctx.tag} and mark it latest"):
        return
    if not ctx.confirm(
        f"Publish GitHub release {ctx.tag}? It becomes the latest release, so installed "
        "Mac apps update from its appcast."
    ):
        log("publish: skipped; rerun with --only publish when ready")
        raise PhaseDeferred

    run(["gh", "release", "edit", ctx.tag, "--draft=false", "--latest"])
    log(f"publish: release {ctx.tag} is live and latest")


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

PHASE_LINKS = {
    "ios": "https://appstoreconnect.apple.com/apps",
    "asc": "https://appstoreconnect.apple.com/apps",
    "play": "https://play.google.com/console",
    "msstore": "https://partner.microsoft.com/dashboard",
    "release": f"https://github.com/{REPO}/releases",
    "publish": f"https://github.com/{REPO}/releases",
}


def print_summary(ctx: Context) -> None:
    print(f"\nRelease {ctx.version}+{ctx.build_number} summary")
    for phase in PHASES:
        if phase == "preflight":
            continue
        if phase not in ctx.phases:
            status = "skipped"
        elif phase in ctx.state.done:
            status = "done"
        else:
            status = "PENDING"
        link = PHASE_LINKS.get(phase, "")
        print(f"  {phase:<12} {status:<8} {link}")
    print()


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

PHASE_FUNCTIONS = {
    "preflight": phase_preflight,
    "changelog": phase_changelog,
    "bump": phase_bump,
    "farm_start": phase_farm_start,
    "ios": phase_ios,
    "asc": phase_asc,
    "farm_wait": phase_farm_wait,
    "play": phase_play,
    "release": phase_release,
    "msstore": phase_msstore,
    "publish": phase_publish,
}


def initialize_state(args: argparse.Namespace) -> State:
    if args.fresh:
        state = None
        if DEPLOY_DIR.exists() and not getattr(args, "dry_run", False):
            shutil.rmtree(DEPLOY_DIR)
    else:
        state = State.load()
    if state:
        if args.version and args.version != state.version:
            raise DeployError(
                f"state at {STATE_PATH} is for {state.version}; finish it, or pass "
                "--fresh to discard it"
            )
        if args.build_number and args.build_number != state.build_number:
            raise DeployError(
                f"state at {STATE_PATH} is for build {state.build_number}; pass "
                "--fresh to discard it"
            )
        log(f"resuming release {state.version}+{state.build_number} "
            f"(done: {', '.join(state.done) or 'nothing'})")
        return state
    if not args.version:
        raise DeployError("--version is required for a new release")
    build_number = args.build_number or read_pubspec_build() + 1
    state = State(version=args.version, build_number=build_number)
    if not getattr(args, "dry_run", False):
        state.save()
    return state


def cmd_release(args: argparse.Namespace) -> int:
    env = load_env_file()
    state = initialize_state(args)
    # The release plan (phase selection + notes source) persists in state so a
    # bare `release` resume repeats the original invocation instead of widening.
    if args.only is None and state.data.get("only") is not None:
        args.only = state.data["only"]
    if args.skip is None and state.data.get("skip") is not None:
        args.skip = state.data["skip"]
    if args.notes is None:
        args.notes = state.data.get("notes") or str(
            ROOT / release_files(state.version, state.build_number)["github"]
        )
    state.data["only"] = args.only
    state.data["skip"] = args.skip
    state.data["notes"] = args.notes
    if not args.dry_run:
        state.save()
    phases = resolve_phases(args.only, args.skip)
    ctx = Context(args=args, env=env, state=state, phases=phases)

    for phase in phases:
        if phase in state.done:
            log(f"{phase}: already done, skipping")
            continue
        log(f"phase: {phase}")
        try:
            PHASE_FUNCTIONS[phase](ctx)
        except PhaseDeferred:
            continue
        except KeyboardInterrupt:
            print()
            log(f"interrupted during {phase!r}; state saved, rerun `release` to resume")
            return 130
        except DeployError as error:
            print(f"\nERROR in phase {phase!r}: {error}", file=sys.stderr)
            if not ctx.dry_run:
                print(
                    f"State saved to {STATE_PATH}; fix the problem and rerun "
                    "`uv run scripts/release/deploy.py release` to resume.",
                    file=sys.stderr,
                )
            return 1
        if not ctx.dry_run and phase != "preflight":
            state.mark_done(phase)

    print_summary(ctx)
    return 0


def cmd_changelog(args: argparse.Namespace) -> int:
    state = State.load()
    if not (state and state.version == args.version):
        state = State(
            version=args.version,
            build_number=args.build_number or read_pubspec_build() + 1,
        )
    args.notes = args.notes or str(ROOT / release_files(state.version, state.build_number)["github"])
    args.dry_run = False
    args.yes = True
    ctx = Context(args=args, env=dict(os.environ), state=state, phases=["changelog"])
    phase_changelog(ctx)
    for relpath in ctx.files.values():
        print(f"  {relpath}")
    return 0


def cmd_status(_args: argparse.Namespace) -> int:
    state = State.load()
    if not state:
        print("no release in progress")
        return 0
    print(f"release {state.version}+{state.build_number}")
    for phase in PHASES:
        marker = "x" if phase in state.done else " "
        print(f"  [{marker}] {phase}")
    if state.data:
        print(json.dumps(state.data, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="deploy.py",
        description="ompanion store release pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="phases: " + " ".join(PHASES),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    release = sub.add_parser("release", help="run the release pipeline")
    release.add_argument("--version", help="semver for a new release (e.g. 1.1.0)")
    release.add_argument("--notes",
                         help="raw release notes (default: store/release-notes/<version>.md)")
    release.add_argument("--build-number", type=int,
                         help="use this build number instead of pubspec+1 "
                              "(for a tree whose version was already bumped)")
    release.add_argument("--only", action="append", metavar="PHASE",
                         help="run only these phases (repeatable, comma-separated)")
    release.add_argument("--skip", action="append", metavar="PHASE",
                         help="skip these phases (repeatable, comma-separated)")
    release.add_argument("--dry-run", action="store_true",
                         help="print external actions without performing them")
    release.add_argument("--submit", action="store_true",
                         help="also submit the App Store version for review")
    release.add_argument("--yes", action="store_true",
                         help="assume yes for confirmation prompts")
    release.add_argument("--fresh", action="store_true",
                         help="discard any in-progress release state")
    release.add_argument("--msstore-replace-pending", action="store_true",
                         help="delete a pending Partner Center submission if present")
    release.set_defaults(func=cmd_release)

    changelog = sub.add_parser("changelog", help="write the per-store release notes only")
    changelog.add_argument("--version", required=True, help="semver of the release (e.g. 1.1.0)")
    changelog.add_argument("--notes",
                           help="raw release notes (default: store/release-notes/<version>.md)")
    changelog.add_argument("--build-number", type=int,
                           help="build number naming the Play changelog (default: pubspec+1)")
    changelog.set_defaults(func=cmd_changelog)

    status = sub.add_parser("status", help="show in-progress release state")
    status.set_defaults(func=cmd_status)

    return parser


def _split_phase_lists(values: list[str] | None) -> list[str] | None:
    if not values:
        return None
    result: list[str] = []
    for value in values:
        result.extend(part.strip() for part in value.split(",") if part.strip())
    return result


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if hasattr(args, "only"):
        args.only = _split_phase_lists(args.only)
        args.skip = _split_phase_lists(args.skip)
    try:
        return args.func(args)
    except DeployError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
