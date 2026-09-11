import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 后台保活：会话活跃时持锁，退后台尽量不中断步进/回测/ML。
class BackgroundKeepAlive with WidgetsBindingObserver {
  BackgroundKeepAlive({required this.onSessionActive});

  /// 当前是否有需要保活的会话（播放、回测、ML 等）。
  final bool Function() onSessionActive;

  bool _enabled = false;
  bool _lifecycleAttached = false;

  void attach() {
    if (_lifecycleAttached) return;
    WidgetsBinding.instance.addObserver(this);
    _lifecycleAttached = true;
    _sync();
  }

  void detach() {
    if (!_lifecycleAttached) return;
    WidgetsBinding.instance.removeObserver(this);
    _lifecycleAttached = false;
    _setWakelock(false);
  }

  void refresh() => _sync();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退后台仍持锁，避免系统挂起导致「像重启」的断档。
    _sync();
  }

  void _sync() {
    final want = onSessionActive();
    _setWakelock(want);
  }

  Future<void> _setWakelock(bool on) async {
    if (on == _enabled) return;
    _enabled = on;
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {}
  }
}
