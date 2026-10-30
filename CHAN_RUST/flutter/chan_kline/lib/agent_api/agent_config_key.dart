/// @file lib/agent_api/agent_config_key.dart
/// @brief Agent `set_config` 的键名/取值解析（纯 Dart，可离线单测）。
///
/// 唯一实现：主界面 `updateConfig` 与服务端都走这里。
/// 只做**参数校验**，不碰 UI、不碰缠论口径。
import 'agent_api_host.dart';

/// 可经 Agent API 写入的配置键。
///
/// 注意：GUI 设置面板里「筹码/笔数分布」总开关与桶宽输入框是**一处写两份**；
/// 走 API 时按 key 分开写，要等价手动操作需同时设 `chip_enabled` + `tick_enabled`
/// （桶宽同理：`chip_bucket` + `tick_bucket`）。
enum AgentConfigKey {
  chipEnabled('chip_enabled'),
  chipBucket('chip_bucket'),
  tickEnabled('tick_enabled'),
  tickBucket('tick_bucket'),
  truncationCheck('truncation_check'),
  bollN('boll_n'),
  donchianN('donchian_n'),
  regressK('regress_k');

  const AgentConfigKey(this.wireName);

  /// 命令里使用的键名。
  final String wireName;

  static AgentConfigKey? fromWire(String key) {
    for (final k in values) {
      if (k.wireName == key) return k;
    }
    return null;
  }
}

/// 一条已校验的配置变更（三选一：bool / int / double）。
class AgentConfigChange {
  final AgentConfigKey key;
  final bool? asBool;
  final int? asInt;
  final double? asNum;

  const AgentConfigChange.bool(this.key, bool v)
      : asBool = v,
        asInt = null,
        asNum = null;

  const AgentConfigChange.integer(this.key, int v)
      : asBool = null,
        asInt = v,
        asNum = null;

  const AgentConfigChange.number(this.key, double v)
      : asBool = null,
        asInt = null,
        asNum = v;
}

/// 全部可写键（用于错误提示）。
String get agentConfigKeyList =>
    AgentConfigKey.values.map((e) => e.wireName).join(', ');

/// 解析并校验一条 `set_config`。
///
/// 非法时抛 [AgentApiError]，消息内附合法范围；**不改变任何状态**。
AgentConfigChange parseAgentConfigChange(String key, String value) {
  final k = AgentConfigKey.fromWire(key.trim());
  if (k == null) {
    throw AgentApiError('未知配置键：$key（可用：$agentConfigKeyList）');
  }
  final raw = value.trim();
  switch (k) {
    case AgentConfigKey.chipEnabled:
    case AgentConfigKey.tickEnabled:
    case AgentConfigKey.truncationCheck:
      return AgentConfigChange.bool(k, _parseBool(raw, k.wireName));
    case AgentConfigKey.chipBucket:
    case AgentConfigKey.tickBucket:
      return AgentConfigChange.number(k, _parseBucketStep(raw, k.wireName));
    case AgentConfigKey.bollN:
    case AgentConfigKey.donchianN:
      return AgentConfigChange.integer(k, _parsePeriod(raw, k.wireName));
    case AgentConfigKey.regressK:
      return AgentConfigChange.number(k, _parseRegressK(raw));
  }
}

bool _parseBool(String raw, String key) {
  switch (raw.toLowerCase()) {
    case 'true':
    case '1':
    case 'on':
    case '开':
      return true;
    case 'false':
    case '0':
    case 'off':
    case '关':
      return false;
  }
  throw AgentApiError('$key 需要布尔值：true/false、1/0、开/关（收到「$raw」）');
}

/// 桶宽：与 GUI 同口径（最小 0.01，四舍五入到 2 位小数）。
double _parseBucketStep(String raw, String key) {
  final v = double.tryParse(raw);
  if (v == null || !v.isFinite) {
    throw AgentApiError('$key 需要数字（收到「$raw」），合法范围 ≥ 0.01');
  }
  if (v < 0.01) {
    throw AgentApiError('$key=$raw 越界，合法范围 ≥ 0.01（GUI 同口径）');
  }
  return (v * 100).round() / 100.0;
}

/// 通道/均线类窗口：正整数。
int _parsePeriod(String raw, String key) {
  final v = int.tryParse(raw);
  if (v == null || v < 1) {
    throw AgentApiError('$key 需要正整数（收到「$raw」），合法范围 ≥ 1');
  }
  return v;
}

/// 回归通道带宽倍数：正数。
double _parseRegressK(String raw) {
  final v = double.tryParse(raw);
  if (v == null || !v.isFinite || v <= 0) {
    throw AgentApiError('regress_k 需要正数（收到「$raw」），必须 > 0');
  }
  return v;
}
