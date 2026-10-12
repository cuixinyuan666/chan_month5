import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// 启动门禁：装上的库必须带版本号且与界面一致。
/// 需本机 `windows/native/chan_ffi.dll`（与界面同号）。
void main() {
  test('chan_ffi 协议号与界面一致', () {
    ChanBridge.instance.ensureInitialized();
    expect(
      ChanBridge.instance.loadedFfiAbiVersion,
      kChanFfiAbiVersion,
      reason: '请重编并覆盖 windows/native/chan_ffi.dll 后再测',
    );
    expect(ChanBridge.instance.supportsAppendDelta, isTrue);
  });
}
