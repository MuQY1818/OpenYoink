"""Validate a new stable version against the Sparkle feed and print its build."""

import re
import sys
import xml.etree.ElementTree as ET


def version(value):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}", value):
        raise ValueError(f"Invalid stable version: {value!r}")
    return tuple(map(int, value.split(".")))


def build(value):
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError(f"Invalid stable build: {value!r}")
    return int(value)


def next_build(feed, requested_version, requested_build=""):
    prefix = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    items = ET.parse(feed).findall("./channel/item")
    if not items:
        raise ValueError("Stable appcast is empty")
    history = (item.findtext(prefix + "shortVersionString", "") for item in items)
    # The first published version was tagged 1.0.
    latest = max(version("1.0.0" if text == "1.0" else text) for text in history)
    previous = max(build(item.findtext(prefix + "version", "")) for item in items)
    if version(requested_version) <= latest:
        raise ValueError(f"Stable version must be newer than {'.'.join(map(str, latest))}")
    number = build(requested_build) if requested_build else previous + 1
    if number <= previous:
        raise ValueError(f"Stable build must be greater than {previous}")
    return number


if __name__ == "__main__":
    try:
        print(next_build(*sys.argv[1:]))
    except (ValueError, OSError, ET.ParseError) as error:
        sys.exit(str(error))
