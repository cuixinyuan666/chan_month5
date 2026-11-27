import 'dart:convert';
import 'dart:io';

/// 双机同步的本机偏好（落盘 `.chan_sync_settings.json`）。
///
/// 只存「跟哪台同步、上次结果」这类界面状态；真正的同步口径在
/// `CHAN_RUST/scripts/sync_to_remote.ps1` 里，不在这里重复实现。
class PeerSyncSettings {
  const PeerSyncSettings({
    this.peerPath = '',
    this.lastSyncAt = '',
    this.lastSyncOk = false,
    this.lastSyncSummary = '',
  });

  /// 对端项目根（UNC 或本地路径），如 `\\192.168.1.6\D$\2\chan_month5`。
  final String peerPath;

  /// 上次同步时间（本地时间字符串），空 = 从未同步。
  final String lastSyncAt;

  final bool lastSyncOk;

  /// 上次同步一句话结论，如 `新增 3 / 覆盖 2，指纹一致，对端已拉起`。
  final String lastSyncSummary;

  bool get hasHistory => lastSyncAt.trim().isNotEmpty;

  PeerSyncSettings copyWith({
    String? peerPath,
    String? lastSyncAt,
    bool? lastSyncOk,
    String? lastSyncSummary,
  }) {
    return PeerSyncSettings(
      peerPath: peerPath ?? this.peerPath,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSyncOk: lastSyncOk ?? this.lastSyncOk,
      lastSyncSummary: lastSyncSummary ?? this.lastSyncSummary,
    );
  }

  factory PeerSyncSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const PeerSyncSettings();
    return PeerSyncSettings(
      peerPath: (json['peer_path'] as String?)?.trim() ?? '',
      lastSyncAt: (json['last_sync_at'] as String?)?.trim() ?? '',
      lastSyncOk: json['last_sync_ok'] == true,
      lastSyncSummary: (json['last_sync_summary'] as String?)?.trim() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        if (peerPath.isNotEmpty) 'peer_path': peerPath,
        if (lastSyncAt.isNotEmpty) 'last_sync_at': lastSyncAt,
        'last_sync_ok': lastSyncOk,
        if (lastSyncSummary.isNotEmpty) 'last_sync_summary': lastSyncSummary,
      };
}

abstract final class PeerSyncSettingsStore {
  static String get path {
    final base = Directory.current.path;
    return '$base${Platform.pathSeparator}.chan_sync_settings.json';
  }

  /// 同步读（设置面板每次 build 都要一行「上次同步」，不为此引入异步状态）。
  static PeerSyncSettings loadSync() {
    try {
      final f = File(path);
      if (!f.existsSync()) return const PeerSyncSettings();
      final obj = jsonDecode(f.readAsStringSync());
      if (obj is Map) {
        return PeerSyncSettings.fromJson(Map<String, dynamic>.from(obj));
      }
    } catch (_) {}
    return const PeerSyncSettings();
  }

  static Future<void> save(PeerSyncSettings cfg) async {
    try {
      await File(path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(cfg.toJson()),
      );
    } catch (_) {}
  }
}
