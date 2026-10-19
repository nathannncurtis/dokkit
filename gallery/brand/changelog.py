"""Writes changelog.json and changelog.xml from the release tags and the commits between them.
Run from anywhere: python gallery/brand/changelog.py"""
import json, os, re, subprocess
from email.utils import format_datetime
from datetime import datetime
from xml.sax.saxutils import escape

here = os.path.dirname(os.path.abspath(__file__))
git = lambda *a: subprocess.run(["git", *a], cwd=here, capture_output=True, text=True, check=True).stdout
site = "https://dokkit.dev"
paperwork = re.compile(r"^(spec/|docs/|gallery/|\.github/|\.impeccable/)|\.md$")

tags = sorted(git("tag", "--list", "v*").split(), key=lambda t: [int(x) for x in t[1:].split(".")])
releases = []
for prev, tag in zip([None] + tags, tags):
    span = f"{prev}..{tag}" if prev else tag
    changes = []
    for block in git("log", "--no-merges", "--format=\x1e%s", "--name-only", span).split("\x1e")[1:]:
        subject, *files = [l for l in block.split("\n") if l.strip()]
        if files and all(paperwork.search(f) for f in files):
            continue
        changes.append(subject.strip())
    at = git("log", "-1", "--format=%cI", tag).strip()
    if changes:
        releases.append({"version": tag, "at": at, "changes": changes})
releases.reverse()

open(os.path.join(here, "changelog.json"), "w", encoding="utf-8").write(json.dumps(releases, indent=1, ensure_ascii=False) + "\n")
items = "".join(
    f"<item><title>Dokkit {r['version']}</title><link>{site}/changelog.html#{r['version']}</link><guid>{site}/changelog.html#{r['version']}</guid>"
    f"<pubDate>{format_datetime(datetime.fromisoformat(r['at']))}</pubDate><description>{escape(''.join(f'<li>{escape(c)}</li>' for c in r['changes']))}</description></item>"
    for r in releases)
open(os.path.join(here, "changelog.xml"), "w", encoding="utf-8").write(
    f'<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0"><channel><title>Dokkit releases</title><link>{site}/changelog.html</link>'
    f"<description>Every Dokkit release, for someone running it.</description>{items}</channel></rss>\n")
print(len(releases), "releases,", sum(len(r["changes"]) for r in releases), "changes")
