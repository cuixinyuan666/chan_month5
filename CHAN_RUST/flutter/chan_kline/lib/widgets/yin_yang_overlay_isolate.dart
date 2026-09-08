import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// 独立 isolate 入口：自己的定时器画分层窗口，不跟 Flutter UI isolate 抢时间片。
void yinYangOverlayIsolateMain(SendPort ready) {
  final cmd = ReceivePort();
  ready.send(cmd.sendPort);

  var running = true;
  var hwnd = 0;
  var hdcMem = 0;
  var hbmp = 0;
  var hdcScreen = 0;
  Pointer<Uint32>? bits;
  var diameter = 0;
  var left = 0;
  var top = 0;
  var opacity = 0.5;
  var turns = 0.0;
  var lastPaintMs = DateTime.now().millisecondsSinceEpoch;
  Timer? ticker;
  final className = TEXT('ChanYinYangOverlay');

  void destroy() {
    ticker?.cancel();
    ticker = null;
    if (hwnd != 0) {
      DestroyWindow(hwnd);
      hwnd = 0;
    }
    if (hbmp != 0) {
      DeleteObject(hbmp);
      hbmp = 0;
    }
    if (hdcMem != 0) {
      DeleteDC(hdcMem);
      hdcMem = 0;
    }
    if (hdcScreen != 0) {
      ReleaseDC(NULL, hdcScreen);
      hdcScreen = 0;
    }
    bits = null;
  }

  void paintFrame() {
    if (hwnd == 0 || bits == null || diameter <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final dt = now - lastPaintMs;
    lastPaintMs = now;
    _fillYinYangBgra(bits!, diameter, turns, opacity);
    final hdcWin = GetDC(hwnd);
    if (hdcWin == 0) return;
    final size = calloc<SIZE>();
    final ptSrc = calloc<POINT>();
    final ptDst = calloc<POINT>();
    final blend = calloc<BLENDFUNCTION>();
    final info = calloc<UPDATELAYEREDWINDOWINFO>();
    try {
      size.ref.cx = diameter;
      size.ref.cy = diameter;
      ptDst.ref.x = left;
      ptDst.ref.y = top;
      blend.ref.BlendOp = 0; // AC_SRC_OVER
      blend.ref.SourceConstantAlpha = 255;
      blend.ref.AlphaFormat = 1; // AC_SRC_ALPHA
      info.ref.cbSize = sizeOf<UPDATELAYEREDWINDOWINFO>();
      info.ref.hdcDst = hdcWin;
      info.ref.pptDst = ptDst;
      info.ref.psize = size;
      info.ref.hdcSrc = hdcMem;
      info.ref.pptSrc = ptSrc;
      info.ref.pblend = blend;
      info.ref.dwFlags = ULW_ALPHA;
      UpdateLayeredWindowIndirect(hwnd, info);
    } finally {
      calloc.free(size);
      calloc.free(ptSrc);
      calloc.free(ptDst);
      calloc.free(blend);
      calloc.free(info);
      ReleaseDC(hwnd, hdcWin);
    }
    turns = (turns + (dt.clamp(1, 50) / 8000.0)) % 1.0;
  }

  void startWindow() {
    destroy();
    final hInst = GetModuleHandle(nullptr);
    final wc = calloc<WNDCLASS>();
    try {
      wc.ref.lpfnWndProc = Pointer.fromFunction<WNDPROC>(_overlayWndProc, 0);
      wc.ref.hInstance = hInst;
      wc.ref.lpszClassName = className;
      wc.ref.hCursor = LoadCursor(NULL, IDC_ARROW);
      RegisterClass(wc);
    } finally {
      calloc.free(wc);
    }
    hwnd = CreateWindowEx(
      WS_EX_LAYERED |
          WS_EX_TRANSPARENT |
          WS_EX_TOPMOST |
          WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE,
      className,
      TEXT(''),
      WS_POPUP,
      left,
      top,
      diameter,
      diameter,
      NULL,
      NULL,
      hInst,
      nullptr,
    );
    if (hwnd == 0) return;
    hdcScreen = GetDC(NULL);
    hdcMem = CreateCompatibleDC(hdcScreen);
    final bmi = calloc<BITMAPINFO>();
    final bitsPtr = calloc<Pointer<Void>>();
    try {
      bmi.ref.bmiHeader.biSize = sizeOf<BITMAPINFOHEADER>();
      bmi.ref.bmiHeader.biWidth = diameter;
      bmi.ref.bmiHeader.biHeight = -diameter;
      bmi.ref.bmiHeader.biPlanes = 1;
      bmi.ref.bmiHeader.biBitCount = 32;
      bmi.ref.bmiHeader.biCompression = BI_RGB;
      hbmp = CreateDIBSection(
        hdcMem,
        bmi,
        DIB_RGB_COLORS,
        bitsPtr,
        NULL,
        0,
      );
      bits = bitsPtr.value.cast<Uint32>();
    } finally {
      calloc.free(bmi);
      calloc.free(bitsPtr);
    }
    if (hbmp == 0 || bits == null || bits!.address == 0) return;
    SelectObject(hdcMem, hbmp);
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    SetWindowPos(
      hwnd,
      HWND_TOPMOST,
      left,
      top,
      diameter,
      diameter,
      SWP_NOACTIVATE | SWP_SHOWWINDOW,
    );
    lastPaintMs = DateTime.now().millisecondsSinceEpoch;
    ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!running) return;
      paintFrame();
    });
    paintFrame();
  }

  cmd.listen((msg) {
    if (msg is! Map) return;
    final op = msg['op']?.toString();
    if (op == 'stop') {
      running = false;
      destroy();
      final ack = msg['ack'];
      if (ack is SendPort) ack.send(true);
      cmd.close();
      return;
    }
    if (op == 'show') {
      opacity = (msg['opacity'] as num?)?.toDouble() ?? 0.5;
      final heightFactor = (msg['heightFactor'] as num?)?.toDouble() ?? 0.25;
      _snapToFlutterWindowCenter(
        heightFactor: heightFactor,
        onPlaced: (l, t, d) {
          left = l;
          top = t;
          diameter = d;
        },
      );
      startWindow();
    }
  });
}

/// 用主窗口的屏幕物理矩形居中（避免 Flutter 逻辑像素被 Win32 当成物理像素，看起来偏一边）。
void _snapToFlutterWindowCenter({
  required double heightFactor,
  required void Function(int left, int top, int diameter) onPlaced,
}) {
  final className = TEXT('FLUTTER_RUNNER_WIN32_WINDOW');
  var hwnd = FindWindow(className, nullptr);
  if (hwnd == 0) hwnd = GetForegroundWindow();
  final rc = calloc<RECT>();
  try {
    var ok = 0;
    if (hwnd != 0) {
      ok = GetWindowRect(hwnd, rc);
    }
    if (ok == 0) {
      rc.ref.left = 0;
      rc.ref.top = 0;
      rc.ref.right = GetSystemMetrics(SM_CXSCREEN);
      rc.ref.bottom = GetSystemMetrics(SM_CYSCREEN);
    }
    final winW = math.max(1, rc.ref.right - rc.ref.left);
    final winH = math.max(1, rc.ref.bottom - rc.ref.top);
    final diameter =
        math.max(48, (winH * heightFactor).round()).clamp(32, 800);
    final left = rc.ref.left + ((winW - diameter) / 2).round();
    final top = rc.ref.top + ((winH - diameter) / 2).round();
    onPlaced(left, top, diameter);
  } finally {
    calloc.free(rc);
  }
}

int _overlayWndProc(int hwnd, int msg, int wParam, int lParam) {
  if (msg == WM_DESTROY) {
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProc(hwnd, msg, wParam, lParam);
}

void _fillYinYangBgra(
  Pointer<Uint32> bits,
  int size,
  double turns,
  double opacity,
) {
  final cx = size / 2.0;
  final r = size / 2.0 - 1.0;
  if (r <= 2) return;
  final ang = turns * math.pi * 2;
  final cosA = math.cos(ang);
  final sinA = math.sin(ang);
  final half = r / 2;
  final eye = math.max(r / 6, r * 0.04);
  final stroke = math.max(r * 0.045, r * 0.02);
  const yangR = 0xF4, yangG = 0xF1, yangB = 0xEA;
  const yinR = 0x14, yinG = 0x14, yinB = 0x14;
  const ringR = 0xC9, ringG = 0xA2, ringB = 0x27;
  bool inC(double x, double y, double ox, double oy, double rad) {
    final dx = x - ox;
    final dy = y - oy;
    return dx * dx + dy * dy <= rad * rad;
  }

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = x + 0.5 - cx;
      final dy = y + 0.5 - cx;
      final rx = dx * cosA - dy * sinA;
      final ry = dx * sinA + dy * cosA;
      final dist = math.sqrt(rx * rx + ry * ry);
      var a = 0, pr = 0, pg = 0, pb = 0;
      if (dist <= r) {
        var cr = yangR, cg = yangG, cb = yangB;
        if (rx >= 0) {
          cr = yinR;
          cg = yinG;
          cb = yinB;
        }
        if (inC(rx, ry, 0, -half, half)) {
          cr = yinR;
          cg = yinG;
          cb = yinB;
        }
        if (inC(rx, ry, 0, half, half)) {
          cr = yangR;
          cg = yangG;
          cb = yangB;
        }
        if (inC(rx, ry, 0, -half, eye)) {
          cr = yangR;
          cg = yangG;
          cb = yangB;
        }
        if (inC(rx, ry, 0, half, eye)) {
          cr = yinR;
          cg = yinG;
          cb = yinB;
        }
        if (dist > r - stroke) {
          cr = ringR;
          cg = ringG;
          cb = ringB;
        }
        final aa = (255.0 * opacity).clamp(0, 255).round();
        a = aa;
        pr = (cr * aa / 255).round();
        pg = (cg * aa / 255).round();
        pb = (cb * aa / 255).round();
      }
      bits[y * size + x] = (a << 24) | (pr << 16) | (pg << 8) | pb;
    }
  }
}
