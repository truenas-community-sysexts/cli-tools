"""Contract: the issue build.yml opens, closed through promote.yml, yields
release notes the installer's selection accepts, for that train only.

Each stage runs the real code (build.yml's and promote.yml's github-script
under node, the selection snippet from get.sh), so a marker format change in
any one of them breaks CI instead of silently approving nothing, or
everything."""
import unittest

from release_fixtures import R11, marker, release
from test_hardware_test_issue import TAG, render
from test_promote import apply, close
from test_release_selection import run_selection

VERSIONS = {"25.10": "25.10.7", "26": "26.0.0-BETA.3"}


def selected(releases, train):
    p = run_selection(releases, VERSIONS[train], train)
    return p.stdout if p.returncode == 0 else None


class SignOffChain(unittest.TestCase):
    def setUp(self):
        issues = render(run="12", date="2026.09.20")["issues"]
        self.issues = {}
        for iss in issues:
            key = "26" if "26 beta" in iss["title"] else "25.10"
            self.issues[key] = dict(iss, number=len(self.issues) + 1,
                                    labels=[{"name": n} for n in iss["labels"]])
        self.releases = [release(TAG, prerelease=True), release(R11)]

    def sign_off(self, train):
        out = close(self.issues[train], self.releases)
        self.assertEqual(len(out["updates"]), 1, out)
        self.releases = apply(self.releases, out["updates"][0])

    def test_before_any_sign_off_both_trains_keep_the_grandfathered_release(self):
        self.assertEqual(selected(self.releases, "25.10"), R11)
        self.assertEqual(selected(self.releases, "26"), R11)

    def test_a_sign_off_approves_its_own_train_only(self):
        self.sign_off("26")
        self.assertEqual(selected(self.releases, "26"), TAG)
        self.assertEqual(selected(self.releases, "25.10"), R11)
        self.sign_off("25.10")
        self.assertEqual(selected(self.releases, "25.10"), TAG)
        self.assertEqual(selected(self.releases, "26"), TAG)

    def test_fixture_marker_matches_what_promote_writes(self):
        self.sign_off("25.10")
        self.assertIn(f"\n\n{marker('25.10')}\n", self.releases[0]["body"])


if __name__ == "__main__":
    unittest.main()
