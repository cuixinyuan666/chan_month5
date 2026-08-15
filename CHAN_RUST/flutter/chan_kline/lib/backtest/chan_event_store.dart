import '../compute/class1_bs_compute.dart';
import '../compute/class2_bs_compute.dart';
import '../compute/zs_signal_compute.dart';
import '../models/buy1_frame.dart';
import '../models/buy2_frame.dart';
import '../models/k0_confirm_signal.dart';
import '../models/level_models.dart';
import '../models/sell1_frame.dart';
import '../models/sell2_frame.dart';
import '../models/zs_signal_event.dart';
import 'divergence_relation_store.dart';
import 'signal_data_catalog.dart';
import 'trade_value.dart';

/// 回测只读现有会话冻结 / 确认列表，不改 merge，不现场重算缠论。
class ChanEventStore {
  final Map<int, List<Buy1Frame>> buy1ByKn;
  final Map<int, List<Sell1Frame>> sell1ByKn;
  final Map<int, List<Buy2Frame>> buy2ByKn;
  final Map<int, List<Sell2Frame>> sell2ByKn;
  final Map<int, List<ZsSignalEvent>> zsConfirmByKn;
  final List<K0ConfirmSignal> k0FractalConfirms;

  const ChanEventStore({
    this.buy1ByKn = const {},
    this.sell1ByKn = const {},
    this.buy2ByKn = const {},
    this.sell2ByKn = const {},
    this.zsConfirmByKn = const {},
    this.k0FractalConfirms = const [],
  });

  static const empty = ChanEventStore();

  bool get isEmpty =>
      buy1ByKn.isEmpty &&
      sell1ByKn.isEmpty &&
      buy2ByKn.isEmpty &&
      sell2ByKn.isEmpty &&
      zsConfirmByKn.isEmpty &&
      k0FractalConfirms.isEmpty;
}

String structureEventId(int kn, String kind) =>
    'STRUCTURE.K$kn.${kind.toUpperCase()}';

String fractalConfirmId(int kn) => 'SUB.K$kn.FRACTAL_CONFIRM';

String zsConfirmId(int kn) => 'SUB.K$kn.ZS_CONFIRM';

bool isRegisteredEventVar(String variableId, {int maxKn = 8}) {
  final def = lookupTradeVariable(variableId, maxKn: maxKn);
  return def != null &&
      def.expressionReady &&
      def.valueType == TradeValueType.event;
}

/// 交易用的首次发现事件。动态段后续 x 仍留在会话历史里给人看，这里不重复出信号。
List<TradeChanEvent> listTradeChanEvents({
  required String variableId,
  required int asOf,
  ChanEventStore store = ChanEventStore.empty,
  List<LevelBundle> levels = const [],
  DivergenceRelationStore? diverRelations,
  int maxKn = 8,
}) {
  final def = lookupTradeVariable(variableId, maxKn: maxKn);
  if (def == null || !def.expressionReady) return const [];
  if (def.valueType != TradeValueType.event) return const [];
  final kn = def.displayKn;
  if (kn == null || kn < 0) return const [];

  final parts = variableId.split('.');
  if (parts.length < 3) return const [];
  final kind = parts.sublist(2).join('.');

  switch (kind) {
    case 'BUY1':
      return _firstBuy1(store.buy1ByKn[kn] ?? const [], kn, asOf);
    case 'SELL1':
      return _firstSell1(store.sell1ByKn[kn] ?? const [], kn, asOf);
    case 'BUY2':
      return _firstBuy2(store.buy2ByKn[kn] ?? const [], kn, asOf);
    case 'SELL2':
      return _firstSell2(store.sell2ByKn[kn] ?? const [], kn, asOf);
    case 'ZS_CONFIRM':
      return _firstZsConfirm(store.zsConfirmByKn[kn] ?? const [], kn, asOf);
    case 'FRACTAL_CONFIRM':
      return kn == 0
          ? _firstK0Fractal(store.k0FractalConfirms, asOf)
          : _firstKnFractal(levels, kn, asOf);
    case 'DIVERGENCE.EXISTS':
      return diverRelations?.listExistsEvents(
            displayKn: kn,
            asOf: asOf,
          ) ??
          const [];
    default:
      return const [];
  }
}

List<TradeChanEvent> _firstBuy1(List<Buy1Frame> hist, int kn, int asOf) {
  return _firstByX(
    items: hist,
    asOf: asOf,
    xOf: (p) => p.x,
    stableOf: buy1StableKey,
    toEvent: (p) => TradeChanEvent(
      eventId: 'BUY1|$kn|${p.segIdx}|${p.label}',
      displayKn: kn,
      discoveryX: p.x,
      availableAt: p.x,
      label: p.label,
      price: p.price,
      source: '一类买点会话历史（稳定身份首次发现；动态后续 x 不重复出信号）',
    ),
  );
}

List<TradeChanEvent> _firstSell1(List<Sell1Frame> hist, int kn, int asOf) {
  return _firstByX(
    items: hist,
    asOf: asOf,
    xOf: (p) => p.x,
    stableOf: sell1StableKey,
    toEvent: (p) => TradeChanEvent(
      eventId: 'SELL1|$kn|${p.segIdx}|${p.label}',
      displayKn: kn,
      discoveryX: p.x,
      availableAt: p.x,
      label: p.label,
      price: p.price,
      source: '一类卖点会话历史（稳定身份首次发现；动态后续 x 不重复出信号）',
    ),
  );
}

List<TradeChanEvent> _firstBuy2(List<Buy2Frame> hist, int kn, int asOf) {
  return _firstByX(
    items: hist,
    asOf: asOf,
    xOf: (p) => p.x,
    stableOf: buy2StableKey,
    toEvent: (p) => TradeChanEvent(
      eventId: 'BUY2|$kn|${p.segIdx}|${p.label}',
      displayKn: kn,
      discoveryX: p.x,
      availableAt: p.x,
      label: p.label,
      price: p.price,
      source: '二类买点会话历史（发现边沿；不把持续存在铺成 true）',
    ),
  );
}

List<TradeChanEvent> _firstSell2(List<Sell2Frame> hist, int kn, int asOf) {
  return _firstByX(
    items: hist,
    asOf: asOf,
    xOf: (p) => p.x,
    stableOf: sell2StableKey,
    toEvent: (p) => TradeChanEvent(
      eventId: 'SELL2|$kn|${p.segIdx}|${p.label}',
      displayKn: kn,
      discoveryX: p.x,
      availableAt: p.x,
      label: p.label,
      price: p.price,
      source: '二类卖点会话历史（发现边沿；不把持续存在铺成 true）',
    ),
  );
}

List<TradeChanEvent> _firstZsConfirm(
  List<ZsSignalEvent> hist,
  int kn,
  int asOf,
) {
  return _firstByX(
    items: hist,
    asOf: asOf,
    xOf: (e) => e.x,
    stableOf: (e) => zsSignalStableKey(e.kn, e.x1),
    toEvent: (e) => TradeChanEvent(
      eventId: 'ZS_CONFIRM|$kn|${e.x1}',
      displayKn: kn,
      discoveryX: e.x,
      availableAt: e.x,
      label: '中枢确认',
      price: 0,
      source: '中枢确认会话历史（is_sure 首次；不暴露框高框低）',
    ),
  );
}

List<TradeChanEvent> _firstK0Fractal(List<K0ConfirmSignal> hist, int asOf) {
  return _firstByX(
    items: hist,
    asOf: asOf,
    xOf: (e) => e.x,
    stableOf: (e) => '0|${e.fractalX1}|${e.fx}',
    toEvent: (e) => TradeChanEvent(
      eventId: 'FRACTAL_CONFIRM|0|${e.fractalX1}|${e.fx}',
      displayKn: 0,
      discoveryX: e.x,
      availableAt: e.x,
      label: e.fx,
      price: 0,
      source: 'K0 分型确认列表（首次确认事件，不是当前已确认清单状态）',
    ),
  );
}

List<TradeChanEvent> _firstKnFractal(
  List<LevelBundle> levels,
  int kn,
  int asOf,
) {
  // 连线族：分型确认取 LevelBundle.level==displayKn
  LevelBundle? lv;
  for (final b in levels) {
    if (b.level == kn) {
      lv = b;
      break;
    }
  }
  if (lv == null) return const [];
  return _firstByX(
    items: lv.confirms,
    asOf: asOf,
    xOf: (e) => e.x,
    stableOf: (e) => '$kn|${e.fractalX1}|${e.fx}',
    toEvent: (e) => TradeChanEvent(
      eventId: 'FRACTAL_CONFIRM|$kn|${e.fractalX1}|${e.fx}',
      displayKn: kn,
      discoveryX: e.x,
      availableAt: e.x,
      label: e.fx,
      price: e.value >= 0 ? e.fractalLow : e.fractalHigh,
      source: 'Kn 分型确认冻结列表（首次确认事件，不是当前已确认清单状态）',
    ),
  );
}

List<TradeChanEvent> _firstByX<T>({
  required List<T> items,
  required int asOf,
  required int Function(T) xOf,
  required String Function(T) stableOf,
  required TradeChanEvent Function(T) toEvent,
}) {
  final sorted = [...items]..sort((a, b) => xOf(a).compareTo(xOf(b)));
  final seen = <String>{};
  final out = <TradeChanEvent>[];
  for (final e in sorted) {
    final x = xOf(e);
    if (x < 0 || x > asOf) continue;
    if (!seen.add(stableOf(e))) continue;
    out.add(toEvent(e));
  }
  return out;
}
