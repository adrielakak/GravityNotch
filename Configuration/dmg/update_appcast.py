#!/usr/bin/env python3
"""Update or create the Sparkle appcast.xml feed for GravityNotch."""

from __future__ import annotations

import argparse
from email.utils import formatdate
from pathlib import Path
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)


def _s(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def _build_empty_tree() -> ET.ElementTree:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "GravityNotch Updates"
    ET.SubElement(channel, "link").text = "https://adrielakak.github.io/GravityNotch/"
    ET.SubElement(channel, "description").text = "Latest releases of GravityNotch for macOS."
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def update_appcast(
    appcast_path: Path,
    *,
    version: str,
    short_version: str,
    url: str,
    length: int,
    ed_signature: str,
    min_macos: str,
    notes_url: str,
) -> None:
    if appcast_path.exists():
        tree = ET.parse(appcast_path)
    else:
        tree = _build_empty_tree()

    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        raise ValueError("Invalid appcast XML: missing <channel> element")

    # Replace any existing item for this exact build number.
    for existing in list(channel.findall("item")):
        ver_el = existing.find(_s("version"))
        if ver_el is not None and (ver_el.text or "").strip() == version:
            channel.remove(existing)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"GravityNotch {short_version}"
    ET.SubElement(item, "link").text = notes_url
    ET.SubElement(item, _s("version")).text = version
    ET.SubElement(item, _s("shortVersionString")).text = short_version
    ET.SubElement(item, _s("releaseNotesLink")).text = notes_url
    ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": url,
            "length": str(length),
            "type": "application/octet-stream",
            _s("edSignature"): ed_signature,
        },
    )
    ET.SubElement(item, _s("minimumSystemVersion")).text = min_macos

    # Keep items sorted newest build first so Sparkle sees the latest release immediately.
    items = channel.findall("item")
    items.append(item)
    for old in channel.findall("item"):
        channel.remove(old)

    def sort_key(el: ET.Element) -> tuple[int, str]:
        txt = (el.findtext(_s("version")) or "0").strip()
        try:
            return (int(txt), txt)
        except ValueError:
            return (0, txt)

    for sorted_item in sorted(items, key=sort_key, reverse=True):
        channel.append(sorted_item)

    ET.indent(tree, space="    ")
    appcast_path.parent.mkdir(parents=True, exist_ok=True)
    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
    appcast_path.write_text(appcast_path.read_text(encoding="utf-8") + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Update GravityNotch Sparkle appcast.xml")
    parser.add_argument("--appcast", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--short-version", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", required=True, type=int)
    parser.add_argument("--ed-signature", required=True)
    parser.add_argument("--min-macos", default="14.0")
    parser.add_argument("--notes-url", required=True)
    args = parser.parse_args()

    update_appcast(
        args.appcast,
        version=args.version,
        short_version=args.short_version,
        url=args.url,
        length=args.length,
        ed_signature=args.ed_signature,
        min_macos=args.min_macos,
        notes_url=args.notes_url,
    )


if __name__ == "__main__":
    main()
