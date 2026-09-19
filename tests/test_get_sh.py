"""End-to-end runs of get.sh, of install.sh's release resolution and of
uninstall.sh's curl|bash path, against stub `midclt` and `curl` commands on
PATH.

The curl stub serves canned GitHub API pages and, for a release download,
writes a fake asset. A fake script prints which asset and release it is, the
arguments it got, the files beside it and the contents of any image it was
handed, so the tests see exactly what get.sh would run. A fake install.sh
accepts --release unless its release is listed in STUB_LEGACY (the releases
from before per-train approval, like v2026.08.21-r11, whose install.sh has no
--release)."""
import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from urllib.parse import urlparse

from release_fixtures import R11, release, tag

ROOT = Path(__file__).resolve().parents[1]
GET_SH = ROOT / "get.sh"
INSTALL_SH = ROOT / "scripts" / "install.sh"
UNINSTALL_SH = ROOT / "scripts" / "uninstall.sh"
REPO = "truenas-community-sysexts/cli-tools"


def logged_host(line):
    """Hostname of the URL in a stub-log line ("curl <url>"), or "" for other lines."""
    parts = line.split()
    if len(parts) > 1 and parts[0] == "curl":
        return urlparse(parts[1]).hostname or ""
    return ""


def logged_path(line):
    """Path of the URL in a stub-log line ("curl <url>"), or "" for other lines."""
    parts = line.split()
    if len(parts) > 1 and parts[0] == "curl":
        return urlparse(parts[1]).path
    return ""


CURL_STUB = textwrap.dedent("""\
    #!/usr/bin/env python3
    import hashlib, json, os, re, sys
    from urllib.parse import urlparse
    args = sys.argv[1:]
    url = next(a for a in args if a.startswith("https://"))
    with open(os.environ["STUB_LOG"], "a") as f:
        f.write("curl " + url + "\\n")
    parsed = urlparse(url)
    host, path = parsed.hostname, parsed.path
    if host == "api.github.com":
        page = int(re.search(r"(?:^|&)page=(\\d+)", parsed.query).group(1))
        pages = json.load(open(os.environ["STUB_PAGES"]))
        print(json.dumps(pages[page - 1] if page <= len(pages) else []))
        sys.exit(0)
    if host != "github.com" or "/releases/download/" not in path:
        sys.exit(22)
    repo = path.split("/releases/download/")[0].strip("/")
    tag, asset = path.split("/releases/download/")[1].split("/")
    if asset in os.environ.get("STUB_FAIL", "").split(","):
        sys.exit(22)
    image = f"cli-tools.raw of {repo} {tag}\\n"
    if asset == "cli-tools.raw":
        text = image
    elif asset == "cli-tools.raw.sha256":
        if os.environ.get("STUB_BADSUM"):
            image = "tampered\\n"
        text = hashlib.sha256(image.encode()).hexdigest() + "  cli-tools.raw\\n"
    elif asset.endswith(".sh"):
        text = "#!/usr/bin/env bash\\n"
        if asset == "install.sh" and tag not in os.environ.get("STUB_LEGACY", "").split(","):
            text += "case x in\\n        --release=*) ;;\\nesac\\n"
        text += (f'echo "RAN {asset} from {tag} with: $*"\\n'
                 'echo "REPO=$CLI_TOOLS_REPO"\\n'
                 'echo "BESIDE: $(cd "$(dirname "$0")" && ls | tr "\\\\n" " ")"\\n'
                 'for a; do [ -f "$a" ] && echo "IMAGE: $(cat "$a")"; done\\n'
                 'exit 0\\n')
    else:
        sys.exit(22)
    with open(args[args.index("-o") + 1], "w") as f:
        f.write(text)
    """)

MIDCLT_STUB = textwrap.dedent("""\
    #!/usr/bin/env bash
    echo "midclt $*" >> "$STUB_LOG"
    [ -n "$STUB_VERSION" ] || exit 1
    echo "{\\"version\\": \\"$STUB_VERSION\\"}"
    """)

# 25.10 boxes: r11 (grandfathered). 26 boxes: r12 (signed off on 26).
RELEASES = [release(tag(13), prerelease=True), release(tag(12), trains=["26"]),
            release(R11), release("v2026.06.08-r9")]


class Stubbed(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        for name, text in (("curl", CURL_STUB), ("midclt", MIDCLT_STUB)):
            path = self.bin / name
            path.write_text(text)
            path.chmod(0o755)
        self.log = self.dir / "log"
        self.log.write_text("")

    def tearDown(self):
        self._tmp.cleanup()

    def env(self, version, releases, **extra):
        pages = self.dir / "pages.json"
        pages.write_text(json.dumps([releases]))
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                   STUB_LOG=str(self.log), STUB_PAGES=str(pages),
                   STUB_VERSION=version, TMPDIR=str(self.dir))
        env.pop("CLI_TOOLS_REPO", None)
        env.update(extra)
        return env

    def run_bash(self, args, version, releases=RELEASES, stdin=None, cwd=None,
                 **extra):
        return subprocess.run(["bash", *args], capture_output=True, text=True,
                              input=stdin, cwd=cwd,
                              env=self.env(version, releases, **extra))

    def calls(self):
        return self.log.read_text().splitlines()

    def downloads(self):
        return [c.split("/releases/download/")[1] for c in self.calls()
                if "/releases/download/" in c]


class GetShBase(Stubbed):
    def get(self, *args, version="25.10.7", releases=RELEASES, **extra):
        return self.run_bash([str(GET_SH), *args], version, releases, **extra)

    def ran(self, p):
        return p.stdout.splitlines()[0].rstrip() if p.stdout else ""


class GetSh(GetShBase):
    def test_runs_the_approved_releases_installer_pinned_to_it(self):
        p = self.get(version="26.0.0-BETA.3")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ran(p), f"RAN install.sh from {tag(12)} with: --release={tag(12)}")
        self.assertIn(f"TrueNAS 26.0.0-BETA.3 (train 26): newest approved release is {tag(12)}",
                      p.stderr)
        # The lib comes from the same release, beside the installer.
        self.assertIn("BESIDE: cli-tools-lib.sh install.sh", p.stdout)
        self.assertEqual(self.downloads(), [f"{tag(12)}/install.sh",
                                            f"{tag(12)}/cli-tools-lib.sh"])

    def test_each_train_gets_its_own_approved_release(self):
        p = self.get(version="25.10.7")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ran(p), f"RAN install.sh from {R11} with: --release={R11}")

    def test_arguments_pass_through(self):
        p = self.get("--pool=fast", "--dry-run", version="26.1.0")
        self.assertEqual(self.ran(p),
                         f"RAN install.sh from {tag(12)} with: --pool=fast --dry-run --release={tag(12)}")

    def test_uninstall_runs_the_approved_releases_uninstaller_beside_its_restore_and_lib(self):
        p = self.get("--uninstall", version="26.0.0-BETA.3")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ran(p), f"RAN uninstall.sh from {tag(12)} with:")
        self.assertIn("BESIDE: cli-tools-lib.sh restore.sh uninstall.sh", p.stdout)
        self.assertEqual(sorted(self.downloads()),
                         sorted(f"{tag(12)}/{a}" for a in
                                ("uninstall.sh", "restore.sh", "cli-tools-lib.sh")))

    def test_pinned_release_skips_selection(self):
        p = self.get(f"--release={tag(13)}", "--check")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ran(p),
                         f"RAN install.sh from {tag(13)} with: --check --release={tag(13)}")
        self.assertFalse(any(c.startswith("midclt")
                             or logged_host(c) == "api.github.com"
                             for c in self.calls()), self.calls())

    def test_pinned_uninstall(self):
        p = self.get("--uninstall", f"--release={tag(13)}")
        self.assertEqual(self.ran(p), f"RAN uninstall.sh from {tag(13)} with:")

    def test_repo_flag_points_everything_at_the_fork(self):
        p = self.get("--repo=someone/fork", version="26.0.0-BETA.3")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("REPO=someone/fork", p.stdout)
        self.assertTrue(any(logged_host(c) == "api.github.com"
                            and logged_path(c) == "/repos/someone/fork/releases"
                            for c in self.calls()), self.calls())
        self.assertTrue(all("/someone/fork/releases/download/" in c
                            for c in self.calls() if "/releases/download/" in c))
        # --repo is get.sh's; the scripts get it through CLI_TOOLS_REPO.
        self.assertEqual(self.ran(p), f"RAN install.sh from {tag(12)} with: --release={tag(12)}")

    def test_default_repo_is_exported(self):
        p = self.get()
        self.assertIn(f"REPO={REPO}", p.stdout)

    def test_no_approved_release_stops_before_any_download(self):
        p = self.get(version="26.0.0-BETA.3",
                     releases=[release(tag(13), prerelease=True)])
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("No release is approved for TrueNAS train 26 yet", p.stderr)
        self.assertEqual(self.downloads(), [])

    def test_unreadable_truenas_version_is_an_error(self):
        p = self.get(version="")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("could not read the TrueNAS version", p.stderr)
        self.assertEqual(self.downloads(), [])

    def test_empty_release_flag_is_refused(self):
        p = self.get("--release=")
        self.assertEqual(p.returncode, 2)

    def test_failed_download_stops(self):
        p = self.get(STUB_FAIL="cli-tools-lib.sh")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(f"could not download cli-tools-lib.sh from release {R11}", p.stderr)
        self.assertNotIn("RAN", p.stdout)

    def test_temp_dir_is_removed(self):
        self.get()
        self.get(STUB_LEGACY=R11)
        self.assertEqual(list(self.dir.glob("cli-tools-get.*")), [])


class GetShLegacyInstaller(GetShBase):
    """A release from before per-train approval (r11 and older) has an
    install.sh without --release that downloads cli-tools.raw from GitHub's
    Latest. get.sh hands it the release's own image instead."""

    def test_installer_gets_this_releases_image_not_release_flag(self):
        p = self.get("--pool=fast", STUB_LEGACY=R11)
        self.assertEqual(p.returncode, 0, p.stderr)
        first = self.ran(p)
        self.assertTrue(first.startswith(f"RAN install.sh from {R11} with: --pool=fast /"), first)
        self.assertTrue(first.endswith("/cli-tools.raw"), first)
        self.assertNotIn("--release", first)
        self.assertIn(f"IMAGE: cli-tools.raw of {REPO} {R11}", p.stdout)
        self.assertIn("cli-tools.raw: OK", p.stderr)
        self.assertEqual(self.downloads(), [f"{R11}/{a}" for a in
                                            ("install.sh", "cli-tools-lib.sh",
                                             "cli-tools.raw", "cli-tools.raw.sha256")])

    def test_bad_checksum_stops_before_the_installer(self):
        p = self.get(STUB_LEGACY=R11, STUB_BADSUM="1")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(f"checksum verification failed for cli-tools.raw from release {R11}",
                      p.stderr)
        self.assertNotIn("RAN", p.stdout)

    def test_check_and_help_need_no_image(self):
        for flag in ("--check", "--help"):
            self.log.write_text("")
            p = self.get(flag, STUB_LEGACY=R11)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(self.ran(p), f"RAN install.sh from {R11} with: {flag}")
            self.assertEqual(self.downloads(), [f"{R11}/install.sh",
                                                f"{R11}/cli-tools-lib.sh"])

    def test_users_own_image_is_left_alone(self):
        own = self.dir / "mine.raw"
        own.write_text("my image\n")
        p = self.get(str(own), STUB_LEGACY=R11)
        self.assertEqual(self.ran(p), f"RAN install.sh from {R11} with: {own}")
        self.assertIn("IMAGE: my image", p.stdout)

    def test_uninstall_is_the_same_for_old_releases(self):
        p = self.get("--uninstall", STUB_LEGACY=R11)
        self.assertEqual(self.ran(p), f"RAN uninstall.sh from {R11} with:")


class ReleaseFlagDetection(unittest.TestCase):
    """get.sh tells the two kinds of install.sh apart with one grep."""

    def pattern(self):
        m = re.search(r"grep -q -e '([^']+)' \"\$\{WORK_DIR\}/install\.sh\"",
                      GET_SH.read_text())
        self.assertIsNotNone(m)
        return m.group(1)

    def matches(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".sh") as f:
            f.write(text)
            f.flush()
            return subprocess.run(["grep", "-q", "-e", self.pattern(), f.name]).returncode == 0

    def test_this_install_sh_accepts_release(self):
        self.assertTrue(self.matches(INSTALL_SH.read_text()))

    def test_install_sh_without_the_flag_is_legacy(self):
        text = INSTALL_SH.read_text()
        start = text.index("        --release=*)")
        end = text.index(";;", start) + 2
        self.assertFalse(self.matches(text[:start] + text[end:]))


class InstallerResolve(Stubbed):
    """install.sh run on its own (not through get.sh) resolves its release by
    the same rule."""

    def resolve(self, version, release_tag="", releases=RELEASES, calls=1):
        text = INSTALL_SH.read_text()
        block = text[text.index("# BEGIN approved-release"):
                     text.index("# END approved-release")]
        fn = re.search(r"^resolve_release_for_install\(\) \{\n.*?^\}\n", text,
                       re.S | re.M).group(0)
        script = self.dir / "resolve.sh"
        script.write_text(
            f'REPO="{REPO}"\n'
            f'RELEASE_TAG="{release_tag}"\nRESOLVED_TAG=""\nRELEASE_DL_BASE=""\n'
            f'{block}\n{fn}\n'
            + 'resolve_release_for_install\n' * calls
            + 'echo "tag=${RESOLVED_TAG} base=${RELEASE_DL_BASE}"\n')
        return self.run_bash([str(script)], version, releases)

    def test_auto_resolve_takes_the_approved_release(self):
        p = self.resolve("26.1.0")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"tag={tag(12)} base=https://github.com/{REPO}/releases/download/{tag(12)}",
                      p.stdout)

    def test_no_approved_release_stops_instead_of_using_latest(self):
        p = self.resolve("26.1.0", releases=[release(tag(13), prerelease=True)])
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("tag=", p.stdout)
        self.assertIn("No release is approved for TrueNAS train 26 yet", p.stderr)

    def test_explicit_release_is_trusted(self):
        p = self.resolve("", release_tag=tag(13))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"tag={tag(13)} ", p.stdout)
        self.assertFalse(any(c.startswith("midclt") for c in self.calls()))

    def test_resolves_once(self):
        # The lib fetch and the image download share one resolution.
        p = self.resolve("25.10.7", calls=2)
        self.assertIn(f"tag={R11} ", p.stdout)
        self.assertEqual(sum(logged_host(c) == "api.github.com"
                             for c in self.calls()), 1)


class UninstallStandalone(Stubbed):
    """uninstall.sh piped to bash has no restore.sh beside it: it fetches
    restore.sh and the lib from the release approved for the train."""

    def uninstall(self, version, releases=RELEASES, **extra):
        # Run from an empty directory: $0 is "bash", so its "sibling"
        # restore.sh would be one in the current directory.
        cwd = self.dir / "cwd"
        cwd.mkdir(exist_ok=True)
        return self.run_bash(["-s", "--", "--help"], version, releases,
                             stdin=UNINSTALL_SH.read_text(), cwd=cwd, **extra)

    def test_restore_and_lib_come_from_the_approved_release(self):
        p = self.uninstall("26.0.0-BETA.3")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"RAN restore.sh from {tag(12)} with: --help", p.stdout)
        self.assertIn("BESIDE: cli-tools-lib.sh restore.sh", p.stdout)
        self.assertEqual(self.downloads(), [f"{tag(12)}/restore.sh",
                                            f"{tag(12)}/cli-tools-lib.sh"])

    def test_no_approved_release_stops(self):
        p = self.uninstall("26.0.0-BETA.3", releases=[release(tag(13), prerelease=True)])
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("No release is approved for TrueNAS train 26 yet", p.stderr)
        self.assertEqual(self.downloads(), [])

    def test_lib_download_failure_is_fatal(self):
        # restore.sh would otherwise look for the lib somewhere else.
        p = self.uninstall("25.10.7", STUB_FAIL="cli-tools-lib.sh")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(f"failed to download cli-tools-lib.sh from {REPO} release {R11}",
                      p.stderr)
        self.assertNotIn("RAN", p.stdout)


if __name__ == "__main__":
    unittest.main()
