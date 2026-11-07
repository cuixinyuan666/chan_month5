import 'package:flutter/material.dart';

import '../settings/telegram_settings_store.dart';

/// Telegram 数据源设置弹窗（含操作步骤说明）。
Future<TelegramSettings?> showTelegramSettingsDialog(
  BuildContext context,
  TelegramSettings initial, {
  VoidCallback? onUpdateTicksNow,
}) async {
  final source = ValueNotifier(initial.source);
  final autoDaily = ValueNotifier(initial.autoTicksDaily);
  final tokenCtrl = TextEditingController(text: initial.botToken);
  final chatCtrl = TextEditingController(text: initial.chatId);
  final indexCtrl = TextEditingController(text: initial.indexFileId);
  final proxyCtrl = TextEditingController(text: initial.proxy);
  final tickIndexCtrl = TextEditingController(text: initial.tickIndexFileId);

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
              const SizedBox(height: 10),
              TextField(
                controller: tickIndexCtrl,
                decoration: const InputDecoration(
                  labelText: '分笔索引 ticks_index.json 的 file_id（可选）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: proxyCtrl,
                decoration: const InputDecoration(
                  labelText: 'HTTP 代理（如 127.0.0.1:19828；直连留空）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const Divider(height: 24),
              ValueListenableBuilder<bool>(
                valueListenable: autoDaily,
                builder: (_, v, __) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('每个交易日自动更新分笔'),
                  subtitle: const Text(
                    '收盘后 15:35 自动上传当天分笔到 Telegram；盘中只补到上一交易日。'
                    '全市场历史上传完成前请先关掉此开关，避免两台重复传当天分笔。',
                  ),
                  value: v,
                  onChanged: (x) => autoDaily.value = x,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('立即更新分笔到 Telegram'),
                  onPressed: onUpdateTicksNow,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '全市场分笔上传和进度已放在主图设置里。',
                style: TextStyle(fontSize: 12, height: 1.35),
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
                  tickIndexFileId: tickIndexCtrl.text.trim(),
                  proxy: proxyCtrl.text.trim(),
                  autoTicksDaily: autoDaily.value,
                  shareDir: initial.shareDir,
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
