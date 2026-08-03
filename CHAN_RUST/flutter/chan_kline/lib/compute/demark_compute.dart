import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../models/math_indicator_config.dart';
import 'kn_ohlc_sample_compute.dart';

/// Demark：移植旧 `Math/Demark.py`；动态 Kn OHLC；K0 颗粒度。

class _DemarkKl {
  final int idx;
  final double close;
  final double high;
  final double low;
  const _DemarkKl(this.idx, this.close, this.high, this.low);

  double v(bool useClose, int dir) {
    if (useClose) return close;
    return dir > 0 ? high : low;
  }
}

class DemarkMark {
  /// setup / countdown
  final String type;
  /// +1 up / -1 down
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
    required bool countdownCmp2Close,
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
    final ref = klList[klList.length - 1 - countdownBias]
        .v(countdownCmp2Close, dir);
    if (dir < 0 && klList.last.close < ref) {
      idx += 1;
      return true;
    }
    if (dir > 0 && klList.last.close > ref) {
      idx += 1;
      return true;
    }
    return false;
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
    required bool setupCmp2Close,
    required bool tiaokongSt,
    required int countdownBias,
    required int maxCountdown,
    required bool countdownCmp2Close,
  }) {
    lastMarks.clear();
    if (!setupFinished) {
      klList.add(kl);
      final ref =
          klList[klList.length - 1 - setupBias].v(setupCmp2Close, dir);
      if (dir < 0) {
        if (klList.last.close < ref) {
          _addSetup();
        } else {
          setupFinished = true;
        }
      } else if (klList.last.close > ref) {
        _addSetup();
      } else {
        setupFinished = true;
      }
    }
    if (idx == demarkLen && !setupFinished && countdown == null) {
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
    if (countdown != null &&
        countdown!.update(
          kl,
          countdownBias: countdownBias,
          maxCountdown: maxCountdown,
          countdownCmp2Close: countdownCmp2Close,
        )) {
      lastMarks.add(DemarkMark(
        type: 'countdown',
        dir: dir,
        idx: countdown!.idx,
      ));
    }
    return List<DemarkMark>.from(lastMarks);
  }

  void _addSetup() {
    idx += 1;
    lastMarks.add(DemarkMark(type: 'setup', dir: dir, idx: idx));
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
    this.setupCmp2Close = true,
    this.countdownCmp2Close = true,
  });

  final int demarkLen;
  final int setupBias;
  final int countdownBias;
  final int maxCountdown;
  final bool tiaokongSt;
  final bool setupCmp2Close;
  final bool countdownCmp2Close;

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
      for (final s in _series) {
        if (s.dir > 0 && s.countdown == null && !s.setupFinished) {
          s.setupFinished = true;
        }
      }
    } else if (last.close > biasClose) {
      if (!_series.any((s) => s.dir > 0 && !s.setupFinished)) {
        _series.add(_DemarkSetup(
          1,
          _klLst.sublist(_klLst.length - setupBias - 1, _klLst.length - 1),
          _klLst[_klLst.length - setupBias - 2],
        ));
      }
      for (final s in _series) {
        if (s.dir < 0 && s.countdown == null && !s.setupFinished) {
          s.setupFinished = true;
        }
      }
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

  /// 更新各序列；若有 setup 达到 demarkLen，返回该序列（只保留它）。
  _DemarkSetup? _cleanSeriesFromSetupFinish() {
    _DemarkSetup? finished;
    for (final series in _series) {
      final marks = series.update(
        _klLst.last,
        setupBias: setupBias,
        demarkLen: demarkLen,
        setupCmp2Close: setupCmp2Close,
        tiaokongSt: tiaokongSt,
        countdownBias: countdownBias,
        maxCountdown: maxCountdown,
        countdownCmp2Close: countdownCmp2Close,
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
}) {
  final samples = collectKnOhlcSamples(
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
  );
  final events = <({int x, List<DemarkMark> v})>[];
  for (final s in samples) {
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
