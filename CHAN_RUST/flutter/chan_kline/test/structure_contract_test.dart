import 'package:chan_kline/backtest/divergence_relation.dart';
import 'package:chan_kline/backtest/signal_data_catalog.dart';
import 'package:chan_kline/backtest/structure_contract.dart';
import 'package:chan_kline/backtest/structure_object.dart';
import 'package:chan_kline/backtest/zhongshu_object_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('统一结构契约', () {
    test('中枢对象接到 StructureMeta：id / 投影 / 当时可见', () {
      const zs = ZhongshuObject(
        objectId: 'ZS|1|10',
        displayKn: 1,
        sourceLevel: 0,
        discoveryX: 10,
        confirmX: 12,
        availableAt: 12,
        startX: 10,
        endX: 18,
        high: 12,
        low: 8,
        center: 10,
        confirmed: true,
        state: StructureObjectState.active,
        source: 'test',
      );
      final meta = structureMetaOfZs(zs);
      expect(meta.id, 'ZS|1|10');
      expect(meta.kind, StructureKind.zhongshu);
      expect(meta.isRelation, isFalse);
      expect(meta.displayKn, 1);
      expect(meta.discoveryX, 10);
      expect(meta.availableAt, 12);
      expect(meta.projections['LOW'], 8);
      expect(meta.projections['HIGH'], 12);
      expect(zsCurrentProjectionSpecs(1).map((e) => e.valueType).toSet(), {
        TradeValueType.objectProjection,
      });
    });

    test('背驰关系接到 StructureMeta：relationId / source / reference', () {
      const rel = DivergenceRelation(
        relationId: 'DIVER|1|area|ZS|1|1|SEG|1|2|area',
        displayKn: 1,
        availableAt: 20,
        discoveryX: 20,
        direction: DivergenceDirection.down,
        sourceObjectId: 'SEG|1|2',
        referenceObjectId: 'ZS|1|1',
        ratio: 0.72,
        confirmed: true,
        source: 'test',
      );
      final meta = structureMetaOfDivergence(rel);
      expect(meta.id, rel.relationId);
      expect(meta.isRelation, isTrue);
      expect(meta.relationKind, StructureRelationKind.divergence);
      expect(meta.sourceId, 'SEG|1|2');
      expect(meta.referenceId, 'ZS|1|1');
      expect(meta.projections['RATIO'], 0.72);
      expect(
        divergenceProjectionSpecs(1)
            .map((e) => '${e.field}:${e.valueType.name}')
            .toList(),
        [
          'EXISTS:event',
          'RATIO:relationProjection',
          'DIRECTION:enumeration',
        ],
      );
    });

    test('空仓 CURRENT 中枢是 null，不是 0', () {
      final store = ZhongshuObjectStore();
      expect(
        currentZsMeta(store: store, displayKn: 1, asOf: 10),
        isNull,
      );
    });
  });
}
