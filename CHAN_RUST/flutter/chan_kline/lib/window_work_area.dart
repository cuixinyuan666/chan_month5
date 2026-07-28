import 'dart:io';

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Work area for [point] (excludes taskbar); falls back to primary.
Future<Rect> workAreaContaining(Offset point) async {
  final displays = await screenRetriever.getAllDisplays();
  for (final d in displays) {
    final vp = d.visiblePosition ?? Offset.zero;
    final vs = d.visibleSize ?? d.size;
    // Hit-test full screen; taskbar side may extend past visible.
    final full = Rect.fromLTWH(vp.dx, vp.dy, d.size.width, d.size.height);
    if (full.inflate(80).contains(point)) {
      return Rect.fromLTWH(vp.dx, vp.dy, vs.width, vs.height);
    }
  }
  final primary = await screenRetriever.getPrimaryDisplay();
  final vp = primary.visiblePosition ?? Offset.zero;
  final vs = primary.visibleSize ?? primary.size;
  return Rect.fromLTWH(vp.dx, vp.dy, vs.width, vs.height);
}

/// Whether window already fills work area (incl. system maximize).
Future<bool> isFillingWorkArea() async {
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
    return false;
  }
  if (await windowManager.isMaximized()) return true;
  final bounds = await windowManager.getBounds();
  final work = await workAreaContaining(bounds.center);
  return (bounds.left - work.left).abs() < 2 &&
      (bounds.top - work.top).abs() < 2 &&
      (bounds.width - work.width).abs() < 4 &&
      (bounds.height - work.height).abs() < 4;
}

/// Fill current monitor work area: fullscreen look, keep taskbar visible.
/// (Native maximize with TitleBarStyle.hidden often covers taskbar.)
Future<void> fillDesktopWorkArea() async {
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
  if (await windowManager.isFullScreen()) {
    await windowManager.setFullScreen(false);
  }
  if (await windowManager.isMaximized()) {
    await windowManager.unmaximize();
  }
  final bounds = await windowManager.getBounds();
  final work = await workAreaContaining(bounds.center);
  await windowManager.setBounds(work);
}