import 'dart:io';

import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/models/kline_bar.dart';

import 'robot_verify_paths.dart';

/// 机器人连续单步验收固定样本（与主图常用 002003 区间一致）。
const kRobotVerifyStockCode = '002003';
const kRobotVerifyBeginDate = '2004/07/19 10:47:00';
const kRobotVerifyEndDate = '2004/07/20 13:09:00';

/// 本地 `002003` 目录下是否存在分笔 txt（不连网、不初始化 FFI）。
bool hasLocal002003TickBackup({String? klineRoot}) {
  return _firstRootWithLocalTicks(_collectCandidateDataRoots(klineRoot: klineRoot)) !=
      null;
}

/// 兼容旧名：仅表示本地备份，不含协议拉取。
@Deprecated('Use hasLocal002003TickBackup or resolveRobotVerify002003LoadPlan')
bool hasOffline002003Data({String? klineRoot}) =>
    hasLocal002003TickBackup(klineRoot: klineRoot);

/// 解析连续单步阶段应使用的数据根与分笔来源。
class RobotVerify002003LoadPlan {
  const RobotVerify002003LoadPlan({
    required this.dataRoot,
    required this.tickSource,
    required this.via,
  });

  final String dataRoot;
  final String tickSource;
  final String via;
}

List<Map<String, Object?>>? _lastResolveTried;

List<Map<String, Object?>>? lastRobotVerifyDataResolveAttempts() =>
    _lastResolveTried;

/// 在候选目录中尝试「本地文件 → 通达信协议」探测，返回首个可加载方案。
Future<RobotVerify002003LoadPlan?> resolveRobotVerify002003LoadPlan({
  String? klineRoot,
}) async {
  ChanBridge.instance.ensureInitialized();
  final bridge = ChanBridge.instance;
  final roots = _collectCandidateDataRoots(klineRoot: klineRoot);
  final tried = <Map<String, Object?>>[];

  for (final root in roots) {
    if (!_folderHasTickTxt('$root${Platform.pathSeparator}$kRobotVerifyStockCode')) {
      continue;
    }
    final ok = _probeLoad(
      bridge: bridge,
      dataRoot: root,
      tickSource: 'file',
    );
    tried.add({
      'dataRoot': root,
      'tickSource': 'file',
      'ok': ok,
    });
    if (ok) {
      _lastResolveTried = tried;
      return RobotVerify002003LoadPlan(
        dataRoot: root,
        tickSource: 'file',
        via: 'local_txt',
      );
    }
  }

  final protocolRoots = <String>{
    ...roots,
    bridge.defaultDataRoot(),
  };
  for (final root in protocolRoots) {
    final ok = _probeLoad(
      bridge: bridge,
      dataRoot: root,
      tickSource: 'protocol',
    );
    tried.add({
      'dataRoot': root,
      'tickSource': 'protocol',
      'ok': ok,
    });
    if (ok) {
      _lastResolveTried = tried;
      return RobotVerify002003LoadPlan(
        dataRoot: root,
        tickSource: 'protocol',
        via: 'tdx_protocol',
      );
    }
  }

  _lastResolveTried = tried;
  return null;
}

bool _probeLoad({
  required ChanBridge bridge,
  required String dataRoot,
  required String tickSource,
}) {
  try {
    final out = bridge.loadKlinesEx(
      dataRoot: dataRoot,
      code: kRobotVerifyStockCode,
      beginDate: kRobotVerifyBeginDate,
      endDate: kRobotVerifyEndDate,
      period: '1m',
      tickSource: tickSource,
    );
    return out.bars.length >= 10;
  } catch (_) {
    return false;
  }
}

List<KlineBar> loadRobotVerifyBars({
  required RobotVerify002003LoadPlan plan,
  required String period,
}) {
  final bridge = ChanBridge.instance;
  return bridge
      .loadKlinesEx(
        dataRoot: plan.dataRoot,
        code: kRobotVerifyStockCode,
        beginDate: kRobotVerifyBeginDate,
        endDate: kRobotVerifyEndDate,
        period: period,
        tickSource: plan.tickSource,
      )
      .bars;
}

List<String> _collectCandidateDataRoots({String? klineRoot}) {
  final seen = <String>{};
  final out = <String>[];

  void add(String? raw) {
    if (raw == null || raw.isEmpty) return;
    final norm = _normPath(raw);
    if (seen.add(norm)) out.add(norm);
  }

  add(Platform.environment['CHAN_DATA_ROOT']?.trim());
  final repo = RobotVerifyPaths.resolveRepoRoot(klineRoot: klineRoot);
  if (repo != null) {
    add('$repo/a_Data');
    add('$repo/../a_Data');
    _scanRepoFor002003Parents(repo, out, seen);
  }

  try {
    ChanBridge.instance.ensureInitialized();
    add(ChanBridge.instance.defaultDataRoot());
  } catch (_) {
    // FFI 未就绪时仍可用 env / repo 路径
  }

  return out;
}

String? _firstRootWithLocalTicks(List<String> roots) {
  for (final root in roots) {
    if (_folderHasTickTxt('$root${Platform.pathSeparator}$kRobotVerifyStockCode')) {
      return root;
    }
  }
  return null;
}

bool _folderHasTickTxt(String folderPath) {
  final dir = Directory(folderPath);
  if (!dir.existsSync()) return false;
  try {
    return dir.listSync().any(
          (e) => e is File && e.path.toLowerCase().endsWith('.txt'),
        );
  } catch (_) {
    return false;
  }
}

void _scanRepoFor002003Parents(
  String repoRoot,
  List<String> out,
  Set<String> seen,
) {
  const maxDepth = 5;
  void walk(String dirPath, int depth) {
    if (depth > maxDepth) return;
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final name = _basename(e.path);
        if (_skipScanDir(name)) continue;
        if (name == kRobotVerifyStockCode && _folderHasTickTxt(e.path)) {
          final parent = _normPath(e.parent.path);
          if (seen.add(parent)) out.add(parent);
        }
        if (depth < maxDepth) walk(e.path, depth + 1);
      }
    } catch (_) {}
  }

  walk(_normPath(repoRoot), 0);
}

bool _skipScanDir(String name) {
  const skip = {
    '.git',
    '.dart_tool',
    'build',
    'node_modules',
    '.tdx_protocol_cache',
    'windows',
    'linux',
    'macos',
    'android',
    'ios',
  };
  return skip.contains(name);
}

String _normPath(String p) {
  try {
    return Directory(p).absolute.path;
  } catch (_) {
    return p.replaceAll('/', Platform.pathSeparator);
  }
}

String _basename(String p) {
  final n = p.replaceAll('\\', '/');
  final i = n.lastIndexOf('/');
  return i < 0 ? n : n.substring(i + 1);
}
