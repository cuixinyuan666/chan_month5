import 'package:flutter/material.dart';

/// Android 设置：全宽底部抽屉（替代桌面侧边面板）。
Future<void> showAndroidSettingsSheet({
  required BuildContext context,
  required Widget Function(BuildContext context, StateSetter setSheetState)
      builder,
  VoidCallback? onClosed,
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
      return StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
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
                          onPressed: () => Navigator.pop(sheetCtx),
                          icon: const Icon(Icons.close, color: Color(0xFF94A3B8)),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0x33FFFFFF)),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                      child: builder(sheetCtx, setSheetState),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  ).whenComplete(() => onClosed?.call());
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
