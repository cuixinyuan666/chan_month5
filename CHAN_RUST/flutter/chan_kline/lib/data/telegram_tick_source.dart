import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import '../settings/telegram_settings_store.dart';

/// 从 Telegram 按代码拉取分笔 zip（按年/年段），解压到 App 现有分笔缓存目录，
/// 之后走 `tickSource=protocol` 即命中本地缓存，不再逐日联网。
class TelegramTickSource {
  TelegramTickSource({required this.settings, required this.cacheRoot});

  final TelegramSettings settings;

  /// App 数据根（`a_Data`）。
  final Directory cacheRoot;

  static const _apiBase = 'https://api.telegram.org/bot';

  Directory get _indexDir =>
      Directory('${cacheRoot.path}${Platform.pathSeparator}.telegram_cache');

  File get _indexFile =>
      File('${_indexDir.path}${Platform.pathSeparator}ticks_index.json');

  Directory _tickDir(String code) => Directory(
        '${cacheRoot.path}${Platform.pathSeparator}.tdx_protocol_cache${Platform.pathSeparator}$code',
      );

  File _packMarker(String code) => File(
        '${_tickDir(code).path}${Platform.pathSeparator}.telegram_packs.json',
      );

  HttpClient _newClient() {
    final client = HttpClient();
    final proxy = settings.proxy.trim();
    if (proxy.isNotEmpty) {
      client.findProxy = (uri) => 'PROXY $proxy';
    }
    client.connectionTimeout = const Duration(seconds: 30);
    return client;
  }

  Future<Map<String, dynamic>> _apiGet(String method,
      [Map<String, String>? query]) async {
    final token = settings.botToken.trim();
    var url = '$_apiBase$token/$method';
    if (query != null && query.isNotEmpty) {
      url +=
          '?${query.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
    }
    final client = _newClient();
    try {
      final resp = await (await client.getUrl(Uri.parse(url))).close();
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      if (j is! Map || j['ok'] != true) {
        throw TelegramTickException(
          j is Map ? (j['description']?.toString() ?? 'Telegram API 失败') : 'Telegram 应答异常',
        );
      }
      return Map<String, dynamic>.from(j['result'] as Map);
    } finally {
      client.close(force: true);
    }
  }

  Future<File> _download(String fileId, File dest) async {
    final info = await _apiGet('getFile', {'file_id': fileId});
    final path = info['file_path'] as String?;
    if (path == null || path.isEmpty) {
      throw TelegramTickException('getFile 无 file_path');
    }
    final token = settings.botToken.trim();
    if (!dest.parent.existsSync()) dest.parent.createSync(recursive: true);
    final client = _newClient();
    try {
      final resp = await (await client.getUrl(
        Uri.parse('https://api.telegram.org/file/bot$token/$path'),
      ))
          .close();
      if (resp.statusCode != 200) {
        throw TelegramTickException('下载失败 HTTP ${resp.statusCode}');
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

  Future<Map<String, dynamic>> loadIndex({bool forceRefresh = false}) async {
    if (!forceRefresh && _indexFile.existsSync()) {
      try {
        final j = jsonDecode(await _indexFile.readAsString());
        if (j is Map && j['files'] is Map) return Map<String, dynamic>.from(j as Map);
      } catch (_) {}
    }
    final fid = settings.tickIndexFileId.trim();
    if (fid.isEmpty) {
      throw TelegramTickException('未配置分笔索引 file_id（tick_index_file_id）');
    }
    await _download(fid, _indexFile);
    final j = jsonDecode(await _indexFile.readAsString());
    if (j is! Map || j['files'] is! Map) {
      throw TelegramTickException('ticks_index.json 格式错误');
    }
    return Map<String, dynamic>.from(j as Map);
  }

  /// 选出覆盖 [begin,end] 的分笔包（无 from/to 的整股包一律包含）。
  static List<Map<String, dynamic>> selectPacks(
    Map<String, dynamic> codeEntry,
    int begin8,
    int end8,
  ) {
    final out = <Map<String, dynamic>>[];
    final years = codeEntry['years'];
    if (years is Map) {
      for (final v in years.values) {
        if (v is! Map) continue;
        final m = Map<String, dynamic>.from(v);
        final from = int.tryParse('${m['from'] ?? ''}');
        final to = int.tryParse('${m['to'] ?? ''}');
        if (from == null || to == null || (from <= end8 && to >= begin8)) {
          out.add(m);
        }
      }
    } else if (codeEntry['file_id'] != null) {
      out.add(codeEntry);
    }
    return out;
  }

  /// 确保 [code] 在 [begin,end] 的分笔已落本地缓存；返回是否全部就绪。
  Future<bool> ensureTicks({
    required String code,
    required DateTime begin,
    required DateTime end,
  }) async {
    final index = await loadIndex();
    final files = Map<String, dynamic>.from(index['files'] as Map);
    final entry = files[code];
    if (entry is! Map) throw TelegramTickException('分笔索引中无 $code');
    final begin8 = begin.year * 10000 + begin.month * 100 + begin.day;
    final end8 = end.year * 10000 + end.month * 100 + end.day;
    final packs = selectPacks(Map<String, dynamic>.from(entry), begin8, end8);
    if (packs.isEmpty) return false;

    final dir = _tickDir(code);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final markerFile = _packMarker(code);
    Map<String, dynamic> marker = {};
    if (markerFile.existsSync()) {
      try {
        final j = jsonDecode(await markerFile.readAsString());
        if (j is Map) marker = Map<String, dynamic>.from(j);
      } catch (_) {}
    }

    var ok = true;
    for (final p in packs) {
      final fid = p['file_id']?.toString() ?? '';
      if (fid.isEmpty) continue;
      if (marker[fid] == true) continue;
      try {
        final zipPath = File(
          '${_indexDir.path}${Platform.pathSeparator}${code}_pack.zip',
        );
        await _download(fid, zipPath);
        final bytes = await zipPath.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final f in archive) {
          if (!f.isFile) continue;
          final name = f.name.split('/').last;
          if (!name.endsWith('.txt')) continue;
          final out = File('${dir.path}${Platform.pathSeparator}$name');
          await out.writeAsBytes(f.content as List<int>, flush: true);
        }
        zipPath.deleteSync();
        marker[fid] = true;
      } catch (_) {
        ok = false;
      }
    }
    await markerFile.writeAsString(jsonEncode(marker), flush: true);
    return ok;
  }
}

class TelegramTickException implements Exception {
  TelegramTickException(this.message);
  final String message;
  @override
  String toString() => message;
}
