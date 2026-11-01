import 'dart:convert';
import 'dart:io';

/// K 线数据源与 Telegram Bot 凭据（落盘 `.chan_telegram_settings.json`）。
enum KlineDataSourceKind {
  protocol,
  telegram,
}

class TelegramSettings {
  const TelegramSettings({
    this.source = KlineDataSourceKind.protocol,
    this.botToken = '',
    this.chatId = '',
    this.indexFileId = '',
    this.tickIndexFileId = '',
    this.proxy = '',
    this.autoTicksDaily = false,
  });

  final KlineDataSourceKind source;
  final String botToken;
  final String chatId;

  /// 索引文件在 Telegram 上的 file_id（首次同步后可缓存，加速拉 index.json）。
  final String indexFileId;

  /// 分笔索引 ticks_index.json 的 file_id。
  final String tickIndexFileId;

  /// HTTP 代理（如 `127.0.0.1:19828`）；留空 = 直连。
  final String proxy;

  /// 每个交易日 15:35 自动把当天分笔增量上传 Telegram。
  final bool autoTicksDaily;

  bool get telegramEnabled =>
      source == KlineDataSourceKind.telegram &&
      botToken.trim().isNotEmpty && chatId.trim().isNotEmpty;

  TelegramSettings copyWith({
    KlineDataSourceKind? source,
    String? botToken,
    String? chatId,
    String? indexFileId,
    String? tickIndexFileId,
    String? proxy,
    bool? autoTicksDaily,
  }) {
    return TelegramSettings(
      source: source ?? this.source,
      botToken: botToken ?? this.botToken,
      chatId: chatId ?? this.chatId,
      indexFileId: indexFileId ?? this.indexFileId,
      tickIndexFileId: tickIndexFileId ?? this.tickIndexFileId,
      proxy: proxy ?? this.proxy,
      autoTicksDaily: autoTicksDaily ?? this.autoTicksDaily,
    );
  }

  factory TelegramSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TelegramSettings();
    final src = (json['source'] as String?)?.trim();
    return TelegramSettings(
      source: src == 'telegram'
          ? KlineDataSourceKind.telegram
          : KlineDataSourceKind.protocol,
      botToken: (json['bot_token'] as String?)?.trim() ?? '',
      chatId: (json['chat_id'] as String?)?.trim() ?? '',
      indexFileId: (json['index_file_id'] as String?)?.trim() ?? '',
      tickIndexFileId: (json['tick_index_file_id'] as String?)?.trim() ?? '',
      proxy: (json['proxy'] as String?)?.trim() ?? '',
      autoTicksDaily: json['auto_ticks_daily'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'source': source == KlineDataSourceKind.telegram ? 'telegram' : 'protocol',
        'bot_token': botToken,
        'chat_id': chatId,
        if (indexFileId.isNotEmpty) 'index_file_id': indexFileId,
        if (tickIndexFileId.isNotEmpty) 'tick_index_file_id': tickIndexFileId,
        if (proxy.isNotEmpty) 'proxy': proxy,
        'auto_ticks_daily': autoTicksDaily,
      };
}

abstract final class TelegramSettingsStore {
  static String get _path {
    final base = Directory.current.path;
    return '$base${Platform.pathSeparator}.chan_telegram_settings.json';
  }

  static Future<TelegramSettings> load() async {
    try {
      final f = File(_path);
      if (!await f.exists()) return const TelegramSettings();
      final obj = jsonDecode(await f.readAsString());
      if (obj is Map) {
        return TelegramSettings.fromJson(Map<String, dynamic>.from(obj));
      }
    } catch (_) {}
    return const TelegramSettings();
  }

  static Future<void> save(TelegramSettings cfg) async {
    try {
      await File(_path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(cfg.toJson()),
      );
    } catch (_) {}
  }
}
