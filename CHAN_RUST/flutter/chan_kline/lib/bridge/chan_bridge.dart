import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../models/kline_combine_frame.dart';
import '../models/pipeline_delta.dart';
import '../models/presentation_cache.dart';
import '../widgets/kline_chip.dart';

/// Rust `chan_ffi` 动态库桥接（纯 FFI：全部计算在 Rust，Dart 无回退实现）。
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

  late final Pointer<Utf8> Function(Pointer<Utf8>) _saveTestOhlc = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        'chan_save_test_ohlc',
      )
      .asFunction();

  late final Pointer<Utf8> Function(Pointer<Utf8>) _klineCombineFrames = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        'chan_kline_combine_frames',
      )
      .asFunction();

  late final Pointer<Utf8> Function(Pointer<Utf8>) _pipelineCreate = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        'chan_pipeline_create',
      )
      .asFunction();

  late final Pointer<Utf8> Function(int, Pointer<Utf8>) _pipelineAppend = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Uint64, Pointer<Utf8>)>>(
        'chan_pipeline_append',
      )
      .asFunction();

  Pointer<Utf8> Function(int, Pointer<Utf8>)? _pipelineAppendDeltaFn;
  bool _appendDeltaLookupDone = false;

  void _ensureAppendDeltaLookup() {
    if (_appendDeltaLookupDone) return;
    _appendDeltaLookupDone = true;
    try {
      _pipelineAppendDeltaFn = _lib
          .lookup<NativeFunction<Pointer<Utf8> Function(Uint64, Pointer<Utf8>)>>(
            'chan_pipeline_append_delta',
          )
          .asFunction();
    } catch (_) {
      _pipelineAppendDeltaFn = null;
    }
  }

  /// 当前 DLL 是否导出 `chan_pipeline_append_delta`（旧 DLL 回退 Full）。
  bool get supportsAppendDelta {
    ensureInitialized();
    _ensureAppendDeltaLookup();
    return _pipelineAppendDeltaFn != null;
  }

  late final Pointer<Utf8> Function(int) _pipelineSnapshot = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Uint64)>>(
        'chan_pipeline_snapshot',
      )
      .asFunction();

  late final Pointer<Utf8> Function(int) _pipelineReset = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Uint64)>>(
        'chan_pipeline_reset',
      )
      .asFunction();

  late final Pointer<Utf8> Function(int) _pipelineLen = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Uint64)>>(
        'chan_pipeline_len',
      )
      .asFunction();

  late final Pointer<Utf8> Function(int) _pipelineFree = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Uint64)>>(
        'chan_pipeline_free',
      )
      .asFunction();

  late final Pointer<Utf8> Function(Pointer<Utf8>) _chipProfile = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        'chan_chip_profile',
      )
      .asFunction();

  late final Pointer<Utf8> Function(Pointer<Utf8>) _mlPredict = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        'chan_ml_predict',
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

  /// 保存 test 自定义 OHLC → `a_Data/test/custom.ohlc.csv`。
  ({String path, int count}) saveTestOhlc({
    String? dataRoot,
    required List<KlineBar> bars,
  }) {
    ensureInitialized();
    final payload = <String, dynamic>{
      if (dataRoot != null) 'data_root': dataRoot,
      'bars': bars.map((b) => b.toJson()).toList(),
    };
    final ptr = _toNative(jsonEncode(payload));
    try {
      final data = _decode(_takeJson(_saveTestOhlc(ptr)));
      final map = Map<String, dynamic>.from(data as Map);
      return (
        path: map['path']?.toString() ?? '',
        count: (map['count'] as num?)?.toInt() ?? bars.length,
      );
    } finally {
      if (ptr != nullptr) calloc.free(ptr);
    }
  }

  /// 对当前已喂入 K 线跑 Rust Kn 流水线（逐K：传入前缀 bars 即可）。
  /// [truncationCheck]：截断监察开关；关=添加截断机制前的旧吸收行为。
  /// 纯 FFI：旧 DLL 只返回 frames 数组时直接报错，提示重新构建。
  /// 保留为黄金对照 / 十字 asOf 无状态路径；主步进请用 [ChanPipelineSession]。
  KlineCombineBundle buildKlineCombineBundle(
    List<KlineBar> bars, {
    bool truncationCheck = true,
  }) {
    ensureInitialized();
    final payload = <String, dynamic>{
      'bars': bars.map((b) => b.toJson()).toList(),
      'truncation_check': truncationCheck,
    };
    final ptr = _toNative(jsonEncode(payload));
    try {
      final data = _decode(_takeJson(_klineCombineFrames(ptr)));
      if (data is! Map) {
        throw StateError(
          'chan_ffi.dll 版本过旧（缺少 N 段流水线输出），请重新构建并替换 windows/native/chan_ffi.dll',
        );
      }
      return KlineCombineBundle.fromJson(Map<String, dynamic>.from(data));
    } finally {
      if (ptr != nullptr) calloc.free(ptr);
    }
  }

  /// Phase 1.5：创建持久 PipelineState 会话（Flutter 只持 handle）。
  int pipelineCreate({bool truncationCheck = true}) {
    ensureInitialized();
    final payload = <String, dynamic>{'truncation_check': truncationCheck};
    final ptr = _toNative(jsonEncode(payload));
    try {
      final data = _decode(_takeJson(_pipelineCreate(ptr)));
      final map = Map<String, dynamic>.from(data as Map);
      return (map['handle'] as num).toInt();
    } finally {
      if (ptr != nullptr) calloc.free(ptr);
    }
  }

  /// 逐根 append，返回完整 bundle（Full Snapshot；首包/回退/asOf 对照）。
  KlineCombineBundle pipelineAppend(int handle, KlineBar bar) {
    ensureInitialized();
    final ptr = _toNative(jsonEncode(bar.toJson()));
    try {
      final data = _decode(_takeJson(_pipelineAppend(handle, ptr)));
      return KlineCombineBundle.fromJson(Map<String, dynamic>.from(data as Map));
    } finally {
      if (ptr != nullptr) calloc.free(ptr);
    }
  }

  /// 逐根 append，返回 PipelineDelta（历史 bar_features 不重复）。
  PipelineDelta pipelineAppendDelta(int handle, KlineBar bar) {
    ensureInitialized();
    _ensureAppendDeltaLookup();
    final fn = _pipelineAppendDeltaFn;
    if (fn == null) {
      throw StateError('chan_ffi.dll 无 chan_pipeline_append_delta，请重编 DLL');
    }
    final ptr = _toNative(jsonEncode(bar.toJson()));
    try {
      final data = _decode(_takeJson(fn(handle, ptr)));
      return PipelineDelta.fromJson(Map<String, dynamic>.from(data as Map));
    } finally {
      if (ptr != nullptr) calloc.free(ptr);
    }
  }

  KlineCombineBundle pipelineSnapshot(int handle) {
    ensureInitialized();
    final data = _decode(_takeJson(_pipelineSnapshot(handle)));
    return KlineCombineBundle.fromJson(Map<String, dynamic>.from(data as Map));
  }

  void pipelineReset(int handle) {
    ensureInitialized();
    _decode(_takeJson(_pipelineReset(handle)));
  }

  int pipelineLen(int handle) {
    ensureInitialized();
    final data = _decode(_takeJson(_pipelineLen(handle)));
    final map = Map<String, dynamic>.from(data as Map);
    return (map['len'] as num).toInt();
  }

  void pipelineFree(int handle) {
    ensureInitialized();
    try {
      _decode(_takeJson(_pipelineFree(handle)));
    } catch (_) {
      // 重复 free / 旧 DLL：忽略
    }
  }

  /// 筹码分桶：截止到 [cutoffX]（含）累加 chip_tick_bins / 三角兜底。
  ChipProfileData chipProfile({
    required List<KlineBar> bars,
    int? cutoffX,
    double bucketStep = 0.1,
  }) {
    ensureInitialized();
    final payload = <String, dynamic>{
      'bars': bars.map((b) => b.toJson()).toList(),
      if (cutoffX != null) 'cutoff_x': cutoffX,
      'bucket_step': bucketStep,
    };
    final ptr = _toNative(jsonEncode(payload));
    try {
      final data = _decode(_takeJson(_chipProfile(ptr)));
      return ChipProfileData.fromJson(Map<String, dynamic>.from(data as Map));
    } finally {
      if (ptr != nullptr) calloc.free(ptr);
    }
  }

  /// 兼容旧调用：仅返回合并线框。
  List<KlineCombineFrame> buildKlineCombineFrames(
    List<KlineBar> bars, {
    bool truncationCheck = true,
  }) {
    return buildKlineCombineBundle(bars, truncationCheck: truncationCheck).frames;
  }

  /// ML：按稠密向量 + 外部模型打分（chan_ml_v1 / 简化 XGB JSON）。
  double mlPredict({
    required String modelPath,
    required List<double> dense,
  }) {
    ensureInitialized();
    final payload = <String, dynamic>{
      'model_path': modelPath,
      'dense': dense,
    };
    final ptr = _toNative(jsonEncode(payload));
    try {
      final data = _decode(_takeJson(_mlPredict(ptr)));
      final map = Map<String, dynamic>.from(data as Map);
      return (map['score'] as num?)?.toDouble() ?? 0;
    } finally {
      if (ptr != nullptr) calloc.free(ptr);
    }
  }
}

/// Phase 1.5：图表会话 = 一个 Rust PipelineState；Flutter 只存 handle + presentation cache。
/// 前进：首包 Full Snapshot，其后 append_delta + mergeDelta；失败回退 snapshot。
/// 步退/复位/换 opt：reset + replay。asOf 仍走无状态 Full。
class ChanPipelineSession {
  ChanPipelineSession._(
    this._bridge,
    this.handle,
    this.truncationCheck, {
    this.preferDelta = true,
  });

  final ChanBridge _bridge;
  final int handle;
  final bool truncationCheck;

  /// false=全程 Full Snapshot（对照路径）；true=首包 Full + 后续 Delta。
  final bool preferDelta;
  final PresentationCache cache = PresentationCache();
  int _len = 0;
  bool _alive = true;

  /// 创建会话（Rust 侧 new PipelineState）
  factory ChanPipelineSession.create({
    bool truncationCheck = true,
    bool preferDelta = true,
    ChanBridge? bridge,
  }) {
    final b = bridge ?? ChanBridge.instance;
    final h = b.pipelineCreate(truncationCheck: truncationCheck);
    return ChanPipelineSession._(
      b,
      h,
      truncationCheck,
      preferDelta: preferDelta,
    );
  }

  int get len => _len;
  bool get isAlive => _alive;
  KlineCombineBundle get cachedBundle => cache.bundle;

  void _resetLocal() {
    _bridge.pipelineReset(handle);
    _len = 0;
    cache.reset();
  }

  /// 同步到可见前缀：短则 reset+replay，长则继续 append。
  KlineCombineBundle syncTo(List<KlineBar> visible) {
    if (!_alive) {
      throw StateError('PipelineSession 已 dispose');
    }
    if (visible.isEmpty) {
      if (_len > 0) {
        _resetLocal();
      }
      return KlineCombineBundle.empty();
    }
    if (_len > visible.length) {
      _resetLocal();
    }
    while (_len < visible.length) {
      _appendOne(visible[_len]);
    }
    return cache.bundle;
  }

  void _appendOne(KlineBar bar) {
    final canDelta = preferDelta &&
        _bridge.supportsAppendDelta &&
        !cache.isEmpty &&
        cache.len == _len;
    if (canDelta) {
      try {
        final d = _bridge.pipelineAppendDelta(handle, bar);
        cache.mergeDelta(d);
        _len += 1;
        return;
      } catch (_) {
        // Rust 若已 append，snapshot 根数=_len+1 → Full 回填，禁止再 append
      }
    }
    // Delta 半成功或旧 DLL：Rust 已吃进这根则只回填 Full
    try {
      if (_bridge.pipelineLen(handle) == _len + 1) {
        cache.seedFromFull(_bridge.pipelineSnapshot(handle));
        _len += 1;
        return;
      }
    } catch (_) {}
    final full = _bridge.pipelineAppend(handle, bar);
    cache.seedFromFull(full);
    _len += 1;
  }

  void dispose() {
    if (!_alive) return;
    _alive = false;
    _bridge.pipelineFree(handle);
    _len = 0;
    cache.reset();
  }
}
