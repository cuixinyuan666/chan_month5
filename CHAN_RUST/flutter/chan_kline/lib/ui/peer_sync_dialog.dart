import 'package:flutter/material.dart';

import '../settings/peer_sync_settings_store.dart';
import '../sync/peer_sync_service.dart';

/// 把对端代理返回的 data 压成一行，给日志用（别把整段 JSON 塞进 200 高的小框）。
String _briefPeer(Object? data) {
  if (data == null) return '';
  if (data is! Map) return data.toString();
  final parts = <String>[];
  for (final k in ['machine', 'pid', 'name', 'op', 'state', 'exitCode', 'output']) {
    if (!data.containsKey(k)) continue;
    var v = data[k].toString().trim();
    if (v.length > 70) v = '${v.substring(0, 70)}…';
    if (v.isEmpty) continue;
    parts.add('$k=$v');
  }
  return parts.join('，');
}

/// 双机同步弹窗：测试连接 → 判哪台最新 → 按最新方同步 → 结论 / 按快照回退。
///
/// 口径全在 `CHAN_RUST/scripts/sync_latest.ps1`：先比两侧清单判「哪台更新」，
/// 再把旧的一侧对齐到新的一侧；旧侧独有文件移进备份目录，不直接删。
/// 旧脚本 `sync_to_remote.ps1`（固定 本机→对端）保留，供命令行单独用。
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
              status = '检测哪台更新……';
              log.clear();
              hasResult = false;
              addLog('>> 检测两侧文件（不动任何文件）');
            });
            final plan = await PeerSyncService.latestPlan(peer: target);
            if (!alive) return;
            if (plan.json == null || !plan.ok) {
              setDlg(() {
                busy = false;
                status = '检测失败，已中止（没有写任何文件）';
                hasResult = true;
                resultOk = false;
                addLog('!! ${plan.error}');
              });
              return;
            }
            final j = plan.json!;
            final dir = (j['direction'] as String?) ?? '';
            final newer = (j['newerSide'] as String?) ?? '';
            final onlyLocal = (j['onlyLocal'] as num?)?.toInt() ?? 0;
            final onlyPeer = (j['onlyPeer'] as num?)?.toInt() ?? 0;
            final bothDiff = (j['bothDiff'] as num?)?.toInt() ?? 0;

            if (dir == 'same') {
              setDlg(() {
                busy = false;
                status = '两台文件已经一致，不需要同步';
                hasResult = true;
                resultOk = true;
                addLog('>> 逐文件比对：0 处差异');
              });
              return;
            }
            if (dir.isEmpty) {
              setDlg(() {
                busy = false;
                status = '判不出哪台更新，已中止';
                hasResult = true;
                resultOk = false;
                addLog('!! 两侧票数与时间都打平：请先做一处改动，或让一侧的修改时间更清楚');
              });
              return;
            }

            final isToPeer = dir == 'local-to-peer';
            final copyN = isToPeer ? onlyLocal + bothDiff : onlyPeer + bothDiff;
            final moveN = isToPeer ? onlyPeer : onlyLocal;

            if (!alive || !ctx.mounted) return;
            final confirmed = await showDialog<bool>(
              context: ctx,
              builder: (c2) => AlertDialog(
                title: Text('以「$newer」为准同步'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('对端：$target', style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 8),
                    Text(
                      '最新的一方：$newer　（${PeerSyncService.directionText(newer)}）',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text('另一台将被对齐：复制 / 覆盖 $copyN 个文件',
                        style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 4),
                    Text('旧侧独有的 $moveN 个文件 → 移进那台的备份目录（不直接删）',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                    const SizedBox(height: 4),
                    Text('同步完成后自动重编那台的 DLL 与 App（cargo + flutter），并重启它的界面',
                        style: TextStyle(fontSize: 12, color: Colors.blue.shade700)),
                    const SizedBox(height: 6),
                    const Text('不含：.git 历史、对端验证现场、各家的工具缓存目录。',
                        style: TextStyle(fontSize: 12)),
                  ],
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

            setDlg(() {
              status = '同步中（以$newer为准）……';
              addLog('>> 开始同步：以 $newer 为准（$dir）');
            });

            final out = await PeerSyncService.latestSync(
              peer: target,
              direction: dir,
              onLine: (l) {
                if (!alive) return;
                final isBuild = l.contains('开始编译') || l.contains('编译中') || l.contains('编译已启动');
                setDlg(() {
                  addLog(l);
                  if (isBuild) status = '正在重编并重启 App……';
                });
              },
            );

            if (!alive) return;
            final now = DateTime.now();
            final stamp = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
                '${now.day.toString().padLeft(2, '0')} '
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
            final summary = PeerSyncService.latestSummaryLine(out);
            final buildFailed = out.json?['buildOk'] == false;
            setDlg(() {
              busy = false;
              hasResult = true;
              resultOk = out.ok;
              status = buildFailed
                  ? '同步完成，但重编没成功（看下面日志）'
                  : (out.ok ? '同步完成' : '同步失败');
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

          /// 走对端常驻代理由本机发一条动作：拉起对端 App / 拉起对端上传 / 停对端上传。
          Future<void> doPeerCtl(
            String label,
            Future<PeerSyncOutcome> Function(String target) run,
          ) async {
            final target = peerCtrl.text.trim();
            if (target.isEmpty) {
              setDlg(() {
                status = '先填对端路径';
                hasResult = true;
                resultOk = false;
                addLog('!! 对端路径为空：先点「默认」或手填对端共享路径');
              });
              return;
            }
            setDlg(() {
              busy = true;
              status = '$label……';
              hasResult = false;
              log.clear();
              addLog('>> $label（对端：$target）');
            });
            PeerSyncOutcome out;
            try {
              out = await run(target);
            } catch (e) {
              if (!alive) return;
              setDlg(() {
                busy = false;
                hasResult = true;
                resultOk = false;
                status = '$label异常';
                addLog('!! 发起请求时异常：$e');
              });
              return;
            }
            if (!alive) return;
            final brief = _briefPeer(out.json?['data']);
            final msg = out.ok
                ? (brief.isEmpty ? '对端已执行' : brief)
                : (out.error.isEmpty ? '对端返回失败（退出码 ${out.exitCode}）' : out.error);
            setDlg(() {
              busy = false;
              hasResult = true;
              resultOk = out.ok;
              status = out.ok ? '$label完成' : '$label失败';
              addLog('>> 脚本退出码 ${out.exitCode}');
              addLog(out.ok ? '>> 结论：$msg' : '!! 结论：$msg');
            });
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
                          '它做什么：比对两台的项目文件，判断哪一台更新，然后把旧的那一台整体对齐到新的那一台。'
                          '方向是自动判的，不用你选「推」还是「拉」。\n\n'
                          '操作步骤：\n'
                          '1. 确认对端路径（默认按主机名自动填：PCA↔PCB）。\n'
                          '2. 点「测试连接」：只读探测共享是否可达、对端代理在不在、对端 App 是否占着产物。\n'
                          '3. 点「按最新方同步」：先逐文件比对出「哪台最新、要改哪些文件」，确认后才真写。\n'
                          '4. 进度逐行显示：列两侧清单 → 判方向 → 复制 → 旧侧独有文件移进备份 → 复核两边是否一致。\n\n'
                          '判「最新」的口径：逐文件比修改时间与内容；差异项最后改动晚的那一台为准'
                          '（时间打平才退到计数、再退到 git 最近提交）。\n'
                          '会改什么：新的一侧有的文件（含新增与内容不同）复制到旧的一侧；'
                          '旧的一侧独有的文件不直接删，移进那台的 a_Data\\remote_ctl\\sync_backup\\latest_<时间戳>\\，可回退。\n'
                          '不同步什么：.git 历史、对端验证现场（a_Data\\robot_verify）、各家的工具缓存目录（__pycache__、.remember 等）。',
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
                          label: const Text('按最新方同步'),
                        ),
                        OutlinedButton.icon(
                          onPressed: canAct ? doRestore : null,
                          icon: const Icon(Icons.undo, size: 18),
                          label: const Text('按快照回退'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 对端那台的「拉起 App / 拉起上传」也在这里一键做（互为对端，两台都有这三颗）
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: canAct
                              ? () => doPeerCtl(
                                    '拉起对端 App',
                                    (t) => PeerSyncService.peerApp(peer: t),
                                  )
                              : null,
                          icon: const Icon(Icons.play_circle_outline, size: 18),
                          label: const Text('拉起对端 App'),
                        ),
                        OutlinedButton.icon(
                          onPressed: canAct
                              ? () => doPeerCtl(
                                    '拉起对端上传',
                                    (t) => PeerSyncService.peerUpload(peer: t, op: 'run'),
                                  )
                              : null,
                          icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                          label: const Text('拉起对端上传'),
                        ),
                        OutlinedButton.icon(
                          onPressed: canAct
                              ? () => doPeerCtl(
                                    '停对端上传',
                                    (t) => PeerSyncService.peerUpload(peer: t, op: 'end'),
                                  )
                              : null,
                          icon: const Icon(Icons.stop_circle_outlined, size: 18),
                          label: const Text('停对端上传'),
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
