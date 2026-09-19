"""Shared fixtures: GitHub release and issue objects as the API returns them.

Release bodies carry verified-train lines in the form promote.yml appends
them; test_workflow_contract.py holds the fixture to what promote.yml
actually writes, so a format change breaks CI instead of orphaning it.
"""
import re
from datetime import datetime, timedelta

# The one release approved today: a full release from before per-train
# sign-off, so grandfathered for every train.
R11 = "v2026.08.21-r11"


def tag(run, date="2026.09.20"):
    """A tag in build.yml's v<build date>-r<run number> form."""
    return f"v{date}-r{run}"


def marker(train):
    return f"<!-- verified-train: {train} -->"


def release(name, prerelease=False, draft=False, trains=(), body=None,
            published=None):
    """A release tagged v<date>-r<N>. Published N hours after a fixed base,
    so a higher run number is newer unless `published` says otherwise."""
    m = re.search(r"-r(\d+)$", name)
    run = int(m.group(1)) if m else 0
    if published is None:
        published = (datetime(2026, 1, 1) + timedelta(hours=run)).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
    if body is None:
        body = "## cli-tools sysext for TrueNAS SCALE\n"
        for t in trains:
            body += f"\n\n{marker(t)}\n"
    return {"id": run or abs(hash(name)), "tag_name": name, "body": body,
            "prerelease": prerelease, "draft": draft,
            "html_url": f"https://example.test/releases/tag/{name}",
            "published_at": published, "created_at": published}


def issue(name, train=None, labels=("hardware-test",), number=1, title=None):
    """A hardware-test issue with the markers build.yml writes."""
    body = f"**Release:** {name}\n<!-- release-tag: {name} -->\n"
    if train:
        body += f"<!-- train: {train} -->\n"
    return {"number": number, "title": title or f"Hardware test: cli-tools {name}",
            "body": body, "labels": [{"name": n} for n in labels]}
