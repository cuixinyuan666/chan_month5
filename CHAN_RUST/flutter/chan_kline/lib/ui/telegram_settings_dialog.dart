import 'package:flutter/material.dart';

import '../settings/telegram_settings_store.dart';
import '../ui/settings_panel_widgets.dart';

/// Telegram 数据源设置弹窗（含操作步骤说明）。
Future<TelegramSettings?> showTelegramSettingsDialog(
  BuildContext context,
  TelegramSettings initial,
) async {
  final source = ValueNotifier(initial.source);
  final tokenCtrl = TextEditingController(text: initial.botToken);
  final chatCtrl = TextEditingController(text: initial.chatId);
  final indexCtrl = TextEditingController(text: initial.indexFileId);

  return showDialog<TelegramSettings>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('Telegram 数据源'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '操作步骤：\n'
                '1. 在 @BotFather 创建 bot，复制 Token。\n'
                '2. 给 bot 发一条消息，用 getUpdates 或脚本拿到 chat_id。\n'
                '3. 运行仓库脚本上传日线与 index.json，把 index 的 file_id 填到下面。\n'
                '4. 选「Telegram 日线」后，加载周期请选「日 K」；分笔仍走本地缓存/通达信。\n'
                '5. 失败会自动回退通达信协议。',
                style: TextStyle(fontSize: 13, height: 1.35),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<KlineDataSourceKind>(
                valueListenable: source,
                builder: (_, v, __) => DropdownButtonFormField<KlineDataSourceKind>(
                  value: v,
                  decoration: const InputDecoration(
                    labelText: 'K 线数据源',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: KlineDataSourceKind.protocol,
                      child: Text('通达信协议（默认）'),
                    ),
                    DropdownMenuItem(
                      value: KlineDataSourceKind.telegram,
                      child: Text('Telegram Bot（按代码精准下日线）'),
                    ),
                  ],
                  onChanged: (x) {
                    if (x != null) source.value = x;
                  },
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: tokenCtrl,
                decoration: const InputDecoration(
                  labelText: 'Bot Token',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                obscureText: true,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: chatCtrl,
                decoration: const InputDecoration(
                  labelText: 'Chat ID',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: indexCtrl,
                decoration: const InputDecoration(
                  labelText: 'index.json 的 file_id（可选，填了可刷新索引）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(
                ctx,
                TelegramSettings(
                  source: source.value,
                  botToken: tokenCtrl.text.trim(),
                  chatId: chatCtrl.text.trim(),
                  indexFileId: indexCtrl.text.trim(),
                ),
              );
            },
            child: const Text('保存'),
          ),
        ],
      );
    },
  );
}
