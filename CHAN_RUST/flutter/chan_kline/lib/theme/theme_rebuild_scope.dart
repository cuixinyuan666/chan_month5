import 'package:flutter/widgets.dart';

import 'theme_settings_store.dart';

/// 主题重建范围：主题/暖色/亮度一变，范围内的整棵子树重建一次。
///
/// 为什么需要它：
/// * 主图、设置面板、分笔画板、K线画板同在一张页面树里，颜色都是
///   build/paint 时现读 [AppPalette]，没有缓存 Paint；
/// * 但 `MaterialApp.home` 是同一个 const 实例，MaterialApp 重建时
///   Element 走「widget 相同」快路径，页面不会重建，画布就停在旧配色；
/// * 另外很多绘制直接读静态 AppPalette，并不依赖 `Theme.of`，
///   也收不到 InheritedWidget 的变更通知。
///
/// 所以显式订阅 [AppThemeController]，让整页在换主题时重建：
/// 拖暖色/亮度滑杆时主图与画板同步变色，不用关掉重开。
///
/// 注意：必须传 [builder] 而不是现成的 child——同一个 child 实例
/// 传给 ListenableBuilder 会被 Element 当成「没变」而跳过重建。
class ThemeRebuildScope extends StatelessWidget {
  const ThemeRebuildScope({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppThemeController.instance,
      builder: (context, _) => builder(context),
    );
  }
}
