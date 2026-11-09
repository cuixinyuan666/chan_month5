import 'package:flutter/material.dart';

import '../settings/peer_sync_settings_store.dart';
import '../sync/peer_sync_service.dart';

/// 双机同步弹窗：测试连接 → 差异清单 → 真同步 → 结论 / 按快照回退。
///
/// 口径全在 `CHAN_RUST/scripts/sync_to_remote.ps1`：发起方为准覆盖同名文件、
/// 不删对端独有文件、覆盖前把被覆盖文件存一份快照、推完把对端 App 拉回。
Future<PeerSyncSettings?> showPeerSyncDialog(
  BuildContext context, {
  required PeerSyncSettings initial,
}) {
  return showDialog<PeerSyncSettings>(
    context: context,
    builder: (dialogCtx) {
      var peer = initial.peerPath.trim().isEmpty
          ? PeerSyncService.defaultPeerPath()
          : initial.peerPath.trim();
      final peerCtrl = TextEditingController(text: peer);
      var busy = false;
      var status = '空闲';
      var lastLine = PeerSyncService.lastSyncLine(
        initial.lastSyncAt,
        initial.lastSyncOk,
        initial.lastSyncSummary,
      );
      final log = <String>[];
      final logScroll = ScrollController();
      var resultOk = true;
      var hasResult = false;
      var alive = true;

      void addLog(String line) {
        if (!alive) return;
        log.add(line);
        if (log.length > 400) log.removeRange(0, log.length - 400);
        // 自动滚到底
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!alive || !logScroll.hasClients) return;
          logScroll.jumpTo(logScroll.position.maxScrollExtent);
        });
      }

      return StatefulBuilder(
        builder: (ctx, setDlg) {
          Future<void> testConn() async {
            final target = peerCtrl.text.trim();
            setDlg(() {
              busy = true;
              status = '测试连接中……';
              log.clear();
              hasResult = false;
            });
            final text = await PeerSyncService.testConnection(peer: target);
            if (!alive) return;
            setDlg(() {
              busy = false;
              status = '测试连接完成';
              hasResult = true;
              resultOk = text.contains('共享：可达');
              log.addAll(text.split('\n'));
            });
          }

          Future<void> doSync() async {
            final target = peerCtrl.text.trim();
            if (target.isEmpty) {
              setDlg(() {
                status = '先填对端路径';
                hasResult = true;
                resultOk = false;
              });
              return;
            }
            setDlg(() {
              busy = true;
              status = '统计差异……';
              log.clear();
              hasResult = false;
              addLog('>> 统计差异（不动任何文件）');
            });
            final diff = await PeerSyncService.diff(peer: target);
            if (!alive) return;
            if (diff.json == null || !diff.ok) {
              setDlg(() {
                busy = false;
                status = '差异统计失败，已中止（没有写任何文件）';
                hasResult = true;
                resultOk = false;
                addLog('!! ${diff.error}');
              });
              return;
            }
            final j = diff.json!;
            final added = (j['new'] as num?)?.toInt() ?? 0;
            final over = (j['overwrite'] as num?)?.toInt() ?? 0;
            final same = (j['same'] as num?)?.toInt() ?? 0;
            final only = (j['onlyInPeer'] as num?)?.toInt() ?? 0;
            final locked = j['peerAppWasLocked'] == true;

            bool skipConfirm = false;
            if (added + over > 0) {
              if (!alive || !ctx.mounted) return;
              final confirmed = await showDialog<bool>(
                context: ctx,
                builder: (c2) => AlertDialog(
                  title: const Text('确认同步到对端'),
                  content: StatefulBuilder(
                    builder: (c3, setC3) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('对端：$target',
                            style: const TextStyle(fontSize: 12)),
                        const SizedBox(height: 8),
                        Text('新增 $added 个，覆盖 $over 个，相同 $same 个',
                            style: const TextStyle(fontSize: 13)),
                        const SizedBox(height: 4),
                        Text('对端独有 $only 个文件不会被删除',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade700)),
                        const SizedBox(height: 4),
                        Text(
                          locked
                              ? '对端 App 正在运行：同步时会先把它关掉（仅代理拉起的那个），推完再拉回。'
                              : '对端 App 没在运行。',
                          style: const TextStyle(fontSize: 12, height: 1.35),
                        ),
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          value: skipConfirm,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('本次不再询问', style: TextStyle(fontSize: 12)),
                          onChanged: (v) => setC3(() => skipConfirm = v ?? false),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(c2).pop(false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.of(c2).pop(true), child: const Text('开始同步')),
                  ],
                ),
              );
              if (confirmed != true || !alive) {
                setDlg(() {
                  busy = false;
                  status = '已取消（没有写任何文件）';
                  hasResult = true;
                  resultOk = true;
                });
                return;
              }
            }

            setDlg(() {
              status = '同步中……';
              addLog('>> 开始同步');
            });

            final out = await PeerSyncService.sync(
              peer: target,
              onLine: (l) {
                if (!alive) return;
                setDlg(() => addLog(l));
              },
            );

            if (!alive) return;
            final now = DateTime.now();
            final stamp = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
                '${now.day.toString().padLeft(2, '0')} '
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
            final summary = out.summaryLine;
            setDlg(() {
              busy = false;
              hasResult = true;
              resultOk = out.ok;
              status = out.ok ? '同步完成' : '同步失败';
              lastLine = PeerSyncService.lastSyncLine(stamp, out.ok, summary);
              addLog('>> 脚本退出码 ${out.exitCode}');
              addLog('>> 结论：$summary');
            });
            final saved = initial.copyWith(
              peerPath: target,
              lastSyncAt: stamp,
              lastSyncOk: out.ok,
              lastSyncSummary: summary,
            );
            await PeerSyncSettingsStore.save(saved);
            initial = saved;
          }

          Future<void> doRestore() async {
            final target = peerCtrl.text.trim();
            if (target.isEmpty) {
              setDlg(() {
                status = '先填对端路径';
                hasResult = true;
                resultOk = false;
                addLog('!! 对端路径为空：先在输入框填对端共享路径');
              });
              return;
            }
            final ok = await showDialog<bool>(
              context: ctx,
              builder: (c2) => AlertDialog(
                title: const Text('按快照回退'),
                content: const Text(
                  '把对端最近一份快照里的文件拷回对端（只回退当时被覆盖的那些文件，不删别的）。\n'
                  '对端 App 若正在运行，exe/dll 会被占用导致回退失败——必要时先关它。',
                  style: TextStyle(fontSize: 13, height: 1.35),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.of(c2).pop(false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.of(c2).pop(true), child: const Text('回退')),
                ],
              ),
            );
            if (ok != true || !alive) {
              if (alive) {
                setDlg(() {
                  status = '已取消回退（对端没有改动）';
                  hasResult = true;
                  resultOk = true;
                  addLog('>> 已取消，没有动任何文件');
                });
              }
              return;
            }
            setDlg(() {
              busy = true;
              status = '回退中……';
              hasResult = false;
              log.clear();
              addLog('>> 按快照回退（对端：$target）');
            });
            PeerSyncOutcome out;
            try {
              out = await PeerSyncService.restore(
                peer: target,
                onLine: (l) {
                  if (!alive) return;
                  setDlg(() => addLog(l));
                },
              );
            } catch (e) {
              if (!alive) return;
              setDlg(() {
                busy = false;
                hasResult = true;
                resultOk = false;
                status = '回退异常';
                addLog('!! 启动或等待回退脚本时异常：$e');
              });
              return;
            }
            if (!alive) return;
            final restored = out.json?['restored'];
            final stampUsed = (out.json?['stamp'] ?? '').toString();
            final now = DateTime.now();
            final ts = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
                '${now.day.toString().padLeft(2, '0')} '
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
            final line = out.ok
                ? '已回退 ${restored ?? 0} 个文件到快照 ${stampUsed.isEmpty ? '-' : stampUsed}（对端）'
                : '回退失败：${out.error}';
            setDlg(() {
              busy = false;
              hasResult = true;
              resultOk = out.ok;
              status = out.ok ? '回退完成' : '回退失败';
              lastLine = PeerSyncService.lastSyncLine(ts, out.ok, line);
              addLog('>> 脚本退出码 ${out.exitCode}');
              addLog(out.ok ? '>> 结论：$line' : '!! 结论：$line');
            });
            final saved = initial.copyWith(
              peerPath: target,
              lastSyncAt: ts,
              lastSyncOk: out.ok,
              lastSyncSummary: line,
            );
            await PeerSyncSettingsStore.save(saved);
            initial = saved;
          }

          final bool canAct = !busy;
          return AlertDialog(
            title: Row(
              children: [
                const Expanded(child: Text('双机同步')),
                IconButton(
                  tooltip: '说明',
                  icon: const Icon(Icons.help_outline, size: 20),
                  onPressed: () => showDialog<void>(
                    context: ctx,
                    builder: (c4) => AlertDialog(
                      title: const Text('双机同步 · 说明'),
                      content: const SingleChildScrollView(
                        child: Text(
                          '它做什么：把「这台」的项目（源码 + 编译产物 + 数据目录）推到「对端」，'
                          '让另一台跑的是同一份最新代码。\n\n'
                          '操作步骤：\n'
                          '1. 确认对端路径（默认按主机名自动填：PCA↔PCB）。\n'
                          '2. 点「测试连接」：只读探测共享是否可达、对端代理在不在、对端 App 是否占着产物。\n'
                          '3. 点「立即同步到对端」：先出差异清单（新增 / 覆盖 / 相同），确认后才真写。\n'
                          '4. 进度逐行显示：探测占用 → 关对端 App → 推源码 → 推产物 → 模板与 BOM → 指纹校验 → 重拉对端 App。\n\n'
                          '会覆盖什么：对端同名文件（以这台为准）；不会删除对端独有的文件。\n'
                          '被覆盖的文件会先在对端 a_Data\\remote_ctl\\sync_backup\\<时间戳>\\ 存一份，留最近 3 份。\n\n'
                          '对端 App：若它正开着，同步时会先关掉（只关代理拉起的那个），推完自动拉回并点掉太极。\n\n'
                          '失败怎么办：任何一步失败立刻停，不会继续推后续层；按「按快照回退」可还原被覆盖的文件。\n\n'
                          '不同步什么：.git 历史、对端的验证现场（a_Data\\robot_verify）、对端独有的数据。',
                          style: TextStyle(fontSize: 13, height: 1.4),
                        ),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(c4).pop(), child: const Text('知道了')),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 640,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: peerCtrl,
                            enabled: canAct,
                            decoration: const InputDecoration(
                              labelText: '对端项目路径（UNC 或本地）',
                              border: OutlineInputBorder(),
                              isDense: true,
                              hintText: r'\\192.168.1.6\D$\2\chan_month5',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: canAct
                              ? () {
                                  final d = PeerSyncService.defaultPeerPath();
                                  if (d.isNotEmpty) peerCtrl.text = d;
                                }
                              : null,
                          child: const Text('默认'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '本机：${PeerSyncService.selfLabel}（${PeerSyncService.hostName}）　脚本：'
                      '${PeerSyncService.scriptsReady ? '已就位' : '缺失'}',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: canAct ? testConn : null,
                          icon: const Icon(Icons.cable, size: 18),
                          label: const Text('测试连接'),
                        ),
                        FilledButton.icon(
                          onPressed: canAct ? doSync : null,
                          icon: const Icon(Icons.sync, size: 18),
                          label: const Text('立即同步到对端'),
                        ),
                        OutlinedButton.icon(
                          onPressed: canAct ? doRestore : null,
                          icon: const Icon(Icons.undo, size: 18),
                          label: const Text('按快照回退'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (busy)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        if (busy) const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$status　$lastLine',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 200,
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B1C1F),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.grey.shade600),
                      ),
                      child: SingleChildScrollView(
                        controller: logScroll,
                        child: SelectableText(
                          log.isEmpty ? '（还没有输出）' : log.join('\n'),
                          style: const TextStyle(
                            fontSize: 11.5,
                            height: 1.45,
                            fontFamily: 'Consolas',
                            color: Color(0xFFD7D7D7),
                          ),
                        ),
                      ),
                    ),
                    if (hasResult) ...[
                      const SizedBox(height: 8),
                      Text(
                        resultOk ? '结论：成功' : '结论：失败（详见上方输出）',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: resultOk ? const Color(0xFF1B7F3B) : const Color(0xFFB3261E),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  alive = false;
                  Navigator.of(dialogCtx).pop(initial);
                },
                child: const Text('关闭'),
              ),
            ],
          );
        },
      );
    },
  );
}
