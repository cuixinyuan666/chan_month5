import 'package:flutter/material.dart';
import 'package:chan_kline/theme/app_palette.dart';

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
    backgroundColor: AppPalette.surface,
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
                        Expanded(
                          child: Text(
                            '设置',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.textPrimary,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(sheetCtx),
                          icon: Icon(Icons.close, color: AppPalette.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: AppPalette.rgb(0x33FFFFFF)),
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
    backgroundColor: AppPalette.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '选择股票',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.textPrimary,
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
                        color: sel ? AppPalette.accent : AppPalette.textPrimary,
                        fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    trailing: sel
                        ? Icon(Icons.check, color: AppPalette.accent, size: 20)
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
