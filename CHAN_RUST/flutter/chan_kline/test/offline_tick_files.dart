import 'package:chan_kline/robot_verify/robot_verify_data.dart';

/// 仓库不再带股票导出 txt 时，依赖本地 002003 分笔的测试应 skip。
const kNoOffline002003Skip =
    '无本地 002003 分笔备份（可设 CHAN_DATA_ROOT 或协议拉取；机器人验证会自动探测）';

bool hasOffline002003TickFiles() => hasLocal002003TickBackup();
