import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' as share_plus;

import 'contour_source_loader.dart';
import 'gpx_route_loader.dart';

enum MapDecorationType { title, northArrow, legend }

void main() {
  runApp(const ContourRouteApp());
}

class ContourRouteApp extends StatelessWidget {
  const ContourRouteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Contour + GPX Route',
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
  bool _showTitleDecoration = false;
  bool _showNorthArrowDecoration = false;
  bool _showLegendDecoration = false;
  String _mapTitle = '나의 트랙';
  String? _statusMessage;
  String _selectedLayerId = '';
  int _trackSerial = 0;

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
      if (_selectedLayerId == trackId) {
        _selectedLayerId = '';
      }
      _statusMessage = '트랙 삭제: ${removed.name}';
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

  void _updateSelectedColor(Color color) {
    final selected = _selectedTrack();
    if (selected == null) {
      return;
    }
    setState(() {
      final idx = _tracks.indexWhere((track) => track.id == selected.id);
      _tracks[idx] = selected.copyWith(color: color);
    });
  }

  void _updateSelectedWidth(double width) {
    final selected = _selectedTrack();
    if (selected == null) {
      return;
    }
    setState(() {
      final idx = _tracks.indexWhere((track) => track.id == selected.id);
      _tracks[idx] = selected.copyWith(width: width);
    });
  }

  void _updateSelectedOpacity(double opacity) {
    final selected = _selectedTrack();
    if (selected == null) {
      return;
    }
    setState(() {
      final idx = _tracks.indexWhere((track) => track.id == selected.id);
      _tracks[idx] = selected.copyWith(opacity: opacity);
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

  void _toggleMapDecoration(MapDecorationType type) {
    setState(() {
      String label;
      bool visible;
      switch (type) {
        case MapDecorationType.title:
          _showTitleDecoration = !_showTitleDecoration;
          label = '제목';
          visible = _showTitleDecoration;
          break;
        case MapDecorationType.northArrow:
          _showNorthArrowDecoration = !_showNorthArrowDecoration;
          label = '방위표';
          visible = _showNorthArrowDecoration;
          break;
        case MapDecorationType.legend:
          _showLegendDecoration = !_showLegendDecoration;
          label = '범례';
          visible = _showLegendDecoration;
          break;
      }
      _statusMessage = visible ? '$label 표시' : '$label 숨김';
    });
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
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
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = '이미지 저장 실패: $error';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('이미지 저장 실패: $error')),
      );
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
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _contourLayers.add(layer);
        _selectedLayerId = layer.id;
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
            final styleEnabled = selectedTrack != null;
            final activeColor = selectedTrack?.color ?? _styleColors.first;
            final activeWidth = selectedTrack?.width ?? 2.2;
            final activeOpacity = selectedTrack?.opacity ?? 1.0;

            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                children: [
                  _TopStrip(
                    statusMessage: _statusMessage,
                    onResetView: () => _resetMapView(world),
                    onExportImage: _exportMapImage,
                    isExportingImage: _isExportingImage,
                    layerPanelVisible: _isLayerPanelVisible,
                    onToggleLayerPanelVisible: _toggleLayerPanelVisible,
                    titleDecorationVisible: _showTitleDecoration,
                    northArrowDecorationVisible: _showNorthArrowDecoration,
                    legendDecorationVisible: _showLegendDecoration,
                    onToggleDecoration: _toggleMapDecoration,
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
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: RepaintBoundary(
                                key: _mapCaptureKey,
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          return InteractiveViewer(
                                            transformationController:
                                                _mapTransformController,
                                            minScale: _minMapScale,
                                            maxScale: _maxMapScale,
                                            panEnabled: true,
                                            scaleEnabled: true,
                                            boundaryMargin: const EdgeInsets.all(
                                              900,
                                            ),
                                            child: SizedBox(
                                              width: constraints.maxWidth,
                                              height: constraints.maxHeight,
                                              child: AnimatedBuilder(
                                                animation: _mapTransformController,
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
                                                          >.unmodifiable(_tracks),
                                                      viewScale: currentScale,
                                                    ),
                                                  );
                                                },
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
                              ),
                            ),
                            if (_isLayerPanelVisible)
                              Positioned(
                                right: 12,
                                top: 12,
                                child: _LayerPanel(
                                  contourLayers: _contourLayers,
                                  selectedLayerId: _selectedLayerId,
                                  tracks: _tracks,
                                  onSelectLayer: (id) {
                                    setState(() {
                                      _selectedLayerId = id;
                                    });
                                  },
                                  onExtraContourVisibleChanged:
                                      _setExtraContourVisible,
                                  onTrackVisibleChanged: _setTrackVisible,
                                  onRemoveContourLayer: _removeContourLayer,
                                  onRemoveTrack: _removeTrack,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _StylePanel(
                    activeLayerName: selectedTrack?.name ?? '선택된 GPX 없음',
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
    required this.onResetView,
    required this.onExportImage,
    required this.isExportingImage,
    required this.layerPanelVisible,
    required this.onToggleLayerPanelVisible,
    required this.titleDecorationVisible,
    required this.northArrowDecorationVisible,
    required this.legendDecorationVisible,
    required this.onToggleDecoration,
  });

  final String? statusMessage;
  final VoidCallback onResetView;
  final VoidCallback onExportImage;
  final bool isExportingImage;
  final bool layerPanelVisible;
  final VoidCallback onToggleLayerPanelVisible;
  final bool titleDecorationVisible;
  final bool northArrowDecorationVisible;
  final bool legendDecorationVisible;
  final ValueChanged<MapDecorationType> onToggleDecoration;

  @override
  Widget build(BuildContext context) {
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
            message: statusMessage ?? '등고선 편집기',
            child: Text(
              '등고선 편집기',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const Spacer(),
          PopupMenuButton<MapDecorationType>(
            tooltip: '아이콘 추가',
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
            icon: const Icon(Icons.add_circle_outline, size: 18),
          ),
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
  const _MapTitleBadge({required this.text, this.onTap});

  final String text;
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
            style: const TextStyle(
              fontSize: 28,
              height: 1.05,
              fontFamily: 'serif',
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: Color(0xFF1F2A24),
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

class _LegendBadge extends StatelessWidget {
  const _LegendBadge({required this.trackColor});

  final Color trackColor;

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
            label: '주곡선',
            lineColor: const Color(0xFF4B6256).withAlpha(190),
            thickness: 2.0,
          ),
          const SizedBox(height: 3),
          _LegendRow(
            label: '보조곡선',
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
  });

  final bool isLoadingContour;
  final VoidCallback onAddContourLayer;
  final bool isLoadingRoute;
  final VoidCallback onPickGpx;

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
      ],
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
    required this.onSelectLayer,
    required this.onExtraContourVisibleChanged,
    required this.onTrackVisibleChanged,
    required this.onRemoveContourLayer,
    required this.onRemoveTrack,
  });

  final List<ContourLayer> contourLayers;
  final String selectedLayerId;
  final List<TrackLayer> tracks;
  final ValueChanged<String> onSelectLayer;
  final void Function(String, bool) onExtraContourVisibleChanged;
  final void Function(String, bool) onTrackVisibleChanged;
  final ValueChanged<String> onRemoveContourLayer;
  final ValueChanged<String> onRemoveTrack;

  @override
  Widget build(BuildContext context) {
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
          Row(
            children: [
              const Expanded(
                child: Text(
                  '레이어',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
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
          ...tracks.map(
            (track) => _LayerTile(
              label: track.name,
              visible: track.visible,
              selected: selectedLayerId == track.id,
              onTap: () => onSelectLayer(track.id),
              onVisibleChanged: (value) =>
                  onTrackVisibleChanged(track.id, value),
              onRemove: () => onRemoveTrack(track.id),
            ),
          ),
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

class _StylePanel extends StatelessWidget {
  const _StylePanel({
    required this.activeLayerName,
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
      height: 116,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFE8EEEA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'GPX 스타일: $activeLayerName',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            enabled ? '현재 선택한 GPX 경로에 적용됩니다.' : '레이어에서 GPX 트랙을 선택하면 적용됩니다.',
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
  const _StyleCell({required this.title, required this.child});

  final String title;
  final Widget child;

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
          Text(title, style: const TextStyle(fontSize: 11)),
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
    required this.viewScale,
  });

  final Rect worldBounds;
  final List<ContourLayer> contourLayers;
  final List<TrackLayer> tracks;
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
    final contourMinorWidth = zoomAdjustedContourStroke(0.18);
    final contourMajorWidth = zoomAdjustedContourStroke(0.30);
    final extraMinorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = contourMinorWidth
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.bevel
      ..color = const Color(0xFF60766A).withAlpha(72);
    final extraMajorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = contourMajorWidth
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.bevel
      ..color = const Color(0xFF4B6256).withAlpha(118);

    for (final layer in contourLayers.where((layer) => layer.visible)) {
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
        oldDelegate.viewScale != viewScale;
  }
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
  });

  final String id;
  final String sourceId;
  final String name;
  final Rect bounds;
  final List<ContourLine> contours;
  final bool visible;

  ContourLayer copyWith({
    String? id,
    String? sourceId,
    String? name,
    Rect? bounds,
    List<ContourLine>? contours,
    bool? visible,
  }) {
    return ContourLayer(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      name: name ?? this.name,
      bounds: bounds ?? this.bounds,
      contours: contours ?? this.contours,
      visible: visible ?? this.visible,
    );
  }
}

class TrackLayer {
  const TrackLayer({
    required this.id,
    required this.name,
    required this.lines,
    required this.visible,
    required this.color,
    required this.width,
    required this.opacity,
  });

  final String id;
  final String name;
  final List<List<Offset>> lines;
  final bool visible;
  final Color color;
  final double width;
  final double opacity;

  TrackLayer copyWith({
    String? id,
    String? name,
    List<List<Offset>>? lines,
    bool? visible,
    Color? color,
    double? width,
    double? opacity,
  }) {
    return TrackLayer(
      id: id ?? this.id,
      name: name ?? this.name,
      lines: lines ?? this.lines,
      visible: visible ?? this.visible,
      color: color ?? this.color,
      width: width ?? this.width,
      opacity: opacity ?? this.opacity,
    );
  }
}
