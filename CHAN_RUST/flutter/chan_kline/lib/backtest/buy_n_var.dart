/// N 类买卖点变量（Phase 10）。
///
/// 不硬编码 BUY3/BUY4：统一 `STRUCTURE.K{n}.BUY_N.{class}`。
/// 兼容 `CHAN.K{n}.BUY_N.{class}`。只读现有 buyN/sellN 会话历史。

const int kTradeMinBsClass = 3;

/// 条件积木里列出的最大类号（更高类号仍可按 id 编译）
const int kTradeUiMaxBsClass = 6;

const int kTradeMaxBsClass = 20;

/// N=0 或 -1：该侧一类+二类+三类及以上全部取上。落盘统一写成 BUY_N.0 / SELL_N.0。
const int kTradeAllBsClass = 0;

bool isChanBsAllClass(int cls) => cls == 0 || cls == -1;

String buyNVarId(int kn, int cls) => 'STRUCTURE.K$kn.BUY_N.$cls';

String sellNVarId(int kn, int cls) => 'STRUCTURE.K$kn.SELL_N.$cls';

/// CHAN.K1.BUY_N.3 → STRUCTURE.K1.BUY_N.3
String canonicalizeTradeVarId(String id) {
  if (id.startsWith('CHAN.')) return 'STRUCTURE.${id.substring(5)}';
  return id;
}

/// 一类 / 二类 / N 类买卖点事件（不含分型确认、中枢确认）。
/// 这些点发现时刻都钉在 K0 当根，层号只说明哪一层打出来的标签。
bool isChanClassBsEventVarId(String id) => parseChanClassBsVarId(id) != null;

/// 策略积木里一类/二类/N类合并成「N类BS」后，用 N 还原真正的变量 id。
/// N=1 仍走 BUY1/SELL1，N=2 走 BUY2/SELL2，N≥3 走 BUY_N/SELL_N。
/// N=0 或 -1：该侧全部类号，统一写成 BUY_N.0 / SELL_N.0。
String chanClassBsVarId({
  required int kn,
  required int cls,
  required bool buy,
}) {
  if (isChanBsAllClass(cls)) {
    return buy
        ? buyNVarId(kn, kTradeAllBsClass)
        : sellNVarId(kn, kTradeAllBsClass);
  }
  final c = cls < 1
      ? 1
      : (cls > kTradeMaxBsClass ? kTradeMaxBsClass : cls);
  if (c == 1) {
    return buy ? 'STRUCTURE.K$kn.BUY1' : 'STRUCTURE.K$kn.SELL1';
  }
  if (c == 2) {
    return buy ? 'STRUCTURE.K$kn.BUY2' : 'STRUCTURE.K$kn.SELL2';
  }
  return buy ? buyNVarId(kn, c) : sellNVarId(kn, c);
}

/// 从 BUY1 / BUY2 / BUY_N.3 读出层号、类号、买/卖。
({int kn, int cls, bool buy})? parseChanClassBsVarId(String id) {
  final canonical = canonicalizeTradeVarId(id);
  final n = parseClassNVarId(canonical);
  if (n != null) return n;
  final parts = canonical.split('.');
  if (parts.length != 3) return null;
  if (parts[0] != 'STRUCTURE') return null;
  if (!parts[1].startsWith('K')) return null;
  final kn = int.tryParse(parts[1].substring(1));
  if (kn == null || kn < 0) return null;
  switch (parts[2]) {
    case 'BUY1':
      return (kn: kn, cls: 1, buy: true);
    case 'SELL1':
      return (kn: kn, cls: 1, buy: false);
    case 'BUY2':
      return (kn: kn, cls: 2, buy: true);
    case 'SELL2':
      return (kn: kn, cls: 2, buy: false);
    default:
      return null;
  }
}

({int kn, int cls, bool buy})? parseClassNVarId(String id) {
  final canonical = canonicalizeTradeVarId(id);
  final parts = canonical.split('.');
  if (parts.length != 4) return null;
  if (parts[0] != 'STRUCTURE') return null;
  if (!parts[1].startsWith('K')) return null;
  final kn = int.tryParse(parts[1].substring(1));
  if (kn == null || kn < 0) return null;
  final buy = parts[2] == 'BUY_N';
  final sell = parts[2] == 'SELL_N';
  if (!buy && !sell) return null;
  final cls = int.tryParse(parts[3]);
  if (cls == null) return null;
  if (isChanBsAllClass(cls)) {
    return (kn: kn, cls: kTradeAllBsClass, buy: buy);
  }
  if (cls < kTradeMinBsClass || cls > kTradeMaxBsClass) return null;
  return (kn: kn, cls: cls, buy: buy);
}

String tradeBsClassCn(int cls) {
  const names = <int, String>{
    1: '一',
    2: '二',
    3: '三',
    4: '四',
    5: '五',
    6: '六',
    7: '七',
    8: '八',
    9: '九',
    10: '十',
  };
  return names[cls] ?? '$cls';
}
