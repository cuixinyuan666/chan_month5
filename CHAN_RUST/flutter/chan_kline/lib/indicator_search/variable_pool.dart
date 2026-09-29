import 'package:chan_kline/backtest/signal_data_catalog.dart';

class VariablePool {
  final int maxKn;
  final List<TradeVariableDef> _registered;
  late final List<TradeVariableDef> all;
  late final List<TradeVariableDef> numeric;
  late final List<TradeVariableDef> events;

  VariablePool(this.maxKn)
      : _registered = buildRegisteredTradeVariables(maxKn)
            .where((d) => d.readiness == TradeReadiness.registered)
            .toList() {
    all = _registered;
    numeric = _registered
        .where((d) => isNumericComparableType(d.valueType))
        .toList();
    events =
        _registered.where((d) => d.valueType == TradeValueType.event).toList();
  }

  Map<String, int> byGroup() {
    final m = <String, int>{};
    for (final d in all) {
      final k = d.groupLabel.isEmpty ? d.panel.name : d.groupLabel;
      m[k] = (m[k] ?? 0) + 1;
    }
    return m;
  }

  List<(TradeVariableDef, TradeVariableDef)> sameClockNumericPairs() {
    final buckets = <String, List<TradeVariableDef>>{};
    for (final d in numeric) {
      final kn = d.displayKn;
      if (kn == null) continue;
      final key = 'K$kn|${d.clockFamily.name}';
      buckets.putIfAbsent(key, () => <TradeVariableDef>[]).add(d);
    }
    final out = <(TradeVariableDef, TradeVariableDef)>[];
    for (final list in buckets.values) {
      if (list.length < 2) continue;
      for (var i = 0; i < list.length; i++) {
        for (var j = i + 1; j < list.length; j++) {
          out.add((list[i], list[j]));
        }
      }
    }
    return out;
  }

  List<TradeVariableDef> buyEvents() => events.where(isBuyEvent).toList();
  List<TradeVariableDef> sellEvents() => events.where(isSellEvent).toList();

  static bool isBuyEvent(TradeVariableDef d) {
    final u = d.variableId.toUpperCase();
    if (u.contains('SELL')) return false;
    if (u.contains('BUY')) return true;
    return false;
  }

  static bool isSellEvent(TradeVariableDef d) {
    final u = d.variableId.toUpperCase();
    if (u.contains('BUY') && !u.contains('SELL')) return false;
    if (u.contains('SELL')) return true;
    return false;
  }

  static List<double> constantsFor(TradeVariableDef d) {
    final u = d.variableId.toUpperCase();
    if (u.contains('.RSI.')) return const [20, 30, 50, 70, 80];
    if (u.contains('.KDJ.')) return const [20, 50, 80];
    if (u.contains('RATIO')) return const [0.8, 1.0, 1.2];
    if (u.contains('MACD')) return const [0];
    if (u.contains('LINE_SLOPE') || u.contains('ADJACENT_RATIO')) {
      return const [0];
    }
    if (u.contains('VOLUME') || u.contains('TICK_COUNT')) return const [];
    return const [];
  }
}
