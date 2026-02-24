import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' as share_plus;

import 'contour_source_loader.dart';
import 'gpx_route_loader.dart';

enum MapDecorationType { title, northArrow, legend }

String _decorationLayerId(MapDecorationType type) => 'decoration:${type.name}';

void main() {
  runApp(const ContourRouteApp());
}

class ContourRouteApp extends StatelessWidget {
  const ContourRouteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Contour + GPX Route',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1D6B52)),
      ),
      home: const ContourRoutePage(),
    );
  }
}

class ContourRoutePage extends StatefulWidget {
  const ContourRoutePage({super.key});

  @override
  State<ContourRoutePage> createState() => _ContourRoutePageState();
}

class _ContourRoutePageState extends State<ContourRoutePage> {
  static const double _minMapScale = 0.2;
  static const double _maxMapScale = 48.0;
  static const double _layerPanelWidth = 210;
  static const double _layerPanelMargin = 12;
  static const double _layerPanelHandleHeight = 40;

  static const _trackPalette = <Color>[
    Color(0xFFE74B3C),
    Color(0xFF1E7E55),
    Color(0xFF0F6CBD),
    Color(0xFFD2691E),
    Color(0xFF7B5EA7),
    Color(0xFF2C3E50),
  ];

  static const _styleColors = <Color>[
    Color(0xFF2C3E50),
    Color(0xFFE74B3C),
    Color(0xFF1E7E55),
    Color(0xFF0F6CBD),
    Color(0xFFD2691E),
    Color(0xFF7B5EA7),
  ];
  static const _titleFontOptions = <MapEntry<String, String>>[
    MapEntry('Noto Sans KR', 'Noto Sans KR'),
    MapEntry('Gothic A1', 'Gothic A1'),
    MapEntry('Nanum Pen Script', 'Nanum Pen Script'),
    MapEntry('Nanum Myeongjo', 'Nanum Myeongjo'),
  ];
  static const Color _defaultContourColor = Color(0xFF4B6256);
  static const double _defaultContourWidth = 2.2;
  static const double _defaultContourOpacity = 0.5;

  late final Future<OverlayData> _baseDataFuture;
  final TransformationController _mapTransformController =
      TransformationController();
  final List<TrackLayer> _tracks = [];
  final List<ContourSource> _contourSources = [];
  final List<ContourLayer> _contourLayers = [];
  final GlobalKey _mapCaptureKey = GlobalKey();

  bool _isLoadingRoute = false;
  bool _isLoadingContourSources = false;
  bool _isLoadingContourLayer = false;
  bool _isExportingImage = false;
  bool _isLayerPanelVisible = true;
  bool _isAddingTrackNote = false;
  bool _showTitleDecoration = false;
  bool _showNorthArrowDecoration = false;
  bool _showLegendDecoration = false;
  String _mapTitle = '나의 트랙';
  Color _titleColor = const Color(0xFF1F2A24);
  double _titleFontSize = 28;
  String _titleFontFamily = 'Noto Sans KR';
  Offset? _layerPanelOffset;
  String? _statusMessage;
  String _selectedLayerId = '';
  String? _draggingTrackId;
  String? _draggingTrackNoteId;
  _TrackNoteDragTarget? _draggingTrackNoteTarget;
  Offset? _draggingLabelGrabDeltaWorld;
  String? _moveReadyTrackId;
  String? _moveReadyTrackNoteId;
  bool _isTrackNoteModalOpen = false;
  int _trackSerial = 0;

  String _resolvedTrackNoteFontFamily() {
    for (final option in _titleFontOptions) {
      if (option.value == _titleFontFamily) {
        return _titleFontFamily;
      }
    }
    return 'Noto Sans KR';
  }

  void _clearTrackNoteDragState() {
    _draggingTrackId = null;
    _draggingTrackNoteId = null;
    _draggingTrackNoteTarget = null;
    _draggingLabelGrabDeltaWorld = null;
  }

  void _clearTrackNoteMoveReady() {
    _moveReadyTrackId = null;
    _moveReadyTrackNoteId = null;
  }

  @override
  void initState() {
    super.initState();
    _baseDataFuture = _loadBaseData();
    _loadContourSources();
  }

  @override
  void dispose() {
    _mapTransformController.dispose();
    super.dispose();
  }

  Future<OverlayData> _loadBaseData() async {
    return OverlayData(
      bounds: const Rect.fromLTRB(0, 0, 1, 1),
      contours: const [],
    );
  }

  Future<void> _loadContourSources() async {
    setState(() {
      _isLoadingContourSources = true;
    });
    try {
      final sources = await discoverContourSources();
      if (!mounted) {
        return;
      }
      setState(() {
        _contourSources
          ..clear()
          ..addAll(sources);
        _statusMessage = sources.isEmpty
            ? '내장 등고선 소스를 찾지 못했습니다. (manifest 확인)'
            : '내장 등고선 소스 ${sources.length}개 로드 완료';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingContourSources = false;
        });
      }
    }
  }

  Future<void> _pickRouteFromGpx() async {
    if (_isLoadingRoute) {
      return;
    }

    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'GPX', extensions: ['gpx']),
      ],
      confirmButtonText: '불러오기',
    );
    if (file == null) {
      return;
    }

    setState(() {
      _isLoadingRoute = true;
      _statusMessage = null;
    });

    try {
      final routeLines = await Future<List<List<Offset>>>(() async {
        final xmlText = await file.readAsString();
        return GpxRouteLoader.loadRouteLinesFromXml(xmlText);
      });

      _trackSerial += 1;
      final color = _trackPalette[(_trackSerial - 1) % _trackPalette.length];
      final layer = TrackLayer(
        id: 'track_$_trackSerial',
        name: file.name,
        lines: routeLines,
        visible: true,
        color: color,
        width: 2.2,
        opacity: 1.0,
      );

      setState(() {
        _tracks.add(layer);
        _selectedLayerId = layer.id;
        _isAddingTrackNote = false;
        _clearTrackNoteDragState();
        _clearTrackNoteMoveReady();
        _statusMessage = '루트 로드 완료: ${file.name}';
      });
    } catch (error) {
      setState(() {
        _statusMessage = '루트 로드 실패: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingRoute = false;
        });
      }
    }
  }

  void _setTrackVisible(String trackId, bool visible) {
    setState(() {
      final idx = _tracks.indexWhere((track) => track.id == trackId);
      if (idx == -1) {
        return;
      }
      _tracks[idx] = _tracks[idx].copyWith(visible: visible);
      if (!visible && _selectedLayerId == trackId) {
        _isAddingTrackNote = false;
        _clearTrackNoteDragState();
        _clearTrackNoteMoveReady();
      } else if (!visible && _moveReadyTrackId == trackId) {
        _clearTrackNoteMoveReady();
      }
    });
  }

  void _setExtraContourVisible(String layerId, bool visible) {
    setState(() {
      final idx = _contourLayers.indexWhere((layer) => layer.id == layerId);
      if (idx == -1) {
        return;
      }
      _contourLayers[idx] = _contourLayers[idx].copyWith(visible: visible);
    });
  }

  void _removeContourLayer(String layerId) {
    setState(() {
      final idx = _contourLayers.indexWhere((layer) => layer.id == layerId);
      if (idx == -1) {
        return;
      }
      final removed = _contourLayers.removeAt(idx);
      if (_selectedLayerId == layerId) {
        _selectedLayerId = '';
      }
      _statusMessage = '등고선 레이어 삭제: ${removed.name}';
    });
  }

  void _removeTrack(String trackId) {
    setState(() {
      final idx = _tracks.indexWhere((track) => track.id == trackId);
      if (idx == -1) {
        return;
      }
      final removed = _tracks.removeAt(idx);
      if (_moveReadyTrackId == trackId) {
        _clearTrackNoteMoveReady();
      }
      if (_draggingTrackId == trackId) {
        _clearTrackNoteDragState();
      }
      if (_selectedLayerId == trackId) {
        _selectedLayerId = '';
        _isAddingTrackNote = false;
        _clearTrackNoteDragState();
        _clearTrackNoteMoveReady();
      }
      _statusMessage = '트랙 삭제: ${removed.name}';
    });
  }

  void _setTrackNoteVisible(String trackId, String noteId, bool visible) {
    setState(() {
      final trackIdx = _tracks.indexWhere((track) => track.id == trackId);
      if (trackIdx == -1) {
        return;
      }
      final track = _tracks[trackIdx];
      final notes = track.notes
          .map((note) => note.id == noteId ? note.copyWith(visible: visible) : note)
          .toList(growable: false);
      _tracks[trackIdx] = track.copyWith(notes: notes);
      if (!visible &&
          _draggingTrackId == trackId &&
          _draggingTrackNoteId == noteId) {
        _clearTrackNoteDragState();
      }
      if (!visible &&
          _moveReadyTrackId == trackId &&
          _moveReadyTrackNoteId == noteId) {
        _clearTrackNoteMoveReady();
      }
    });
  }

  void _removeTrackNote(String trackId, String noteId) {
    setState(() {
      final trackIdx = _tracks.indexWhere((track) => track.id == trackId);
      if (trackIdx == -1) {
        return;
      }
      final track = _tracks[trackIdx];
      final removed = track.notes.where((note) => note.id == noteId);
      final removedLabel = removed.isEmpty ? '포인트' : removed.first.text;
      final notes = track.notes
          .where((note) => note.id != noteId)
          .toList(growable: false);
      _tracks[trackIdx] = track.copyWith(notes: notes);
      if (_draggingTrackId == trackId && _draggingTrackNoteId == noteId) {
        _clearTrackNoteDragState();
      }
      if (_moveReadyTrackId == trackId && _moveReadyTrackNoteId == noteId) {
        _clearTrackNoteMoveReady();
      }
      _statusMessage = '포인트 삭제: $removedLabel';
    });
  }

  TrackLayer? _selectedTrack() {
    for (final track in _tracks) {
      if (track.id == _selectedLayerId) {
        return track;
      }
    }
    return null;
  }

  ContourLayer? _selectedContourLayer() {
    for (final layer in _contourLayers) {
      if (layer.id == _selectedLayerId) {
        return layer;
      }
    }
    return null;
  }

  ContourLayer? _selectedVisibleContourLayer() {
    for (final layer in _contourLayers) {
      if (layer.id == _selectedLayerId && layer.visible) {
        return layer;
      }
    }
    return null;
  }

  ContourLayer? _firstVisibleContourLayer() {
    for (final layer in _contourLayers) {
      if (layer.visible) {
        return layer;
      }
    }
    return null;
  }

  _LegendIntervals _legendIntervals() {
    final layer = _selectedVisibleContourLayer() ?? _firstVisibleContourLayer();
    if (layer == null || layer.contours.isEmpty) {
      return const _LegendIntervals(majorInterval: 100, minorInterval: 20);
    }

    final majorElevations = layer.contours
        .where((contour) => contour.major)
        .map((contour) => contour.elevation.abs())
        .toSet()
        .toList()
      ..sort();
    final minorElevations = layer.contours
        .where((contour) => !contour.major)
        .map((contour) => contour.elevation.abs())
        .toSet()
        .toList()
      ..sort();
    final allElevations = layer.contours
        .map((contour) => contour.elevation.abs())
        .toSet()
        .toList()
      ..sort();

    final majorInterval = _minPositiveStep(majorElevations) ?? 100;
    final minorFromMinor = _minPositiveStep(minorElevations);
    final minorFromAll = _minPositiveStep(allElevations);

    final minorInterval = minorFromMinor ??
        ((minorFromAll != null && minorFromAll < majorInterval)
            ? minorFromAll
            : (majorInterval >= 100 ? 20 : 10));

    return _LegendIntervals(
      majorInterval: majorInterval,
      minorInterval: minorInterval,
    );
  }

  int? _minPositiveStep(List<int> sortedValues) {
    if (sortedValues.length < 2) {
      return null;
    }
    var best = 1 << 30;
    for (var i = 1; i < sortedValues.length; i++) {
      final diff = sortedValues[i] - sortedValues[i - 1];
      if (diff > 0 && diff < best) {
        best = diff;
      }
    }
    if (best == (1 << 30)) {
      return null;
    }
    return best;
  }

  void _updateSelectedColor(Color color) {
    final selectedTrack = _selectedTrack();
    if (selectedTrack != null) {
      setState(() {
        final idx = _tracks.indexWhere((track) => track.id == selectedTrack.id);
        _tracks[idx] = selectedTrack.copyWith(color: color);
      });
      return;
    }
    final selectedContour = _selectedContourLayer();
    if (selectedContour != null) {
      setState(() {
        final idx = _contourLayers.indexWhere(
          (layer) => layer.id == selectedContour.id,
        );
        _contourLayers[idx] = selectedContour.copyWith(color: color);
      });
    }
  }

  void _updateSelectedWidth(double width) {
    final selectedTrack = _selectedTrack();
    if (selectedTrack != null) {
      setState(() {
        final idx = _tracks.indexWhere((track) => track.id == selectedTrack.id);
        _tracks[idx] = selectedTrack.copyWith(width: width);
      });
      return;
    }
    final selectedContour = _selectedContourLayer();
    if (selectedContour != null) {
      setState(() {
        final idx = _contourLayers.indexWhere(
          (layer) => layer.id == selectedContour.id,
        );
        _contourLayers[idx] = selectedContour.copyWith(width: width);
      });
    }
  }

  void _updateSelectedOpacity(double opacity) {
    final selectedTrack = _selectedTrack();
    if (selectedTrack != null) {
      setState(() {
        final idx = _tracks.indexWhere((track) => track.id == selectedTrack.id);
        _tracks[idx] = selectedTrack.copyWith(opacity: opacity);
      });
      return;
    }
    final selectedContour = _selectedContourLayer();
    if (selectedContour != null) {
      setState(() {
        final idx = _contourLayers.indexWhere(
          (layer) => layer.id == selectedContour.id,
        );
        _contourLayers[idx] = selectedContour.copyWith(opacity: opacity);
      });
    }
  }

  void _updateTitleColor(Color color) {
    setState(() {
      _titleColor = color;
    });
  }

  void _updateTitleFontSize(double size) {
    setState(() {
      _titleFontSize = size;
    });
  }

  void _toggleTrackNoteMode() {
    final selectedTrack = _selectedTrack();
    if (selectedTrack == null) {
      setState(() {
        _statusMessage = '레이어에서 GPX 트랙을 먼저 선택해 주세요.';
      });
      return;
    }
    setState(() {
      _isAddingTrackNote = !_isAddingTrackNote;
      if (!_isAddingTrackNote) {
        _clearTrackNoteDragState();
        _clearTrackNoteMoveReady();
      }
      _statusMessage = _isAddingTrackNote
          ? '경로 편집 모드 ON: 포인트 추가/수정/삭제 가능, 텍스트 이동은 메뉴에서 실행'
          : '경로 편집 모드 OFF';
    });
  }

  Future<void> _handleMapTapForTrackNote({
    required Offset tapLocalPosition,
    required Size canvasSize,
    required Rect worldBounds,
  }) async {
    if (!_isAddingTrackNote || _isTrackNoteModalOpen) {
      return;
    }
    try {
      final selectedTrack = _selectedTrack();
      if (selectedTrack == null || !selectedTrack.visible) {
        if (!mounted) {
          return;
        }
        setState(() {
          _isAddingTrackNote = false;
          _clearTrackNoteDragState();
          _clearTrackNoteMoveReady();
          _statusMessage = '보이는 GPX 트랙을 선택한 뒤 다시 시도해 주세요.';
        });
        return;
      }

      final canvasTap = _mapTransformController.toScene(tapLocalPosition);
      final projector = _Projector(world: worldBounds, canvasSize: canvasSize);
      final nearestNote = _findNearestTrackNoteOnCanvas(
        track: selectedTrack,
        canvasTap: canvasTap,
        projector: projector,
      );
      final noteHitThreshold = nearestNote?.hitTarget == _TrackNoteHitTarget.label
          ? 16.0
          : 24.0;
      if (nearestNote != null && nearestNote.distancePx <= noteHitThreshold) {
        final action = await _showTrackNoteActionSheet(nearestNote.note.text);
        if (!mounted || action == null) {
          return;
        }
        if (action == _TrackNoteAction.moveText) {
          setState(() {
            _moveReadyTrackId = selectedTrack.id;
            _moveReadyTrackNoteId = nearestNote.note.id;
            _statusMessage = '텍스트 이동 대기: 라벨을 드래그하세요.';
          });
          return;
        }
        setState(_clearTrackNoteMoveReady);
        if (action == _TrackNoteAction.delete) {
          _removeTrackNote(selectedTrack.id, nearestNote.note.id);
          return;
        }

        final edited = await _promptTrackNoteText(
          title: '포인트 메모 수정',
          initialValue: nearestNote.note.text,
        );
        if (!mounted || edited == null) {
          return;
        }
        final trimmedEdited = edited.trim();
        if (trimmedEdited.isEmpty) {
          return;
        }
        setState(() {
          final idx = _tracks.indexWhere(
            (track) => track.id == selectedTrack.id,
          );
          if (idx == -1) {
            return;
          }
          final notes = _tracks[idx].notes
              .map(
                (note) => note.id == nearestNote.note.id
                    ? note.copyWith(text: trimmedEdited)
                    : note,
              )
              .toList(growable: false);
          _tracks[idx] = _tracks[idx].copyWith(notes: notes);
          _statusMessage = '포인트 메모 수정: $trimmedEdited';
        });
        return;
      }

      if (_moveReadyTrackId == selectedTrack.id &&
          _moveReadyTrackNoteId != null) {
        setState(() {
          _statusMessage = '텍스트 이동 대기 중: 선택한 라벨을 드래그하세요.';
        });
        return;
      }

      final nearestOnTrack = _findNearestTrackPointOnCanvas(
        track: selectedTrack,
        canvasTap: canvasTap,
        projector: projector,
      );

      if (nearestOnTrack == null || nearestOnTrack.distancePx > 24) {
        if (!mounted) {
          return;
        }
        setState(() {
          _statusMessage = '트랙 선 또는 기존 포인트를 탭해 주세요.';
        });
        return;
      }

      final memo = await _promptTrackNoteText(
        title: '포인트 메모 추가',
        initialValue: '',
      );
      if (!mounted || memo == null) {
        return;
      }
      final trimmedMemo = memo.trim();
      if (trimmedMemo.isEmpty) {
        return;
      }

      setState(() {
        final idx = _tracks.indexWhere((track) => track.id == selectedTrack.id);
        if (idx == -1) {
          return;
        }
        final defaultLabelOffset = _defaultTrackNoteLabelOffset(projector);
        final notes = List<TrackNote>.from(_tracks[idx].notes)
          ..add(
            TrackNote(
              id: 'note_${DateTime.now().microsecondsSinceEpoch}',
              point: nearestOnTrack.worldPoint,
              text: trimmedMemo,
              labelOffset: defaultLabelOffset,
            ),
          );
        _tracks[idx] = _tracks[idx].copyWith(
          notes: List<TrackNote>.unmodifiable(notes),
        );
        _statusMessage = '포인트 추가: $trimmedMemo';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = '포인트 편집 오류: $error';
      });
    }
  }

  _NearestTrackPoint? _findNearestTrackPointOnCanvas({
    required TrackLayer track,
    required Offset canvasTap,
    required _Projector projector,
  }) {
    _NearestTrackPoint? nearest;
    var bestDistSquared = double.infinity;

    for (final line in track.lines) {
      for (var i = 1; i < line.length; i++) {
        final aWorld = line[i - 1];
        final bWorld = line[i];
        final aCanvas = projector.toCanvas(aWorld);
        final bCanvas = projector.toCanvas(bWorld);
        final t = _segmentProjectionFactor(
          point: canvasTap,
          start: aCanvas,
          end: bCanvas,
        );
        final closestCanvas = aCanvas + (bCanvas - aCanvas) * t;
        final distSquared = (closestCanvas - canvasTap).distanceSquared;
        if (distSquared < bestDistSquared) {
          bestDistSquared = distSquared;
          final closestWorld = aWorld + (bWorld - aWorld) * t;
          nearest = _NearestTrackPoint(
            worldPoint: closestWorld,
            distancePx: math.sqrt(distSquared),
          );
        }
      }
    }

    return nearest;
  }

  _NearestTrackNote? _findNearestTrackNoteOnCanvas({
    required TrackLayer track,
    required Offset canvasTap,
    required _Projector projector,
  }) {
    _NearestTrackNote? nearest;
    var bestDistance = double.infinity;
    for (final note in track.notes) {
      if (!note.isVisible) {
        continue;
      }
      final noteCanvas = projector.toCanvas(note.point);
      final markerDistance = (noteCanvas - canvasTap).distance;
      if (markerDistance < bestDistance) {
        bestDistance = markerDistance;
        nearest = _NearestTrackNote(
          note: note,
          distancePx: markerDistance,
          hitTarget: _TrackNoteHitTarget.marker,
        );
      }
      final labelLayout = _buildTrackNoteLabelLayout(
        note: note,
        projector: projector,
        fontFamily: _resolvedTrackNoteFontFamily(),
      );
      final labelHitRect = labelLayout.rect.inflate(12);
      final labelDistance = _distanceFromPointToRect(canvasTap, labelHitRect);
      if (labelDistance < bestDistance) {
        bestDistance = labelDistance;
        nearest = _NearestTrackNote(
          note: note,
          distancePx: labelDistance,
          hitTarget: _TrackNoteHitTarget.label,
        );
      }
    }
    return nearest;
  }

  void _handleMapPanStartForTrackNote({
    required Offset localPosition,
    required Size canvasSize,
    required Rect worldBounds,
  }) {
    if (!_isAddingTrackNote || _isTrackNoteModalOpen) {
      return;
    }
    final selectedTrack = _selectedTrack();
    if (selectedTrack == null || !selectedTrack.visible) {
      return;
    }
    final moveReadyTrackId = _moveReadyTrackId;
    final moveReadyNoteId = _moveReadyTrackNoteId;
    if (moveReadyTrackId != selectedTrack.id || moveReadyNoteId == null) {
      return;
    }

    final canvasPoint = _mapTransformController.toScene(localPosition);
    final projector = _Projector(world: worldBounds, canvasSize: canvasSize);
    final noteIdx = selectedTrack.notes.indexWhere(
      (note) => note.id == moveReadyNoteId && note.isVisible,
    );
    if (noteIdx == -1) {
      return;
    }
    final targetNote = selectedTrack.notes[noteIdx];
    final labelLayout = _buildTrackNoteLabelLayout(
      note: targetNote,
      projector: projector,
      fontFamily: _resolvedTrackNoteFontFamily(),
    );
    final labelHitRect = labelLayout.rect.inflate(16);
    final labelDistance = _distanceFromPointToRect(canvasPoint, labelHitRect);
    if (labelDistance > 20) {
      return;
    }

    setState(() {
      _draggingTrackId = selectedTrack.id;
      _draggingTrackNoteId = targetNote.id;
      _draggingTrackNoteTarget = _TrackNoteDragTarget.label;
      final pointerWorld = projector.toWorld(canvasPoint);
      final labelCenterWorld = targetNote.point + targetNote.labelOffset;
      _draggingLabelGrabDeltaWorld = labelCenterWorld - pointerWorld;
      _statusMessage = '텍스트 위치 이동 중...';
    });
  }

  void _handleMapPanUpdateForTrackNote({
    required Offset localPosition,
    required Size canvasSize,
    required Rect worldBounds,
  }) {
    if (!_isAddingTrackNote || _isTrackNoteModalOpen) {
      return;
    }
    final draggingTrackId = _draggingTrackId;
    final draggingNoteId = _draggingTrackNoteId;
    final draggingTarget = _draggingTrackNoteTarget;
    if (draggingTrackId == null ||
        draggingNoteId == null ||
        draggingTarget != _TrackNoteDragTarget.label) {
      return;
    }
    final trackIdx = _tracks.indexWhere((track) => track.id == draggingTrackId);
    if (trackIdx == -1) {
      return;
    }
    final track = _tracks[trackIdx];
    final canvasPoint = _mapTransformController.toScene(localPosition);
    final projector = _Projector(world: worldBounds, canvasSize: canvasSize);
    final noteIdx = track.notes.indexWhere((note) => note.id == draggingNoteId);
    if (noteIdx == -1) {
      return;
    }
    final currentNote = track.notes[noteIdx];
    final pointerWorld = projector.toWorld(canvasPoint);
    final grabDelta = _draggingLabelGrabDeltaWorld ?? Offset.zero;
    final labelCenterWorld = pointerWorld + grabDelta;
    final nextLabelOffset = labelCenterWorld - currentNote.point;
    setState(() {
      final notes = track.notes
          .map(
            (note) => note.id == draggingNoteId
                ? note.copyWith(labelOffset: nextLabelOffset)
                : note,
          )
          .toList(growable: false);
      _tracks[trackIdx] = track.copyWith(notes: notes);
    });
  }

  void _handleMapPanEndForTrackNote() {
    if (_draggingTrackNoteId == null) {
      return;
    }
    final finishedTarget = _draggingTrackNoteTarget;
    setState(() {
      _clearTrackNoteDragState();
      _clearTrackNoteMoveReady();
      _statusMessage = finishedTarget == _TrackNoteDragTarget.label
          ? '텍스트 위치 이동 완료'
          : '경로 지점은 고정입니다';
    });
  }

  Offset _defaultTrackNoteLabelOffset(_Projector projector) {
    final scale = math.max(projector.scale, 0.0001);
    return Offset(36 / scale, 16 / scale);
  }

  double _distanceFromPointToRect(Offset point, Rect rect) {
    final dx = point.dx < rect.left
        ? rect.left - point.dx
        : (point.dx > rect.right ? point.dx - rect.right : 0.0);
    final dy = point.dy < rect.top
        ? rect.top - point.dy
        : (point.dy > rect.bottom ? point.dy - rect.bottom : 0.0);
    return math.sqrt(dx * dx + dy * dy);
  }

  double _segmentProjectionFactor({
    required Offset point,
    required Offset start,
    required Offset end,
  }) {
    final segment = end - start;
    final segLengthSquared =
        segment.dx * segment.dx + segment.dy * segment.dy;
    if (segLengthSquared <= 0) {
      return 0;
    }
    final fromStart = point - start;
    final dot = fromStart.dx * segment.dx + fromStart.dy * segment.dy;
    return (dot / segLengthSquared).clamp(0.0, 1.0).toDouble();
  }

  Future<String?> _promptTrackNoteText({
    required String title,
    required String initialValue,
  }) async {
    if (_isTrackNoteModalOpen || !mounted) {
      return null;
    }
    _isTrackNoteModalOpen = true;
    var draft = initialValue;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        return null;
      }
      final memo = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(title),
            content: TextFormField(
              initialValue: initialValue,
              autofocus: true,
              maxLength: 28,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(hintText: '예: 산입구'),
              onChanged: (value) => draft = value,
              onFieldSubmitted: (value) => Navigator.of(dialogContext).pop(value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(draft),
                child: const Text('저장'),
              ),
            ],
          );
        },
      );
      return memo;
    } finally {
      _isTrackNoteModalOpen = false;
    }
  }

  Future<_TrackNoteAction?> _showTrackNoteActionSheet(String noteText) async {
    if (_isTrackNoteModalOpen || !mounted) {
      return null;
    }
    _isTrackNoteModalOpen = true;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        return null;
      }
      return showModalBottomSheet<_TrackNoteAction>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        builder: (sheetContext) {
          return Wrap(
            children: [
              ListTile(
                dense: true,
                title: Text(
                  noteText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: const Text('포인트 옵션'),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('텍스트 수정'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_TrackNoteAction.edit),
              ),
              ListTile(
                leading: const Icon(Icons.open_with),
                title: const Text('텍스트 이동'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_TrackNoteAction.moveText),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('포인트 삭제'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_TrackNoteAction.delete),
              ),
            ],
          );
        },
      );
    } finally {
      _isTrackNoteModalOpen = false;
    }
  }

  Future<void> _showTitleFontPicker() async {
    final pickedFamily = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (bottomSheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          minChildSize: 0.45,
          initialChildSize: 0.68,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    '제목 폰트 선택',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    itemCount: _titleFontOptions.length,
                    separatorBuilder: (_, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final option = _titleFontOptions[index];
                      final selected = option.value == _titleFontFamily;
                      return ListTile(
                        dense: true,
                        title: Text(
                          option.key,
                          style: TextStyle(
                            fontFamily: option.value,
                            fontSize: 15,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                        subtitle: Text(
                          option.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: selected
                            ? const Icon(Icons.check, size: 18)
                            : null,
                        onTap: () =>
                            Navigator.of(bottomSheetContext).pop(option.value),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (!mounted || pickedFamily == null) {
      return;
    }

    setState(() {
      _titleFontFamily = pickedFamily;
      _statusMessage = '제목 폰트 변경: $pickedFamily';
    });
  }

  Rect _worldBounds(OverlayData baseData) {
    Rect? bounds;
    if (baseData.contours.isNotEmpty) {
      bounds = baseData.bounds;
    }
    for (final contourLayer in _contourLayers.where((layer) => layer.visible)) {
      bounds = bounds == null ? contourLayer.bounds : _unionRect(bounds, contourLayer.bounds);
    }
    for (final track in _tracks.where((track) => track.visible)) {
      final trackBounds = _boundsFromLines(track.lines).inflate(1400);
      bounds = bounds == null ? trackBounds : _unionRect(bounds, trackBounds);
    }
    return bounds ?? const Rect.fromLTWH(0, 0, 1, 1);
  }

  Rect _boundsFromLines(List<List<Offset>> lines) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    for (final line in lines) {
      for (final point in line) {
        if (point.dx < minX) minX = point.dx;
        if (point.dy < minY) minY = point.dy;
        if (point.dx > maxX) maxX = point.dx;
        if (point.dy > maxY) maxY = point.dy;
      }
    }
    if (!minX.isFinite) {
      return const Rect.fromLTWH(0, 0, 1, 1);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  Rect _unionRect(Rect a, Rect b) {
    return Rect.fromLTRB(
      math.min(a.left, b.left),
      math.min(a.top, b.top),
      math.max(a.right, b.right),
      math.max(a.bottom, b.bottom),
    );
  }

  Rect? _selectedVisibleBoundsOrNull() {
    for (final layer in _contourLayers) {
      if (layer.id == _selectedLayerId && layer.visible) {
        return layer.bounds;
      }
    }
    for (final track in _tracks) {
      if (track.id == _selectedLayerId && track.visible) {
        return _boundsFromLines(track.lines).inflate(1400);
      }
    }
    return null;
  }

  Rect? _visibleBoundsOrNull() {
    Rect? bounds;
    for (final layer in _contourLayers.where((layer) => layer.visible)) {
      bounds = bounds == null ? layer.bounds : _unionRect(bounds, layer.bounds);
    }
    for (final track in _tracks.where((track) => track.visible)) {
      final b = _boundsFromLines(track.lines).inflate(1400);
      bounds = bounds == null ? b : _unionRect(bounds, b);
    }
    return bounds;
  }

  void _resetMapView(Rect worldBounds) {
    final viewportSize = _mapCaptureKey.currentContext?.size;
    final selectedBounds = _selectedVisibleBoundsOrNull();
    final targetBounds = selectedBounds ?? _visibleBoundsOrNull();
    if (viewportSize == null || targetBounds == null) {
      _mapTransformController.value = Matrix4.identity();
      setState(() {
        _statusMessage = '표시할 레이어가 없어 기본 뷰로 이동';
      });
      return;
    }

    final projector = _Projector(world: worldBounds, canvasSize: viewportSize);
    final a = projector.toCanvas(Offset(targetBounds.left, targetBounds.top));
    final b = projector.toCanvas(Offset(targetBounds.right, targetBounds.bottom));
    final targetRect = Rect.fromLTRB(
      math.min(a.dx, b.dx),
      math.min(a.dy, b.dy),
      math.max(a.dx, b.dx),
      math.max(a.dy, b.dy),
    );

    const fitRatio = 0.92;
    final fitScaleX = (viewportSize.width * fitRatio) / math.max(targetRect.width, 1.0);
    final fitScaleY = (viewportSize.height * fitRatio) / math.max(targetRect.height, 1.0);
    final scale = math.min(fitScaleX, fitScaleY).clamp(_minMapScale, _maxMapScale).toDouble();

    final center = targetRect.center;
    final tx = (viewportSize.width / 2) - center.dx * scale;
    final ty = (viewportSize.height / 2) - center.dy * scale;

    final transform = Matrix4.identity();
    transform.setEntry(0, 0, scale);
    transform.setEntry(1, 1, scale);
    transform.setEntry(0, 3, tx);
    transform.setEntry(1, 3, ty);
    _mapTransformController.value = transform;

    setState(() {
      _statusMessage = selectedBounds != null
          ? '선택 레이어 중심으로 이동'
          : '표시중인 레이어 중심으로 이동';
    });
  }

  void _toggleLayerPanelVisible() {
    setState(() {
      _isLayerPanelVisible = !_isLayerPanelVisible;
      _statusMessage = _isLayerPanelVisible ? '레이어 패널 표시' : '레이어 패널 숨김';
    });
  }

  Offset _defaultLayerPanelOffset(Size mapSize) {
    final left = math.max(
      _layerPanelMargin,
      mapSize.width - _layerPanelWidth - _layerPanelMargin,
    );
    return Offset(left, _layerPanelMargin);
  }

  Offset _clampLayerPanelOffset(Offset offset, Size mapSize) {
    final maxX = math.max(
      _layerPanelMargin,
      mapSize.width - _layerPanelWidth - _layerPanelMargin,
    );
    final maxY = math.max(
      _layerPanelMargin,
      mapSize.height - _layerPanelHandleHeight - _layerPanelMargin,
    );
    return Offset(
      offset.dx.clamp(_layerPanelMargin, maxX).toDouble(),
      offset.dy.clamp(_layerPanelMargin, maxY).toDouble(),
    );
  }

  Offset _resolvedLayerPanelOffset(Size mapSize) {
    final offset = _layerPanelOffset ?? _defaultLayerPanelOffset(mapSize);
    return _clampLayerPanelOffset(offset, mapSize);
  }

  void _moveLayerPanel(Offset delta, Size mapSize) {
    setState(() {
      final current = _resolvedLayerPanelOffset(mapSize);
      _layerPanelOffset = _clampLayerPanelOffset(current + delta, mapSize);
    });
  }

  String _decorationLabel(MapDecorationType type) {
    switch (type) {
      case MapDecorationType.title:
        return '제목';
      case MapDecorationType.northArrow:
        return '방위표';
      case MapDecorationType.legend:
        return '범례';
    }
  }

  bool _isDecorationVisible(MapDecorationType type) {
    switch (type) {
      case MapDecorationType.title:
        return _showTitleDecoration;
      case MapDecorationType.northArrow:
        return _showNorthArrowDecoration;
      case MapDecorationType.legend:
        return _showLegendDecoration;
    }
  }

  void _setMapDecorationVisible(MapDecorationType type, bool visible) {
    setState(() {
      switch (type) {
        case MapDecorationType.title:
          _showTitleDecoration = visible;
          break;
        case MapDecorationType.northArrow:
          _showNorthArrowDecoration = visible;
          break;
        case MapDecorationType.legend:
          _showLegendDecoration = visible;
          break;
      }
      if (!visible && _selectedLayerId == _decorationLayerId(type)) {
        _selectedLayerId = '';
      }
      final label = _decorationLabel(type);
      _statusMessage = visible ? '$label 표시' : '$label 숨김';
    });
  }

  void _removeMapDecoration(MapDecorationType type) {
    _setMapDecorationVisible(type, false);
  }

  void _toggleMapDecoration(MapDecorationType type) {
    _setMapDecorationVisible(type, !_isDecorationVisible(type));
  }

  Future<void> _editMapTitle() async {
    var draftTitle = _mapTitle;
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('제목 편집'),
          content: TextFormField(
            initialValue: _mapTitle,
            autofocus: true,
            maxLength: 32,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(hintText: '지도의 제목을 입력하세요'),
            onChanged: (value) => draftTitle = value,
            onFieldSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(draftTitle),
              child: const Text('저장'),
            ),
          ],
        );
      },
    );

    if (!mounted || edited == null) {
      return;
    }

    final next = edited.trim();
    setState(() {
      _mapTitle = next.isEmpty ? '나의 트랙' : next;
      _showTitleDecoration = true;
      _statusMessage = '제목 변경: $_mapTitle';
    });
  }

  String _twoDigits(int value) {
    if (value >= 10) {
      return '$value';
    }
    return '0$value';
  }

  Future<Directory> _resolveExportDirectory() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        return downloads;
      }
    } catch (_) {
      // Mobile platforms may not provide a public downloads path.
    }
    return getApplicationDocumentsDirectory();
  }

  Future<bool> _saveImageToGallery(String filePath) async {
    try {
      var hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        hasAccess = await Gal.requestAccess();
      }
      if (!hasAccess) {
        return false;
      }
      await Gal.putImage(filePath);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _exportMapImage() async {
    if (_isExportingImage) {
      return;
    }

    final prevShowTitle = _showTitleDecoration;
    final prevShowNorthArrow = _showNorthArrowDecoration;
    final prevShowLegend = _showLegendDecoration;

    setState(() {
      _isExportingImage = true;
      // Always include export decorations regardless of current toggle state.
      _showTitleDecoration = true;
      _showNorthArrowDecoration = true;
      _showLegendDecoration = true;
      _statusMessage = '이미지 내보내는 중... (제목/방위표/범례 포함)';
    });

    try {
      final pixelRatio =
          (View.of(context).devicePixelRatio * 2).clamp(2.0, 5.0).toDouble();
      await WidgetsBinding.instance.endOfFrame;

      final boundary = _mapCaptureKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        throw StateError('맵 캡처 영역을 찾지 못했습니다.');
      }

      final capturedImage = await boundary.toImage(pixelRatio: pixelRatio);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final exportSize = Size(
        capturedImage.width.toDouble(),
        capturedImage.height.toDouble(),
      );
      canvas.drawRect(
        Offset.zero & exportSize,
        Paint()..color = Colors.white,
      );
      canvas.drawImage(capturedImage, Offset.zero, Paint());
      final image = await recorder
          .endRecording()
          .toImage(capturedImage.width, capturedImage.height);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw StateError('이미지 인코딩에 실패했습니다.');
      }
      capturedImage.dispose();
      image.dispose();

      final now = DateTime.now();
      final fileName =
          'contour_${now.year}${_twoDigits(now.month)}${_twoDigits(now.day)}_'
          '${_twoDigits(now.hour)}${_twoDigits(now.minute)}${_twoDigits(now.second)}.png';
      final bytes = byteData.buffer.asUint8List();
      final saveDirectory = await _resolveExportDirectory();
      final file = File.fromUri(
        Uri.directory(saveDirectory.path).resolve(fileName),
      );
      await file.writeAsBytes(bytes, flush: true);
      final gallerySaved = await _saveImageToGallery(file.path);

      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = gallerySaved
            ? '이미지 저장 완료(갤러리 포함): $fileName'
            : '이미지 저장 완료(파일만): $fileName';
      });
      final successMessenger = ScaffoldMessenger.of(context);
      successMessenger.hideCurrentSnackBar();
      final successController = successMessenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 4),
          content: Text(
            gallerySaved
                ? 'PNG 저장 완료 · 갤러리에 저장됨'
                : 'PNG 저장 완료 · 갤러리 저장 실패',
          ),
          action: SnackBarAction(
            label: '공유',
            onPressed: () {
              share_plus.Share.shareXFiles(
                [
                  XFile(
                    file.path,
                    name: fileName,
                    mimeType: 'image/png',
                  ),
                ],
                text: '등고선 + GPX 이미지',
              );
            },
          ),
        ),
      );
      Future<void>.delayed(const Duration(seconds: 5), () {
        successController.close();
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = '이미지 저장 실패: $error';
      });
      final errorMessenger = ScaffoldMessenger.of(context);
      errorMessenger.hideCurrentSnackBar();
      final errorController = errorMessenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 4),
          content: Text('이미지 저장 실패: $error'),
        ),
      );
      Future<void>.delayed(const Duration(seconds: 5), () {
        errorController.close();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isExportingImage = false;
          _showTitleDecoration = prevShowTitle;
          _showNorthArrowDecoration = prevShowNorthArrow;
          _showLegendDecoration = prevShowLegend;
        });
      }
    }
  }

  Rect? _tracksBoundsOrNull() {
    if (_tracks.isEmpty) {
      return null;
    }
    Rect? bounds;
    for (final track in _tracks) {
      final b = _boundsFromLines(track.lines);
      bounds = bounds == null ? b : _unionRect(bounds, b);
    }
    return bounds;
  }

  Future<void> _showContourSourcePicker() async {
    if (_isLoadingContourLayer) {
      return;
    }
    if (_isLoadingContourSources) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('등고선 목록을 불러오는 중입니다.')));
      return;
    }
    if (_contourSources.isEmpty) {
      await _loadContourSources();
      if (!mounted) {
        return;
      }
    }
    if (_contourSources.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('추가 가능한 등고선 소스를 찾지 못했습니다.')));
      return;
    }

    final picked = await showModalBottomSheet<ContourSource>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView.separated(
            itemCount: _contourSources.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final source = _contourSources[index];
              final alreadyAdded = _contourLayers.any(
                (layer) => layer.sourceId == source.id,
              );
              return ListTile(
                dense: true,
                title: Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: alreadyAdded
                    ? const Icon(
                        Icons.check_circle,
                        size: 18,
                        color: Color(0xFF1E7E55),
                      )
                    : null,
                onTap: () => Navigator.of(context).pop(source),
              );
            },
          ),
        );
      },
    );

    if (picked == null) {
      return;
    }
    await _addContourLayerFromSource(picked);
  }

  Future<void> _addContourLayerFromSource(ContourSource source) async {
    ContourLayer? existing;
    for (final layer in _contourLayers) {
      if (layer.sourceId == source.id) {
        existing = layer;
        break;
      }
    }
    if (existing != null) {
      final existingLayer = existing;
      setState(() {
        _selectedLayerId = existingLayer.id;
        _isAddingTrackNote = false;
        _clearTrackNoteDragState();
        _clearTrackNoteMoveReady();
        _statusMessage = '이미 추가된 등고선 레이어입니다: ${existingLayer.name}';
      });
      return;
    }

    setState(() {
      _isLoadingContourLayer = true;
      _statusMessage = '등고선 로딩 중: ${source.name}';
    });

    try {
      final tracksBounds = _tracksBoundsOrNull();
      final clipBounds = tracksBounds?.inflate(5000);
      var loaded = await loadContourSource(
        source: source,
        clipBounds: clipBounds,
      );
      if (loaded.contours.isEmpty && clipBounds != null) {
        loaded = await loadContourSource(source: source, clipBounds: null);
      }

      final layer = ContourLayer(
        id: 'contour_${source.id}',
        sourceId: source.id,
        name: source.name,
        bounds: loaded.bounds,
        contours: loaded.contours
            .map(
              (line) => ContourLine(
                elevation: line.elevation,
                major: line.major,
                line: line.line,
              ),
            )
            .toList(growable: false),
        visible: true,
        color: _defaultContourColor,
        width: _defaultContourWidth,
        opacity: _defaultContourOpacity,
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _contourLayers.add(layer);
        _selectedLayerId = layer.id;
        _isAddingTrackNote = false;
        _clearTrackNoteDragState();
        _clearTrackNoteMoveReady();
        _statusMessage =
            '등고선 레이어 추가: ${source.name} (${layer.contours.length}선)';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = '등고선 로딩 실패: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingContourLayer = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<OverlayData>(
          future: _baseDataFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('초기 데이터 로드 실패\n${snapshot.error}'),
                ),
              );
            }

            final baseData = snapshot.requireData;
            final world = _worldBounds(baseData);
            final selectedTrack = _selectedTrack();
            final selectedContour = _selectedContourLayer();
            final isTitleLayerSelected =
                _selectedLayerId == _decorationLayerId(MapDecorationType.title);
            final selectedStyleLayerName =
                selectedTrack?.name ?? selectedContour?.name ?? '선택된 레이어 없음';
            final selectedStyleLayerKind =
                selectedTrack != null
                    ? 'GPX'
                    : (selectedContour != null ? '등고선' : '레이어');
            final styleEnabled = selectedTrack != null || selectedContour != null;
            final activeColor =
                selectedTrack?.color ??
                selectedContour?.color ??
                _styleColors.first;
            final activeWidth =
                selectedTrack?.width ??
                selectedContour?.width ??
                _defaultContourWidth;
            final activeOpacity =
                selectedTrack?.opacity ??
                selectedContour?.opacity ??
                _defaultContourOpacity;
            final legendIntervals = _legendIntervals();
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                children: [
                  _TopStrip(
                    statusMessage: _statusMessage,
                    trackEditMode: _isAddingTrackNote,
                    onResetView: () => _resetMapView(world),
                    onExportImage: _exportMapImage,
                    isExportingImage: _isExportingImage,
                    layerPanelVisible: _isLayerPanelVisible,
                    onToggleLayerPanelVisible: _toggleLayerPanelVisible,
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F8F5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFC9D4CD)),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: LayoutBuilder(
                          builder: (context, mapConstraints) {
                            final layerPanelOffset = _resolvedLayerPanelOffset(
                              mapConstraints.biggest,
                            );
                            return Stack(
                              children: [
                                Positioned.fill(
                                  child: RepaintBoundary(
                                    key: _mapCaptureKey,
                                    child: Stack(
                                      children: [
                                        Positioned.fill(
                                          child: LayoutBuilder(
                                            builder: (context, constraints) {
                                              return GestureDetector(
                                                excludeFromSemantics: true,
                                                behavior: HitTestBehavior.opaque,
                                                dragStartBehavior: DragStartBehavior.down,
                                                onTapUp: _isAddingTrackNote
                                                    ? (details) {
                                                        _handleMapTapForTrackNote(
                                                          tapLocalPosition:
                                                              details.localPosition,
                                                          canvasSize: Size(
                                                            constraints.maxWidth,
                                                            constraints.maxHeight,
                                                          ),
                                                          worldBounds: world,
                                                        );
                                                      }
                                                    : null,
                                                onPanStart: _isAddingTrackNote
                                                    ? (details) {
                                                        _handleMapPanStartForTrackNote(
                                                          localPosition:
                                                              details.localPosition,
                                                          canvasSize: Size(
                                                            constraints.maxWidth,
                                                            constraints.maxHeight,
                                                          ),
                                                          worldBounds: world,
                                                        );
                                                      }
                                                    : null,
                                                onPanUpdate: _isAddingTrackNote
                                                    ? (details) {
                                                        _handleMapPanUpdateForTrackNote(
                                                          localPosition:
                                                              details.localPosition,
                                                          canvasSize: Size(
                                                            constraints.maxWidth,
                                                            constraints.maxHeight,
                                                          ),
                                                          worldBounds: world,
                                                        );
                                                      }
                                                    : null,
                                                onPanEnd: _isAddingTrackNote
                                                    ? (_) =>
                                                          _handleMapPanEndForTrackNote()
                                                    : null,
                                                child: InteractiveViewer(
                                                  transformationController:
                                                      _mapTransformController,
                                                  minScale: _minMapScale,
                                                  maxScale: _maxMapScale,
                                                  panEnabled: !_isAddingTrackNote,
                                                  scaleEnabled: !_isAddingTrackNote,
                                                  boundaryMargin:
                                                      const EdgeInsets.all(900),
                                                  child: SizedBox(
                                                    width: constraints.maxWidth,
                                                    height: constraints.maxHeight,
                                                    child: AnimatedBuilder(
                                                      animation:
                                                          _mapTransformController,
                                                      builder: (context, _) {
                                                        final currentScale =
                                                            _mapTransformController
                                                                .value
                                                                .getMaxScaleOnAxis();
                                                        return CustomPaint(
                                                          painter: OverlayPainter(
                                                            worldBounds: world,
                                                            contourLayers:
                                                                List<
                                                                  ContourLayer
                                                                >.unmodifiable(
                                                                  _contourLayers,
                                                                ),
                                                            tracks:
                                                                List<
                                                                  TrackLayer
                                                                >.unmodifiable(
                                                                  _tracks,
                                                                ),
                                                            trackNoteFontFamily:
                                                                _resolvedTrackNoteFontFamily(),
                                                            viewScale:
                                                                currentScale,
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                        if (_showTitleDecoration)
                                          Positioned(
                                            top: 14,
                                            left: 70,
                                            right: 70,
                                            child: _MapTitleBadge(
                                              text: _mapTitle,
                                              onTap: _editMapTitle,
                                              color: _titleColor,
                                              fontSize: _titleFontSize,
                                              fontFamily: _titleFontFamily,
                                            ),
                                          ),
                                        if (_showNorthArrowDecoration)
                                          Positioned(
                                            top: _showTitleDecoration ? 58 : 14,
                                            right: 12,
                                            child: const IgnorePointer(
                                              child: _NorthArrowBadge(),
                                            ),
                                          ),
                                        if (_showLegendDecoration)
                                          Positioned(
                                            left: 12,
                                            bottom: 12,
                                            child: IgnorePointer(
                                              child: _LegendBadge(
                                                trackColor:
                                                    selectedTrack?.color ??
                                                    const Color(0xFFE74B3C),
                                                majorInterval:
                                                    legendIntervals.majorInterval,
                                                minorInterval:
                                                    legendIntervals.minorInterval,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: 12,
                                  top: 12,
                                  child: _LeftTools(
                                    isLoadingContour:
                                        _isLoadingContourSources ||
                                        _isLoadingContourLayer,
                                    onAddContourLayer: _showContourSourcePicker,
                                    isLoadingRoute: _isLoadingRoute,
                                    onPickGpx: _pickRouteFromGpx,
                                    titleDecorationVisible: _showTitleDecoration,
                                    northArrowDecorationVisible:
                                        _showNorthArrowDecoration,
                                    legendDecorationVisible:
                                        _showLegendDecoration,
                                    onToggleDecoration: _toggleMapDecoration,
                                  ),
                                ),
                                if (_isLayerPanelVisible)
                                  Positioned(
                                    left: layerPanelOffset.dx,
                                    top: layerPanelOffset.dy,
                                    child: _LayerPanel(
                                      contourLayers: _contourLayers,
                                      selectedLayerId: _selectedLayerId,
                                      tracks: _tracks,
                                      titleDecorationVisible:
                                          _showTitleDecoration,
                                      northArrowDecorationVisible:
                                          _showNorthArrowDecoration,
                                      legendDecorationVisible:
                                          _showLegendDecoration,
                                      onDecorationVisibleChanged:
                                          _setMapDecorationVisible,
                                      onRemoveDecoration: _removeMapDecoration,
                                      onClose: _toggleLayerPanelVisible,
                                      onHeaderDragUpdate: (details) =>
                                          _moveLayerPanel(
                                            details.delta,
                                            mapConstraints.biggest,
                                          ),
                                      onSelectLayer: (id) {
                                        setState(() {
                                          _selectedLayerId = id;
                                          if (!_tracks.any(
                                            (track) => track.id == id,
                                          )) {
                                            _isAddingTrackNote = false;
                                            _clearTrackNoteDragState();
                                            _clearTrackNoteMoveReady();
                                          }
                                        });
                                      },
                                      onExtraContourVisibleChanged:
                                          _setExtraContourVisible,
                                      onTrackVisibleChanged: _setTrackVisible,
                                      onTrackNoteVisibleChanged:
                                          _setTrackNoteVisible,
                                      onRemoveContourLayer: _removeContourLayer,
                                      onRemoveTrack: _removeTrack,
                                      onRemoveTrackNote: _removeTrackNote,
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (isTitleLayerSelected)
                    _TitleStylePanel(
                      titleText: _mapTitle,
                      selectedColor: _titleColor,
                      selectedFontSize: _titleFontSize,
                      selectedFontFamily: _titleFontFamily,
                      colorChoices: _styleColors,
                      onColorChanged: _updateTitleColor,
                      onFontSizeChanged: _updateTitleFontSize,
                      onOpenFontPicker: _showTitleFontPicker,
                    )
                  else
                    _StylePanel(
                      activeLayerName: selectedStyleLayerName,
                      activeLayerKind: selectedStyleLayerKind,
                      isTrackLayerSelected: selectedTrack != null,
                      trackNoteMode: _isAddingTrackNote,
                      onToggleTrackNoteMode: _toggleTrackNoteMode,
                      enabled: styleEnabled,
                      selectedColor: activeColor,
                      selectedWidth: activeWidth,
                      selectedOpacity: activeOpacity,
                      colorChoices: _styleColors,
                      onColorChanged: _updateSelectedColor,
                      onWidthChanged: _updateSelectedWidth,
                      onOpacityChanged: _updateSelectedOpacity,
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TopStrip extends StatelessWidget {
  const _TopStrip({
    required this.statusMessage,
    required this.trackEditMode,
    required this.onResetView,
    required this.onExportImage,
    required this.isExportingImage,
    required this.layerPanelVisible,
    required this.onToggleLayerPanelVisible,
  });

  final String? statusMessage;
  final bool trackEditMode;
  final VoidCallback onResetView;
  final VoidCallback onExportImage;
  final bool isExportingImage;
  final bool layerPanelVisible;
  final VoidCallback onToggleLayerPanelVisible;

  @override
  Widget build(BuildContext context) {
    final titleText = trackEditMode ? '경로 편집 모드' : '등고선 편집기';
    final titleStyle = trackEditMode
        ? const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
            color: Color(0xFF1D2A24),
          )
        : Theme.of(context).textTheme.titleSmall;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFE8EEEA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.terrain, size: 18),
          const SizedBox(width: 8),
          Tooltip(
            message: statusMessage ?? titleText,
            child: Text(
              titleText,
              style: titleStyle,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: layerPanelVisible ? '레이어 패널 숨기기' : '레이어 패널 보기',
            onPressed: onToggleLayerPanelVisible,
            icon: Icon(
              layerPanelVisible
                  ? Icons.layers_clear_outlined
                  : Icons.layers_outlined,
              size: 18,
            ),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: 'PNG 저장',
            onPressed: isExportingImage ? null : onExportImage,
            icon: Icon(
              isExportingImage ? Icons.hourglass_top : Icons.download_rounded,
              size: 18,
            ),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: '선택 레이어 중심 이동',
            onPressed: onResetView,
            icon: const Icon(Icons.center_focus_strong, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _MapTitleBadge extends StatelessWidget {
  const _MapTitleBadge({
    required this.text,
    required this.color,
    required this.fontSize,
    required this.fontFamily,
    this.onTap,
  });

  final String text;
  final Color color;
  final double fontSize;
  final String fontFamily;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: fontSize,
              height: 1.05,
              fontFamily: fontFamily,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

class _NorthArrowBadge extends StatelessWidget {
  const _NorthArrowBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(238),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFC9D4CD)),
      ),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('N', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          Icon(Icons.navigation, size: 18),
        ],
      ),
    );
  }
}

class _LegendIntervals {
  const _LegendIntervals({
    required this.majorInterval,
    required this.minorInterval,
  });

  final int majorInterval;
  final int minorInterval;
}

class _LegendBadge extends StatelessWidget {
  const _LegendBadge({
    required this.trackColor,
    required this.majorInterval,
    required this.minorInterval,
  });

  final Color trackColor;
  final int majorInterval;
  final int minorInterval;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(240),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFC9D4CD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '범례',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          _LegendRow(
            label: '주곡선 (${majorInterval}m 간격)',
            lineColor: const Color(0xFF4B6256).withAlpha(190),
            thickness: 2.0,
          ),
          const SizedBox(height: 3),
          _LegendRow(
            label: '보조곡선 (${minorInterval}m 간격)',
            lineColor: const Color(0xFF60766A).withAlpha(130),
            thickness: 1.2,
          ),
          const SizedBox(height: 3),
          _LegendRow(label: '트랙', lineColor: trackColor, thickness: 2.4),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.label,
    required this.lineColor,
    required this.thickness,
  });

  final String label;
  final Color lineColor;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 30,
          height: thickness,
          decoration: BoxDecoration(
            color: lineColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 7),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

class _LeftTools extends StatelessWidget {
  const _LeftTools({
    required this.isLoadingContour,
    required this.onAddContourLayer,
    required this.isLoadingRoute,
    required this.onPickGpx,
    required this.titleDecorationVisible,
    required this.northArrowDecorationVisible,
    required this.legendDecorationVisible,
    required this.onToggleDecoration,
  });

  final bool isLoadingContour;
  final VoidCallback onAddContourLayer;
  final bool isLoadingRoute;
  final VoidCallback onPickGpx;
  final bool titleDecorationVisible;
  final bool northArrowDecorationVisible;
  final bool legendDecorationVisible;
  final ValueChanged<MapDecorationType> onToggleDecoration;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ToolButton(
          icon: isLoadingContour ? Icons.hourglass_top : Icons.layers_outlined,
          onTap: isLoadingContour ? null : onAddContourLayer,
          tooltip: '등고선 레이어 추가',
        ),
        const SizedBox(height: 8),
        _ToolButton(
          icon: isLoadingRoute ? Icons.hourglass_top : Icons.route,
          onTap: isLoadingRoute ? null : onPickGpx,
          tooltip: '내 트랙 가져오기',
        ),
        const SizedBox(height: 8),
        _DecorationToolButton(
          titleDecorationVisible: titleDecorationVisible,
          northArrowDecorationVisible: northArrowDecorationVisible,
          legendDecorationVisible: legendDecorationVisible,
          onToggleDecoration: onToggleDecoration,
        ),
      ],
    );
  }
}

class _DecorationToolButton extends StatelessWidget {
  const _DecorationToolButton({
    required this.titleDecorationVisible,
    required this.northArrowDecorationVisible,
    required this.legendDecorationVisible,
    required this.onToggleDecoration,
  });

  final bool titleDecorationVisible;
  final bool northArrowDecorationVisible;
  final bool legendDecorationVisible;
  final ValueChanged<MapDecorationType> onToggleDecoration;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withAlpha(235),
      borderRadius: BorderRadius.circular(8),
      child: Tooltip(
        message: '제목/방위표/범례 추가',
        child: SizedBox(
          width: 38,
          height: 38,
          child: PopupMenuButton<MapDecorationType>(
            onSelected: onToggleDecoration,
            itemBuilder: (context) => [
              CheckedPopupMenuItem<MapDecorationType>(
                value: MapDecorationType.title,
                checked: titleDecorationVisible,
                child: const Text('제목'),
              ),
              CheckedPopupMenuItem<MapDecorationType>(
                value: MapDecorationType.northArrow,
                checked: northArrowDecorationVisible,
                child: const Text('방위표'),
              ),
              CheckedPopupMenuItem<MapDecorationType>(
                value: MapDecorationType.legend,
                checked: legendDecorationVisible,
                child: const Text('범례'),
              ),
            ],
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.add_reaction_outlined, size: 19),
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withAlpha(235),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Tooltip(
          message: tooltip,
          child: SizedBox(width: 38, height: 38, child: Icon(icon, size: 19)),
        ),
      ),
    );
  }
}

class _LayerPanel extends StatelessWidget {
  const _LayerPanel({
    required this.contourLayers,
    required this.selectedLayerId,
    required this.tracks,
    required this.titleDecorationVisible,
    required this.northArrowDecorationVisible,
    required this.legendDecorationVisible,
    required this.onDecorationVisibleChanged,
    required this.onRemoveDecoration,
    required this.onClose,
    required this.onHeaderDragUpdate,
    required this.onSelectLayer,
    required this.onExtraContourVisibleChanged,
    required this.onTrackVisibleChanged,
    required this.onTrackNoteVisibleChanged,
    required this.onRemoveContourLayer,
    required this.onRemoveTrack,
    required this.onRemoveTrackNote,
  });

  final List<ContourLayer> contourLayers;
  final String selectedLayerId;
  final List<TrackLayer> tracks;
  final bool titleDecorationVisible;
  final bool northArrowDecorationVisible;
  final bool legendDecorationVisible;
  final void Function(MapDecorationType, bool) onDecorationVisibleChanged;
  final ValueChanged<MapDecorationType> onRemoveDecoration;
  final VoidCallback onClose;
  final GestureDragUpdateCallback onHeaderDragUpdate;
  final ValueChanged<String> onSelectLayer;
  final void Function(String, bool) onExtraContourVisibleChanged;
  final void Function(String, bool) onTrackVisibleChanged;
  final void Function(String, String, bool) onTrackNoteVisibleChanged;
  final ValueChanged<String> onRemoveContourLayer;
  final ValueChanged<String> onRemoveTrack;
  final void Function(String, String) onRemoveTrackNote;

  @override
  Widget build(BuildContext context) {
    final hasDecorationLayers =
        titleDecorationVisible ||
        northArrowDecorationVisible ||
        legendDecorationVisible;
    final hasDataLayers = contourLayers.isNotEmpty || tracks.isNotEmpty;

    return Container(
      width: 210,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(242),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFC9D4CD)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onPanUpdate: onHeaderDragUpdate,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                const Icon(Icons.drag_indicator, size: 16, color: Color(0xFF718179)),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text(
                    '레이어',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '레이어 패널 닫기',
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 16),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          if (hasDecorationLayers) const SizedBox(height: 2),
          if (titleDecorationVisible)
            _LayerTile(
              label: '제목',
              visible: titleDecorationVisible,
              selected:
                  selectedLayerId == _decorationLayerId(MapDecorationType.title),
              onTap: () => onSelectLayer(_decorationLayerId(MapDecorationType.title)),
              onVisibleChanged: (value) =>
                  onDecorationVisibleChanged(MapDecorationType.title, value),
              onRemove: () => onRemoveDecoration(MapDecorationType.title),
            ),
          if (northArrowDecorationVisible)
            _LayerTile(
              label: '방위표',
              visible: northArrowDecorationVisible,
              selected: selectedLayerId ==
                  _decorationLayerId(MapDecorationType.northArrow),
              onTap: () =>
                  onSelectLayer(_decorationLayerId(MapDecorationType.northArrow)),
              onVisibleChanged: (value) =>
                  onDecorationVisibleChanged(MapDecorationType.northArrow, value),
              onRemove: () => onRemoveDecoration(MapDecorationType.northArrow),
            ),
          if (legendDecorationVisible)
            _LayerTile(
              label: '범례',
              visible: legendDecorationVisible,
              selected:
                  selectedLayerId == _decorationLayerId(MapDecorationType.legend),
              onTap: () =>
                  onSelectLayer(_decorationLayerId(MapDecorationType.legend)),
              onVisibleChanged: (value) =>
                  onDecorationVisibleChanged(MapDecorationType.legend, value),
              onRemove: () => onRemoveDecoration(MapDecorationType.legend),
            ),
          if (hasDecorationLayers && hasDataLayers) const SizedBox(height: 2),
          ...contourLayers.map(
            (contourLayer) => _LayerTile(
              label: contourLayer.name,
              visible: contourLayer.visible,
              selected: selectedLayerId == contourLayer.id,
              onTap: () => onSelectLayer(contourLayer.id),
              onVisibleChanged: (value) =>
                  onExtraContourVisibleChanged(contourLayer.id, value),
              onRemove: () => onRemoveContourLayer(contourLayer.id),
            ),
          ),
          ...tracks.expand((track) sync* {
            yield _LayerTile(
              label: track.name,
              visible: track.visible,
              selected: selectedLayerId == track.id,
              onTap: () => onSelectLayer(track.id),
              onVisibleChanged: (value) =>
                  onTrackVisibleChanged(track.id, value),
              onRemove: () => onRemoveTrack(track.id),
            );
            for (final note in track.notes) {
              yield _LayerSubTile(
                label: note.text,
                visible: note.isVisible,
                onTap: () => onSelectLayer(track.id),
                onVisibleChanged: (value) =>
                    onTrackNoteVisibleChanged(track.id, note.id, value),
                onRemove: () => onRemoveTrackNote(track.id, note.id),
              );
            }
          }),
        ],
      ),
    );
  }
}

class _LayerTile extends StatelessWidget {
  const _LayerTile({
    required this.label,
    required this.visible,
    required this.selected,
    required this.onTap,
    required this.onVisibleChanged,
    this.onRemove,
  });

  final String label;
  final bool visible;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onVisibleChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFFEAF1ED) : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 32,
          child: Row(
            children: [
              Checkbox(
                value: visible,
                onChanged: (value) => onVisibleChanged(value ?? false),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              if (onRemove != null)
                IconButton(
                  tooltip: '레이어 삭제',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LayerSubTile extends StatelessWidget {
  const _LayerSubTile({
    required this.label,
    required this.visible,
    required this.onTap,
    required this.onVisibleChanged,
    this.onRemove,
  });

  final String label;
  final bool visible;
  final VoidCallback onTap;
  final ValueChanged<bool> onVisibleChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 28,
            child: Row(
              children: [
                Checkbox(
                  value: visible,
                  onChanged: (value) => onVisibleChanged(value ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                const Icon(Icons.place_outlined, size: 12, color: Color(0xFF6C7D74)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF33443C)),
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    tooltip: '포인트 삭제',
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline, size: 14),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TitleStylePanel extends StatelessWidget {
  const _TitleStylePanel({
    required this.titleText,
    required this.selectedColor,
    required this.selectedFontSize,
    required this.selectedFontFamily,
    required this.colorChoices,
    required this.onColorChanged,
    required this.onFontSizeChanged,
    required this.onOpenFontPicker,
  });

  final String titleText;
  final Color selectedColor;
  final double selectedFontSize;
  final String selectedFontFamily;
  final List<Color> colorChoices;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onFontSizeChanged;
  final VoidCallback onOpenFontPicker;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 128,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFE8EEEA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '제목 스타일: $titleText',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          const Text(
            '선택한 제목 레이어에 적용됩니다.',
            style: TextStyle(fontSize: 10, color: Color(0xFF5A6A62)),
          ),
          Text(
            '현재 폰트: $selectedFontFamily',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Color(0xFF5A6A62)),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _StyleCell(
                    title: '색상',
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: colorChoices
                          .map(
                            (color) => GestureDetector(
                              onTap: () => onColorChanged(color),
                              child: Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: color.toARGB32() ==
                                            selectedColor.toARGB32()
                                        ? Colors.black
                                        : Colors.white,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
                Expanded(
                  child: _StyleCell(
                    title: '글씨 크기',
                    child: Slider(
                      value: selectedFontSize.clamp(12, 56),
                      min: 12,
                      max: 56,
                      onChanged: onFontSizeChanged,
                    ),
                  ),
                ),
                Expanded(
                  child: _StyleCell(
                    title: '폰트',
                    trailing: TextButton(
                      onPressed: onOpenFontPicker,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 0,
                        ),
                        minimumSize: const Size(0, 22),
                      ),
                      child: const Text('선택', style: TextStyle(fontSize: 10)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '선택: $selectedFontFamily',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: const Color(0xFF4E5E56),
                                fontFamily: selectedFontFamily,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StylePanel extends StatelessWidget {
  const _StylePanel({
    required this.activeLayerName,
    required this.activeLayerKind,
    required this.isTrackLayerSelected,
    required this.trackNoteMode,
    required this.onToggleTrackNoteMode,
    required this.enabled,
    required this.selectedColor,
    required this.selectedWidth,
    required this.selectedOpacity,
    required this.colorChoices,
    required this.onColorChanged,
    required this.onWidthChanged,
    required this.onOpacityChanged,
  });

  final String activeLayerName;
  final String activeLayerKind;
  final bool isTrackLayerSelected;
  final bool trackNoteMode;
  final VoidCallback onToggleTrackNoteMode;
  final bool enabled;
  final Color selectedColor;
  final double selectedWidth;
  final double selectedOpacity;
  final List<Color> colorChoices;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onWidthChanged;
  final ValueChanged<double> onOpacityChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: isTrackLayerSelected ? 136 : 102,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFE8EEEA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isTrackLayerSelected)
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 168,
                height: 22,
                child: OutlinedButton.icon(
                  onPressed: onToggleTrackNoteMode,
                  icon: Icon(
                    trackNoteMode
                        ? Icons.edit_location_alt
                        : Icons.edit_location_outlined,
                    size: 12,
                  ),
                  label: Text(
                    trackNoteMode ? '경로 편집 모드 OFF' : '경로 편집 모드 ON',
                    style: const TextStyle(fontSize: 9.5),
                  ),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                    side: BorderSide(
                      color: trackNoteMode
                          ? const Color(0xFF1E7E55)
                          : const Color(0xFF8CA095),
                      width: 1,
                    ),
                    backgroundColor: trackNoteMode
                        ? const Color(0xFFDDECE4)
                        : Colors.white.withAlpha(220),
                    foregroundColor: const Color(0xFF23322B),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ),
          if (isTrackLayerSelected) const SizedBox(height: 4),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _StyleCell(
                    title: '색상',
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: colorChoices
                          .map(
                            (color) => GestureDetector(
                              onTap: enabled
                                  ? () => onColorChanged(color)
                                  : null,
                              child: Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  color: enabled ? color : color.withAlpha(110),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color:
                                        color.toARGB32() ==
                                            selectedColor.toARGB32()
                                        ? Colors.black
                                        : Colors.white,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
                Expanded(
                  child: _StyleCell(
                    title: '두께',
                    child: Slider(
                      value: selectedWidth,
                      min: 0.3,
                      max: 6.0,
                      onChanged: enabled ? onWidthChanged : null,
                    ),
                  ),
                ),
                Expanded(
                  child: _StyleCell(
                    title: '투명도',
                    child: Slider(
                      value: selectedOpacity,
                      min: 0.1,
                      max: 1.0,
                      onChanged: enabled ? onOpacityChanged : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StyleCell extends StatelessWidget {
  const _StyleCell({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(204),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              ?trailing,
            ],
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class OverlayPainter extends CustomPainter {
  OverlayPainter({
    required this.worldBounds,
    required this.contourLayers,
    required this.tracks,
    required this.trackNoteFontFamily,
    required this.viewScale,
  });

  final Rect worldBounds;
  final List<ContourLayer> contourLayers;
  final List<TrackLayer> tracks;
  final String trackNoteFontFamily;
  final double viewScale;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }

    final projector = _Projector(world: worldBounds, canvasSize: size);
    final safeScale = viewScale <= 0 ? 1.0 : viewScale;
    // Treat contour rendering as one step more zoomed-in so mountain-level
    // views look lighter and less bulky at the same gesture scale.
    final contourRenderScale = safeScale * 1.85;

    double zoomAdjustedStroke(double base) {
      return (base / safeScale).clamp(0.4, 7.0);
    }

    double zoomAdjustedContourStroke(double base) {
      return (base / contourRenderScale).clamp(0.03, 0.52);
    }

    double zoomAdjustedRadius(double base) {
      return (base / safeScale).clamp(0.7, 3.2);
    }

    final contourInterval = _contourIntervalForScale(contourRenderScale);
    for (final layer in contourLayers.where((layer) => layer.visible)) {
      final layerWidth = layer.width.clamp(0.3, 6.0);
      final layerOpacity = layer.opacity.clamp(0.0, 1.0);
      final minorBase = 0.08 * layerWidth;
      final majorBase = 0.14 * layerWidth;
      final minorAlpha = (255 * layerOpacity * 0.75).round().clamp(0, 255);
      final majorAlpha = (255 * layerOpacity).round().clamp(0, 255);
      final extraMinorPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = zoomAdjustedContourStroke(minorBase)
        ..strokeCap = StrokeCap.butt
        ..strokeJoin = StrokeJoin.bevel
        ..color = layer.color.withAlpha(minorAlpha);
      final extraMajorPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = zoomAdjustedContourStroke(majorBase)
        ..strokeCap = StrokeCap.butt
        ..strokeJoin = StrokeJoin.bevel
        ..color = layer.color.withAlpha(majorAlpha);

      for (final contour in layer.contours) {
        if (!_shouldDrawContour(contour, contourInterval)) {
          continue;
        }
        if (contourInterval >= 20 && contour.line.length < 3) {
          // Avoid dot-like artifacts from tiny contour fragments when zoomed out.
          continue;
        }
        final path = _polylinePath(contour.line, projector);
        canvas.drawPath(
          path,
          contour.major ? extraMajorPaint : extraMinorPaint,
        );
      }
    }

    for (final track in tracks.where((track) => track.visible)) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = zoomAdjustedStroke(track.width)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = track.color.withAlpha(
          (track.opacity.clamp(0.0, 1.0) * 255).round(),
        );

      for (final line in track.lines) {
        final path = _polylinePath(line, projector);
        canvas.drawPath(path, paint);
      }

      if (track.lines.isNotEmpty && track.lines.first.isNotEmpty) {
        final start = projector.toCanvas(track.lines.first.first);
        final end = projector.toCanvas(track.lines.last.last);
        final markerRadius = zoomAdjustedRadius(1.4);
        canvas.drawCircle(
          start,
          markerRadius,
          Paint()..color = const Color(0xFF1E7E55),
        );
        canvas.drawCircle(
          end,
          markerRadius,
          Paint()..color = const Color(0xFFC7292D),
        );
      }

      for (final note in track.notes) {
        if (!note.isVisible) {
          continue;
        }
        final markerCenter = projector.toCanvas(note.point);
        final markerRadius = zoomAdjustedRadius(1.8);
        final markerFill = Paint()..color = Colors.white.withAlpha(235);
        final markerStroke = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = track.color.withAlpha(220);
        canvas.drawCircle(markerCenter, markerRadius + 0.6, markerFill);
        canvas.drawCircle(markerCenter, markerRadius + 0.6, markerStroke);

        final labelLayout = _buildTrackNoteLabelLayout(
          note: note,
          projector: projector,
          fontFamily: trackNoteFontFamily,
        );
        final leaderStroke = zoomAdjustedStroke(0.35).clamp(0.3, 1.0);
        final leaderPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = leaderStroke
          ..color = track.color.withAlpha(145);
        canvas.drawLine(markerCenter, labelLayout.rect.center, leaderPaint);

        labelLayout.textPainter.paint(
          canvas,
          Offset(labelLayout.rect.left + 3, labelLayout.rect.top + 2),
        );
      }
    }
  }

  int _contourIntervalForScale(double scale) {
    if (scale < 1.1) {
      return 100;
    }
    if (scale < 2.0) {
      return 40;
    }
    if (scale < 3.6) {
      return 20;
    }
    if (scale < 6.0) {
      return 10;
    }
    return 0;
  }

  bool _shouldDrawContour(ContourLine contour, int interval) {
    if (interval <= 0) {
      return true;
    }
    final elev = contour.elevation.abs();
    if (elev == 0) {
      return contour.major || interval <= 20;
    }
    if (elev % interval == 0) {
      return true;
    }
    // Keep index contours visible when zoomed out even if interval does not align.
    if (interval >= 40 && contour.major) {
      return true;
    }
    return false;
  }

  Path _polylinePath(List<Offset> line, _Projector projector) {
    final path = Path();
    if (line.isEmpty) {
      return path;
    }
    final first = projector.toCanvas(line.first);
    path.moveTo(first.dx, first.dy);
    for (var i = 1; i < line.length; i++) {
      final p = projector.toCanvas(line[i]);
      path.lineTo(p.dx, p.dy);
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant OverlayPainter oldDelegate) {
    return oldDelegate.worldBounds != worldBounds ||
        oldDelegate.contourLayers != contourLayers ||
        oldDelegate.tracks != tracks ||
        oldDelegate.trackNoteFontFamily != trackNoteFontFamily ||
        oldDelegate.viewScale != viewScale;
  }
}

class _TrackNoteLabelLayout {
  const _TrackNoteLabelLayout({
    required this.rect,
    required this.textPainter,
  });

  final Rect rect;
  final TextPainter textPainter;
}

_TrackNoteLabelLayout _buildTrackNoteLabelLayout({
  required TrackNote note,
  required _Projector projector,
  required String fontFamily,
}) {
  final textPainter = TextPainter(
    text: TextSpan(
      text: note.text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: const Color(0xFF22302A),
        fontFamily: fontFamily,
        fontFamilyFallback: const ['Noto Sans KR'],
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: 120);

  final labelCenter = projector.toCanvas(note.point + note.labelOffset);
  final labelRect = Rect.fromCenter(
    center: labelCenter,
    width: textPainter.width + 6,
    height: textPainter.height + 4,
  );

  return _TrackNoteLabelLayout(rect: labelRect, textPainter: textPainter);
}

class _Projector {
  _Projector({required this.world, required this.canvasSize}) {
    final sx = canvasSize.width / world.width;
    final sy = canvasSize.height / world.height;
    // Keep a zoomed baseline so mountain-scale sections are visible by default.
    scale = math.min(sx, sy) * 1.6;

    final drawW = world.width * scale;
    final drawH = world.height * scale;
    leftPad = (canvasSize.width - drawW) / 2;
    topPad = (canvasSize.height - drawH) / 2;
  }

  final Rect world;
  final Size canvasSize;
  late final double scale;
  late final double leftPad;
  late final double topPad;

  Offset toCanvas(Offset worldPoint) {
    final x = leftPad + (worldPoint.dx - world.left) * scale;
    final y = topPad + (world.bottom - worldPoint.dy) * scale;
    return Offset(x, y);
  }

  Offset toWorld(Offset canvasPoint) {
    final x = world.left + (canvasPoint.dx - leftPad) / scale;
    final y = world.bottom - (canvasPoint.dy - topPad) / scale;
    return Offset(x, y);
  }
}

class OverlayData {
  OverlayData({required this.bounds, required this.contours});

  final Rect bounds;
  final List<ContourLine> contours;

  factory OverlayData.fromJson(Map<String, dynamic> json) {
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
              (item) => ContourLine(
                elevation: (item['elev'] as num).toInt(),
                major: item['major'] as bool,
                line: _parseLine(item['line'] as List<dynamic>),
              ),
            )
            .toList(growable: false);

    return OverlayData(bounds: bounds, contours: contours);
  }

  static List<Offset> _parseLine(List<dynamic> rawLine) {
    return rawLine
        .map((point) => point as List<dynamic>)
        .map(
          (point) => Offset(
            (point[0] as num).toDouble(),
            (point[1] as num).toDouble(),
          ),
        )
        .toList(growable: false);
  }
}

class ContourLine {
  const ContourLine({
    required this.elevation,
    required this.major,
    required this.line,
  });

  final int elevation;
  final bool major;
  final List<Offset> line;
}

class ContourLayer {
  const ContourLayer({
    required this.id,
    required this.sourceId,
    required this.name,
    required this.bounds,
    required this.contours,
    required this.visible,
    required this.color,
    required this.width,
    required this.opacity,
  });

  final String id;
  final String sourceId;
  final String name;
  final Rect bounds;
  final List<ContourLine> contours;
  final bool visible;
  final Color color;
  final double width;
  final double opacity;

  ContourLayer copyWith({
    String? id,
    String? sourceId,
    String? name,
    Rect? bounds,
    List<ContourLine>? contours,
    bool? visible,
    Color? color,
    double? width,
    double? opacity,
  }) {
    return ContourLayer(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      name: name ?? this.name,
      bounds: bounds ?? this.bounds,
      contours: contours ?? this.contours,
      visible: visible ?? this.visible,
      color: color ?? this.color,
      width: width ?? this.width,
      opacity: opacity ?? this.opacity,
    );
  }
}

class TrackLayer {
  const TrackLayer({
    required this.id,
    required this.name,
    required this.lines,
    this.notes = const [],
    required this.visible,
    required this.color,
    required this.width,
    required this.opacity,
  });

  final String id;
  final String name;
  final List<List<Offset>> lines;
  final List<TrackNote> notes;
  final bool visible;
  final Color color;
  final double width;
  final double opacity;

  TrackLayer copyWith({
    String? id,
    String? name,
    List<List<Offset>>? lines,
    List<TrackNote>? notes,
    bool? visible,
    Color? color,
    double? width,
    double? opacity,
  }) {
    return TrackLayer(
      id: id ?? this.id,
      name: name ?? this.name,
      lines: lines ?? this.lines,
      notes: notes ?? this.notes,
      visible: visible ?? this.visible,
      color: color ?? this.color,
      width: width ?? this.width,
      opacity: opacity ?? this.opacity,
    );
  }
}

class TrackNote {
  const TrackNote({
    required this.id,
    required this.point,
    required this.text,
    this.labelOffset = Offset.zero,
    this.visible = true,
  });

  final String id;
  final Offset point;
  final String text;
  final Offset labelOffset;
  final bool? visible;
  bool get isVisible => visible ?? true;

  TrackNote copyWith({
    String? id,
    Offset? point,
    String? text,
    Offset? labelOffset,
    bool? visible,
  }) {
    return TrackNote(
      id: id ?? this.id,
      point: point ?? this.point,
      text: text ?? this.text,
      labelOffset: labelOffset ?? this.labelOffset,
      visible: visible ?? this.visible ?? true,
    );
  }
}

class _NearestTrackPoint {
  const _NearestTrackPoint({
    required this.worldPoint,
    required this.distancePx,
  });

  final Offset worldPoint;
  final double distancePx;
}

class _NearestTrackNote {
  const _NearestTrackNote({
    required this.note,
    required this.distancePx,
    required this.hitTarget,
  });

  final TrackNote note;
  final double distancePx;
  final _TrackNoteHitTarget hitTarget;
}

enum _TrackNoteAction {
  edit,
  moveText,
  delete,
}

enum _TrackNoteHitTarget {
  marker,
  label,
}

enum _TrackNoteDragTarget {
  label,
}
