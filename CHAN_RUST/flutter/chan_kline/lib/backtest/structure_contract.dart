import 'divergence_relation.dart';
import 'signal_data_catalog.dart';
import 'structure_object.dart';
import 'zhongshu_object_store.dart';
import 'divergence_relation_store.dart';

/// 统一结构契约（Phase 11）。
///
/// 已有中枢对象、背驰关系接到同一套元数据：id / source / reference /
/// displayKn / discoveryX / availableAt / state / projection。
/// 不改中枢/背驰算法，不另建第二套计算。

enum StructureRelationKind {
  divergence,
  priceComparison,
  structureComparison,
}

/// 数值/事件/枚举投影：对象或关系在某一字段上的可读值。
class StructureProjectionSpec {
  final String projectionId;
  final TradeValueType valueType;
  final String field;
  final String source;

  const StructureProjectionSpec({
    required this.projectionId,
    required this.valueType,
    required this.field,
    required this.source,
  });
}

/// 对象或关系的统一身份快照（当时可见，不回写）。
class StructureMeta {
  final String id;
  final StructureKind kind;
  final StructureRelationKind? relationKind;
  final int displayKn;
  final int discoveryX;
  final int availableAt;
  final StructureObjectState state;
  final String source;
  /// 关系才有：比较对象
  final String? referenceId;
  /// 关系才有：当前对象
  final String? sourceId;
  final Map<String, double?> projections;

  const StructureMeta({
    required this.id,
    required this.kind,
    this.relationKind,
    required this.displayKn,
    required this.discoveryX,
    required this.availableAt,
    required this.state,
    required this.source,
    this.referenceId,
    this.sourceId,
    this.projections = const {},
  });

  bool get isRelation => relationKind != null;
}

StructureMeta structureMetaOfZs(ZhongshuObject zs) => StructureMeta(
      id: zs.objectId,
      kind: StructureKind.zhongshu,
      displayKn: zs.displayKn,
      discoveryX: zs.discoveryX,
      availableAt: zs.availableAt,
      state: zs.state,
      source: zs.source,
      projections: {
        'HIGH': zs.high,
        'LOW': zs.low,
        'CENTER': zs.center,
      },
    );

StructureMeta structureMetaOfDivergence(DivergenceRelation rel) => StructureMeta(
      id: rel.relationId,
      kind: StructureKind.segment,
      relationKind: StructureRelationKind.divergence,
      displayKn: rel.displayKn,
      discoveryX: rel.discoveryX,
      availableAt: rel.availableAt,
      state: rel.confirmed
          ? StructureObjectState.active
          : StructureObjectState.discovered,
      source: rel.source,
      referenceId: rel.referenceObjectId,
      sourceId: rel.sourceObjectId,
      projections: {
        'RATIO': rel.ratio,
        'DIRECTION': divergenceDirectionCode(rel.direction),
        'PRICE_FORCE': rel.priceForce,
        'INDICATOR_FORCE': rel.indicatorForce,
      },
    );

/// 当时可见的确认中枢 → 统一 StructureMeta。没有就是 null，不是 0。
StructureMeta? currentZsMeta({
  required ZhongshuObjectStore store,
  required int displayKn,
  required int asOf,
}) {
  final zs = store.resolveCurrentConfirmedZs(
    displayKn: displayKn,
    asOf: asOf,
  );
  if (zs == null) return null;
  return structureMetaOfZs(zs);
}

/// 当时可见的确认背驰关系 → 统一 StructureMeta。
StructureMeta? currentDivergenceMeta({
  required DivergenceRelationStore store,
  required int displayKn,
  required int asOf,
}) {
  final rel = store.resolveCurrent(displayKn: displayKn, asOf: asOf);
  if (rel == null) return null;
  return structureMetaOfDivergence(rel);
}

/// 中枢数值投影契约（HIGH/LOW/CENTER）。
List<StructureProjectionSpec> zsCurrentProjectionSpecs(int kn) => [
      StructureProjectionSpec(
        projectionId: zsCurrentVarId(kn, 'HIGH'),
        valueType: TradeValueType.objectProjection,
        field: 'HIGH',
        source: 'CURRENT_CONFIRMED_ZS.HIGH',
      ),
      StructureProjectionSpec(
        projectionId: zsCurrentVarId(kn, 'LOW'),
        valueType: TradeValueType.objectProjection,
        field: 'LOW',
        source: 'CURRENT_CONFIRMED_ZS.LOW',
      ),
      StructureProjectionSpec(
        projectionId: zsCurrentVarId(kn, 'CENTER'),
        valueType: TradeValueType.objectProjection,
        field: 'CENTER',
        source: 'CURRENT_CONFIRMED_ZS.CENTER',
      ),
    ];

/// 背驰关系投影契约（EXISTS/RATIO/DIRECTION）。
List<StructureProjectionSpec> divergenceProjectionSpecs(int kn) => [
      StructureProjectionSpec(
        projectionId: diverExistsId(kn),
        valueType: TradeValueType.event,
        field: 'EXISTS',
        source: 'DivergenceRelation EXISTS',
      ),
      StructureProjectionSpec(
        projectionId: diverRatioId(kn),
        valueType: TradeValueType.relationProjection,
        field: 'RATIO',
        source: 'DivergenceRelation.ratio',
      ),
      StructureProjectionSpec(
        projectionId: diverDirectionId(kn),
        valueType: TradeValueType.enumeration,
        field: 'DIRECTION',
        source: 'DivergenceRelation.direction',
      ),
    ];
