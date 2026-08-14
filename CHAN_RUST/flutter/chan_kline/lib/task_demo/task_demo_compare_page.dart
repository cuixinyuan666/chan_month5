import 'dart:io';

import 'package:flutter/material.dart';

import '../bridge/chan_bridge.dart';
import '../models/kline_bar.dart';
import 'task_demo_loader.dart';
import 'task_demo_manifest.dart';

/// 任务演示：上=原本实现，下=本次实现（同页对比）
class TaskDemoListPage extends StatefulWidget {
  const TaskDemoListPage({
    super.key,
    required this.dataRoot,
    required this.onLoadDemoCsv,
  });

  final String dataRoot;
  final Future<void> Function(List<KlineBar> bars) onLoadDemoCsv;

  @override
  State<TaskDemoListPage> createState() => _TaskDemoListPageState();
}

class _TaskDemoListPageState extends State<TaskDemoListPage> {
  late Future<List<TaskDemoManifest>> _future;

  @override
  void initState() {
    super.initState();
    _future = TaskDemoLoader.listDemos(widget.dataRoot);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('任务演示列表')),
      body: FutureBuilder<List<TaskDemoManifest>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data ?? const [];
          if (list.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '暂无演示条目。\n'
                '智能体完成任务后应在 a_Data/test/demos/{task_id}/ 放置 manifest.json。\n'
                '详见仓库 AGENT_LONG_TERM_MEMORY.md。',
              ),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final m = list[i];
              return ListTile(
                title: Text(m.title),
                subtitle: Text(
                  '${m.completedAt} · ${m.agent}'
                  '${m.isNewFeature ? " · 全新" : " · 有对比"}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => TaskDemoComparePage(
                        dataRoot: widget.dataRoot,
                        manifest: m,
                        onLoadDemoCsv: widget.onLoadDemoCsv,
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class TaskDemoComparePage extends StatefulWidget {
  const TaskDemoComparePage({
    super.key,
    required this.dataRoot,
    required this.manifest,
    required this.onLoadDemoCsv,
  });

  final String dataRoot;
  final TaskDemoManifest manifest;
  final Future<void> Function(List<KlineBar> bars) onLoadDemoCsv;

  @override
  State<TaskDemoComparePage> createState() => _TaskDemoComparePageState();
}

class _TaskDemoComparePageState extends State<TaskDemoComparePage> {
  String? _beforeMd;
  String? _afterMd;
  bool _hasBeforePng = false;
  bool _loading = true;
  bool _importing = false;

  TaskDemoManifest get m => widget.manifest;

  @override
  void initState() {
    super.initState();
    _loadContent();
  }

  Future<void> _loadContent() async {
    final dir = m.demoDirPath;
    final sep = Platform.pathSeparator;
    final before = await TaskDemoLoader.readTextIfExists('$dir${sep}before.md');
    final after = await TaskDemoLoader.readTextIfExists('$dir${sep}after.md');
    final hasPng = await TaskDemoLoader.hasImage(dir, 'before.png');
    if (!mounted) return;
    setState(() {
      _beforeMd = before;
      _afterMd = after;
      _hasBeforePng = hasPng;
      _loading = false;
    });
  }

  Future<List<KlineBar>> _parseDemoCsv(String path) =>
      TaskDemoLoader.parseDemoCsv(path);

  Future<void> _importDemoCsv() async {
    final csvPath = TaskDemoLoader.demoCsvPath(m);
    if (csvPath == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('本演示未配置 demoCsv；可用现有 custom.ohlc.csv 或默认股票验收'),
        ),
      );
      return;
    }
    setState(() => _importing = true);
    try {
      if (!await File(csvPath).exists()) {
        throw StateError('找不到演示 CSV：$csvPath');
      }
      final parsed = await _parseDemoCsv(csvPath);
      if (parsed.isEmpty) throw StateError('演示 CSV 无有效行');
      ChanBridge.instance.saveTestOhlc(dataRoot: widget.dataRoot, bars: parsed);
      await widget.onLoadDemoCsv(parsed);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已加载 ${parsed.length} 根 K 线到 test，关闭本页后在主图连续单步验收'),
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(m.title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(m.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (TaskDemoLoader.demoCsvPath(m) != null)
            TextButton(
              onPressed: _importing ? null : _importDemoCsv,
              child: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('加载演示数据'),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _DemoSection(
              title: '原本实现',
              accent: Colors.orange.shade800,
              summary: m.beforeSummary,
              body: _beforeMd,
              imagePath: _hasBeforePng
                  ? TaskDemoLoader.imagePath(m.demoDirPath, 'before.png')
                  : null,
              verificationPoints: m.isNewFeature ? const [] : m.verificationPoints,
              footer: m.isNewFeature ? '（全新功能：无旧版对比，上半区仅作背景说明）' : null,
            ),
          ),
          const Divider(height: 2, thickness: 2),
          Expanded(
            child: _DemoSection(
              title: '本次实现',
              accent: Colors.lightGreen.shade700,
              summary: m.afterSummary,
              body: _afterMd,
              verificationPoints: m.verificationPoints,
              keySteps: m.keySteps,
              defaultStockCode: m.defaultStockCode,
              defaultStockNote: m.defaultStockNote,
              footer: '关闭本页后，在主图区域连续单步验收（一键跳末≠步进验收）。',
            ),
          ),
        ],
      ),
    );
  }
}

class _DemoSection extends StatelessWidget {
  const _DemoSection({
    required this.title,
    required this.accent,
    required this.summary,
    this.body,
    this.imagePath,
    this.verificationPoints = const [],
    this.keySteps = const [],
    this.defaultStockCode,
    this.defaultStockNote,
    this.footer,
  });

  final String title;
  final Color accent;
  final String summary;
  final String? body;
  final String? imagePath;
  final List<String> verificationPoints;
  final List<int> keySteps;
  final String? defaultStockCode;
  final String? defaultStockNote;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: accent.withValues(alpha: 0.06),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: accent,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(summary, style: const TextStyle(fontSize: 13)),
          if (defaultStockCode != null && defaultStockCode!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '默认股票验收：$defaultStockCode'
              '${defaultStockNote != null ? " — $defaultStockNote" : ""}',
              style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ],
          if (imagePath != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.file(
                File(imagePath!),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ],
          if (body != null && body!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(body!, style: const TextStyle(fontSize: 12)),
          ],
          if (verificationPoints.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('验证点位', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            ...verificationPoints.map(
              (p) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('· ', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Text(p, style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (keySteps.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '关键步进：${keySteps.join(", ")}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
          if (footer != null) ...[
            const SizedBox(height: 10),
            Text(
              footer!,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }
}
