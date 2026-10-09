import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 分类下只有一项时，点击分类直接勾选，不再展开子列表。
bool pickerHasUniqueChild<T>(List<T> items) => items.length == 1;

/// 主/副图指标选择面板：层级 → 类别 → 指标，默认可展开树。
const pickerDefaultExpandedCategories = <String>{
  '延伸',
  '均线',
  'KnN类BS',
  '背驰',
};

String pickerCategoryKey(int level, String category) => '$level|$category';

bool pickerCategoryDefaultExpanded(String categoryLabel) =>
    pickerDefaultExpandedCategories.contains(categoryLabel);

/// 层级 → 类别 → 指标 三级树形选择面板（主/副图通用）。
class IndicatorPickerOverlay<T> extends StatefulWidget {
  const IndicatorPickerOverlay({
    super.key,
    required this.title,
    required this.catalog,
    required this.selected,
    required this.onToggle,
    required this.labelOf,
    required this.displayLevelOf,
    required this.categoryLabelOf,
    required this.categoryOrderOf,
    required this.onClose,
    this.valueTextOf,
    this.itemOrderOf,
  });

  final String title;
  final List<T> catalog;
  final Set<T> selected;
  final void Function(T item) onToggle;
  final String Function(T) labelOf;
  final int Function(T) displayLevelOf;
  final String Function(T) categoryLabelOf;
  final int Function(T) categoryOrderOf;
  final int Function(T)? itemOrderOf;
  final String? Function(T)? valueTextOf;
  final VoidCallback onClose;

  @override
  State<IndicatorPickerOverlay<T>> createState() =>
      _IndicatorPickerOverlayState<T>();
}

class _IndicatorPickerOverlayState<T> extends State<IndicatorPickerOverlay<T>> {
  static const _activeColor = Color(0xFFFFFFFF);
  static const _inactiveColor = Color(0xFF6B7280);
  static const _valueColor = Color(0xFF38BDF8);
  static const _hintColor = Color(0xFF94A3B8);
  static const _sectionColor = Color(0xFFCBD5E1);

  late Set<int> _expandedLevels;
  late Set<String> _expandedCategories;

  @override
  void initState() {
    super.initState();
    _seedExpanded();
  }

  @override
  void didUpdateWidget(covariant IndicatorPickerOverlay<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.catalog != widget.catalog) {
      // 取消「勾选指标即缩回父目录」：保留用户已展开的层级/类别，
      // 仅同步层级集合（丢弃已消失的层级、其类别键一并清理），不强制重置展开态。
      final newLevels = _levels.toSet();
      _expandedLevels.removeWhere((l) => !newLevels.contains(l));
      _expandedCategories.removeWhere((key) {
        final lv = int.tryParse(key.split('|').first) ?? -1;
        return !newLevels.contains(lv);
      });
      // 新增层级保持折叠（与首次打开一致），不强制展开。
    }
  }

  void _seedExpanded() {
    _expandedLevels = {};
    _expandedCategories = {
      for (final lv in _levels)
        for (final cat in _categoriesAtLevel(lv))
          if (pickerCategoryDefaultExpanded(cat.label))
            pickerCategoryKey(lv, cat.label),
    };
  }

  List<int> get _levels {
    final s = <int>{};
    for (final e in widget.catalog) {
      s.add(widget.displayLevelOf(e));
    }
    final out = s.toList()..sort();
    return out;
  }

  List<T> _itemsAtLevel(int lv) =>
      widget.catalog.where((e) => widget.displayLevelOf(e) == lv).toList();

  List<({String label, int order})> _categoriesAtLevel(int lv) {
    final map = <String, int>{};
    for (final e in _itemsAtLevel(lv)) {
      final label = widget.categoryLabelOf(e);
      final order = widget.categoryOrderOf(e);
      final prev = map[label];
      if (prev == null || order < prev) {
        map[label] = order;
      }
    }
    final out = map.entries
        .map((e) => (label: e.key, order: e.value))
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return out;
  }

  List<T> _itemsInCategory(int lv, String category) {
    final orderOf = widget.itemOrderOf ?? widget.categoryOrderOf;
    return _itemsAtLevel(lv)
        .where((e) => widget.categoryLabelOf(e) == category)
        .toList()
      ..sort((a, b) {
        final c = orderOf(a).compareTo(orderOf(b));
        if (c != 0) return c;
        return widget.labelOf(a).compareTo(widget.labelOf(b));
      });
  }

  int _selectedCount(Iterable<T> items) =>
      items.where(widget.selected.contains).length;

  void _toggleLevel(int lv) {
    setState(() {
      if (_expandedLevels.contains(lv)) {
        _expandedLevels.remove(lv);
      } else {
        _expandedLevels.add(lv);
      }
    });
  }

  void _toggleCategory(int lv, String category) {
    final key = pickerCategoryKey(lv, category);
    setState(() {
      if (_expandedCategories.contains(key)) {
        _expandedCategories.remove(key);
      } else {
        _expandedCategories.add(key);
      }
    });
  }

  void _onCategoryTap(int lv, String category) {
    final items = _itemsInCategory(lv, category);
    if (pickerHasUniqueChild(items)) {
      widget.onToggle(items.first);
      return;
    }
    _toggleCategory(lv, category);
  }

  TextStyle _rowStyle(bool selected) => TextStyle(
        color: selected ? _activeColor : _inactiveColor,
        fontSize: 15,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        height: 1.35,
        decoration: selected ? TextDecoration.none : TextDecoration.lineThrough,
        decorationColor: _inactiveColor,
      );

  Widget _itemRow(T item) {
    final selected = widget.selected.contains(item);
    final value = widget.valueTextOf?.call(item);
    return InkWell(
      onTap: () => widget.onToggle(item),
      child: Padding(
        // 缩进：类别头文字在 48px（22 padding + 22 箭头 + 4 间距），
        // 指标项再缩进 8px 到 56px，形成 层级→类别→指标 一致的三级树缩进。
        padding: const EdgeInsets.fromLTRB(56, 10, 14, 10),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: widget.labelOf(item),
                style: _rowStyle(selected),
              ),
              if (value != null && value.isNotEmpty)
                TextSpan(
                  text: '  $value',
                  style: TextStyle(
                    color: selected ? _valueColor : _inactiveColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader({
    required String title,
    String? subtitle,
    required bool expanded,
    required VoidCallback onTap,
    EdgeInsets padding = const EdgeInsets.fromLTRB(14, 12, 8, 12),
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              size: 22,
              color: _hintColor,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: _sectionColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        subtitle,
                        style: const TextStyle(
                          color: _hintColor,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoryBlock(int lv, ({String label, int order}) cat) {
    final items = _itemsInCategory(lv, cat.label);
    if (items.isEmpty) return const SizedBox.shrink();
    if (pickerHasUniqueChild(items)) {
      return _itemRow(items.first);
    }
    final key = pickerCategoryKey(lv, cat.label);
    final expanded = _expandedCategories.contains(key);
    final cnt = _selectedCount(items);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          title: cat.label,
          subtitle: cnt > 0 ? '已选 $cnt 项' : '${items.length} 项可选',
          expanded: expanded,
          onTap: () => _onCategoryTap(lv, cat.label),
          padding: const EdgeInsets.fromLTRB(22, 8, 8, 8),
        ),
        if (expanded)
          for (final item in items) _itemRow(item),
      ],
    );
  }

  Widget _levelBlock(int lv) {
    final items = _itemsAtLevel(lv);
    if (items.isEmpty) return const SizedBox.shrink();
    if (pickerHasUniqueChild(items)) {
      return _itemRow(items.first);
    }
    final expanded = _expandedLevels.contains(lv);
    final cnt = _selectedCount(items);
    final cats = _categoriesAtLevel(lv);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          title: 'K$lv',
          subtitle: cnt > 0 ? '已选 $cnt 项' : '${cats.length} 个类别',
          expanded: expanded,
          onTap: () => _toggleLevel(lv),
        ),
        if (expanded)
          for (final cat in cats) _categoryBlock(lv, cat),
      ],
    );
  }

  Widget _body() {
    if (widget.catalog.isEmpty) {
      return const Center(
        child: Text(
          '暂无可选指标',
          style: TextStyle(color: _inactiveColor, fontSize: 14),
        ),
      );
    }
    final levels = _levels;
    if (levels.isEmpty) {
      return const Center(
        child: Text(
          '暂无可选指标',
          style: TextStyle(color: _inactiveColor, fontSize: 14),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: levels.length,
      separatorBuilder: (_, __) => const Divider(
        height: 1,
        indent: 14,
        endIndent: 14,
        color: Color(0x22FFFFFF),
      ),
      itemBuilder: (_, i) => _levelBlock(levels[i]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final marginH = math.max(12.0, size.width * 0.04);
    final marginV = math.max(28.0, size.height * 0.05);
    // 宽度随内容（最长指标名）自适应，不再占满整屏；高度封顶后内部滚动。
    // 注意：不能用 IntrinsicWidth 包裹含 ListView 的 Column —— ListView 无固有宽度，
    // Expanded 在固有测量阶段拿到 0 高度，面板会塌陷/不显示（只剩变暗遮罩）。
    // 故改为显式测量内容宽度并给定确定宽高。
    final maxAllowed = size.width - marginH * 2;
    final maxH = size.height - marginV * 2;
    final contentW = _measureContentWidth().clamp(240.0, maxAllowed);
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        child: Container(
          color: const Color(0x99000000),
          alignment: Alignment.center,
          padding: EdgeInsets.fromLTRB(marginH, marginV, marginH, marginV),
          child: GestureDetector(
            onTap: () {},
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: contentW,
                maxWidth: contentW,
                maxHeight: maxH,
              ),
              child: Material(
                  color: const Color(0xF01A1A1A),
                  borderRadius: BorderRadius.circular(10),
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 6, 6, 4),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: '关闭',
                            visualDensity: VisualDensity.compact,
                            onPressed: widget.onClose,
                            icon: const Icon(
                              Icons.close,
                              size: 22,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              widget.title,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFE2E8F0),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Color(0x33FFFFFF)),
                    Expanded(child: _body()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 测量面板所需宽度：取标题、各指标项、各分类头的文字宽度的较大者，
  /// 加上对应左右内边距。用于让面板宽度随最长指标名自适应（而非占满整屏）。
  double _measureContentWidth() {
    final tp = TextPainter(textDirection: TextDirection.ltr);
    double maxW = 0.0;
    const rowStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      height: 1.35,
    );
    const valueStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
    const headerStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);
    // 标题：关闭图标(~48) + 标题文字 + 间距
    tp.text = TextSpan(
      text: widget.title,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    );
    tp.layout();
    maxW = 56.0 + tp.width;
    for (final e in widget.catalog) {
      double w = 56.0 + 14.0; // 指标项左右 padding
      tp.text = TextSpan(text: widget.labelOf(e), style: rowStyle);
      tp.layout();
      w += tp.width;
      final v = widget.valueTextOf?.call(e);
      if (v != null && v.isNotEmpty) {
        tp.text = TextSpan(text: '  $v', style: valueStyle);
        tp.layout();
        w += tp.width;
      }
      // 分类/层级头（左 padding 22 + 箭头 22 + 间距 4 + 右 padding 14）也计入
      final cat = widget.categoryLabelOf(e);
      tp.text = TextSpan(text: cat, style: headerStyle);
      tp.layout();
      final headerW = 22.0 + 4.0 + 14.0 + tp.width;
      if (headerW > w) w = headerW;
      if (w > maxW) maxW = w;
    }
    tp.dispose();
    return maxW;
  }
}
