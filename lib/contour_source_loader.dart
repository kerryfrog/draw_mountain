import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;

const _manifestAssetPath = 'assets/data/contour_sources_manifest.json';

class ContourSource {
  const ContourSource({
    required this.id,
    required this.name,
    required this.assetPath,
  });

  final String id;
  final String name;
  final String assetPath;
}

class LoadedContourData {
  const LoadedContourData({required this.bounds, required this.contours});

  final Rect bounds;
  final List<LoadedContourLine> contours;
}

class LoadedContourLine {
  const LoadedContourLine({
    required this.elevation,
    required this.major,
    required this.line,
  });

  final int elevation;
  final bool major;
  final List<Offset> line;
}

class _ContourCacheEntry {
  const _ContourCacheEntry({required this.bounds, required this.contours});

  final Rect bounds;
  final List<LoadedContourLine> contours;
}

final Map<String, _ContourCacheEntry> _cache = {};

Future<List<ContourSource>> discoverContourSources() async {
  try {
    final raw = await rootBundle.loadString(_manifestAssetPath);
    final json = jsonDecode(raw);
    final list = (json as List<dynamic>).cast<Map<String, dynamic>>();

    final sources = list
        .map(
          (item) => ContourSource(
            id: (item['id'] as String?) ?? '',
            name: (item['name'] as String?) ?? '',
            assetPath: (item['asset'] as String?) ?? '',
          ),
        )
        .where((source) => source.id.isNotEmpty && source.assetPath.isNotEmpty)
        .toList(growable: false);

    return sources;
  } catch (_) {
    return const [];
  }
}

Future<LoadedContourData> loadContourSource({
  required ContourSource source,
  Rect? clipBounds,
}) async {
  final cached = await _loadAndCache(source);
  if (clipBounds == null) {
    return LoadedContourData(bounds: cached.bounds, contours: cached.contours);
  }

  final clipped = <LoadedContourLine>[];
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = -double.infinity;
  var maxY = -double.infinity;

  for (final contour in cached.contours) {
    var lineMinX = double.infinity;
    var lineMinY = double.infinity;
    var lineMaxX = -double.infinity;
    var lineMaxY = -double.infinity;

    for (final p in contour.line) {
      if (p.dx < lineMinX) lineMinX = p.dx;
      if (p.dy < lineMinY) lineMinY = p.dy;
      if (p.dx > lineMaxX) lineMaxX = p.dx;
      if (p.dy > lineMaxY) lineMaxY = p.dy;
    }

    if (lineMaxX < clipBounds.left ||
        lineMinX > clipBounds.right ||
        lineMaxY < clipBounds.top ||
        lineMinY > clipBounds.bottom) {
      continue;
    }

    clipped.add(contour);
    if (lineMinX < minX) minX = lineMinX;
    if (lineMinY < minY) minY = lineMinY;
    if (lineMaxX > maxX) maxX = lineMaxX;
    if (lineMaxY > maxY) maxY = lineMaxY;
  }

  if (clipped.isEmpty) {
    return const LoadedContourData(
      bounds: Rect.fromLTRB(0, 0, 1, 1),
      contours: [],
    );
  }

  return LoadedContourData(
    bounds: Rect.fromLTRB(minX, minY, maxX, maxY),
    contours: clipped,
  );
}

Future<_ContourCacheEntry> _loadAndCache(ContourSource source) async {
  final hit = _cache[source.id];
  if (hit != null) {
    return hit;
  }

  final raw = await rootBundle.loadString(source.assetPath);
  final json = jsonDecode(raw) as Map<String, dynamic>;

  final boundsList = (json['bounds'] as List<dynamic>).cast<num>();
  final bounds = Rect.fromLTRB(
    boundsList[0].toDouble(),
    boundsList[1].toDouble(),
    boundsList[2].toDouble(),
    boundsList[3].toDouble(),
  );

  final contours =
      ((json['contours'] as List<dynamic>).cast<Map<String, dynamic>>())
          .map(
            (item) => LoadedContourLine(
              elevation: (item['elev'] as num).toInt(),
              major: item['major'] as bool,
              line: _parseLine(item['line'] as List<dynamic>),
            ),
          )
          .toList(growable: false);

  final created = _ContourCacheEntry(bounds: bounds, contours: contours);
  _cache[source.id] = created;
  return created;
}

List<Offset> _parseLine(List<dynamic> rawLine) {
  return rawLine
      .map((point) => point as List<dynamic>)
      .map(
        (point) =>
            Offset((point[0] as num).toDouble(), (point[1] as num).toDouble()),
      )
      .toList(growable: false);
}
