import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../models/kline_combine_frame.dart';

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

  /// 兼容旧调用：仅返回合并线框。
  List<KlineCombineFrame> buildKlineCombineFrames(
    List<KlineBar> bars, {
    bool truncationCheck = true,
  }) {
    return buildKlineCombineBundle(bars, truncationCheck: truncationCheck).frames;
  }
}
