import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'robot_verify_model.dart';
import 'robot_verify_paths.dart';
import 'robot_verify_runner.dart';

/// 机器人验证 UI：全程可见进度；结束后仅简短提示，详情进剪贴板（见 agent.md）。
class RobotVerifyApp extends StatefulWidget {
  const RobotVerifyApp({
    super.key,
    required this.suiteId,
    required this.klineRoot,
  });

  final String suiteId;
  final String klineRoot;

  @override
  State<RobotVerifyApp> createState() => _RobotVerifyAppState();
}

class _RobotVerifyAppState extends State<RobotVerifyApp> {
  static const _steps = [
    '机器人验证模式已开启',
    'flutter test（JSON）',
    '进程内自检',
    '连续单步冻结对拍',
    '写入 JSON 报告并复制剪贴板',
  ];

  int _activeStep = 0;
  String _detail = '正在初始化…';
  double? _fraction;
  bool _done = false;
  bool? _passed;
  bool _clipboardOk = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _progress(String detail, {int? step, double? fraction}) {
    if (!mounted) return;
    setState(() {
      if (step != null) _activeStep = step;
      _detail = detail;
      _fraction = fraction;
    });
  }

  Future<void> _run() async {
    _progress('会话已加载，套件 ${widget.suiteId}', step: 0, fraction: 0.02);
    await RobotVerifyPaths.writeStatus(
      phase: 'running',
      ok: null,
      message: 'started',
      klineRoot: widget.klineRoot,
    );
    try {
      _progress('套件阶段即将开始…', step: 1, fraction: 0.08);
      final report = await runFullRobotVerify(
        suiteId: widget.suiteId,
        klineRoot: widget.klineRoot,
        onProgress: (label, frac) {
          final step = _stepIndexForPhase(label);
          _progress(label, step: step, fraction: frac);
        },
      );
      final payload = report.toClipboardPayload();
      final allPass = report.ok;
      _progress('正在复制 JSON 报告到剪贴板…', step: 4, fraction: 0.98);
      await Clipboard.setData(ClipboardData(text: payload));
      _clipboardOk = true;
      await RobotVerifyPaths.writeStatus(
        phase: 'done',
        ok: allPass,
        message: allPass ? 'ALL PASS' : 'FAILED',
        klineRoot: widget.klineRoot,
      );
      if (!mounted) return;
      setState(() {
        _done = true;
        _passed = allPass;
        _activeStep = _steps.length;
        _fraction = 1.0;
        _detail = allPass ? '全部检查通过' : '存在未通过项（详见剪贴板全文）';
      });
    } catch (e, st) {
      final fail = jsonEncode({
        'v': RobotVerifyReport.currentSchema,
        'ok': false,
        'error': 'exception',
        'message': '$e',
        'stack': '$st',
      });
      final reportFile = RobotVerifyPaths.lastReportFile(klineRoot: widget.klineRoot);
      if (reportFile != null) {
        await reportFile.writeAsString(fail);
      }
      final jsonFile = RobotVerifyPaths.lastReportJsonFile(klineRoot: widget.klineRoot);
      if (jsonFile != null) {
        await jsonFile.writeAsString(fail);
      }
      try {
        await Clipboard.setData(ClipboardData(text: fail));
        _clipboardOk = true;
      } catch (_) {}
      await RobotVerifyPaths.writeStatus(
        phase: 'done',
        ok: false,
        message: 'exception',
        klineRoot: widget.klineRoot,
      );
      if (!mounted) return;
      setState(() {
        _done = true;
        _passed = false;
        _activeStep = _steps.length;
        _detail = '运行异常（错误摘要已尝试写入剪贴板）';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '机器人验证',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  '套件：${widget.suiteId}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (!_done) ...[
                  LinearProgressIndicator(
                    value: _fraction,
                    minHeight: 6,
                    backgroundColor: Colors.white12,
                    color: Colors.tealAccent,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _detail,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 20),
                  ...List.generate(_steps.length, (i) {
                    final done = i < _activeStep;
                    final active = i == _activeStep && !_done;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Icon(
                            done
                                ? Icons.check_circle
                                : active
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                            color: done
                                ? Colors.greenAccent
                                : active
                                    ? Colors.tealAccent
                                    : Colors.white24,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _steps[i],
                              style: TextStyle(
                                color: done || active
                                    ? Colors.white
                                    : Colors.white38,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ] else ...[
                  Icon(
                    _passed == true ? Icons.verified : Icons.warning_amber,
                    color: _passed == true
                        ? Colors.greenAccent
                        : Colors.orangeAccent,
                    size: 56,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '验证已完成',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _detail,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _clipboardOk
                        ? 'JSON 验证报告已复制到剪贴板（单行 UTF-8）。\n请粘贴给智能体解析；亦见 last_report.json。\n\n请手动关闭本窗口。'
                        : '报告已写入 a_Data/robot_verify/last_report.json；\n剪贴板失败时请手动打开该文件。\n\n请手动关闭本窗口。',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

int _stepIndexForPhase(String label) {
  if (label.contains('continuous_step')) return 3;
  if (label.contains('inprocess')) return 2;
  if (label.contains('flutter_test') || label.contains('suite')) return 1;
  if (label.contains('report')) return 4;
  return 1;
}

String? readSuiteIdFromSession({String? klineRoot}) {
  final dir = RobotVerifyPaths.verifyDir(klineRoot: klineRoot);
  if (dir == null) return null;
  final f = File('${dir.path}/session.json');
  if (!f.existsSync()) return null;
  try {
    final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    return m['suiteId'] as String?;
  } catch (_) {
    return null;
  }
}
