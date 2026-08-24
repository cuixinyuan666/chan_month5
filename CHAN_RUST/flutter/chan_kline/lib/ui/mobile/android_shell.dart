import 'package:flutter/material.dart';

/// Android 顶栏：避让状态栏，集中股票/周期/设置（参考行情 App 顶栏）。
class AndroidTopBar extends StatelessWidget {
  const AndroidTopBar({
    super.key,
    required this.selectedCode,
    required this.codes,
    required this.periodLabel,
    required this.periods,
    required this.onPickStock,
    required this.onPeriodChanged,
    required this.onOpenSettings,
    this.busy = false,
  });

  final String? selectedCode;
  final List<String> codes;
  final String periodLabel;
  final Map<String, String> periods;
  final VoidCallback onPickStock;
  final ValueChanged<String> onPeriodChanged;
  final VoidCallback onOpenSettings;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1A1A1A),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: busy || codes.isEmpty ? null : onPickStock,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          Text(
                            selectedCode ?? '选股票',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFE2E8F0),
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.arrow_drop_down,
                            size: 20,
                            color: Color(0xFF94A3B8),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: periods.containsKey(periodLabel)
                          ? periodLabel
                          : (periods.keys.isEmpty ? null : periods.keys.first),
                      icon: const Icon(Icons.arrow_drop_down, size: 18),
                      dropdownColor: const Color(0xFF1E1E1E),
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFE2E8F0),
                      ),
                      items: periods.entries
                          .map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(
                                e.value,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: busy
                          ? null
                          : (v) {
                              if (v != null) onPeriodChanged(v);
                            },
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '设置',
                  onPressed: busy ? null : onOpenSettings,
                  icon: const Icon(Icons.tune, color: Color(0xFFE2E8F0)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Android 底栏：步退/播放/步进/跳末 + 步进读数。
class AndroidPlayBar extends StatelessWidget {
  const AndroidPlayBar({
    super.key,
    required this.stepIdx,
    required this.totalBars,
    required this.isPlaying,
    required this.canStep,
    required this.onStepBack,
    required this.onPlay,
    required this.onStepForward,
    required this.onRunToEnd,
  });

  final int stepIdx;
  final int totalBars;
  final bool isPlaying;
  final bool canStep;
  final VoidCallback? onStepBack;
  final VoidCallback? onPlay;
  final VoidCallback? onStepForward;
  final VoidCallback? onRunToEnd;

  @override
  Widget build(BuildContext context) {
    final pos = stepIdx < 0 ? 0 : stepIdx + 1;
    final total = totalBars;
    return Material(
      color: const Color(0xFF1A1A1A),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              IconButton(
                tooltip: '步退',
                onPressed: onStepBack,
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                tooltip: isPlaying ? '暂停' : '播放',
                onPressed: onPlay,
                iconSize: 32,
                icon: Icon(
                  isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                  color: const Color(0xFF42A5F5),
                ),
              ),
              IconButton(
                tooltip: '步进',
                onPressed: onStepForward,
                icon: const Icon(Icons.skip_next),
              ),
              IconButton(
                tooltip: '跑到末尾',
                onPressed: onRunToEnd,
                icon: const Icon(Icons.fast_forward),
              ),
              Expanded(
                child: Text(
                  canStep ? 'K $pos / $total' : '加载中…',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF94A3B8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Android 设置：全宽底部抽屉（替代桌面侧边面板）。
Future<void> showAndroidSettingsSheet({
  required BuildContext context,
  required Widget child,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (ctx) {
      final maxH = MediaQuery.sizeOf(ctx).height * 0.88;
      return SafeArea(
        child: SizedBox(
          height: maxH,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        '加载与显示设置',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFE2E8F0),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close, color: Color(0xFF94A3B8)),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0x33FFFFFF)),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Android 股票列表底部抽屉。
Future<void> showAndroidStockPicker({
  required BuildContext context,
  required List<String> codes,
  required String? selected,
  required ValueChanged<String> onSelected,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '选择股票',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFE2E8F0),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: codes.length,
                itemBuilder: (_, i) {
                  final c = codes[i];
                  final sel = c == selected;
                  return ListTile(
                    dense: true,
                    title: Text(
                      c,
                      style: TextStyle(
                        color: sel ? const Color(0xFF42A5F5) : const Color(0xFFE2E8F0),
                        fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    trailing: sel
                        ? const Icon(Icons.check, color: Color(0xFF42A5F5), size: 20)
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      onSelected(c);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}
