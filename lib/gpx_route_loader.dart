import 'dart:math' as math;
import 'dart:ui';

import 'package:xml/xml.dart';

class GpxRouteLoader {
  const GpxRouteLoader._();

  static List<List<Offset>> loadRouteLinesFromXml(String xmlText) {
    final document = XmlDocument.parse(xmlText);

    final routeLines = <List<Offset>>[];

    for (final trkSeg in _elementsByLocalName(document, 'trkseg')) {
      final lonLatLine = _parseLonLatPoints(
        _elementsByLocalName(trkSeg, 'trkpt'),
      );
      if (lonLatLine.length >= 2) {
        routeLines.add(_projectLineToUnified(lonLatLine));
      }
    }

    if (routeLines.isEmpty) {
      final routePoints = _parseLonLatPoints(
        _elementsByLocalName(document, 'rtept'),
      );
      if (routePoints.length >= 2) {
        routeLines.add(_projectLineToUnified(routePoints));
      }
    }

    if (routeLines.isEmpty) {
      throw const FormatException('GPX에서 trkpt/rtept 라인 좌표를 찾지 못했습니다.');
    }

    return routeLines;
  }

  static Iterable<XmlElement> _elementsByLocalName(
    XmlNode root,
    String localName,
  ) {
    return root.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == localName,
    );
  }

  static List<Offset> _parseLonLatPoints(Iterable<XmlElement> points) {
    final result = <Offset>[];
    for (final point in points) {
      final lat = double.tryParse(point.getAttribute('lat') ?? '');
      final lon = double.tryParse(point.getAttribute('lon') ?? '');
      if (lat == null || lon == null) {
        continue;
      }
      result.add(Offset(lon, lat));
    }
    return result;
  }

  static List<Offset> _projectLineToUnified(List<Offset> lonLatLine) {
    return lonLatLine
        .map((point) => _lonLatToUnified(point.dx, point.dy))
        .toList(growable: false);
  }

  // Korea 2000 / Unified CS parameters.
  static const double _a = 6378137.0;
  static const double _f = 1 / 298.257222101;
  static const double _k0 = 0.9996;
  static const double _lat0Deg = 38.0;
  static const double _lon0Deg = 127.5;
  static const double _falseEasting = 1000000.0;
  static const double _falseNorthing = 2000000.0;

  static final double _e2 = 2 * _f - _f * _f;
  static final double _ep2 = _e2 / (1 - _e2);
  static final double _lat0 = _lat0Deg * math.pi / 180.0;
  static final double _lon0 = _lon0Deg * math.pi / 180.0;
  static final double _m0 = _meridionalArc(_lat0);

  static double _meridionalArc(double phi) {
    final e4 = _e2 * _e2;
    final e6 = e4 * _e2;
    return _a *
        ((1 - _e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi -
            (3 * _e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * math.sin(2 * phi) +
            (15 * e4 / 256 + 45 * e6 / 1024) * math.sin(4 * phi) -
            (35 * e6 / 3072) * math.sin(6 * phi));
  }

  static Offset _lonLatToUnified(double lonDeg, double latDeg) {
    final phi = latDeg * math.pi / 180.0;
    final lambda = lonDeg * math.pi / 180.0;
    final sinPhi = math.sin(phi);
    final cosPhi = math.cos(phi);
    final tanPhi = math.tan(phi);

    final n = _a / math.sqrt(1 - _e2 * sinPhi * sinPhi);
    final t = tanPhi * tanPhi;
    final c = _ep2 * cosPhi * cosPhi;
    final aTerm = cosPhi * (lambda - _lon0);
    final m = _meridionalArc(phi);

    final x =
        _falseEasting +
        _k0 *
            n *
            (aTerm +
                (1 - t + c) * math.pow(aTerm, 3) / 6 +
                (5 - 18 * t + t * t + 72 * c - 58 * _ep2) *
                    math.pow(aTerm, 5) /
                    120);
    final y =
        _falseNorthing +
        _k0 *
            (m -
                _m0 +
                n *
                    tanPhi *
                    (aTerm * aTerm / 2 +
                        (5 - t + 9 * c + 4 * c * c) * math.pow(aTerm, 4) / 24 +
                        (61 - 58 * t + t * t + 600 * c - 330 * _ep2) *
                            math.pow(aTerm, 6) /
                            720));
    return Offset(x, y);
  }
}
