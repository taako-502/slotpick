#!/usr/bin/env python3
"""Plan semantic versions and publish verified DMGs. No third-party Python dependencies."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def parse_version(value):
    match = SEMVER.fullmatch(value)
    if not match:
        raise ValueError(f"Invalid semantic version: {value}")
    return tuple(map(int, match.groups()))


def bumped_version(base, tags, bump):
    versions = [parse_version(base)]
    versions.extend(parse_version(tag[1:]) for tag in tags if tag.startswith("v") and SEMVER.fullmatch(tag[1:]))
    major, minor, patch = max(versions)
    if bump == "major":
        return f"{major + 1}.0.0"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    if bump == "patch":
        return f"{major}.{minor}.{patch + 1}"
    raise ValueError("Choose patch, minor, or major")


def marker(run_id, bump):
    if not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise ValueError("Invalid GitHub run ID")
    if bump not in ("patch", "minor", "major"):
        raise ValueError("Invalid version bump")
    return f"SlotPick release run {run_id} ({bump})"


def tag_subject(tag):
    return command("git", "for-each-ref", "--format=%(contents:subject)", f"refs/tags/{tag}")


def verify_tag(tag, run_id, bump):
    if tag_subject(tag) != marker(run_id, bump):
        raise ValueError(f"{tag} belongs to another release run; refusing to change it")
    if command("git", "rev-parse", f"refs/tags/{tag}^{{commit}}") != command("git", "rev-parse", "HEAD"):
        raise ValueError(f"{tag} points to another commit")


def plan(bump, run_id):
    expected = marker(run_id, bump)
    tags = command("git", "tag", "--list").splitlines()
    # A retry after tag creation must resume the same release, not bump again.
    matching = [tag for tag in tags if tag.startswith("v") and SEMVER.fullmatch(tag[1:]) and tag_subject(tag) == expected]
    if len(matching) > 1:
        raise ValueError("Multiple release tags found for this run")
    if matching:
        verify_tag(matching[0], run_id, bump)
        return matching[0][1:]
    project = Path("SlotPick.xcodeproj/project.pbxproj").read_text()
    versions = set(re.findall(r'"?MARKETING_VERSION"?\s*=\s*"?([0-9]+\.[0-9]+\.[0-9]+)"?\s*;', project))
    if len(versions) != 1:
        raise ValueError("Expected one consistent project marketing version")
    return bumped_version(versions.pop(), tags, bump)


def get_release(tag):
    # The REST releases/tags endpoint does not reliably expose drafts. The CLI
    # resolves unpublished releases too, which is required before publication.
    result = subprocess.run(
        ["gh", "release", "view", tag, "--json", "isDraft,assets,url"],
        text=True, capture_output=True,
    )
    if result.returncode == 0:
        value = json.loads(result.stdout)
        return {"draft": value["isDraft"], "assets": value["assets"], "html_url": value["url"]}
    if result.stderr.strip() == "release not found":
        return None
    raise RuntimeError(result.stderr.strip())


def publish(version, bump, run_id, assets):
    parse_version(version)
    marker(run_id, bump)
    assets = Path(assets).resolve()
    filenames = [f"SlotPick-{version}.dmg", f"SlotPick-{version}.dmg.sha256"]
    for name in filenames:
        if not (assets / name).is_file() or (assets / name).stat().st_size == 0:
            raise ValueError(f"Missing release asset: {name}")
    subprocess.run(["shasum", "-a", "256", "-c", filenames[1]], cwd=assets, check=True)
    tag = f"v{version}"
    tags = command("git", "tag", "--list").splitlines()
    if tag in tags:
        verify_tag(tag, run_id, bump)
    else:
        # Re-plan to refuse an unexpected version or an unrelated tag collision.
        if plan(bump, run_id) != version:
            raise ValueError("Release version changed; rerun the workflow")
        command("git", "-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "-c", "tag.gpgsign=false", "tag", "-a", tag, "-m", marker(run_id, bump))
    command("git", "push", "origin", f"refs/tags/{tag}")

    release = get_release(tag)
    if release and not release["draft"]:
        uploaded = {asset["name"] for asset in release["assets"] if asset["size"] > 0}
        if not set(filenames).issubset(uploaded):
            raise ValueError("Published release is missing assets; inspect it manually")
        return release["html_url"]  # Never replace assets of an already published release.

    if not release:
        notes = (
            f"SlotPick {version}\n\n"
            f"Assetsから `{filenames[0]}` をダウンロードし、SlotPick.appをApplicationsへドラッグしてください。\n\n"
            "- macOS 14以降 / Apple Silicon・Intel対応\n"
            "- 初回起動時にカレンダーのフルアクセスを許可してください。\n"
            "- ローカル（ad-hoc）署名版です。Developer ID署名・Appleの公証は未実施のため、macOSで警告される場合があります。\n"
            "- SHA-256チェックサムを併記しています。\n\n"
            f"Source: `{command('git', 'rev-parse', 'HEAD')}`\n\n[via ChatGPT]\n"
        )
        with tempfile.TemporaryDirectory() as temp:
            note_path = Path(temp) / "release-notes.md"
            note_path.write_text(notes)
            command("gh", "release", "create", tag, "--verify-tag", "--draft", "--title", f"SlotPick {tag}", "--notes-file", str(note_path))

    # Only drafts can be resumed/replaced. Publish after BOTH assets have uploaded.
    command("gh", "release", "upload", tag, *(str(assets / name) for name in filenames), "--clobber")
    release = get_release(tag)
    if release is None:
        raise ValueError("Release could not be retrieved after upload; leaving it unpublished")
    uploaded = {asset["name"]: asset["size"] for asset in release["assets"]}
    if any(uploaded.get(name) != (assets / name).stat().st_size for name in filenames):
        raise ValueError("Release asset verification failed; leaving release as a draft")
    command("gh", "release", "edit", tag, "--draft=false")
    return get_release(tag)["html_url"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="action", required=True)
    for name in ("plan", "publish"):
        sub = subcommands.add_parser(name)
        sub.add_argument("--bump", required=True, choices=["patch", "minor", "major"])
        sub.add_argument("--run-id", required=True)
        if name == "publish":
            sub.add_argument("--version", required=True)
            sub.add_argument("--assets", required=True)
    args = parser.parse_args()
    if args.action == "plan":
        version = plan(args.bump, args.run_id)
        output = f"version={version}\ntag=v{version}\n"
        print(output, end="")
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as file:
                file.write(output)
    else:
        url = publish(args.version, args.bump, args.run_id, args.assets)
        print(url)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as file:
                file.write(f"## Release published\n\n[Download SlotPick v{args.version}]({url})\n")


if __name__ == "__main__":
    main()
