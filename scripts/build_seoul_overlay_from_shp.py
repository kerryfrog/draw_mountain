#!/usr/bin/env python3
"""Builds Seoul contour overlay JSON from shapefile + dbf."""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
SEOUL_SHP = ROOT / "contours/N3L_F0010000_서울/N3L_F0010000_11.shp"
SEOUL_DBF = ROOT / "contours/N3L_F0010000_서울/N3L_F0010000_11.dbf"
OUT_JSON = ROOT / "assets/data/seoul_overlay.json"


def _distance_sq_point_to_segment(
    p: tuple[float, float], a: tuple[float, float], b: tuple[float, float]
) -> float:
    px, py = p
    ax, ay = a
    bx, by = b
    dx = bx - ax
    dy = by - ay
    if dx == 0 and dy == 0:
        return (px - ax) ** 2 + (py - ay) ** 2
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    qx = ax + t * dx
    qy = ay + t * dy
    return (px - qx) ** 2 + (py - qy) ** 2


def _simplify_line(
    points: list[tuple[float, float]], tolerance: float
) -> list[tuple[float, float]]:
    if len(points) <= 2:
        return points

    tol_sq = tolerance * tolerance
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]

    while stack:
        i, j = stack.pop()
        a = points[i]
        b = points[j]
        max_dist_sq = -1.0
        max_idx = -1
        for k in range(i + 1, j):
            dist_sq = _distance_sq_point_to_segment(points[k], a, b)
            if dist_sq > max_dist_sq:
                max_dist_sq = dist_sq
                max_idx = k
        if max_dist_sq > tol_sq and max_idx != -1:
            keep[max_idx] = True
            stack.append((i, max_idx))
            stack.append((max_idx, j))

    return [pt for idx, pt in enumerate(points) if keep[idx]]


def _round_line(line: Iterable[tuple[float, float]], digits: int = 2) -> list[list[float]]:
    return [[round(x, digits), round(y, digits)] for x, y in line]


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

        cont_idx = next((i for i, fd in enumerate(fields) if fd[0].upper() == "CONT"), None)
        if cont_idx is None:
            raise RuntimeError("DBF field CONT not found")

        f.seek(header_len)
        contours: list[int] = []
        for _ in range(num_records):
            rec = f.read(record_len)
            if len(rec) < record_len:
                break
            if rec[0] == 0x2A:  # deleted
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


def read_shp_polylines(path: Path) -> tuple[tuple[float, float, float, float], list[list[list[tuple[float, float]]]]]:
    with path.open("rb") as f:
        header = f.read(100)
        if len(header) < 100:
            raise RuntimeError("Invalid shapefile header")
        shape_type = struct.unpack("<i", header[32:36])[0]
        if shape_type not in (3, 13, 23):
            raise RuntimeError(f"Unsupported shapefile type: {shape_type}")

        min_x, min_y, max_x, max_y = struct.unpack("<4d", header[36:68])

        shapes: list[list[list[tuple[float, float]]]] = []
        while True:
            rec_header = f.read(8)
            if not rec_header:
                break
            if len(rec_header) < 8:
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
            parts = list(struct.unpack(f"<{num_parts}i", content[44 : 44 + 4 * num_parts]))
            points_off = 44 + 4 * num_parts

            points: list[tuple[float, float]] = []
            for i in range(num_points):
                x, y = struct.unpack("<2d", content[points_off + i * 16 : points_off + (i + 1) * 16])
                points.append((x, y))

            lines: list[list[tuple[float, float]]] = []
            for i, start in enumerate(parts):
                end = parts[i + 1] if i + 1 < len(parts) else num_points
                line = points[start:end]
                if len(line) >= 2:
                    lines.append(line)
            shapes.append(lines)

    return (min_x, min_y, max_x, max_y), shapes


def build_overlay(
    shp_path: Path,
    dbf_path: Path,
    out_json: Path,
    *,
    elev_step: int,
    major_step: int,
    major_tolerance: float,
    minor_tolerance: float,
    bounds_padding: float,
) -> None:
    bounds, shapes = read_shp_polylines(shp_path)
    contours = read_dbf_contours(dbf_path)
    if len(contours) < len(shapes):
        contours.extend([0] * (len(shapes) - len(contours)))

    output_lines = []
    for idx, lines in enumerate(shapes):
        elev = contours[idx]
        if elev_step > 0 and elev % elev_step != 0:
            continue
        is_major = major_step > 0 and elev % major_step == 0
        tolerance = major_tolerance if is_major else minor_tolerance
        for line in lines:
            simplified = _simplify_line(line, tolerance)
            if len(simplified) < 2:
                continue
            output_lines.append(
                {
                    "elev": int(elev),
                    "major": is_major,
                    "line": _round_line(simplified),
                }
            )

    min_x, min_y, max_x, max_y = bounds
    output = {
        "crs": "Korea_2000_Korea_Unified_Coordinate_System",
        "units": "meter",
        "bounds": [
            round(min_x - bounds_padding, 2),
            round(min_y - bounds_padding, 2),
            round(max_x + bounds_padding, 2),
            round(max_y + bounds_padding, 2),
        ],
        "route": [],
        "contours": output_lines,
    }

    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(
        json.dumps(output, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    points = sum(len(item["line"]) for item in output_lines)
    print(f"Wrote: {out_json}")
    print(f"Contours: {len(output_lines)} lines, {points} points")
    print(f"Bounds: {output['bounds']}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build contour overlay JSON from shapefile + dbf."
    )
    parser.add_argument("--shp", type=Path, default=SEOUL_SHP)
    parser.add_argument("--dbf", type=Path, default=SEOUL_DBF)
    parser.add_argument("--out", type=Path, default=OUT_JSON)
    parser.add_argument("--elev-step", type=int, default=20)
    parser.add_argument("--major-step", type=int, default=100)
    parser.add_argument("--major-tolerance", type=float, default=8.0)
    parser.add_argument("--minor-tolerance", type=float, default=12.0)
    parser.add_argument("--bounds-padding", type=float, default=2000.0)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    build_overlay(
        shp_path=args.shp,
        dbf_path=args.dbf,
        out_json=args.out,
        elev_step=args.elev_step,
        major_step=args.major_step,
        major_tolerance=args.major_tolerance,
        minor_tolerance=args.minor_tolerance,
        bounds_padding=args.bounds_padding,
    )


if __name__ == "__main__":
    main()
