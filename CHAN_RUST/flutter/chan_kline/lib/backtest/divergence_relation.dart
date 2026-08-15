import 'trade_clock.dart';

/// 背驰结构关系（Phase 9）。
///
/// 不是「这根 K 看起来像背驰」的无身份布尔，而是：
/// 哪一个结构对比哪一个结构，在哪根 K0 被发现。
/// 力度只读现有背驰冻结仓（默认 MACD 面积），不另算一套。

enum DivergenceDirection {
  /// 离开段向上：顶背驰（偏卖）
  up,
  /// 离开段向下：底背驰（偏买）
  down,
}

String divergenceDirectionToken(DivergenceDirection d) =>
    d == DivergenceDirection.up ? 'UP' : 'DOWN';

String divergenceDirectionCn(DivergenceDirection d) =>
    d == DivergenceDirection.up ? '向上' : '向下';

DivergenceDirection? divergenceDirectionFromToken(String token) {
  switch (token.toUpperCase()) {
    case 'UP':
      return DivergenceDirection.up;
    case 'DOWN':
      return DivergenceDirection.down;
    default:
      return null;
  }
}

double divergenceDirectionCode(DivergenceDirection d) =>
    d == DivergenceDirection.up ? 1 : -1;

DivergenceDirection divergenceDirectionFromSegDir(int outDir) =>
    outDir >= 0 ? DivergenceDirection.up : DivergenceDirection.down;

/// 交易用背驰关系：引用稳定结构对象，历史快照不回写。
class DivergenceRelation {
  final String relationId;
  final int displayKn;
  final TradeClockFamily clockFamily;
  final int availableAt;
  final int discoveryX;
  final DivergenceDirection direction;
  final String sourceObjectId;
  final String referenceObjectId;
  final int? sourceSegment;
  final String? sourceZs;
  final int? referenceSegment;
  final String? referenceZs;
  final double? priceForce;
  final double? indicatorForce;
  final double? ratio;
  final bool confirmed;
  final String source;

  const DivergenceRelation({
    required this.relationId,
    required this.displayKn,
    this.clockFamily = TradeClockFamily.zsMath,
    required this.availableAt,
    required this.discoveryX,
    required this.direction,
    required this.sourceObjectId,
    required this.referenceObjectId,
    this.sourceSegment,
    this.sourceZs,
    this.referenceSegment,
    this.referenceZs,
    this.priceForce,
    this.indicatorForce,
    this.ratio,
    required this.confirmed,
    required this.source,
  });
}

/// 第一版交易背驰：本层 MACD 面积（已有算法，不新写）。
const String kTradeDivergenceAlgoKey = 'area';

String diverRelationId({
  required int displayKn,
  required String referenceObjectId,
  required String sourceObjectId,
  required int inSeg,
  required int outSeg,
  required String mode,
}) =>
    'DIVER|$displayKn|$kTradeDivergenceAlgoKey|'
    '$referenceObjectId|$sourceObjectId|$inSeg|$outSeg|$mode';

String diverExistsId(int kn) => 'STRUCTURE.K$kn.DIVERGENCE.EXISTS';

String diverRatioId(int kn) => 'STRUCTURE.K$kn.DIVERGENCE.RATIO';

String diverDirectionId(int kn) => 'STRUCTURE.K$kn.DIVERGENCE.DIRECTION';

bool isDiverProjectionId(String id, String field) {
  final parts = id.split('.');
  return parts.length == 4 &&
      parts[0] == 'STRUCTURE' &&
      parts[1].startsWith('K') &&
      parts[2] == 'DIVERGENCE' &&
      parts[3] == field;
}
