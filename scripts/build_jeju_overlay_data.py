#!/usr/bin/env python3
"""Builds a lightweight Jeju contour + route overlay JSON for Flutter demo."""

from __future__ import annotations

import json
import math
import sqlite3
import struct
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
ROUTE_GPKG = ROOT / "test_data/씨투써밋 루트.gpkg"
CONTOUR_GPKG = ROOT / "test_data/씨투써밋 등고선 20 100.gpkg"
OUT_JSON = ROOT / "assets/data/jeju_overlay.json"


def _feature_table(conn: sqlite3.Connection) -> str:
    row = conn.execute(
        "SELECT table_name FROM gpkg_contents WHERE data_type='features' LIMIT 1"
    ).fetchone()
    if not row:
        raise RuntimeError("No features table found in GeoPackage")
    return row[0]


def _geom_column(conn: sqlite3.Connection, table: str) -> str:
    row = conn.execute(
        "SELECT column_name FROM gpkg_geometry_columns WHERE table_name=?",
        (table,),
    ).fetchone()
    if not row:
        raise RuntimeError(f"No geometry column found for table: {table}")
    return row[0]


def _pk_column(conn: sqlite3.Connection, table: str) -> str:
    for _, name, _, _, _, pk in conn.execute(f'PRAGMA table_info("{table}")'):
        if pk:
            return name
    raise RuntimeError(f"No primary key column found for table: {table}")


def _gpkg_blob_to_wkb(blob: bytes) -> bytes:
    if len(blob) < 8 or blob[0:2] != b"GP":
        raise RuntimeError("Invalid GeoPackage geometry blob")
    flags = blob[3]
    envelope_code = (flags >> 1) & 0x07
    envelope_bytes = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}.get(envelope_code)
    if envelope_bytes is None:
        raise RuntimeError(f"Unsupported envelope code: {envelope_code}")
    return blob[8 + envelope_bytes :]


def _parse_lines_from_wkb(data: bytes, offset: int = 0) -> tuple[list[list[tuple[float, float]]], int]:
    byte_order = data[offset]
    if byte_order not in (0, 1):
        raise RuntimeError("Invalid WKB byte order")
    little = byte_order == 1
    fmt_i = "<I" if little else ">I"
    fmt_d = "<d" if little else ">d"
    offset += 1

    geom_type = struct.unpack_from(fmt_i, data, offset)[0]
    offset += 4

    has_z = False
    has_m = False
    if geom_type >= 3000:
        base_type = geom_type - 3000
        has_z = True
        has_m = True
    elif geom_type >= 2000:
        base_type = geom_type - 2000
        has_m = True
    elif geom_type >= 1000:
        base_type = geom_type - 1000
        has_z = True
    else:
        base_type = geom_type

    if base_type == 2:  # LineString
        n = struct.unpack_from(fmt_i, data, offset)[0]
        offset += 4
        points: list[tuple[float, float]] = []
        for _ in range(n):
            x = struct.unpack_from(fmt_d, data, offset)[0]
            y = struct.unpack_from(fmt_d, data, offset + 8)[0]
            offset += 16
            if has_z:
                offset += 8
            if has_m:
                offset += 8
            points.append((x, y))
        return [points], offset

    if base_type == 5:  # MultiLineString
        n = struct.unpack_from(fmt_i, data, offset)[0]
        offset += 4
        lines: list[list[tuple[float, float]]] = []
        for _ in range(n):
            child, offset = _parse_lines_from_wkb(data, offset)
            lines.extend(child)
        return lines, offset

    raise RuntimeError(f"Unsupported base geometry type: {base_type}")


def _distance_sq_point_to_segment(p: tuple[float, float], a: tuple[float, float], b: tuple[float, float]) -> float:
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


def _simplify_line(points: list[tuple[float, float]], tolerance: float) -> list[tuple[float, float]]:
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


def _expand_bounds(bounds: tuple[float, float, float, float], margin: float) -> tuple[float, float, float, float]:
    min_x, min_y, max_x, max_y = bounds
    return min_x - margin, min_y - margin, max_x + margin, max_y + margin


def _round_line(line: Iterable[tuple[float, float]], digits: int = 2) -> list[list[float]]:
    return [[round(x, digits), round(y, digits)] for x, y in line]


# Korea 2000 / Unified Coordinate System parameters.
A = 6378137.0
F = 1.0 / 298.257222101
E2 = 2 * F - F * F
EP2 = E2 / (1.0 - E2)
K0 = 0.9996
LAT0 = math.radians(38.0)
LON0 = math.radians(127.5)
FALSE_EASTING = 1000000.0
FALSE_NORTHING = 2000000.0


def _meridional_arc(phi: float) -> float:
    e4 = E2 * E2
    e6 = e4 * E2
    return A * (
        (1 - E2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi
        - (3 * E2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * math.sin(2 * phi)
        + (15 * e4 / 256 + 45 * e6 / 1024) * math.sin(4 * phi)
        - (35 * e6 / 3072) * math.sin(6 * phi)
    )


M0 = _meridional_arc(LAT0)


def _lon_lat_to_unified(lon_deg: float, lat_deg: float) -> tuple[float, float]:
    phi = math.radians(lat_deg)
    lam = math.radians(lon_deg)
    sin_phi = math.sin(phi)
    cos_phi = math.cos(phi)
    tan_phi = math.tan(phi)

    n = A / math.sqrt(1.0 - E2 * sin_phi * sin_phi)
    t = tan_phi * tan_phi
    c = EP2 * cos_phi * cos_phi
    a_term = cos_phi * (lam - LON0)
    m = _meridional_arc(phi)

    x = FALSE_EASTING + K0 * n * (
        a_term
        + (1 - t + c) * (a_term**3) / 6
        + (5 - 18 * t + t * t + 72 * c - 58 * EP2) * (a_term**5) / 120
    )
    y = FALSE_NORTHING + K0 * (
        m
        - M0
        + n
        * tan_phi
        * (
            (a_term * a_term) / 2
            + (5 - t + 9 * c + 4 * c * c) * (a_term**4) / 24
            + (61 - 58 * t + t * t + 600 * c - 330 * EP2) * (a_term**6) / 720
        )
    )
    return x, y


def load_route_lines(route_gpkg: Path) -> list[list[tuple[float, float]]]:
    conn = sqlite3.connect(route_gpkg)
    try:
        table = _feature_table(conn)
        geom_col = _geom_column(conn, table)
        row = conn.execute(f'SELECT "{geom_col}" FROM "{table}" LIMIT 1').fetchone()
        if not row:
            raise RuntimeError("Route table has no rows")
        wkb = _gpkg_blob_to_wkb(row[0])
        lines_ll, _ = _parse_lines_from_wkb(wkb)
        projected = []
        for line in lines_ll:
            projected.append([_lon_lat_to_unified(lon, lat) for lon, lat in line])
        return projected
    finally:
        conn.close()


def compute_bounds(lines: Iterable[list[tuple[float, float]]]) -> tuple[float, float, float, float]:
    min_x = float("inf")
    min_y = float("inf")
    max_x = float("-inf")
    max_y = float("-inf")
    for line in lines:
        for x, y in line:
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    if min_x == float("inf"):
        raise RuntimeError("No coordinates available for bounds")
    return min_x, min_y, max_x, max_y


def load_contours(
    contour_gpkg: Path,
    query_bounds: tuple[float, float, float, float],
    simplify_minor: float,
    simplify_major: float,
) -> list[dict]:
    min_x, min_y, max_x, max_y = query_bounds
    conn = sqlite3.connect(contour_gpkg)
    try:
        table = _feature_table(conn)
        geom_col = _geom_column(conn, table)
        pk_col = _pk_column(conn, table)
        rtree = f"rtree_{table}_{geom_col}"
        sql = f"""
            SELECT d."{geom_col}", d.CONT
            FROM "{table}" d
            JOIN "{rtree}" r ON d."{pk_col}" = r.id
            WHERE r.maxx >= ? AND r.minx <= ? AND r.maxy >= ? AND r.miny <= ?
              AND CAST(d.CONT AS INTEGER) % 20 = 0
            ORDER BY d.CONT
        """
        rows = conn.execute(sql, (min_x, max_x, min_y, max_y))

        contours: list[dict] = []
        for geom_blob, elev in rows:
            wkb = _gpkg_blob_to_wkb(geom_blob)
            lines, _ = _parse_lines_from_wkb(wkb)
            elev_int = int(round(float(elev)))
            is_major = elev_int % 100 == 0
            tolerance = simplify_major if is_major else simplify_minor
            for line in lines:
                if len(line) < 2:
                    continue
                simplified = _simplify_line(line, tolerance)
                if len(simplified) < 2:
                    continue
                contours.append({"elev": elev_int, "line": simplified, "major": is_major})
        return contours
    finally:
        conn.close()


def main() -> None:
    route_lines = load_route_lines(ROUTE_GPKG)
    route_bounds = compute_bounds(route_lines)
    contour_query_bounds = _expand_bounds(route_bounds, margin=4000.0)
    view_bounds = _expand_bounds(route_bounds, margin=2500.0)

    contours = load_contours(
        CONTOUR_GPKG,
        query_bounds=contour_query_bounds,
        simplify_minor=12.0,
        simplify_major=8.0,
    )

    output = {
        "crs": "Korea_2000_Korea_Unified_Coordinate_System",
        "units": "meter",
        "bounds": [round(v, 2) for v in view_bounds],
        "route": [_round_line(line) for line in route_lines],
        "contours": [
            {
                "elev": item["elev"],
                "major": item["major"],
                "line": _round_line(item["line"]),
            }
            for item in contours
        ],
    }

    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(json.dumps(output, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")

    contour_points = sum(len(item["line"]) for item in contours)
    route_points = sum(len(line) for line in route_lines)
    print(f"Wrote: {OUT_JSON}")
    print(f"Contours: {len(contours)} lines, {contour_points} points")
    print(f"Route: {len(route_lines)} lines, {route_points} points")


if __name__ == "__main__":
    main()
