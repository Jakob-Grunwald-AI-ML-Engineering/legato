#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.14.5"
# dependencies = ["Pillow==12.1.1"]
# ///
# pyright: strict
"""Compare light key faces and letter ink in matching iPhone 17 simulator captures.

Usage: uv run scripts/e2e/keyboard-geometry.py native.png legato.png
AX frames are deliberately excluded: Apple's AX cells include inter-key space,
whereas Legato exposes the drawn key. Screen captures compare like with like.
"""

import argparse
import json
from pathlib import Path
from typing import Protocol, TypedDict, cast

from PIL import Image


class RGBPixels(Protocol):
    def __getitem__(self, point: tuple[int, int]) -> tuple[int, int, int]: ...


class Arguments(argparse.Namespace):
    native: Path
    legato: Path
    tolerance: float
    glyph_dimensions: str


class Measurements(TypedDict):
    row_bands_pt: list[tuple[float, float]]
    first_row_faces_x_pt: list[tuple[float, float]]
    # Ink top, bottom and width relative to each detected white key face.
    glyph_ink_pt: list[tuple[float, float, float]]


def runs(values: list[int], minimum: float) -> list[tuple[int, int]]:
    groups: list[tuple[int, int]] = []
    for value in values:
        if groups and groups[-1][1] == value:
            groups[-1] = (groups[-1][0], value + 1)
        else:
            groups.append((value, value + 1))
    return [(start, end) for start, end in groups if end - start >= minimum]


def measure(path: Path) -> Measurements:
    with Image.open(path) as source:
        image = source.convert("RGB")
    landscape = image.width > image.height
    reference_width, reference_height = (874, 402) if landscape else (402, 874)
    scale = image.width / reference_width
    if image.height / scale != reference_height:
        raise ValueError(f"{path}: expected 402 x 874 pt portrait or 874 x 402 pt landscape")
    pixels = cast(RGBPixels, image.load())
    # Restrict to the four key rows; omit the white host and system globe area.
    start, end = (0.59, 0.945) if landscape else (0.64, 0.92)
    white_rows = [
        y for y in range(round(image.height * start), round(image.height * end))
        if sum(min(pixels[x, y]) > 245 for x in range(round(6 * scale), image.width - round(6 * scale)))
        > image.width * 0.22
    ]
    bands = runs(white_rows, 20 * scale)
    if len(bands) != 4:
        raise ValueError(f"{path}: expected four white key-face bands, found {len(bands)}")
    # Landscape capitals reach higher; scan above their ink. Portrait has more space.
    face_scan_depth = 2 if landscape else 5
    first_row_y = bands[0][0] + round(face_scan_depth * scale)
    columns = runs([x for x in range(image.width) if min(pixels[x, first_row_y]) > 245], 20 * scale)
    if len(columns) != 10:
        raise ValueError(f"{path}: expected ten first-row keys, found {len(columns)}")
    glyphs: list[tuple[float, float, float]] = []
    # QWERTY and ASDF rows only: omit modifiers and symbols. Matching case is a
    # capture prerequisite, not inferred from OCR or from Legato's constants.
    for row_index, expected_keys in [(0, 10), (1, 9)]:
        top, bottom = bands[row_index]
        scan_y = top + round(face_scan_depth * scale)
        faces = runs([x for x in range(image.width) if min(pixels[x, scan_y]) > 245], 20 * scale)
        if len(faces) != expected_keys:
            raise ValueError(f"{path}: unexpected key count in row {row_index + 1}")
        for left, right in faces:
            ink = [(x, y) for x in range(left + round(3 * scale), right - round(3 * scale))
                   for y in range(top + round(5 * scale), bottom - round(4 * scale))
                   if max(pixels[x, y]) < 100]
            if not ink:
                raise ValueError(f"{path}: missing dark letter ink")
            xs, ys = zip(*ink, strict=True)
            glyphs.append(((min(ys) - top) / scale, (max(ys) + 1 - top) / scale,
                           (max(xs) + 1 - min(xs)) / scale))
    return {
        "glyph_ink_pt": glyphs,
        "row_bands_pt": [(start / scale, end / scale) for start, end in bands],
        "first_row_faces_x_pt": [(start / scale, end / scale) for start, end in columns],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native", type=Path)
    parser.add_argument("legato", type=Path)
    parser.add_argument("--tolerance", type=float, default=1.0, help="maximum edge difference in points")
    parser.add_argument("--glyph-dimensions", choices=["all", "vertical"], default="all",
                        help="vertical checks ink top/bottom and reports width separately; all also gates width")
    args = parser.parse_args(namespace=Arguments())
    native, legato = measure(args.native), measure(args.legato)
    differences = {
        key: max(abs(a - b) for left, right in zip(native[key], legato[key], strict=True)
                 for a, b in zip(left, right, strict=True))
        for key in ("glyph_ink_pt", "row_bands_pt", "first_row_faces_x_pt")
    }
    vertical_difference = max(abs(a - b)
                              for left, right in zip(native["glyph_ink_pt"], legato["glyph_ink_pt"], strict=True)
                              for a, b in zip(left[:2], right[:2], strict=True))
    width_difference = max(abs(left[2] - right[2])
                           for left, right in zip(native["glyph_ink_pt"], legato["glyph_ink_pt"], strict=True))
    glyph_difference = vertical_difference if args.glyph_dimensions == "vertical" else differences["glyph_ink_pt"]
    passed = max(glyph_difference, differences["row_bands_pt"], differences["first_row_faces_x_pt"]) <= args.tolerance
    print(json.dumps({"native": native, "legato": legato, "max_edge_difference_pt": differences,
                      "glyph_vertical_difference_pt": vertical_difference,
                      "glyph_width_difference_pt": width_difference,
                      "checked_glyph_dimensions": args.glyph_dimensions,
                      "tolerance_pt": args.tolerance, "passed": passed}, indent=2))
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
