import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'yin_yang_overlay_isolate.dart';

/// Windows：阴阳鱼画在独立 isolate 的分层窗口上，主 isolate 算缠论时它仍能转。
class YinYangNativeOverlay {
  Isolate? _iso;
  SendPort? _cmd;
  bool _showing = false;

  bool get isShowing => _showing;

  /// 直径=窗口高度×[heightFactor]；位置由 overlay isolate 用窗口物理矩形居中。
  Future<void> showCentered({
    required double heightFactor,
    required double opacity,
  }) async {
    if (!Platform.isWindows) return;
    await show(heightFactor: heightFactor, opacity: opacity);
  }

  Future<void> show({
    required double heightFactor,
    required double opacity,
  }) async {
    if (!Platform.isWindows) return;
    await hide();
    final ready = ReceivePort();
    _iso = await Isolate.spawn(
      yinYangOverlayIsolateMain,
      ready.sendPort,
      debugName: 'yin-yang-overlay',
    );
    _cmd = await ready.first as SendPort;
    ready.close();
    _cmd!.send({
      'op': 'show',
      'heightFactor': heightFactor,
      'opacity': opacity,
    });
    _showing = true;
  }

  Future<void> hide() async {
    if (_cmd == null && _iso == null) return;
    final ack = ReceivePort();
    try {
      _cmd?.send({'op': 'stop', 'ack': ack.sendPort});
      await ack.first.timeout(const Duration(milliseconds: 400));
    } catch (_) {
    } finally {
      ack.close();
    }
    _iso?.kill(priority: Isolate.beforeNextEvent);
    _iso = null;
    _cmd = null;
    _showing = false;
  }
}
