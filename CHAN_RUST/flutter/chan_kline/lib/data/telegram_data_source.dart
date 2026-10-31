import 'dart:convert';
import 'dart:io';

import '../models/kline_bar.dart';
import '../settings/telegram_settings_store.dart';

/// 从 Telegram Bot 按股票代码精准拉取日线 CSV（与导出器格式一致）。
class TelegramDataSource {
  TelegramDataSource({
    required this.settings,
    required this.cacheRoot,
  });

  final TelegramSettings settings;
  final Directory cacheRoot;

  static const _apiBase = 'https://api.telegram.org/bot';

  Directory get _indexDir => Directory(
    '${cacheRoot.path}${Platform.pathSeparator}.telegram_cache',
  );

  File get _indexFile => File(
    '${_indexDir.path}${Platform.pathSeparator}index.json',
  );

  Future<Map<String, dynamic>> _apiGet(String method,
      [Map<String, String>? query]) async {
    final token = settings.botToken.trim();
    var url = '$_apiBase$token/$method';
    if (query != null && query.isNotEmpty) {
      url +=
          '?${query.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
    }
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      if (j is! Map) throw TelegramDataException('Telegram 应答不是 JSON');
      if (j['ok'] != true) {
        throw TelegramDataException(
          j['description']?.toString() ?? 'Telegram API 失败',
        );
      }
      return Map<String, dynamic>.from(j['result'] as Map);
    } finally {
      client.close(force: true);
    }
  }

  Future<File> _downloadFile(String fileId, File dest) async {
    final info = await _apiGet('getFile', {'file_id': fileId});
    final path = info['file_path'] as String?;
    if (path == null || path.isEmpty) {
      throw TelegramDataException('getFile 无 file_path');
    }
    final token = settings.botToken.trim();
    final url =
        'https://api.telegram.org/file/bot$token/$path';
    if (!dest.parent.existsSync()) {
      dest.parent.createSync(recursive: true);
    }
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw TelegramDataException('下载失败 HTTP ${resp.statusCode}');
      }
      final sink = dest.openWrite(mode: FileMode.writeOnly);
      await resp.pipe(sink);
      await sink.flush();
      await sink.close();
      return dest;
    } finally {
      client.close(force: true);
    }
  }

  /// 拉取或读缓存 index.json（code -> file_id 等）。
  Future<Map<String, dynamic>> loadIndex({bool forceRefresh = false}) async {
    if (!forceRefresh && _indexFile.existsSync()) {
      try {
        final j = jsonDecode(await _indexFile.readAsString());
        if (j is Map && j['files'] is Map) {
          return Map<String, dynamic>.from(j as Map);
        }
      } catch (_) {}
    }
    final fid = settings.indexFileId.trim();
    if (fid.isEmpty) {
      throw TelegramDataException(
        '尚未配置 index_file_id：请先上传 index.json 并在设置里填入，或在本机执行一次上传脚本写入 upload_state',
      );
    }
    await _downloadFile(fid, _indexFile);
    final j = jsonDecode(await _indexFile.readAsString());
    if (j is! Map || j['files'] is! Map) {
      throw TelegramDataException('index.json 格式错误');
    }
    return Map<String, dynamic>.from(j as Map);
  }

  static String _exchangePrefix(int market) {
    switch (market) {
      case 1:
        return 'sh';
      case 2:
        return 'bj';
      default:
        return 'sz';
    }
  }

  Future<File> _stockCsvFile(String code, Map<String, dynamic> index) async {
    final files = Map<String, dynamic>.from(index['files'] as Map);
    final meta = files[code];
    if (meta is! Map) {
      throw TelegramDataException('索引中无股票 $code');
    }
    final fileId = meta['file_id']?.toString() ?? '';
    if (fileId.isEmpty) {
      throw TelegramDataException('股票 $code 无 file_id');
    }
    final market = (meta['market'] as num?)?.toInt() ?? 0;
    final name =
        '${_exchangePrefix(market)}$code.csv';
    final dest = File(
      '${_indexDir.path}${Platform.pathSeparator}daily${Platform.pathSeparator}$name',
    );
    if (dest.existsSync() && dest.lengthSync() > 40) {
      return dest;
    }
    return _downloadFile(fileId, dest);
  }

  /// 加载单只股票日线，并按起止时间过滤。
  Future<List<KlineBar>> loadDailyBars({
    required String code,
    required DateTime begin,
    required DateTime end,
  }) async {
    final index = await loadIndex();
    final csvFile = await _stockCsvFile(code, index);
    final text = await csvFile.readAsString();
    return parseDailyCsvText(text, begin: begin, end: end);
  }

  KlineBar? _parseDailyRow(List<String> parts) => _parseDailyRowStatic(parts);

  /// 解析导出器日线 CSV 全文（供单测与本地文件）。
  static List<KlineBar> parseDailyCsvText(
    String text, {
    required DateTime begin,
    required DateTime end,
  }) {
    final beginMs = begin.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    final out = <KlineBar>[];
    for (var i = 1; i < text.split('\n').length; i++) {
      final line = text.split('\n')[i].trim();
      if (line.isEmpty) continue;
      final parts = line.split(',');
      if (parts.length < 7) continue;
      final bar = _parseDailyRowStatic(parts);
      if (bar == null) continue;
      if (bar.timeMs < beginMs || bar.timeMs > endMs) continue;
      out.add(bar);
    }
    out.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    for (var i = 0; i < out.length; i++) {
      final b = out[i];
      out[i] = KlineBar(
        idx: i,
        timeMs: b.timeMs,
        timeText: b.timeText,
        open: b.open,
        high: b.high,
        low: b.low,
        close: b.close,
        volume: b.volume,
        amount: b.amount,
      );
    }
    return out;
  }

  static KlineBar? _parseDailyRowStatic(List<String> parts) {
    final dateRaw = parts[0].trim();
    final digits = dateRaw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length != 8) return null;
    final y = int.parse(digits.substring(0, 4));
    final m = int.parse(digits.substring(4, 6));
    final d = int.parse(digits.substring(6, 8));
    final dt = DateTime.utc(y, m, d, 15, 0);
    double p(String s) => double.tryParse(s.trim()) ?? 0;
    return KlineBar(
      timeMs: dt.millisecondsSinceEpoch,
      timeText:
          '${y.toString().padLeft(4, '0')}/${m.toString().padLeft(2, '0')}/${d.toString().padLeft(2, '0')} 15:00',
      open: p(parts[1]),
      high: p(parts[2]),
      low: p(parts[3]),
      close: p(parts[4]),
      volume: p(parts[5]),
      amount: p(parts[6]),
    );
  }
}

class TelegramDataException implements Exception {
  TelegramDataException(this.message);
  final String message;
  @override
  String toString() => message;
}
