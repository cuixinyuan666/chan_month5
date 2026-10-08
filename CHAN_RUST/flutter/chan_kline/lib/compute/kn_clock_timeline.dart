import '../models/level_models.dart';

/// K1+ 采样钟的「当时快照」时间线（动态段口径 / 当下性）。
///
/// **为什么需要它**：K1 及以上的穿越/事件条件按「虚拟 K 样本」取样，而样本点落在哪根 K，
/// 取决于**当时那一段走到哪了**。若事后用最终态的段划分来采样，「当时正在生长、还没定型」
/// 的那一段会被划到别处，asOf 那一刻就没有采样点，动态段中途成立的信号因此丢失或被推迟到段尾。
///
/// 本时间线在步进重放时**每一步**记下「这一步新确认了哪些段」+「这一步正在生长的是哪一段」，
/// 求值时按 asOf 还原当时的段划分，从而与实盘当时真正能看到的一致。
///
/// **只存增量**：每步大约记 0~1 个新确认段 + 1 个动态段，内存与步数成正比（不与段数平方成正比）。
class KnClockStep {
  /// 本步新确认（定型）的段。
  final List<LevelUnitBar> newlyConfirmed;

  /// 本步正在生长、尚未定型的那一段（离开则为 null）。
  final LevelUnitBar? activeUnit;

  const KnClockStep({required this.newlyConfirmed, required this.activeUnit});
}

/// asOf 当时的段划分还原结果。
typedef KnClockState = ({List<LevelUnitBar> unitBars, LevelUnitBar? activeUnit});

class KnClockTimeline {
  /// 记录步序（升序）。步进是连续递增的，用数组即可；查最近一步走二分。
  final List<int> _asOfKeys = <int>[];

  final List<KnClockStep> _steps = <KnClockStep>[];
  final Map<int?, KnClockState> _cache = <int?, KnClockState>{};
  final Map<int?, List<int>> _sampleEndsCache = <int?, List<int>>{};

  bool get isEmpty => _steps.isEmpty;

  /// 清空（换标的 / 重来 / 步退到根）。
  void clear() {
    _asOfKeys.clear();
    _steps.clear();
    _cache.clear();
    _sampleEndsCache.clear();
  }

  /// 已记录的步数。
  int get length => _steps.length;

  /// 最后记录的 asOf（空时为 -1）。
  int get lastAsOf => _asOfKeys.isEmpty ? -1 : _asOfKeys.last;

  /// 记一步。重复 asOf 会被忽略（步进每根 K 只记一次）。
  void record(
    int asOf, {
    required List<LevelUnitBar> newlyConfirmed,
    required LevelUnitBar? activeUnit,
  }) {
    if (_asOfKeys.isNotEmpty && _asOfKeys.last == asOf) return;
    _asOfKeys.add(asOf);
    _steps.add(KnClockStep(
      newlyConfirmed: List<LevelUnitBar>.unmodifiable(newlyConfirmed),
      activeUnit: activeUnit,
    ));
    _cache.clear();
    _sampleEndsCache.clear();
  }

  /// 还原 asOf 当时的段划分：[asOf] 为 null 表示最后一步。
  ///
  /// 累计 asOf 之前（含）各步新确认的段，并取那一步的动态段。
  KnClockState at(int? asOf) {
    final cached = _cache[asOf];
    if (cached != null) return cached;
    if (_steps.isEmpty) {
      return _cache[asOf] = (unitBars: const <LevelUnitBar>[], activeUnit: null);
    }
    // 找 <= asOf 的最后一步（asOf 为 null 取最后一步）
    var hi = _asOfKeys.length;
    var stepIndex = _steps.length;
    if (asOf != null) {
      var lo = 0;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (_asOfKeys[mid] <= asOf) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      stepIndex = lo;
      if (lo == 0) {
        // asOf 早于第一次记录：当时什么都还没有
        return _cache[asOf] =
            (unitBars: const <LevelUnitBar>[], activeUnit: null);
      }
    }
    final last = stepIndex - 1;
    final unitBars = <LevelUnitBar>[];
    for (var i = 0; i <= last; i++) {
      unitBars.addAll(_steps[i].newlyConfirmed);
    }
    unitBars.sort((a, b) => a.x2.compareTo(b.x2));
    return _cache[asOf] = (unitBars: unitBars, activeUnit: _steps[last].activeUnit);
  }

  /// 指纹（供前缀重放对拍比对）。
  String signature(int? asOf) {
    final s = at(asOf);
    final conf = s.unitBars
        .map((u) => '${u.x1}-${u.x2}d${u.dir}')
        .join(',');
    final a = s.activeUnit;
    return '$conf|act=${a == null ? '-' : '${a.x1}-${a.x2}d${a.dir}@${a.close}'}';
  }

  // ---------------------------------------------------------------------
  // 逐 bar 采样点（K1+ 穿越判定的正确口径 / 当下性）
  //
  // 上一段「一段一个采样点」的做法只对 asOf=末根成立：一次性判全区间时，
  // 「第 x 根那里有一个采样点」这件事只有走到 x 才知道，单点求值永远拿不到。
  // 实盘是**每根 K 都在场判一次**，所以采样点必须是：
  //   所有 x ≤ asOf 且「x 那一刻存在正在生长的段（dir≠0）」的 bar。
  // 段定型那一根也算（那一刻它就是 active 段末端），因此已确认段的右端天然被覆盖。
  // ---------------------------------------------------------------------

  /// 逐 bar 采样点右端（升序、去重）。结果按 asOf 缓存。
  List<int> sampleEnds(int? asOf) {
    final cached = _sampleEndsCache[asOf];
    if (cached != null) return cached;
    final limit = asOf ?? (_asOfKeys.isEmpty ? -1 : _asOfKeys.last);
    final seen = <int>{};
    final out = <int>[];
    for (var i = 0; i < _asOfKeys.length; i++) {
      if (_asOfKeys[i] > limit) break;
      final a = _steps[i].activeUnit;
      if (a == null || (a.dir != 1 && a.dir != -1) || a.x2 < 0) continue;
      if (a.x1 > _asOfKeys[i]) continue;
      if (seen.add(_asOfKeys[i])) out.add(_asOfKeys[i]);
    }
    out.sort();
    return _sampleEndsCache[asOf] = out;
  }

  /// x 那一刻的动态段 OHLC（x 必须是采样点）。
  ({double open, double high, double low, double close})? activeOhlcAt(int x) {
    final i = _indexOfAsOf(x);
    if (i < 0) return null;
    final a = _steps[i].activeUnit;
    if (a == null || (a.dir != 1 && a.dir != -1) || a.x2 < 0) return null;
    return (open: a.open, high: a.high, low: a.low, close: a.close);
  }

  int _indexOfAsOf(int x) {
    var lo = 0;
    var hi = _asOfKeys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_asOfKeys[mid] < x) {
        lo = mid + 1;
      } else if (_asOfKeys[mid] > x) {
        hi = mid;
      } else {
        return mid;
      }
    }
    return -1;
  }
}

/// 步进时用的增量记录器：比较 bundle 里 unitBars 数量变化，得出本步新确认的段。
class KnClockTimelineRecorder {
  final KnClockTimeline timeline = KnClockTimeline();
  int _seenUnits = 0;

  void reset() {
    _seenUnits = 0;
  }

  /// [unitBars] 取 level 0（displayKn=1 的父层）的已确认段；[activeUnit] 同层动态段。
  void record(int asOf, List<LevelUnitBar> unitBars, LevelUnitBar? activeUnit) {
    final start = _seenUnits > unitBars.length ? unitBars.length : _seenUnits;
    final fresh = start < unitBars.length
        ? unitBars.sublist(start)
        : const <LevelUnitBar>[];
    _seenUnits = unitBars.length;
    timeline.record(asOf, newlyConfirmed: fresh, activeUnit: activeUnit);
  }
}

/// 取 level 0 的已确认段与动态段（displayKn=1 的采样父层）。
({List<LevelUnitBar> unitBars, LevelUnitBar? activeUnit}) level0Units(
  List<LevelBundle> levels,
) {
  for (final lv in levels) {
    if (lv.level == 0) {
      return (unitBars: lv.unitBars, activeUnit: lv.activeUnit);
    }
  }
  return (unitBars: const <LevelUnitBar>[], activeUnit: null);
}