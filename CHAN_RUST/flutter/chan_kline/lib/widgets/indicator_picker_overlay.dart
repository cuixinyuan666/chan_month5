import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 单个指标条目（兼容旧引用；新面板走 [IndicatorPickerOverlay] 泛型）。
class IndicatorChipEntry {
  const IndicatorChipEntry({
    required this.label,
    required this.onTapToggle,
    required this.displayLevel,
    this.selected = true,
    this.valueText,
  });

  final String label;
  final VoidCallback onTapToggle;
  final int displayLevel;
  final bool selected;
  final String? valueText;
}

enum _PickerNav { levels, categories, items }

/// 层级 → 类别 → 指标 三级导航选择面板（主/副图通用）。
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
  });

  final String title;
  final List<T> catalog;
  final Set<T> selected;
  final void Function(T item) onToggle;
  final String Function(T) labelOf;
  final int Function(T) displayLevelOf;
  final String Function(T) categoryLabelOf;
  final int Function(T) categoryOrderOf;
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

  _PickerNav _nav = _PickerNav.levels;
  int? _level;
  String? _category;

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
    return _itemsAtLevel(lv)
        .where((e) => widget.categoryLabelOf(e) == category)
        .toList()
      ..sort((a, b) {
        final c = widget.categoryOrderOf(a).compareTo(widget.categoryOrderOf(b));
        if (c != 0) return c;
        return widget.labelOf(a).compareTo(widget.labelOf(b));
      });
  }

  int _selectedCount(Iterable<T> items) =>
      items.where(widget.selected.contains).length;

  void _goLevels() {
    setState(() {
      _nav = _PickerNav.levels;
      _level = null;
      _category = null;
    });
  }

  void _goCategories(int lv) {
    setState(() {
      _nav = _PickerNav.categories;
      _level = lv;
      _category = null;
    });
  }

  void _goItems(int lv, String category) {
    setState(() {
      _nav = _PickerNav.items;
      _level = lv;
      _category = category;
    });
  }

  void _onBack() {
    switch (_nav) {
      case _PickerNav.levels:
        widget.onClose();
      case _PickerNav.categories:
        _goLevels();
      case _PickerNav.items:
        if (_level != null) _goCategories(_level!);
    }
  }

  String get _headerTitle {
    switch (_nav) {
      case _PickerNav.levels:
        return widget.title;
      case _PickerNav.categories:
        return 'K$_level';
      case _PickerNav.items:
        return 'K$_level · $_category';
    }
  }

  TextStyle _rowStyle(bool selected) => TextStyle(
        color: selected ? _activeColor : _inactiveColor,
        fontSize: 15,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        height: 1.35,
        decoration: selected ? TextDecoration.none : TextDecoration.lineThrough,
        decorationColor: _inactiveColor,
      );

  Widget _navRow({
    required String title,
    String? subtitle,
    required VoidCallback onTap,
    bool showChevron = true,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: _activeColor,
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
            if (showChevron)
              const Icon(
                Icons.chevron_right,
                size: 22,
                color: _hintColor,
              ),
          ],
        ),
      ),
    );
  }

  Widget _itemRow(T item) {
    final selected = widget.selected.contains(item);
    final value = widget.valueTextOf?.call(item);
    return InkWell(
      onTap: () => widget.onToggle(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
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

  Widget _body() {
    if (widget.catalog.isEmpty) {
      return const Center(
        child: Text(
          '暂无可选指标',
          style: TextStyle(color: _inactiveColor, fontSize: 14),
        ),
      );
    }

    switch (_nav) {
      case _PickerNav.levels:
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
          itemBuilder: (_, i) {
            final lv = levels[i];
            final items = _itemsAtLevel(lv);
            final cnt = _selectedCount(items);
            return _navRow(
              title: 'K$lv',
              subtitle: cnt > 0 ? '已选 $cnt 项' : '点击进入类别',
              onTap: () => _goCategories(lv),
            );
          },
        );

      case _PickerNav.categories:
        final lv = _level;
        if (lv == null) return const SizedBox.shrink();
        final cats = _categoriesAtLevel(lv);
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: cats.length,
          separatorBuilder: (_, __) => const Divider(
            height: 1,
            indent: 14,
            endIndent: 14,
            color: Color(0x22FFFFFF),
          ),
          itemBuilder: (_, i) {
            final cat = cats[i];
            final items = _itemsInCategory(lv, cat.label);
            final cnt = _selectedCount(items);
            return _navRow(
              title: cat.label,
              subtitle: cnt > 0 ? '已选 $cnt 项' : '${items.length} 项可选',
              onTap: () => _goItems(lv, cat.label),
            );
          },
        );

      case _PickerNav.items:
        final lv = _level;
        final cat = _category;
        if (lv == null || cat == null) return const SizedBox.shrink();
        final items = _itemsInCategory(lv, cat);
        if (items.isEmpty) {
          return const Center(
            child: Text(
              '该类别暂无指标',
              style: TextStyle(color: _inactiveColor, fontSize: 14),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(
            height: 1,
            indent: 14,
            endIndent: 14,
            color: Color(0x22FFFFFF),
          ),
          itemBuilder: (_, i) => _itemRow(items[i]),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final marginH = math.max(12.0, size.width * 0.04);
    final marginV = math.max(28.0, size.height * 0.05);
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
            child: Material(
              color: const Color(0xF01A1A1A),
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: size.width - marginH * 2,
                height: size.height - marginV * 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 6, 6, 4),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: _nav == _PickerNav.levels ? '关闭' : '返回',
                            visualDensity: VisualDensity.compact,
                            onPressed: _onBack,
                            icon: Icon(
                              _nav == _PickerNav.levels
                                  ? Icons.close
                                  : Icons.arrow_back,
                              size: 22,
                              color: const Color(0xFF94A3B8),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              _headerTitle,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFE2E8F0),
                              ),
                            ),
                          ),
                          if (_nav != _PickerNav.levels)
                            TextButton(
                              onPressed: _goLevels,
                              child: const Text(
                                '全部层级',
                                style: TextStyle(
                                  color: Color(0xFF38BDF8),
                                  fontSize: 13,
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
}
