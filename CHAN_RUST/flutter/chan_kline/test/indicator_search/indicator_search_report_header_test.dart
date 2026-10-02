import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/search_verdict_views.dart';
import 'package:chan_kline/widgets/indicator_search_result_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _code = '002003';
const _period = '1m';
const _bars = 289;
const _splitX = 202;

RawScore _score({
  int trades = 0,
  double? winRate,
  double? payoff,
  double? profitFactor,
  double netProfit = 0,
}) => RawScore(
  trades: trades,
  winRate: winRate,
  payoff: payoff,
  profitFactor: profitFactor,
  netProfit: netProfit,
);

/// 过线（胜率 70% / 盈亏比 2.0 / 8 笔）
RawScore get _strong => _score(
  trades: 8,
  winRate: 0.7,
  payoff: 2.0,
  profitFactor: 2.1,
  netProfit: 1200,
);

/// 不过线（胜率 30% / 盈亏比 0.8 / 8 笔）
RawScore get _weak => _score(
  trades: 8,
  winRate: 0.3,
  payoff: 0.8,
  profitFactor: 0.7,
  netProfit: -400,
);

ComboVerdict _verdict(
  String name, {
  required RawScore inSample,
  required RawScore outSample,
  bool passed = false,
  bool outSampleSkipped = false,
  double rank = 1.2,
}) => ComboVerdict(
  name: name,
  buyText: '买：收盘上穿 X',
  sellText: '卖：收盘下穿 X',
  inSample: inSample,
  outSample: outSample,
  inRankScore: rank,
  passed: passed,
  splitX: _splitX,
  outSampleSkipped: outSampleSkipped,
);

void main() {
  group('寻优报告头：内外各独立重跑口径', () {
    test('含「各独立重跑」与「不再全跑再切单」关键口径', () {
      final header = reportHeader(
        code: _code,
        period: _period,
        bars: _bars,
        splitX: _splitX,
        gateTrades: const PassGate().minTrades,
        align: const IndicatorSearchAlignSnapshot(),
      );

      // 口径核心：内外各独立重跑 + 本金重置 + 单仓只做多
      expect(header, contains('样本内、样本外各独立重跑'));
      expect(header, contains('本金重置'));
      expect(header, contains('单仓只做多'));
      // 跨界语义：不再「全跑再切单」
      expect(header, contains('不再「全跑再切单」'));
      expect(header, contains('内外段成交路径互不影响'));
      // 切点 K 根号可追溯
      expect(header, contains('K0#$_splitX'));
      // 门槛与警示
      expect(header, contains('胜率≥60%'));
      expect(header, contains('盈亏比≥1.5'));
      expect(header, contains('净利绝对值勿横向对比强弱'));
    });

    test('P0：显式声明外段 asOf 至末尾且逐根因果（避免被误读成前视）', () {
      final header = reportHeader(
        code: _code,
        period: _period,
        bars: _bars,
        splitX: _splitX,
        gateTrades: const PassGate().minTrades,
        align: const IndicatorSearchAlignSnapshot(),
      );
      // 外段条件可见全区间，但必须是「逐根因果」而非「用了未来信息」。
      expect(header, contains('外段条件求值 asOf 至最后一根'));
      expect(header, contains('逐根因果，无未来函数'));
      expect(header, contains('K0#$_splitX 更保守'));
    });

    test('无快照（旧版）时给出复现参数兜底文案，不空缺', () {
      final header = reportHeader(
        code: _code,
        period: _period,
        bars: _bars,
        splitX: _splitX,
        gateTrades: const PassGate().minTrades,
      );
      expect(header, contains('复现参数：未写入快照（旧版）'));
      expect(header, contains('（快照未记录，默认本周期收盘）'));
      // 口径行不因缺快照而丢失
      expect(header, contains('样本内、样本外各独立重跑'));
    });

    test('切点随区间变化时报告头同步（不留旧切点）', () {
      final a = reportHeader(
        code: _code,
        period: _period,
        bars: _bars,
        splitX: _splitX,
        gateTrades: 5,
      );
      final b = reportHeader(
        code: _code,
        period: _period,
        bars: _bars,
        splitX: 100,
        gateTrades: 5,
      );
      expect(a, contains('K0#$_splitX'));
      expect(a, isNot(contains('K0#100')));
      expect(b, contains('K0#100'));
    });
  });

  group('寻优结果面板：报告头与分桶 Tab（UI 层）', () {
    Future<void> pumpPanel(
      WidgetTester tester,
      List<ComboVerdict> verdicts, {
      bool skipOosEarly = false,
      CandidateBuildSummary? buildSummary,
    }) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IndicatorSearchResultPanel(
              header: reportHeader(
                code: _code,
                period: _period,
                bars: _bars,
                splitX: _splitX,
                gateTrades: const PassGate().minTrades,
                align: const IndicatorSearchAlignSnapshot(),
              ),
              verdicts: verdicts,
              resultsFilePath: 'D:/tmp/indicator_search_results.tsv',
              elapsed: const Duration(minutes: 3, seconds: 5),
              skipOosEarly: skipOosEarly,
              buildSummary: buildSummary,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('面板把「各独立重跑」报告头原文渲染出来', (tester) async {
      await pumpPanel(tester, const []);
      expect(find.textContaining('样本内、样本外各独立重跑'), findsOneWidget);
      expect(find.textContaining('不再「全跑再切单」'), findsOneWidget);
      expect(find.textContaining('K0#$_splitX'), findsOneWidget);
    });

    testWidgets('面板展示耗时 / 跑通 / 双达标摘要行', (tester) async {
      await pumpPanel(tester, [
        _verdict(
          '模板｜双达标甲',
          inSample: _strong,
          outSample: _strong,
          passed: true,
        ),
        _verdict('模板｜仅内乙', inSample: _strong, outSample: _weak),
      ]);
      expect(find.textContaining('耗时 3分5秒'), findsOneWidget);
      expect(find.textContaining('跑通 2 · 双达标 1'), findsOneWidget);
    });

    testWidgets('分桶 Tab 计数正确：双达标/仅内/仅外/外段过线', (tester) async {
      final v = [
        _verdict('模板｜双达标', inSample: _strong, outSample: _strong, passed: true),
        _verdict('模板｜仅内达标', inSample: _strong, outSample: _weak),
        _verdict('模板｜仅外达标', inSample: _weak, outSample: _strong),
        _verdict(
          '模板｜外段未测',
          inSample: _weak,
          outSample: _strong,
          outSampleSkipped: true,
          rank: 0,
        ),
      ];
      await pumpPanel(tester, v);

      expect(find.text('双达标(1)'), findsOneWidget);
      expect(find.text('仅内达标(1)'), findsOneWidget);
      expect(find.text('仅外达标(1)'), findsOneWidget);
      // 外段过线 = 仅外达标 + 双达标
      expect(find.text('外段过线(2)'), findsOneWidget);
      // 早停未测外段不计入「仅外达标」
      expect(
        SearchVerdictBuckets.outSampleOnly(v).map((e) => e.name),
        isNot(contains('模板｜外段未测')),
      );
      expect(find.textContaining('外段未测 1'), findsOneWidget);
    });

    testWidgets('早停开启时给出中文说明卡片与枚举构成行', (tester) async {
      await pumpPanel(
        tester,
        const [],
        skipOosEarly: true,
        buildSummary: const CandidateBuildSummary(
          templates: 12,
          events: 300,
          crosses: 900,
          crossesK1Plus: 120,
          thresholds: 260,
          total: 2000,
        ),
      );
      expect(find.textContaining('内段不过关则外段不参与双达标'), findsOneWidget);
      expect(find.textContaining('枚举构成：模板 12'), findsOneWidget);
    });
  });
}
