import 'dart:convert';

/// Agent-oriented robot verify report (UTF-8 JSON, no decorative text).
class RobotVerifyReport {
  RobotVerifyReport({
    required this.schemaVersion,
    required this.suiteId,
    required this.klineRoot,
    required this.started,
    required this.phases,
    this.ended,
  });

  static const int currentSchema = 1;

  final int schemaVersion;
  final String suiteId;
  final String klineRoot;
  final String started;
  String? ended;
  final List<RobotVerifyPhase> phases;

  bool get ok {
    for (final p in phases) {
      if (p.skipped) continue;
      if (!p.ok) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
        'v': schemaVersion,
        'suiteId': suiteId,
        'klineRoot': klineRoot,
        'started': started,
        'ended': ended,
        'ok': ok,
        'phases': phases.map((p) => p.toJson()).toList(),
      };

  /// Single-line JSON for clipboard (no BOM, no extra wrapping).
  String toClipboardPayload() => jsonEncode(toJson());
}

class RobotVerifyPhase {
  RobotVerifyPhase({
    required this.id,
    required this.ok,
    this.skipped = false,
    this.skipReason,
    Map<String, Object?>? details,
  }) : details = details ?? <String, Object?>{};

  final String id;
  final bool ok;
  final bool skipped;
  final String? skipReason;
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => {
        'id': id,
        'ok': ok,
        if (skipped) 'skipped': true,
        if (skipReason != null) 'skipReason': skipReason,
        if (details.isNotEmpty) 'details': details,
      };
}

class RobotVerifyCheck {
  RobotVerifyCheck({
    required this.id,
    required this.ok,
    Map<String, Object?>? data,
  }) : data = data ?? <String, Object?>{};

  final String id;
  final bool ok;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
        'id': id,
        'ok': ok,
        if (data.isNotEmpty) ...data,
      };
}
