// 跨平台整屏截取
//
//   * Windows — 通过 Rust 内核走 GDI BitBlt, 直接拿到 BGRA
//   * Android — 通过平台通道走 MediaProjection + ImageReader, 拿到 RGBA
//
// 两者返回同样的 [CapturedFrame], 上层 UI 与 OCR 流程完全共用。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/services.dart';

import 'native.dart';

const MethodChannel _channel = MethodChannel('dpg/native');

/// 当前平台是否支持屏幕截取
bool get captureSupported => Platform.isWindows || Platform.isAndroid;

/// 读取 Rust 侧屏幕信息 (仅桌面平台有原生 GDI 实现)
Map<String, dynamic> screenInfoJson() {
  if (!Platform.isWindows) return {};
  try {
    final n = NativeDpg.instance;
    final ptr = n.screenInfo();
    final s = NativeDpg.takeString(ptr, n);
    final d = jsonDecode(s);
    return d is Map ? Map<String, dynamic>.from(d) : {};
  } catch (_) {
    return {};
  }
}

/// 计算屏幕矩形:
///   * `physical` — 物理像素, 用于截屏
///   * `logical`  — 逻辑像素, 用于摆放 Flutter 窗口 (仅桌面需要)
///
/// 不使用屏幕插件, 避免 work-area / DPI 语义差异带来的坐标错位。
(Rect physical, Rect logical)? screenRects(double devicePixelRatio) {
  final info = screenInfoJson();
  final v = info['virtual'] as Map?;
  if (v == null) return null;
  final x = (v['x'] as num?)?.toDouble() ?? 0;
  final y = (v['y'] as num?)?.toDouble() ?? 0;
  final w = (v['width'] as num?)?.toDouble() ?? 1920;
  final h = (v['height'] as num?)?.toDouble() ?? 1080;
  if (w <= 0 || h <= 0) return null;
  final dpr = devicePixelRatio > 0 ? devicePixelRatio : 1.0;
  return (
    Rect.fromLTWH(x, y, w, h),
    Rect.fromLTWH(x / dpr, y / dpr, w / dpr, h / dpr),
  );
}

/// 抓取整屏
Future<CapturedFrame> captureFullScreen({double devicePixelRatio = 1.0}) async {
  if (Platform.isAndroid) {
    final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('capture');
    if (r == null) {
      throw DpgException('Android 截屏失败: 平台通道返回空');
    }
    final pixels = r['pixels'] as Uint8List?;
    if (pixels == null || pixels.isEmpty) {
      throw DpgException('Android 截屏失败: 像素数据为空');
    }
    return CapturedFrame(
      bgra: pixels,
      width: (r['width'] as num).toInt(),
      height: (r['height'] as num).toInt(),
      stride: (r['stride'] as num?)?.toInt() ??
          (r['width'] as num).toInt() * 4,
      originX: 0,
      originY: 0,
      isRgba: true,
    );
  }

  // 桌面平台: Rust GDI
  final rects = screenRects(devicePixelRatio);
  if (rects == null) throw DpgException('无法获取屏幕尺寸');
  final p = rects.$1;
  return captureRegion(
    p.left.round(),
    p.top.round(),
    p.width.round(),
    p.height.round(),
  );
}

/// Android: 让本应用退到后台 / 回到前台
///
/// 用于"先退到后台 → 拍到前台应用 → 再回到前台显示覆盖层"的流程,
/// 否则会把 DPG 自己的界面拍进冻结背景。
Future<void> setAppBackground(bool background) async {
  if (!Platform.isAndroid) return;
  try {
    await _channel
        .invokeMethod<bool>(background ? 'minimizeApp' : 'restoreApp');
  } catch (_) {
    // 忽略: 部分 ROM 不允许后台切换
  }
}

/// Android: 定位内核与 ONNX Runtime 动态库
Future<({String coreLib, String ortLib})> androidNativeLibs() async {
  final dir = await _channel.invokeMethod<String>('nativeLibDir') ?? '';
  return (
    coreLib: '$dir/libdpg_core.so',
    ortLib: '$dir/libonnxruntime.so',
  );
}

/// Android: 屏幕物理像素尺寸
Future<({int width, int height})> androidScreenSize() async {
  final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('screenSize');
  return (
    width: (r?['width'] as num?)?.toInt() ?? 1080,
    height: (r?['height'] as num?)?.toInt() ?? 1920,
  );
}

/// Android: 解包 APK 内的模型到应用私有目录, 返回模型根目录
///
/// 模型以原生 assets 形式打包, 由 Kotlin 侧递归复制 (首次启动约需数秒),
/// 之后用文件标记跳过。
Future<String> ensureAndroidModels() async {
  final r = await _channel
      .invokeMethod<Map<dynamic, dynamic>>('ensureModels');
  final err = r?['error'] as String?;
  if (err != null) throw DpgException('模型解包失败: $err');
  final path = r?['path'] as String?;
  if (path == null || path.isEmpty) throw DpgException('模型解包失败: 未返回路径');
  return path;
}
