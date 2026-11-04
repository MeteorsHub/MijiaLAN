#!/usr/bin/env python3
"""Generate icon resources with Pillow; validate committed resources/bundles using only the standard library."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import plistlib
import struct
import zlib

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Resources/AppIcon/AppIcon.source.png"
ICONSET = ROOT / "Resources/AppIcon.iconset"
ICNS = ROOT / "Resources/AppIcon.icns"
MANIFEST = ROOT / "Resources/AppIcon/manifest.json"
VARIANTS = (
    ("icon_16x16.png", 16, b"icp4"),
    ("icon_16x16@2x.png", 32, b"ic11"),
    ("icon_32x32.png", 32, b"icp5"),
    ("icon_32x32@2x.png", 64, b"ic12"),
    ("icon_128x128.png", 128, b"ic07"),
    ("icon_128x128@2x.png", 256, b"ic13"),
    ("icon_256x256.png", 256, b"ic08"),
    ("icon_256x256@2x.png", 512, b"ic14"),
    ("icon_512x512.png", 512, b"ic09"),
    ("icon_512x512@2x.png", 1024, b"ic10"),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def generate():
    from PIL import Image
    master = Image.open(SOURCE).convert("RGBA")
    if master.width != master.height or master.width < 1024:
        raise ValueError("Icon master must be square and at least 1024 pixels")
    ICONSET.mkdir(exist_ok=True)
    chunks, hashes = [], {}
    for name, size, kind in VARIANTS:
        buffer = io.BytesIO()
        master.resize((size, size), Image.Resampling.LANCZOS).save(buffer, format="PNG")
        data = buffer.getvalue()
        (ICONSET / name).write_bytes(data)
        hashes[name] = digest(data)
        chunks.append(kind + struct.pack(">I", len(data) + 8) + data)
    body = b"".join(chunks)
    ICNS.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    MANIFEST.write_text(json.dumps({"source_sha256": digest(SOURCE.read_bytes()),
                                   "png_sha256": hashes, "icns_sha256": digest(ICNS.read_bytes())}, indent=2) + "\n")


def png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Invalid PNG signature")
    offset, size = 8, None
    while offset < len(data):
        length, kind = struct.unpack(">I4s", data[offset:offset + 8])
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack(">I", data[offset + 8 + length:offset + 12 + length])[0]
        if zlib.crc32(kind + payload) != crc:
            raise ValueError("Invalid PNG checksum")
        if kind == b"IHDR":
            size = struct.unpack(">II", payload[:8])
            if payload[8:10] != bytes((8, 6)):
                raise ValueError("Icon PNG must contain 8-bit RGBA transparency")
        offset += length + 12
        if kind == b"IEND" and offset == len(data) and size:
            return size
    raise ValueError("Incomplete PNG")


def check(app=None):
    manifest = json.loads(MANIFEST.read_text())
    source = SOURCE.read_bytes()
    width, height = png_size(source)
    if width != height or width < 1024 or digest(source) != manifest["source_sha256"]:
        raise ValueError("Master changed; regenerate icon resources")
    data = ICNS.read_bytes()
    if data[:4] != b"icns" or struct.unpack(">I", data[4:8])[0] != len(data):
        raise ValueError("Invalid ICNS header")
    if digest(data) != manifest["icns_sha256"]:
        raise ValueError("ICNS does not match the resource manifest")
    offset = 8
    for name, size, kind in VARIANTS:
        png = (ICONSET / name).read_bytes()
        if png_size(png) != (size, size) or digest(png) != manifest["png_sha256"][name]:
            raise ValueError(f"Incorrect icon variant: {name}")
        actual_kind, length = struct.unpack(">4sI", data[offset:offset + 8])
        if actual_kind != kind or length != len(png) + 8 or data[offset + 8:offset + length] != png:
            raise ValueError(f"Missing or incorrect ICNS representation: {name}")
        offset += length
    if offset != len(data):
        raise ValueError("Unexpected trailing ICNS data")
    if app:
        contents = Path(app) / "Contents"
        plist = plistlib.loads((contents / "Info.plist").read_bytes())
        if plist.get("CFBundleIconFile") != "AppIcon.icns":
            raise ValueError("Bundle must declare CFBundleIconFile = AppIcon.icns")
        if (contents / "Resources/AppIcon.icns").read_bytes() != data:
            raise ValueError("Bundle is missing the current application icon")
    print("PASS: master, 10 PNG representations (16–1024px), ICNS and manifest" + ("; bundle icon verified" if app else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate without requiring Pillow or modifying resources")
    parser.add_argument("--app", type=Path, help="Also validate a built .app bundle")
    args = parser.parse_args()
    if not args.check:
        generate()
    check(args.app)
