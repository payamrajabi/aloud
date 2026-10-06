#!/usr/bin/env python3
"""Adds a release to docs/appcast.xml, the Sparkle update feed. Newest first; older releases stay.

Usage: update-appcast.py <appcast> <version> <build number> <ed signature> <length> [notes]
Re-running for the same version replaces its entry.
"""
import os
import re
import sys
from email.utils import formatdate
from xml.sax.saxutils import escape

path, version, build, signature, length = sys.argv[1:6]
notes = sys.argv[6] if len(sys.argv) > 6 else ""
url = f"https://github.com/payamrajabi/readaloud/releases/download/v{version}/Aloud.dmg"

description = f"\n      <description><![CDATA[<p>{escape(notes)}</p>]]></description>" if notes else ""
item = f"""<item>
      <title>Aloud {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>{description}
      <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>"""

older = []
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        older = re.findall(r"<item>.*?</item>", f.read(), re.S)
    mine = f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
    older = [i for i in older if mine not in i]

items = "".join(f"    {i}\n" for i in [item] + older)
feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Aloud</title>
    <link>https://payamrajabi.github.io/readaloud/</link>
    <description>Updates for Aloud</description>
    <language>en</language>
{items}  </channel>
</rss>
"""
with open(path, "w", encoding="utf-8") as f:
    f.write(feed)
print(f"Updated {path}: Aloud {version} (build {build}), {len(older)} older release(s) kept")
