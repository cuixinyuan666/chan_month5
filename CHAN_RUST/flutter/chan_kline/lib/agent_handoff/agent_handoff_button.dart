import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent_handoff_package.dart';

/// 「智能体交流」按钮的公共部件。
/// 点击后把当次结论数据整理成结构化交接包、复制到剪贴板，并弹窗告知用户粘贴给智能体。
class AgentHandoffButton extends StatelessWidget {
  const AgentHandoffButton({super.key, required this.buildPackage});

  /// 调用方得到交接包文件的回调。
  final Future<String> Function() buildPackage;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      icon: const Icon(Icons.forum_outlined, size: 18),
      label: const Text('智能体交流'),
      onPressed: () async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        try {
          final path = await buildPackage();
          final text = await _readOrBuild(path);
          await Clipboard.setData(ClipboardData(text: text));
          if (!context.mounted) return;
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('交接包已生成'),
              content: Text(AgentHandoffPackage.handoffHint(path)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('好'),
                ),
              ],
            ),
          );
        } catch (e) {
          messenger?.showSnackBar(
            SnackBar(content: Text('交接包生成失败：$e')),
          );
        }
      },
    );
  }

  static Future<String> _readOrBuild(String path) async {
    final f = File(path);
    if (await f.exists()) return f.readAsString();
    return AgentHandoffPackage.encode({});
  }
}
