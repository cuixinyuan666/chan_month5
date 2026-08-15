/// 缠论结构对象契约（Phase 8）。
///
/// 中枢不再只是「确认事件」，而是有身份、有生命周期、有当时价格的对象。
/// 交易数值（HIGH/LOW/CENTER）只是对象在某根 asOf 上的投影，禁止另算一套中枢。

/// 结构种类。第一版只做中枢；背驰以后要引用「哪一段、哪一个中枢」。
enum StructureKind {
  zhongshu,
  segment,
  bi,
  fractalGroup,
}

/// 中枢生命周期。未确认不进交易变量。
enum StructureObjectState {
  /// 已经看见框，但还没确认（is_sure=false）
  discovered,
  /// 本步刚确认
  confirmed,
  /// 已确认、仍是当前这一个，框还没明显拉长
  active,
  /// 已确认后框/高低被当下延伸（同一个 objectId）
  extended,
  /// 后面又确认了更新的中枢，这个不再是 CURRENT
  ended,
}

/// 通用结构对象身份（中枢/以后的段、背驰比较对象都走这套字段）。
class StructureObject {
  final String objectId;
  final StructureKind kind;
  final int displayKn;
  /// 方案B：K0=0；K1+ 的结构层 = displayKn-1
  final int sourceLevel;
  final int discoveryX;
  final int availableAt;
  final bool confirmed;
  final int startX;
  final int endX;
  final StructureObjectState state;
  final String source;

  const StructureObject({
    required this.objectId,
    required this.kind,
    required this.displayKn,
    required this.sourceLevel,
    required this.discoveryX,
    required this.availableAt,
    required this.confirmed,
    required this.startX,
    required this.endX,
    required this.state,
    required this.source,
  });
}

/// 中枢对象：稳定身份 + 当时可见的框高/框低/中轴。
/// high/low 是当时 ZG/ZD，不是未来扩大后的末态。
class ZhongshuObject {
  final String objectId;
  final int displayKn;
  final int sourceLevel;
  final int discoveryX;
  /// 首次 is_sure 的那根 K0；未确认对象没有确认时刻
  final int? confirmX;
  final int availableAt;
  final int startX;
  final int endX;
  final double high;
  final double low;
  final double center;
  final bool confirmed;
  final StructureObjectState state;
  final String source;

  const ZhongshuObject({
    required this.objectId,
    required this.displayKn,
    required this.sourceLevel,
    required this.discoveryX,
    required this.confirmX,
    required this.availableAt,
    required this.startX,
    required this.endX,
    required this.high,
    required this.low,
    required this.center,
    required this.confirmed,
    required this.state,
    required this.source,
  });

  StructureObject asStructure() => StructureObject(
        objectId: objectId,
        kind: StructureKind.zhongshu,
        displayKn: displayKn,
        sourceLevel: sourceLevel,
        discoveryX: discoveryX,
        availableAt: availableAt,
        confirmed: confirmed,
        startX: startX,
        endX: endX,
        state: state,
        source: source,
      );
}

/// 数值投影：只投影确认中枢，不是事件。
enum ZsProjection {
  high,
  low,
  center,
}

/// 稳定 objectId：层 + 框左端。seq 合并会变号，不能当身份。
String zsObjectId(int displayKn, int x1) => 'ZS|$displayKn|$x1';

int zsSourceLevel(int displayKn) => displayKn <= 0 ? 0 : displayKn - 1;

double zsCenterOf({required double high, required double low}) =>
    (high + low) / 2.0;

String zsCurrentVarId(int kn, String field) =>
    'STRUCTURE.K$kn.ZS.CURRENT.${field.toUpperCase()}';

/// 段身份：层 + 段序号（背驰比较对象；中枢仍优先用 ZS|{kn}|{x1}）
String segObjectId(int displayKn, int segIdx) => 'SEG|$displayKn|$segIdx';
