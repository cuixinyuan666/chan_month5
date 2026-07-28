import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/models/zs_frame.dart';

void main() {
  test('ZSFrame.fromJson 解析原生中枢字段', () {
    final json = <String, dynamic>{
      'seq': 2,
      'x1': 100,
      'x2': 320,
      'high': 20.0,
      'low': 12.0,
      'level': 1,
      'count': 5,
      'dir': 1,
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
    expect(f.isSure, isTrue);
    expect(f.inSegIdx, 7);
    expect(f.outSegIdx, 12);
  });

  test('ZSFrame.fromJson 缺省字段回退', () {
    final f = ZSFrame.fromJson(const <String, dynamic>{});
    expect(f.seq, 0);
    expect(f.level, 1);
    expect(f.count, 0);
    expect(f.isSure, isTrue);
    expect(f.inSegIdx, isNull);
    expect(f.outSegIdx, isNull);
  });

  test('ZSFrame.fromJson 解析 is_sure=false（不确定态虚线）', () {
    final f = ZSFrame.fromJson(const <String, dynamic>{
      'x1': 0,
      'x2': 10,
      'high': 20.0,
      'low': 10.0,
      'is_sure': false,
    });
    expect(f.isSure, isFalse);
  });
}
