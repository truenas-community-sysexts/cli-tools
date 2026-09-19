"""Render the hardware-test issues and release notes build.yml produces and
check them.

The github-script body of the issue step is extracted verbatim and run under
node with a stub GitHub client, from the repo root, so it reads the real
tracked-versions.json; the release-notes step's run: block runs under bash.
The issues are procedures a human follows by hand, so these checks pin what
their commands depend on: the markers promote.yml parses, flags get.sh and
install.sh accept, and the per-train duplicate check."""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from release_fixtures import R11
from workflow_script import OWNER, REPO, ROOT, run_script, step_script

BUILD_YML = ROOT / ".github" / "workflows" / "build.yml"
CHECK_RELEASES_YML = ROOT / ".github" / "workflows" / "check-releases.yml"
GET_SH = ROOT / "get.sh"
INSTALL_SH = ROOT / "scripts" / "install.sh"
STEP = "Open hardware-test issues, one per train (prerelease gate)"
TAG = "v2026.09.20-r12"
GET = f"https://raw.githubusercontent.com/{OWNER}/{REPO}/main/get.sh"

HARNESS = """
const state = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const out = { labels: [], issues: [] };
console.log = (...a) => process.stderr.write(a.join(' ') + '\\n');
const github = { rest: { issues: {
  createLabel: async (args) => { out.labels.push(args);
    if ((state.existingLabels || []).includes(args.name)) {
      throw Object.assign(new Error('exists'), { status: 422 }); } },
  listForRepo: async ({ labels }) => ({ data: (state.open || [])
    .filter((i) => i.labels.includes(labels)) }),
  create: async (args) => { out.issues.push(args); },
} } };
const context = { repo: { owner: 'truenas-community-sysexts', repo: 'cli-tools' } };
(async () => {
%s
})().then(() => process.stdout.write(JSON.stringify(out)),
          (e) => { process.stderr.write(String(e && e.stack || e)); process.exit(1); });
"""


def render(run="12", date="2026.09.20", open_issues=(), existing_labels=()):
    env = dict(os.environ, RUN_NUMBER=run, BUILD_DATE=date)
    return run_script(HARNESS, step_script("build.yml", STEP),
                      {"open": list(open_issues),
                       "existingLabels": list(existing_labels)}, env=env)


def open_issue(title, body="", labels=("hardware-test",), number=7):
    return {"number": number, "title": title, "body": body, "labels": list(labels)}


def code_lines(body):
    out, inside = [], False
    for ln in body.splitlines():
        if ln.startswith("```"):
            inside = not inside
            continue
        if inside:
            out.append(ln)
    return out


def accepted_flags():
    flags = set()
    for path in (GET_SH, INSTALL_SH):
        flags |= set(re.findall(r"^\s+(--[a-z-]+=?)\*?\)", path.read_text(), re.M))
    return flags


class PerTrain(unittest.TestCase):
    def setUp(self):
        self.out = render()
        self.by_train = {re.search(r"<!-- train: (\S+) -->", i["body"]).group(1): i
                         for i in self.out["issues"]}

    def test_one_issue_per_tracked_train(self):
        tracked = json.loads((ROOT / ".github" / "tracked-versions.json").read_text())
        self.assertEqual(sorted(self.by_train), sorted(t["key"] for t in tracked["trains"]))

    def test_titles_name_the_train(self):
        self.assertEqual(
            self.by_train["25.10"]["title"],
            f"Hardware test: cli-tools 2026.09.20 | any TrueNAS 25.10 system, no special hardware | {TAG}")
        self.assertEqual(
            self.by_train["26"]["title"],
            f"Preview hardware test: cli-tools 2026.09.20 | any TrueNAS 26 beta system, no special hardware | {TAG}")

    def test_labels_follow_the_channel(self):
        self.assertEqual(self.by_train["25.10"]["labels"], ["hardware-test"])
        self.assertEqual(self.by_train["26"]["labels"], ["preview-hardware-test"])
        self.assertEqual(sorted(l["name"] for l in self.out["labels"]),
                         ["hardware-test", "preview-hardware-test"])

    def test_existing_labels_are_fine(self):
        out = render(existing_labels=["hardware-test", "preview-hardware-test"])
        self.assertEqual(len(out["issues"]), 2)

    def test_markers_promote_yml_parses(self):
        for key, iss in self.by_train.items():
            body = iss["body"]
            self.assertIn(f"<!-- release-tag: {TAG} -->", body.splitlines())
            self.assertIn(f"<!-- train: {key} -->", body.splitlines())
            # promote.yml's regexes, verbatim.
            self.assertEqual(re.search(r"<!--\s*release-tag:\s*(\S+?)\s*-->", body).group(1), TAG)
            self.assertEqual(re.search(r"<!--\s*train:\s*(\S+?)\s*-->", body).group(1), key)

    def test_body_tells_the_tester_which_train(self):
        body = self.by_train["26"]["body"]
        self.assertIn("approves it for **TrueNAS 26 beta** boxes only", body)
        self.assertIn("on a TrueNAS 26 beta box", body)
        self.assertIn("TrueNAS 25.10 has its own issue for this release", body)
        self.assertIn("cat /etc/version                       # starts with 26.", body)
        self.assertIn("`verified-train: 26`", body)

    def test_install_commands_pin_this_release_via_get_sh(self):
        for iss in self.out["issues"]:
            lines = code_lines(iss["body"])
            self.assertIn(f"I={GET}", lines)
            runs = [ln for ln in lines if ln.startswith('curl -fsSL "$I"')]
            self.assertEqual(len(runs), 4)
            for ln in runs:
                self.assertIn(f"--release={TAG}", ln)
            self.assertFalse(any("releases/latest" in ln for ln in lines))

    def test_every_flag_in_the_procedure_exists(self):
        flags = accepted_flags()
        for iss in self.out["issues"]:
            for ln in code_lines(iss["body"]):
                if 'curl -fsSL "$I"' not in ln:
                    continue
                cmd = ln.split("#")[0].split("bash -s --", 1)[1]
                for f in re.findall(r"(--[a-z-]+=?)", cmd):
                    self.assertIn(f, flags, ln)

    def test_expected_output_is_what_install_sh_prints(self):
        text = INSTALL_SH.read_text()
        for needle in ('Downloading cli-tools.raw from ${REPO} release ${RESOLVED_TAG}...',
                       '"Checksum OK"', '"=== Dry-run complete ==="', '"Tools now on PATH:"',
                       '"All bundled tools resolve on PATH"',
                       '"PREINIT completed successfully this boot"'):
            self.assertIn(needle, text)
        body = self.by_train["25.10"]["body"]
        self.assertIn(f'"Downloading cli-tools.raw from {OWNER}/{REPO} release {TAG}..."', body)


class DuplicateCheck(unittest.TestCase):
    def trains_created(self, *open_issues):
        out = render(open_issues=open_issues)
        return sorted(re.search(r"<!-- train: (\S+) -->", i["body"]).group(1)
                      for i in out["issues"])

    def test_open_issue_for_tag_and_train_by_markers(self):
        body = f"<!-- release-tag: {TAG} -->\n<!-- train: 25.10 -->\n"
        self.assertEqual(self.trains_created(open_issue("renamed", body)), ["26"])

    def test_open_issue_for_tag_and_train_by_title(self):
        title = ("Preview hardware test: cli-tools 2026.09.20 | any TrueNAS 26 beta system, "
                 f"no special hardware | {TAG}")
        self.assertEqual(self.trains_created(
            open_issue(title, labels=("preview-hardware-test",))), ["25.10"])

    def test_old_single_issue_covers_every_train(self):
        # The title format from before per-train issues (issue #11), and the
        # one before that (issues #1-#10).
        title = ("Hardware test: cli-tools 2026.09.20 | any TrueNAS 25.10+ system, "
                 f"no special hardware | {TAG}")
        self.assertEqual(self.trains_created(
            open_issue(title, f"<!-- release-tag: {TAG} -->\n")), [])
        self.assertEqual(self.trains_created(
            open_issue(f"Hardware test: cli-tools {TAG}")), [])

    def test_other_train_or_tag_does_not_block(self):
        self.assertEqual(self.trains_created(
            open_issue("x", f"<!-- release-tag: {TAG} -->\n<!-- train: 24.04 -->\n"),
            open_issue("Hardware test: cli-tools v2026.09.20-r1", number=8),
            open_issue("y", f"<!-- release-tag: {R11} -->\n<!-- train: 25.10 -->\n", number=9)),
            ["25.10", "26"])


class ReleaseNotes(unittest.TestCase):
    """The notes build.yml writes: the get.sh commands, and nothing that
    reads as an approval."""

    def render_notes(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / ".github").mkdir()
            shutil.copy(ROOT / ".github" / "tracked-versions.json", Path(d) / ".github")
            lib = Path(d) / "root" / "usr" / "lib" / "cli-tools"
            lib.mkdir(parents=True)
            (lib / "versions.txt").write_text("btop         v1.4.7 (github)\n")
            env = dict(os.environ, SUITE="bookworm", BUILD_DATE="2026.09.20",
                       RUN_NUMBER="12", BUILD_SHA="abc123", REPO=f"{OWNER}/{REPO}",
                       SYSEXT_ROOT=str(Path(d) / "root"))
            p = subprocess.run(["bash", "-euo", "pipefail", "-c",
                                step_script("build.yml", "Render release notes", key="run")],
                               cwd=d, env=env, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            return (Path(d) / "release-notes.md").read_text()

    def test_notes_use_get_sh(self):
        notes = self.render_notes()
        self.assertIn(f"curl -fsSL {GET} | sudo bash\n", notes)
        self.assertIn(f"curl -fsSL {GET} | sudo bash -s -- --release={TAG}\n", notes)
        self.assertIn(f"curl -fsSL {GET} | sudo bash -s -- --check\n", notes)
        self.assertIn(f"curl -fsSL {GET} | sudo bash -s -- --uninstall\n", notes)
        self.assertIn("A hardware test on a TrueNAS train (TrueNAS 25.10, TrueNAS 26 beta)", notes)
        self.assertNotIn("releases/latest", notes)

    def test_notes_carry_no_approval(self):
        self.assertNotIn("verified-train", self.render_notes())


class PublishGate(unittest.TestCase):
    def test_no_publish_straight_to_latest(self):
        # A full release with no verified-train marker is approved for every
        # train, so nothing may publish one: every release starts as a
        # prerelease, and callers pass no mark_latest.
        text = BUILD_YML.read_text()
        self.assertNotIn("mark_latest", text)
        self.assertNotIn("make_latest", text)
        self.assertNotIn("mark_latest", CHECK_RELEASES_YML.read_text())
        self.assertIn('-F draft=false -F prerelease=true', text)

    def test_release_job_checks_out_tracked_versions(self):
        # The issue step reads .github/tracked-versions.json in the release
        # job, whose checkout is sparse.
        text = BUILD_YML.read_text()
        job = text[text.index("\n  release:\n"):]
        checkout = job[:job.index("- name: Download build artifacts")]
        self.assertIn("            .github\n", checkout)


if __name__ == "__main__":
    unittest.main()
