/// 特征序列线框（Rust `EigenFrame`）。
class EigenFrame {
  final int slot;
  final int x1;
  final int x2;
  final double high;
  final double low;
  final String fx;
  final int k1Count;

  const EigenFrame({
    required this.slot,
    required this.x1,
    required this.x2,
    required this.high,
    required this.low,
    required this.fx,
    required this.k1Count,
  });

  factory EigenFrame.fromJson(Map<String, dynamic> json) {
    return EigenFrame(
      slot: (json['slot'] as num?)?.toInt() ?? 0,
      x1: (json['x1'] as num).toInt(),
      x2: (json['x2'] as num).toInt(),
      high: (json['high'] as num).toDouble(),
      low: (json['low'] as num).toDouble(),
      fx: json['fx'] as String? ?? 'UNKNOWN',
      k1Count: (json['k1_count'] as num?)?.toInt() ?? 1,
    );
  }
}

/// K1连线确认柱（Rust `K1ConfirmSignal`）。
class K1ConfirmSignal {
  final int x;
  final String fx;
  final int value;
  final int endedSegDir;
  final int peakK1Idx;
  final int fractalX1;
  final int fractalX2;
  final double fractalHigh;
  final double fractalLow;

  const K1ConfirmSignal({
    required this.x,
    required this.fx,
    required this.value,
    required this.endedSegDir,
    required this.peakK1Idx,
    this.fractalX1 = 0,
    this.fractalX2 = 0,
    this.fractalHigh = 0,
    this.fractalLow = 0,
  });

  factory K1ConfirmSignal.fromJson(Map<String, dynamic> json) {
    return K1ConfirmSignal(
      x: (json['x'] as num).toInt(),
      fx: json['fx'] as String? ?? '',
      value: (json['value'] as num).toInt(),
      endedSegDir: (json['ended_seg_dir'] as num).toInt(),
      peakK1Idx: (json['peak_k1_idx'] as num?)?.toInt() ?? -1,
      fractalX1: (json['fractal_x1'] as num?)?.toInt() ?? 0,
      fractalX2: (json['fractal_x2'] as num?)?.toInt() ?? 0,
      fractalHigh: (json['fractal_high'] as num?)?.toDouble() ?? 0,
      fractalLow: (json['fractal_low'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// 首段方向锁定（Rust `FirstSegDirSignal`）。
class FirstSegDirSignal {
  final int x;
  final int dir;

  const FirstSegDirSignal({required this.x, required this.dir});

  factory FirstSegDirSignal.fromJson(Map<String, dynamic> json) {
    return FirstSegDirSignal(
      x: (json['x'] as num).toInt(),
      dir: (json['dir'] as num).toInt(),
    );
  }
}

/// 已确认 K1连线（主图展示，不参与 ML）。
class K1Line {
  final int idx;
  final int dir;
  final int beginX;
  final int endX;
  final int beginFractalX1;
  final int beginFractalX2;
  final int endFractalX1;
  final int endFractalX2;
  final double beginPrice;
  final double endPrice;

  const K1Line({
    required this.idx,
    required this.dir,
    required this.beginX,
    required this.endX,
    required this.beginPrice,
    required this.endPrice,
    this.beginFractalX1 = 0,
    this.beginFractalX2 = 0,
    this.endFractalX1 = 0,
    this.endFractalX2 = 0,
  });

  factory K1Line.fromJson(Map<String, dynamic> json) {
    return K1Line(
      idx: (json['idx'] as num).toInt(),
      dir: (json['dir'] as num).toInt(),
      beginX: (json['begin_x'] as num).toInt(),
      endX: (json['end_x'] as num).toInt(),
      beginFractalX1: (json['begin_fractal_x1'] as num?)?.toInt() ?? 0,
      beginFractalX2: (json['begin_fractal_x2'] as num?)?.toInt() ?? 0,
      endFractalX1: (json['end_fractal_x1'] as num?)?.toInt() ?? 0,
      endFractalX2: (json['end_fractal_x2'] as num?)?.toInt() ?? 0,
      beginPrice: (json['begin_price'] as num).toDouble(),
      endPrice: (json['end_price'] as num).toDouble(),
    );
  }
}

/// 逐 K 副图快照（Rust `BarSubSnapshot`）。
class BarSubSnapshot {
  final int idx;
  final int buildingSegDir;
  final int firstSegDir;
  final int k1Confirm;
  final int eigenSlot;
  final List<EigenFrame> eigenFrames;

  const BarSubSnapshot({
    required this.idx,
    required this.buildingSegDir,
    required this.firstSegDir,
    required this.k1Confirm,
    this.eigenSlot = -1,
    this.eigenFrames = const [],
  });

  factory BarSubSnapshot.fromJson(Map<String, dynamic> json) {
    return BarSubSnapshot(
      idx: (json['idx'] as num?)?.toInt() ?? 0,
      buildingSegDir: (json['building_seg_dir'] as num?)?.toInt() ?? 0,
      firstSegDir: (json['first_seg_dir'] as num?)?.toInt() ?? 0,
      k1Confirm: (json['k1_confirm'] as num?)?.toInt() ?? 0,
      eigenSlot: (json['eigen_slot'] as num?)?.toInt() ?? -1,
      eigenFrames: (json['eigen_frames'] as List? ?? const [])
          .map((e) => EigenFrame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }

  String get eigenFx {
    for (final f in eigenFrames.reversed) {
      if (f.fx != 'UNKNOWN') return f.fx;
    }
    return eigenFrames.isNotEmpty ? eigenFrames.last.fx : 'UNKNOWN';
  }
}

/// K1连线分析整包（Rust `K1AnalysisBundle`；旧称2段/线段）。
class K1AnalysisBundle {
  final List<EigenFrame> eigenFrames;
  final List<K1ConfirmSignal> k1Confirms;
  final List<FirstSegDirSignal> firstSegDirSignals;
  final List<K1Line> k1Lines;
  final List<BarSubSnapshot> barSubSnapshots;
  final int buildingSegDir;
  final int firstSegDir;

  const K1AnalysisBundle({
    this.eigenFrames = const [],
    this.k1Confirms = const [],
    this.firstSegDirSignals = const [],
    this.k1Lines = const [],
    this.barSubSnapshots = const [],
    this.buildingSegDir = 0,
    this.firstSegDir = 0,
  });

  factory K1AnalysisBundle.fromJson(Map<String, dynamic> json) {
    return K1AnalysisBundle(
      eigenFrames: (json['eigen_frames'] as List? ?? const [])
          .map((e) => EigenFrame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      k1Confirms: (json['k1_confirms'] as List? ?? const [])
          .map((e) => K1ConfirmSignal.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      firstSegDirSignals: (json['first_seg_dir_signals'] as List? ?? const [])
          .map((e) => FirstSegDirSignal.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      k1Lines: (json['k1_lines'] as List? ?? const [])
          .map((e) => K1Line.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      barSubSnapshots: (json['bar_sub_snapshots'] as List? ?? const [])
          .map((e) => BarSubSnapshot.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      buildingSegDir: (json['building_seg_dir'] as num?)?.toInt() ?? 0,
      firstSegDir: (json['first_seg_dir'] as num?)?.toInt() ?? 0,
    );
  }

  BarSubSnapshot? snapshotAt(int idx) {
    for (final s in barSubSnapshots) {
      if (s.idx == idx) return s;
    }
    return null;
  }

  static K1AnalysisBundle empty() => const K1AnalysisBundle();
}
