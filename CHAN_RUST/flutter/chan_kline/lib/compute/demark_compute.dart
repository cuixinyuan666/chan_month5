import 'dart:math' as math;

import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../models/math_indicator_config.dart';
import 'kn_ohlc_sample_compute.dart';

/// Demark：移植旧 `Math/Demark.py`；动态 Kn OHLC；K0 颗粒度。
/// 可配：Countdown 宽松/严、完美9、反向 Setup 是否打断 Countdown。

class _DemarkKl {
  final int idx;
  final double close;
  final double high;
  final double low;
  const _DemarkKl(this.idx, this.close, this.high, this.low);
}

class DemarkMark {
  /// setup / countdown / complete（完成买/卖信号）
  final String type;
  /// +1 卖向 / -1 买向
  final int dir;
  final int idx;
  const DemarkMark({
    required this.type,
    required this.dir,
    required this.idx,
  });
}

class _DemarkCountdown {
  _DemarkCountdown(this.dir, List<_DemarkKl> klList, this.tdstPeak)
      : klList = List<_DemarkKl>.from(klList);

  final int dir;
  final List<_DemarkKl> klList;
  final double tdstPeak;
  int idx = 0;
  bool finish = false;

  bool update(
    _DemarkKl kl, {
    required int countdownBias,
    required int maxCountdown,
    required DemarkCountdownMode mode,
  }) {
    if (finish) return false;
    klList.add(kl);
    if (klList.length <= countdownBias) return false;
    if (idx == maxCountdown) {
      finish = true;
      return false;
    }
    if ((dir < 0 && kl.high > tdstPeak) || (dir > 0 && kl.low < tdstPeak)) {
      finish = true;
      return false;
    }
    final refKl = klList[klList.length - 1 - countdownBias];
    final close = klList.last.close;
    final hit = switch (mode) {
      DemarkCountdownMode.looseClose =>
        (dir < 0 && close < refKl.close) || (dir > 0 && close > refKl.close),
      DemarkCountdownMode.strictExtreme =>
        (dir < 0 && close <= refKl.low) || (dir > 0 && close >= refKl.high),
    };
    if (!hit) return false;
    idx += 1;
    return true;
  }
}

class _DemarkSetup {
  _DemarkSetup(this.dir, List<_DemarkKl> klList, this.preKl)
      : klList = List<_DemarkKl>.from(klList);

  final int dir;
  final List<_DemarkKl> klList;
  final _DemarkKl preKl;
  _DemarkCountdown? countdown;
  bool setupFinished = false;
  int idx = 0;
  double? tdstPeak;
  final List<DemarkMark> lastMarks = [];

  List<DemarkMark> update(
    _DemarkKl kl, {
    required int setupBias,
    required int demarkLen,
    required bool tiaokongSt,
    required int countdownBias,
    required int maxCountdown,
    required DemarkCountdownMode countdownMode,
    required bool perfect9,
  }) {
    lastMarks.clear();
    if (!setupFinished) {
      klList.add(kl);
      final refClose = klList[klList.length - 1 - setupBias].close;
      if (dir < 0) {
        if (klList.last.close < refClose) {
          _addSetup();
        } else {
          setupFinished = true;
        }
      } else if (klList.last.close > refClose) {
        _addSetup();
      } else {
        setupFinished = true;
      }
    }
    if (idx == demarkLen && !setupFinished && countdown == null) {
      final setupOk = !perfect9 || _isPerfected(setupBias: setupBias, demarkLen: demarkLen);
      if (setupOk) {
        lastMarks.add(DemarkMark(type: 'complete', dir: dir, idx: demarkLen));
        countdown = _DemarkCountdown(
          dir,
          klList.sublist(0, klList.length - 1),
          _calTdstPeak(
            setupBias: setupBias,
            demarkLen: demarkLen,
            tiaokongSt: tiaokongSt,
          ),
        );
      }
    }
    if (countdown != null &&
        countdown!.update(
          kl,
          countdownBias: countdownBias,
          maxCountdown: maxCountdown,
          mode: countdownMode,
        )) {
      lastMarks.add(DemarkMark(
        type: 'countdown',
        dir: dir,
        idx: countdown!.idx,
      ));
      if (countdown!.idx == maxCountdown) {
        lastMarks.add(DemarkMark(
          type: 'complete',
          dir: dir,
          idx: maxCountdown,
        ));
      }
    }
    return List<DemarkMark>.from(lastMarks);
  }

  void _addSetup() {
    idx += 1;
    lastMarks.add(DemarkMark(type: 'setup', dir: dir, idx: idx));
  }

  /// 完美买9：第8或9根 low < 第6、7根 low；卖镜像比 high。
  bool _isPerfected({required int setupBias, required int demarkLen}) {
    final arr = klList.sublist(setupBias, setupBias + demarkLen);
    if (arr.length < demarkLen) return false;
    if (dir < 0) {
      final thr = math.min(arr[5].low, arr[6].low);
      return arr[7].low < thr || arr[8].low < thr;
    }
    final thr = math.max(arr[5].high, arr[6].high);
    return arr[7].high > thr || arr[8].high > thr;
  }

  double _calTdstPeak({
    required int setupBias,
    required int demarkLen,
    required bool tiaokongSt,
  }) {
    final arr = klList.sublist(setupBias, setupBias + demarkLen);
    late double res;
    if (dir < 0) {
      res = arr.first.high;
      for (final kl in arr) {
        if (kl.high > res) res = kl.high;
      }
      if (tiaokongSt && arr.first.high < preKl.close) {
        res = res > preKl.close ? res : preKl.close;
      }
    } else {
      res = arr.first.low;
      for (final kl in arr) {
        if (kl.low < res) res = kl.low;
      }
      if (tiaokongSt && arr.first.low > preKl.close) {
        res = res < preKl.close ? res : preKl.close;
      }
    }
    tdstPeak = res;
    return res;
  }
}

class DemarkEngine {
  DemarkEngine({
    this.demarkLen = 9,
    this.setupBias = 4,
    this.countdownBias = 2,
    this.maxCountdown = 13,
    this.tiaokongSt = true,
    this.countdownMode = DemarkCountdownMode.looseClose,
    this.perfect9 = false,
    this.interruptCountdownOnReverse = true,
  });

  final int demarkLen;
  final int setupBias;
  final int countdownBias;
  final int maxCountdown;
  final bool tiaokongSt;
  final DemarkCountdownMode countdownMode;
  final bool perfect9;
  final bool interruptCountdownOnReverse;

  final List<_DemarkKl> _klLst = [];
  final List<_DemarkSetup> _series = [];

  List<DemarkMark> update({
    required int idx,
    required double close,
    required double high,
    required double low,
  }) {
    _klLst.add(_DemarkKl(idx, close, high, low));
    if (_klLst.length <= setupBias + 1) return const [];

    final last = _klLst.last;
    final biasClose = _klLst[_klLst.length - 1 - setupBias].close;
    if (last.close < biasClose) {
      if (!_series.any((s) => s.dir < 0 && !s.setupFinished)) {
        _series.add(_DemarkSetup(
          -1,
          _klLst.sublist(_klLst.length - setupBias - 1, _klLst.length - 1),
          _klLst[_klLst.length - setupBias - 2],
        ));
      }
      _killOpposite(oppositeDir: 1);
    } else if (last.close > biasClose) {
      if (!_series.any((s) => s.dir > 0 && !s.setupFinished)) {
        _series.add(_DemarkSetup(
          1,
          _klLst.sublist(_klLst.length - setupBias - 1, _klLst.length - 1),
          _klLst[_klLst.length - setupBias - 2],
        ));
      }
      _killOpposite(oppositeDir: -1);
    }

    _clear();
    final finished = _cleanSeriesFromSetupFinish();
    if (finished != null) {
      _series.removeWhere((s) => !identical(s, finished));
    }
    final result = <DemarkMark>[];
    for (final s in _series) {
      result.addAll(s.lastMarks);
    }
    _clear();
    return result;
  }

  void _killOpposite({required int oppositeDir}) {
    for (final s in _series) {
      if (s.dir != oppositeDir) continue;
      if (s.countdown == null && !s.setupFinished) {
        s.setupFinished = true;
      }
      if (interruptCountdownOnReverse && s.countdown != null) {
        s.countdown!.finish = true;
      }
    }
  }

  _DemarkSetup? _cleanSeriesFromSetupFinish() {
    _DemarkSetup? finished;
    for (final series in _series) {
      final marks = series.update(
        _klLst.last,
        setupBias: setupBias,
        demarkLen: demarkLen,
        tiaokongSt: tiaokongSt,
        countdownBias: countdownBias,
        maxCountdown: maxCountdown,
        countdownMode: countdownMode,
        perfect9: perfect9,
      );
      for (final m in marks) {
        if (m.type == 'setup' && m.idx == demarkLen) {
          finished = series;
        }
      }
    }
    return finished;
  }

  void _clear() {
    _series.removeWhere((s) => s.setupFinished && s.countdown == null);
    _series.removeWhere((s) => s.countdown != null && s.countdown!.finish);
  }
}

/// 每根 K0：该步产生的 Demark 标记列表（阶梯 hold 最近一次非空）。
class DemarkK0Series {
  final List<List<DemarkMark>?> marksAt;
  const DemarkK0Series(this.marksAt);
}

DemarkK0Series computeDemarkForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  MathIndicatorConfig config = const MathIndicatorConfig(),
  int? asOf,
  List<KnOhlcSample>? samples,
}) {
  final use = samples ??
      collectKnOhlcSamples(
        displayKn: displayKn,
        bars: bars,
        levels: levels,
        asOf: asOf,
      );
  final eng = DemarkEngine(
    demarkLen: config.demarkLen,
    setupBias: config.demarkSetupBias,
    countdownBias: config.demarkCountdownBias,
    maxCountdown: config.demarkMaxCountdown,
    countdownMode: config.demarkCountdownMode,
    perfect9: config.demarkPerfect9,
    interruptCountdownOnReverse: config.demarkInterruptCountdownOnReverse,
  );
  final events = <({int x, List<DemarkMark> v})>[];
  for (final s in use) {
    final marks = eng.update(
      idx: s.endX,
      close: s.close,
      high: s.high,
      low: s.low,
    );
    if (marks.isNotEmpty) {
      events.add((x: s.endX, v: marks));
    }
  }
  return DemarkK0Series(
    expandEventsToK0(events, bars.length, asOf: asOf),
  );
}
