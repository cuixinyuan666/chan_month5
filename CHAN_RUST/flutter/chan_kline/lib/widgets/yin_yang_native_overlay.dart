import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'yin_yang_overlay_isolate.dart';

/// Windows：阴阳鱼画在独立 isolate 的分层窗口上，主 isolate 算缠论时它仍能转。
///
/// 关键约束（详见 [yinYangOverlayIsolateMain] 顶部注释）：
/// Win32 窗口类的 WndProc 绑的是 overlay isolate 的 FFI 回调，isolate 一死回调就废，
/// 那时候任何一次 Win32 消息回调都会让 Dart VM
/// `Callback invoked after it has been deleted` 把进程带走。
/// 所以这里：
/// - isolate 一旦起来就**常驻**，不再每次 show/hide 都 spawn/kill；
/// - [hide] 只收起窗口（停转 + SW_HIDE），不拆窗口、不杀 isolate；
/// - 只有整个 app 收摊时才用 [dispose]，并且是让 overlay 自己
///   「拆窗口 → 注销窗口类 → 退出」，绝不抢跑 kill。
class YinYangNativeOverlay {
  SendPort? _cmd;
  Future<void>? _spawning;
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
    await _ensureIsolate();
    final port = _cmd;
    if (port == null) return;
    final ack = ReceivePort();
    var ok = false;
    try {
      port.send({
        'op': 'show',
        'heightFactor': heightFactor,
        'opacity': opacity,
        'ack': ack.sendPort,
      });
      final reply = await ack.first.timeout(const Duration(milliseconds: 800));
      ok = reply == true;
    } catch (_) {
      ok = false;
    } finally {
      ack.close();
    }
    _showing = ok;
  }

  /// 收起：只是隐藏，资源与 isolate 都留着，下次 [show] 直接复用。
  Future<void> hide() async {
    final port = _cmd;
    if (port == null) {
      _showing = false;
      return;
    }
    final ack = ReceivePort();
    try {
      port.send({'op': 'hide', 'ack': ack.sendPort});
      await ack.first.timeout(const Duration(milliseconds: 400));
    } catch (_) {
      // 收不到 ack 也无所谓：窗口至多停在屏幕上，下次 show 会抢回来
    } finally {
      ack.close();
    }
    _showing = false;
  }

  /// app 收摊专用：销毁窗口 → 注销窗口类 → overlay isolate 自行退出。
  Future<void> dispose() async {
    final port = _cmd;
    _cmd = null;
    _spawning = null;
    _showing = false;
    if (port == null) return;
    final ack = ReceivePort();
    try {
      port.send({'op': 'stop', 'ack': ack.sendPort});
      await ack.first.timeout(const Duration(milliseconds: 500));
    } catch (_) {
      // 超时也不补刀 kill：强杀会留下「活着但没有回调」的窗口，反而更危险
    } finally {
      ack.close();
    }
  }

  /// overlay isolate 全局只起一次（懒启动）。
  Future<void> _ensureIsolate() async {
    if (_cmd != null) return;
    final pending = _spawning;
    if (pending != null) {
      await pending;
      return;
    }
    final task = _spawn();
    _spawning = task;
    await task;
  }

  Future<void> _spawn() async {
    final ready = ReceivePort();
    try {
      await Isolate.spawn(
        yinYangOverlayIsolateMain,
        ready.sendPort,
        debugName: 'yin-yang-overlay',
      );
      _cmd = await ready.first as SendPort;
    } catch (_) {
      _cmd = null;
    } finally {
      ready.close();
    }
  }
}
