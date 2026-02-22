#!/usr/bin/env python3
"""Builds multi-region contour overlay JSON assets from shapefile + dbf."""

from __future__ import annotations

import json
import math
import struct
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
CONTOUR_ROOT = ROOT / "contours"
ASSET_ROOT = ROOT / "assets/data"

REGIONS = [
    {
        "id": "incheon_base",
        "name": "인천",
        "asset": "assets/data/incheon_overlay.json",
        "codes": ["28"],
    },
    {
        "id": "sejong_base",
        "name": "세종",
        "asset": "assets/data/sejong_overlay.json",
        "codes": ["36"],
    },
    {
        "id": "ulsan_base",
        "name": "울산",
        "asset": "assets/data/ulsan_overlay.json",
        "codes": ["31"],
    },
    {
        "id": "chungbuk_base",
        "name": "충북",
        "asset": "assets/data/chungbuk_overlay.json",
        "codes": ["43_A", "43_B"],
    },
    {
        "id": "chungnam_base",
        "name": "충남",
        "asset": "assets/data/chungnam_overlay.json",
        "codes": ["44_A", "44_B"],
    },
    {
        "id": "jeonbuk_base",
        "name": "전북특별자치도",
        "asset": "assets/data/jeonbuk_overlay.json",
        "codes": ["52_A", "52_B"],
    },
    {
        "id": "jeonnam_base",
        "name": "전남",
        "asset": "assets/data/jeonnam_overlay.json",
        "codes": ["46_A", "46_B", "46_C"],
    },
]


def _simplify_line_fast(
    points: list[tuple[float, float]],
    min_spacing: float,
    max_points: int,
) -> list[tuple[float, float]]:
    if len(points) <= 2:
        return points

    spacing_sq = min_spacing * min_spacing

    simplified: list[tuple[float, float]] = [points[0]]
    last_x, last_y = points[0]
    for x, y in points[1:-1]:
        dx = x - last_x
        dy = y - last_y
        if dx * dx + dy * dy >= spacing_sq:
            simplified.append((x, y))
            last_x, last_y = x, y

    if simplified[-1] != points[-1]:
        simplified.append(points[-1])

    if len(simplified) <= max_points:
        return simplified

    # Keep overall shape with uniform down-sampling after spacing filter.
    step = int(math.ceil((len(simplified) - 2) / (max_points - 2)))
    if step < 1:
        step = 1
    trimmed = [simplified[0]]
    trimmed.extend(simplified[i] for i in range(1, len(simplified) - 1, step))
    if trimmed[-1] != simplified[-1]:
        trimmed.append(simplified[-1])
    return trimmed


def _round_line(
    line: Iterable[tuple[float, float]], digits: int = 2
) -> list[list[float]]:
    return [[round(x, digits), round(y, digits)] for x, y in line]


def _find_shp(code: str) -> Path:
    matches = sorted(CONTOUR_ROOT.glob(f"**/N3L_F0010000_{code}.shp"))
    if not matches:
        raise RuntimeError(f"Missing shapefile for code: {code}")
    if len(matches) > 1:
        raise RuntimeError(
            f"Ambiguous shapefile for code {code}: {[str(m) for m in matches]}"
        )
    return matches[0]


def read_dbf_contours(path: Path) -> list[int]:
    with path.open("rb") as f:
        header = f.read(32)
        num_records = struct.unpack("<I", header[4:8])[0]
        header_len = struct.unpack("<H", header[8:10])[0]
        record_len = struct.unpack("<H", header[10:12])[0]

        f.seek(32)
        fields: list[tuple[str, str, int, int]] = []
        while True:
            desc = f.read(32)
            if not desc:
                raise RuntimeError("Unexpected EOF while reading DBF fields")
            if desc[0] == 0x0D:
                break
            name = desc[:11].split(b"\x00", 1)[0].decode("ascii", "ignore")
            field_type = chr(desc[11])
            field_len = desc[16]
            decimals = desc[17]
            fields.append((name, field_type, field_len, decimals))

        cont_idx = next(
            (i for i, fd in enumerate(fields) if fd[0].upper() == "CONT"), None
        )
        if cont_idx is None:
            raise RuntimeError(f"DBF field CONT not found: {path}")

        f.seek(header_len)
        contours: list[int] = []
        for _ in range(num_records):
            rec = f.read(record_len)
            if len(rec) < record_len:
                break
            if rec[0] == 0x2A:
                contours.append(0)
                continue
            pos = 1
            cont_raw = ""
            for idx, (_, _, flen, _) in enumerate(fields):
                txt = rec[pos : pos + flen].decode("ascii", "ignore").strip()
                if idx == cont_idx:
                    cont_raw = txt
                pos += flen
            try:
                contours.append(int(round(float(cont_raw))))
            except ValueError:
                contours.append(0)
    return contours


def read_shp_polylines(
    path: Path,
) -> tuple[tuple[float, float, float, float], list[list[list[tuple[float, float]]]]]:
    with path.open("rb") as f:
        header = f.read(100)
        if len(header) < 100:
            raise RuntimeError(f"Invalid shapefile header: {path}")
        shape_type = struct.unpack("<i", header[32:36])[0]
        if shape_type not in (3, 13, 23):
            raise RuntimeError(f"Unsupported shapefile type: {shape_type} ({path})")

        min_x, min_y, max_x, max_y = struct.unpack("<4d", header[36:68])

        shapes: list[list[list[tuple[float, float]]]] = []
        while True:
            rec_header = f.read(8)
            if not rec_header or len(rec_header) < 8:
                break
            _, content_len_words = struct.unpack(">2i", rec_header)
            content_bytes = content_len_words * 2
            content = f.read(content_bytes)
            if len(content) < content_bytes:
                break

            rec_shape_type = struct.unpack("<i", content[0:4])[0]
            if rec_shape_type == 0:
                shapes.append([])
                continue
            if rec_shape_type not in (3, 13, 23):
                shapes.append([])
                continue

            num_parts = struct.unpack("<i", content[36:40])[0]
            num_points = struct.unpack("<i", content[40:44])[0]
            parts = list(
                struct.unpack(f"<{num_parts}i", content[44 : 44 + 4 * num_parts])
            )
            points_off = 44 + 4 * num_parts

            points: list[tuple[float, float]] = []
            for i in range(num_points):
                x, y = struct.unpack(
                    "<2d", content[points_off + i * 16 : points_off + (i + 1) * 16]
                )
                points.append((x, y))

            lines: list[list[tuple[float, float]]] = []
            for i, start in enumerate(parts):
                end = parts[i + 1] if i + 1 < len(parts) else num_points
                line = points[start:end]
                if len(line) >= 2:
                    lines.append(line)
            shapes.append(lines)

    return (min_x, min_y, max_x, max_y), shapes


def _merge_bounds(
    a: tuple[float, float, float, float] | None, b: tuple[float, float, float, float]
) -> tuple[float, float, float, float]:
    if a is None:
        return b
    return (
        min(a[0], b[0]),
        min(a[1], b[1]),
        max(a[2], b[2]),
        max(a[3], b[3]),
    )


def build_region(region: dict[str, object]) -> None:
    name = str(region["name"])
    asset = str(region["asset"])
    codes = list(region["codes"])  # type: ignore[arg-type]

    all_lines: list[dict[str, object]] = []
    merged_bounds: tuple[float, float, float, float] | None = None

    for code in codes:
        shp = _find_shp(str(code))
        dbf = shp.with_suffix(".dbf")
        if not dbf.exists():
            raise RuntimeError(f"Missing DBF pair for {shp}")

        bounds, shapes = read_shp_polylines(shp)
        contours = read_dbf_contours(dbf)
        if len(contours) < len(shapes):
            contours.extend([0] * (len(shapes) - len(contours)))

        merged_bounds = _merge_bounds(merged_bounds, bounds)

        for idx, lines in enumerate(shapes):
            elev = contours[idx]
            if elev % 20 != 0:
                continue
            is_major = elev % 100 == 0
            min_spacing = 22.0 if is_major else 32.0
            max_points = 150 if is_major else 110
            for line in lines:
                simplified = _simplify_line_fast(
                    line,
                    min_spacing=min_spacing,
                    max_points=max_points,
                )
                if len(simplified) < 2:
                    continue
                all_lines.append(
                    {
                        "elev": int(elev),
                        "major": is_major,
                        "line": _round_line(simplified),
                    }
                )

    if merged_bounds is None:
        raise RuntimeError(f"No bounds parsed for region: {name}")

    min_x, min_y, max_x, max_y = merged_bounds
    output = {
        "crs": "Korea_2000_Korea_Unified_Coordinate_System",
        "units": "meter",
        "bounds": [
            round(min_x - 2000, 2),
            round(min_y - 2000, 2),
            round(max_x + 2000, 2),
            round(max_y + 2000, 2),
        ],
        "route": [],
        "contours": all_lines,
    }

    out_path = ROOT / asset
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(output, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    points = sum(len(item["line"]) for item in all_lines)
    print(f"[{name}] wrote: {out_path}", flush=True)
    print(f"[{name}] contours: {len(all_lines)} lines, {points} points", flush=True)
    print(f"[{name}] bounds: {output['bounds']}", flush=True)


def main() -> None:
    for region in REGIONS:
        build_region(region)


if __name__ == "__main__":
    main()
