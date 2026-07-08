import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../compute/bar_feature_compute.dart';
import '../compute/bi_combine_compute.dart';
import '../compute/bi_confirm_compute.dart';
import '../compute/seg_analysis_compute.dart';
import '../compute/bi_virtual_bar_compute.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/bi_confirm_signal.dart';
import '../models/bi_segment.dart';
import '../models/bi_virtual_bar.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../models/kline_combine_frame.dart';
import '../models/seg_analysis.dart';

/// Rust `chan_ffi` 动态库桥接。
class ChanBridge {
  ChanBridge._();

  static final ChanBridge instance = ChanBridge._();

  late final DynamicLibrary _lib;
  bool _ready = false;

  void ensureInitialized() {
    if (_ready) return;
    _lib = _openLibrary();
    _ready = true;
  }

  DynamicLibrary _openLibrary() {
    if (Platform.isWindows) {
      // 开发态优先用工程内绝对路径，避免误加载其它目录旧 DLL。
      final devAbs =
          '${Directory.current.path}${Platform.pathSeparator}windows${Platform.pathSeparator}native${Platform.pathSeparator}chan_ffi.dll';
      if (File(devAbs).existsSync()) {
        return DynamicLibrary.open(devAbs);
      }
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final besideExe = '$exeDir${Platform.pathSeparator}chan_ffi.dll';
      if (File(besideExe).existsSync()) {
        return DynamicLibrary.open(besideExe);
      }
      return DynamicLibrary.open('chan_ffi.dll');
    }
    if (Platform.isLinux) {
      return DynamicLibrary.open('libchan_ffi.so');
    }
    if (Platform.isMacOS) {
      return DynamicLibrary.open('libchan_ffi.dylib');
    }
    throw UnsupportedError('当前平台暂不支持 FFI: ${Platform.operatingSystem}');
  }

  Pointer<Utf8> _toNative(String? text) {
    if (text == null) return nullptr;
    return text.toNativeUtf8();
  }

  String _takeJson(Pointer<Utf8> ptr) {
    if (ptr == nullptr) {
      throw StateError('Rust 返回空指针');
    }
    try {
      return ptr.toDartString();
    } finally {
      _freeString(ptr);
    }
  }

  late final void Function(Pointer<Utf8>) _freeString = _lib
      .lookup<NativeFunction<Void Function(Pointer<Utf8>)>>(
        'chan_free_string',
      )
      .asFunction();

  late final Pointer<Utf8> Function() _defaultDataRoot = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function()>>(
        'chan_default_data_root',
      )
      .asFunction();

  late final Pointer<Utf8> Function(Pointer<Utf8>) _listStockCodes = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        'chan_list_stock_codes',
      )
      .asFunction();

  late final Pointer<Utf8> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  ) _loadKlines = _lib
      .lookup<
          NativeFunction<
              Pointer<Utf8> Function(
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
              )>>('chan_load_klines')
      .asFunction();

  late final Pointer<Utf8> Function(Pointer<Utf8>) _klineCombineFrames = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        'chan_kline_combine_frames',
      )
      .asFunction();

  dynamic _decode(String jsonText) {
    final obj = jsonDecode(jsonText);
    if (obj is! Map<String, dynamic>) {
      throw FormatException('无效 JSON 响应');
    }
    if (obj['ok'] == true) {
      return obj['data'];
    }
    throw StateError(obj['error']?.toString() ?? 'Rust 调用失败');
  }

  String defaultDataRoot() {
    ensureInitialized();
    return _decode(_takeJson(_defaultDataRoot())) as String;
  }

  List<String> listStockCodes({String? dataRoot}) {
    ensureInitialized();
    final ptr = _toNative(dataRoot);
    try {
      final data = _decode(_takeJson(_listStockCodes(ptr)));
      return (data as List).map((e) => e.toString()).toList();
    } finally {
      if (ptr != nullptr) calloc.free(ptr);
    }
  }

  List<KlineBar> loadKlines({
    String? dataRoot,
    required String code,
    required String beginDate,
    required String endDate,
    String period = 'day',
  }) {
    ensureInitialized();
    final pRoot = _toNative(dataRoot);
    final pCode = _toNative(code);
    final pBegin = _toNative(beginDate);
    final pEnd = _toNative(endDate);
    final pPeriod = _toNative(period);
    try {
      final data = _decode(
        _takeJson(
          _loadKlines(pRoot, pCode, pBegin, pEnd, pPeriod),
        ),
      );
      return (data as List)
          .map((e) => KlineBar.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } finally {
      for (final p in [pRoot, pCode, pBegin, pEnd, pPeriod]) {
        if (p != nullptr) calloc.free(p);
      }
    }
  }

  KlineCombineBundle _finalizeCombineBundle(
    List<KlineBar> bars,
    List<KlineCombineFrame> frames,
    List<BiConfirmSignal> biConfirms,
    List<BarCrosshairFeature> barFeatures,
    List<BiSegment> biSegments,
    SegAnalysisBundle segAnalysis,
    List<BiVirtualBar> biVirtualBars,
    List<KlineCombineFrame> biCombineFrames,
  ) {
    final signals = biConfirms.isNotEmpty
        ? biConfirms
        : computeBiConfirmSignals(bars);
    final features = enrichFractalPeakDist(
      bars,
      barFeatures.isNotEmpty
          ? barFeatures
          : computeBarCrosshairFeatures(bars, frames),
      signals,
    );
    final segments = biSegments.isNotEmpty
        ? biSegments
        : computeBiSegments(signals);
    final virtualBars = biVirtualBars.isNotEmpty
        ? biVirtualBars
        : computeBiVirtualBars(bars, segments);
    final biCombines = biCombineFrames.isNotEmpty
        ? biCombineFrames
        : computeBiCombineFrames(bars, virtualBars);
    final analysis = segAnalysis.segConfirms.isNotEmpty ||
            segAnalysis.barSubSnapshots.isNotEmpty
        ? segAnalysis
        : computeSegAnalysis(bars, segments, signals);
    return KlineCombineBundle(
      frames: frames,
      biConfirms: signals,
      barFeatures: features,
      biSegments: segments,
      segAnalysis: analysis,
      biVirtualBars: virtualBars,
      biCombineFrames: biCombines,
    );
  }

  /// 对当前已喂入 K 线做包含合并（逐K：传入前缀 bars 即可）。
  KlineCombineBundle buildKlineCombineBundle(List<KlineBar> bars) {
    ensureInitialized();
    final jsonBars = jsonEncode(bars.map((b) => b.toJson()).toList());
    final ptr = _toNative(jsonBars);
    try {
      final data = _decode(_takeJson(_klineCombineFrames(ptr)));
      if (data is List) {
        final frames = data
            .map(
              (e) => KlineCombineFrame.fromJson(
                Map<String, dynamic>.from(e as Map),
              ),
            )
            .toList();
        return _finalizeCombineBundle(
          bars,
          frames,
          const [],
          const [],
          const [],
          SegAnalysisBundle.empty(),
          const [],
          const [],
        );
      }
      final bundle = KlineCombineBundle.fromJson(
        Map<String, dynamic>.from(data as Map),
      );
      return _finalizeCombineBundle(
        bars,
        bundle.frames,
        bundle.biConfirms,
        bundle.barFeatures,
        bundle.biSegments,
        bundle.segAnalysis,
        bundle.biVirtualBars,
        bundle.biCombineFrames,
      );
    } finally {
      if (ptr != nullptr) calloc.free(ptr);
    }
  }

  /// 兼容旧调用：仅返回合并线框。
  List<KlineCombineFrame> buildKlineCombineFrames(List<KlineBar> bars) {
    return buildKlineCombineBundle(bars).frames;
  }
}
