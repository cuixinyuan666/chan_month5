import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/models/zs_frame.dart';

void main() {
  test('ZSFrame.fromJson 解析原生中枢字段', () {
    final json = <String, dynamic>{
      'seq': 2,
      'x1': 100,
      'x2': 320,
      'high': 20.0, // ZD 上沿（更高价）
      'low': 12.0, // ZG 下沿（更低价）
      'level': 1,
      'count': 5,
      'dir': 1,
      'is_one_bi_zs': false,
      'is_nine_seg_upgrade': false,
      'is_sure': true,
      'in_seg_idx': 7,
      'out_seg_idx': 12,
    };
    final f = ZSFrame.fromJson(json);
    expect(f.seq, 2);
    expect(f.x1, 100);
    expect(f.x2, 320);
    expect(f.high, 20.0);
    expect(f.low, 12.0);
    expect(f.level, 1);
    expect(f.count, 5);
    expect(f.dir, 1);
    expect(f.isOneBiZs, isFalse);
    expect(f.isNineSegUpgrade, isFalse);
    expect(f.isSure, isTrue);
    expect(f.biInIdx, 7);
    expect(f.biOutIdx, 12);
  });

  test('ZSFrame.fromJson 缺省字段回退', () {
    final f = ZSFrame.fromJson(const <String, dynamic>{});
    expect(f.seq, 0);
    expect(f.level, 1);
    expect(f.count, 0);
    expect(f.isOneBiZs, isFalse);
    expect(f.isNineSegUpgrade, isFalse);
    expect(f.isSure, isTrue);
    expect(f.biInIdx, isNull);
    expect(f.biOutIdx, isNull);
  });

  test('ZSFrame 九段升级与单段标记', () {
    final json = <String, dynamic>{
      'x1': 0,
      'x2': 10,
      'high': 30.0,
      'low': 20.0,
      'count': 9,
      'is_nine_seg_upgrade': true,
      'is_one_bi_zs': true,
    };
    final f = ZSFrame.fromJson(json);
    expect(f.isNineSegUpgrade, isTrue);
    expect(f.isOneBiZs, isTrue);
    expect(f.count, 9);
  });
}
