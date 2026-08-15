/// N 类买卖点变量（Phase 10）。
///
/// 不硬编码 BUY3/BUY4：统一 `STRUCTURE.K{n}.BUY_N.{class}`。
/// 兼容 `CHAN.K{n}.BUY_N.{class}`。只读现有 buyN/sellN 会话历史。

const int kTradeMinBsClass = 3;

/// 条件积木里列出的最大类号（更高类号仍可按 id 编译）
const int kTradeUiMaxBsClass = 6;

const int kTradeMaxBsClass = 20;

String buyNVarId(int kn, int cls) => 'STRUCTURE.K$kn.BUY_N.$cls';

String sellNVarId(int kn, int cls) => 'STRUCTURE.K$kn.SELL_N.$cls';

/// CHAN.K1.BUY_N.3 → STRUCTURE.K1.BUY_N.3
String canonicalizeTradeVarId(String id) {
  if (id.startsWith('CHAN.')) return 'STRUCTURE.${id.substring(5)}';
  return id;
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
  if (cls == null || cls < kTradeMinBsClass) return null;
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
