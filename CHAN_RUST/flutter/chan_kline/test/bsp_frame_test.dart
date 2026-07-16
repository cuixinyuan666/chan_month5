import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/models/bsp_frame.dart';

void main() {
  test('BSPFrame.fromJson 解析三类买卖点字段', () {
    final json = <String, dynamic>{
      'cls': 1,
      'is_buy': true, // 一类买点
      'price': 12.5,
      'x': 320,
      'level': 1,
      'seg_idx': 7,
      'relate_seg_idx': null,
    };
    final f = BSPFrame.fromJson(json);
    expect(f.cls, 1);
    expect(f.isBuy, isTrue);
    expect(f.price, 12.5);
    expect(f.x, 320);
    expect(f.level, 1);
    expect(f.segIdx, 7);
    expect(f.relateSegIdx, isNull);
  });

  test('BSPFrame.fromJson 二/三类携带关联一类段 idx', () {
    final f = BSPFrame.fromJson(<String, dynamic>{
      'cls': 3,
      'is_buy': false, // 三类卖点
      'price': 88.0,
      'x': 540,
      'level': 2,
      'seg_idx': 19,
      'relate_seg_idx': 12,
    });
    expect(f.cls, 3);
    expect(f.isBuy, isFalse);
    expect(f.price, 88.0);
    expect(f.level, 2);
    expect(f.segIdx, 19);
    expect(f.relateSegIdx, 12);
  });

  test('BSPFrame.fromJson 缺省字段回退', () {
    final f = BSPFrame.fromJson(const <String, dynamic>{});
    expect(f.cls, 1);
    expect(f.isBuy, isFalse);
    expect(f.price, 0);
    expect(f.x, 0);
    expect(f.level, 1);
    expect(f.segIdx, 0);
    expect(f.relateSegIdx, isNull);
  });
}
