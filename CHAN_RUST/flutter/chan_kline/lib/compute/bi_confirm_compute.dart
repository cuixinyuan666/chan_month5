import '../models/bi_confirm_signal.dart';
import '../models/kline_bar.dart';

enum _KlineDir { up, down, combine }

enum _FxType { top, bottom, unknown }

class _MergedKlc {
  double high;
  double low;
  _KlineDir dir;
  _FxType fx;
  int beginIdx;
  int endIdx;

  _MergedKlc({
    required this.high,
    required this.low,
    required this.dir,
    required this.beginIdx,
    required this.endIdx,
  }) : fx = _FxType.unknown;
}

/// Dart 回退：与 Rust `build_kline_combine_bundle` 同逻辑的笔确认柱。
List<BiConfirmSignal> computeBiConfirmSignals(List<KlineBar> bars) {
  if (bars.isEmpty) return const [];

  final klcs = <_MergedKlc>[];
  final signals = <BiConfirmSignal>[];

  for (var i = 0; i < bars.length; i++) {
    final bar = bars[i];
    if (klcs.isEmpty) {
      klcs.add(
        _MergedKlc(
          high: bar.high,
          low: bar.low,
          dir: _KlineDir.up,
          beginIdx: i,
          endIdx: i,
        ),
      );
      continue;
    }

    final last = klcs.last;
    final dir = _testCombineRange(last.high, last.low, bar.high, bar.low);
    if (dir == _KlineDir.combine) {
      if (last.dir == _KlineDir.up) {
        if ((bar.high - bar.low).abs() > 1e-12 ||
            (bar.high - last.high).abs() > 1e-12) {
          last.high = mathMax(last.high, bar.high);
          last.low = mathMax(last.low, bar.low);
        }
      } else if (last.dir == _KlineDir.down) {
        if ((bar.high - bar.low).abs() > 1e-12 ||
            (bar.low - last.low).abs() > 1e-12) {
          last.high = mathMin(last.high, bar.high);
          last.low = mathMin(last.low, bar.low);
        }
      }
      last.endIdx = i;
    } else {
      klcs.add(
        _MergedKlc(
          high: bar.high,
          low: bar.low,
          dir: dir,
          beginIdx: i,
          endIdx: i,
        ),
      );
      if (klcs.length >= 3) {
        final n = klcs.length;
        _updateFx(klcs[n - 2], klcs[n - 3], klcs[n - 1]);
        _pushBiConfirmIfFx(klcs[n - 2], i, signals);
      }
    }
  }
  return signals;
}

_KlineDir _testCombineRange(
  double highA,
  double lowA,
  double highB,
  double lowB,
) {
  if (highA >= highB && lowA <= lowB) return _KlineDir.combine;
  if (highA <= highB && lowA >= lowB) return _KlineDir.combine;
  if (highA > highB && lowA > lowB) return _KlineDir.down;
  if (highA < highB && lowA < lowB) return _KlineDir.up;
  return _KlineDir.combine;
}

void _updateFx(_MergedKlc self, _MergedKlc pre, _MergedKlc next) {
  self.fx = _FxType.unknown;
  if (pre.high < self.high &&
      next.high < self.high &&
      pre.low < self.low &&
      next.low < self.low) {
    self.fx = _FxType.top;
  } else if (pre.high > self.high &&
      next.high > self.high &&
      pre.low > self.low &&
      next.low > self.low) {
    self.fx = _FxType.bottom;
  }
}

void _pushBiConfirmIfFx(
  _MergedKlc klc,
  int confirmBarIdx,
  List<BiConfirmSignal> signals,
) {
  switch (klc.fx) {
    case _FxType.top:
      signals.add(
        BiConfirmSignal(
          x: confirmBarIdx,
          fx: 'TOP',
          value: -1,
          fractalX1: klc.beginIdx,
          fractalX2: klc.endIdx,
        ),
      );
    case _FxType.bottom:
      signals.add(
        BiConfirmSignal(
          x: confirmBarIdx,
          fx: 'BOTTOM',
          value: 1,
          fractalX1: klc.beginIdx,
          fractalX2: klc.endIdx,
        ),
      );
    case _FxType.unknown:
      break;
  }
}

double mathMax(double a, double b) => a > b ? a : b;
double mathMin(double a, double b) => a < b ? a : b;
