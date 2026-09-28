#!/usr/bin/env python3
# Generate the synthetic /rs-test/ corpus used by the Round Sync second-development acceptance matrix.
# Every image is a real encoded file; no file is produced by renaming another format.
#
#   py -3 scripts/make-test-corpus.py --out D:/Development/RoundSyncTestAssets
#
# Writes <out>/rs-test/ plus <out>/rs-test/manifest.json (path, size, sha256).

import argparse
import hashlib
import json
import random
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

from PIL import Image
import pillow_heif

pillow_heif.register_heif_opener()

SCHEMA_VERSION = 1
NOISE_SEED = 20260928


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def noise(size, seed=NOISE_SEED):
    # randbytes keeps this C-level: building 24 M pixels in a Python loop is unusably slow.
    raw = random.Random(seed).randbytes(size[0] * size[1] * 3)
    return Image.frombytes("RGB", size, raw)


def gradient(size, alpha=False):
    """Bright, orientation-detectable test image.

    A dark fixture cannot be told apart from a decode failure on a small card, so every
    sample carries four saturated quadrants plus a gold top band and a magenta right band:
    a wrong EXIF rotation is visible immediately (the bands move).
    """
    from PIL import ImageDraw

    w, h = size
    img = Image.new("RGB", size, (235, 235, 230))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w // 2, h // 2], fill=(220, 40, 40))
    d.rectangle([w // 2, 0, w, h // 2], fill=(40, 160, 60))
    d.rectangle([0, h // 2, w // 2, h], fill=(40, 80, 220))
    d.rectangle([w // 2, h // 2, w, h], fill=(250, 200, 40))
    d.rectangle([0, 0, w, max(h // 12, 2)], fill=(255, 215, 0))            # top edge marker
    d.rectangle([w - max(w // 12, 2), 0, w, h], fill=(200, 0, 200))        # right edge marker
    if alpha:
        img = img.convert("RGBA")
        # left half opaque, right half fully transparent
        img.putalpha(Image.eval(Image.new("L", size, 255), lambda v: v))
        mask = Image.new("L", size, 255)
        ImageDraw.Draw(mask).rectangle([w // 2, 0, w, h], fill=0)
        img.putalpha(mask)
    return img


def exif_with_orientation(orientation):
    exif = Image.Exif()
    exif[274] = orientation  # 0x0112 Orientation
    return exif.tobytes()


def save(img, path: Path, fmt=None, **kw):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, fmt, **kw)
    return path


def build_images(root: Path, entries: list):
    def note(path, kind, case, note=""):
        entries.append({
            "path": path.relative_to(root).as_posix(),
            "kind": kind,
            "case": case,
            "note": note,
        })

    inbox = root / "inbox"

    note(save(gradient((640, 480)), inbox / "IMG_0001_baseline.jpg", quality=90, progressive=False, subsampling=0),
         "image/jpeg", "A01", "baseline DCT JPEG")
    note(save(gradient((640, 480)), inbox / "IMG_0002_progressive.jpg", progressive=True, quality=90),
         "image/jpeg", "A01", "progressive JPEG")
    note(save(gradient((640, 480)), inbox / "IMG_0003_UPPER.JPG", quality=88, progressive=False),
         "image/jpeg", "A04", "uppercase extension")
    note(save(gradient((512, 512), alpha=True), inbox / "alpha.png"), "image/png", "A01", "PNG with alpha")
    note(save(gradient((512, 512)), inbox / "lossy.webp", quality=80), "image/webp", "A01", "lossy WebP")
    note(save(gradient((256, 256)), inbox / "lossless.webp", lossless=True), "image/webp", "A01", "lossless WebP")
    note(save(gradient((600, 600)), inbox / "pixel.bmp"), "image/bmp", "A01", "uncompressed BMP")

    frames = [Image.new("RGB", (200, 200), c) for c in ((220, 40, 40), (40, 160, 60), (40, 80, 220), (250, 200, 40))]
    gif = root / "inbox" / "anim.gif"
    gif.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(gif, save_all=True, append_images=frames[1:], duration=200, loop=0)
    note(gif, "image/gif", "A02", "4 frame animated GIF")

    heic_plain = save(gradient((800, 600)), inbox / "IMG_1000.heic", "HEIF", quality=75)
    note(heic_plain, "image/heic", "A03", "real HEVC/HEIC, no orientation tag")
    heic_rot = save(gradient((800, 600)), inbox / "IMG_1001.heic", "HEIF", quality=75,
                    exif=exif_with_orientation(6))
    note(heic_rot, "image/heic", "A03", "real HEIC with EXIF Orientation=6 (90 CW)")
    note(save(gradient((640, 640)), inbox / "IMG_1002.HEIC", "HEIF", quality=70),
         "image/heic", "A04", "uppercase extension + HEIC")
    note(save(gradient((640, 480)), inbox / "clip_1003.heif", "HEIF", quality=70),
         "image/heif", "A03", "lowercase .heif name; libheif still writes a heic brand")

    try:
        save(gradient((512, 512)), inbox / "sample.avif", "AVIF", quality=60)
        note(inbox / "sample.avif", "image/avif", "A05", "real AVIF; needs Android 14+ to decode")
    except Exception as exc:  # encoder may be absent in this libheif build
        note(None, "image/avif", "A05", f"AVIF not generated here: {exc}")

    big = save(noise((6000, 4000), 11), inbox / "big_over_budget.jpg", quality=100, subsampling=0, optimize=False)
    note(big, "image/jpeg", "A07", "over the 32 MiB preview read budget")
    note(save(gradient((8000, 8000)), inbox / "huge_pixels.png", optimize=True),
         "image/png", "A07", "small file, 64 MP decoded size")

    good = inbox / "IMG_0001_baseline.jpg"
    trunc = inbox / "truncated.jpg"
    trunc.write_bytes(good.read_bytes()[: good.stat().st_size // 3])
    note(trunc, "image/jpeg", "A06", "file cut short, decoder must not hang")
    note(save(gradient((300, 300)), inbox / "not_really.heic", "HEIF", quality=60),
         "image/heic", "A06", "HEIC container, valid")
    bogus = inbox / "mislabeled_jpg_named.heic"
    bogus.write_bytes(good.read_bytes())
    note(bogus, "image/jpeg", "A06", "JPEG bytes with .heic name: extension must not win over content")
    note(save(gradient((64, 64)), inbox / "no_extension", "PNG"), "unknown", "A04",
         "no dot in name; PNG content")
    note(save(gradient((64, 64)), inbox / "octet_named.bin", "PNG"), "application/octet-stream", "A04",
         "server reports octet-stream by extension")

    base = {"nfc": unicodedata.normalize("NFC", "café-nfc.jpg"),
            "nfd": unicodedata.normalize("NFD", "café-nfd.jpg")}
    for name, case in [
        ("-dash-leading.jpg", "C11"),
        ("plus+sign.jpg", "C11"),
        ("hash#tag.jpg", "C11"),
        ("percent%2Fliteral.jpg", "C11"),
        ("percent-encoded.jpg", "C11"),
        ("space in name.jpg", "C11"),
        ("single'quote.jpg", "C11"),
        (base["nfc"], "C11"),
        (base["nfd"], "C11"),
        ("中文 空格.jpg", "C11"),
        ("😀emoji.jpg", "C11"),
        ("ampersand&and.jpg", "C11"),
        ("paren (1).jpg", "C11"),
        ("at@sign.jpg", "C11"),
    ]:
        src = gradient((320, 240))
        p = inbox / name
        p.parent.mkdir(parents=True, exist_ok=True)
        src.save(p, "JPEG", quality=80)
        note(p, "image/jpeg", case, "special character handling")

    weird_dir = root / "paths" / "中文 空格+百分号%井号#😀"
    weird_dir.mkdir(parents=True, exist_ok=True)
    d = weird_dir / "中文 空格+井号#😀.jpg"
    gradient((320, 240)).save(d, "JPEG", quality=80)
    note(d, "image/jpeg", "C11", "whole directory name is special")

    nested = inbox / "subdir-nested" / "deeper"
    nested.mkdir(parents=True, exist_ok=True)
    for i in range(3):
        p = nested / f"deep_{i}.jpg"
        gradient((200, 200)).save(p, "JPEG", quality=80)
        note(p, "image/jpeg", "C09", "nested listing")

    (inbox / "empty-subdir").mkdir(parents=True, exist_ok=True)

    # 1000-item directory for the 10k filter benchmark (B07) and batch tests (D02)
    bulk = root / "bulk" / "b1000"
    bulk.mkdir(parents=True, exist_ok=True)
    tiny = gradient((32, 32))
    for i in range(1000):
        tiny.save(bulk / f"BULK_{i:04d}.jpg", "JPEG", quality=60)
    note(bulk / "BULK_0000.jpg", "image/jpeg", "B07/D02", "one of 1000 bulk files")


def build_conflicts(root: Path, entries: list):
    src = root / "inbox" / "IMG_0001_baseline.jpg"
    tgt = root / "target-conflicts"
    tgt.mkdir(parents=True, exist_ok=True)

    same_name_diff = tgt / "IMG_0001_baseline.jpg"
    save(noise((640, 480), 99), same_name_diff, "JPEG", quality=70)
    entries.append({"path": same_name_diff.relative_to(root).as_posix(), "kind": "image/jpeg",
                    "case": "D03/D04", "note": "same name as inbox file, different bytes"})

    same_name_same = tgt / "IMG_0002_progressive.jpg"
    same_name_same.write_bytes((root / "inbox" / "IMG_0002_progressive.jpg").read_bytes())
    entries.append({"path": same_name_same.relative_to(root).as_posix(), "kind": "image/jpeg",
                    "case": "D03", "note": "same name and identical bytes: still must not be treated as removable"})

    (root / "target-empty").mkdir(parents=True, exist_ok=True)
    readonly = root / "target-readonly"
    readonly.mkdir(parents=True, exist_ok=True)
    save(gradient((100, 100)), readonly / "occupied.jpg", "JPEG", quality=60)
    # Write refusal for target-readonly/ is enforced by tools/webdavtest, not by NTFS ACLs.
    entries.append({"path": "target-readonly", "kind": "directory", "case": "D10",
                    "note": "server must answer 403 for writes under this prefix"})


def build_video(root: Path, entries: list):
    """Real short H.264 MP4 via the ffmpeg binary bundled with imageio-ffmpeg, if available."""
    try:
        import imageio_ffmpeg
    except ImportError:
        entries.append({"path": None, "kind": "video/mp4", "case": "D11",
                        "note": "skipped: pip install imageio-ffmpeg then re-run"})
        return
    exe = imageio_ffmpeg.get_ffmpeg_exe()
    out = root / "inbox" / "clip_0001.mp4"
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        frame = Path(td) / "f.png"
        gradient((320, 240)).save(frame, "PNG")
        cmd = [exe, "-y", "-loop", "1", "-i", str(frame), "-t", "2", "-r", "10",
               "-pix_fmt", "yuv420p", "-c:v", "libx264", str(out)]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0 or not out.exists() or out.stat().st_size == 0:
            entries.append({"path": None, "kind": "video/mp4", "case": "D11",
                            "note": f"ffmpeg failed: {proc.stderr[-300:]}"})
            return
    entries.append({"path": out.relative_to(root).as_posix(), "kind": "video/mp4", "case": "D11/A01",
                    "note": "2 s H.264 MP4 for the no-download-on-move test"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="directory that will contain rs-test/")
    args = ap.parse_args()

    root = Path(args.out) / "rs-test"
    root.mkdir(parents=True, exist_ok=True)
    entries = []

    build_images(root, entries)
    build_conflicts(root, entries)
    build_video(root, entries)

    manifest = {"schemaVersion": SCHEMA_VERSION, "generator": "scripts/make-test-corpus.py",
                "directories": [], "files": []}
    for e in entries:
        if e["kind"] == "directory":
            manifest["directories"].append(e)
            continue
        p = root / e["path"] if e.get("path") else None
        if p and p.is_file():
            manifest["files"].append({
                "path": e["path"],
                "kind": e["kind"],
                "case": e["case"],
                "note": e["note"],
                "size": p.stat().st_size,
                "sha256": sha256(p),
            })
        elif e.get("path"):
            manifest["files"].append({**e, "size": None, "sha256": None, "missing": True})
        else:
            manifest["files"].append({**e, "size": None, "sha256": None, "missing": True})

    skipped = [f for f in manifest["files"] if f.get("missing")]
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    total = sum(f["size"] or 0 for f in manifest["files"])
    print(f"corpus: {root}")
    print(f"files listed with hashes: {len(manifest['files']) - len(skipped)}, missing/skipped: {len(skipped)}, "
          f"bytes: {total} ({total / 1024 / 1024:.1f} MiB)")
    for f in skipped:
        print(f"  SKIP [{f['case']}] {f['note']}")
    print("NTFS cannot hold a file name containing a double quote: that C11 case must be seeded server side.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
