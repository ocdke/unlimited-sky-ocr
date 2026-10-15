// DPG 内核 Dart FFI 绑定
//
// 对应 Rust 侧 core/src/ffi.rs 导出的 C ABI。
// 每个 isolate 都会独立打开一次动态库 (DynamicLibrary 句柄不可跨 isolate 传递)。

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// 与 Rust `DpgImage` 内存布局一致
final class DpgImage extends Struct {
  external Pointer<Uint8> data;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int stride;
}

// ---- C 函数签名 ----
typedef _EngineNewC = Pointer<Void> Function(Pointer<Utf8>);
typedef _EngineNewDart = Pointer<Void> Function(Pointer<Utf8>);
typedef _PtrOnlyC = Void Function(Pointer<Void>);
typedef _PtrOnlyDart = void Function(Pointer<Void>);
typedef _PtrToStrC = Pointer<Utf8> Function(Pointer<Void>);
typedef _PtrToStrDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _NoArgToStrC = Pointer<Utf8> Function();
typedef _NoArgToStrDart = Pointer<Utf8> Function();
typedef _StrFreeC = Void Function(Pointer<Utf8>);
typedef _StrFreeDart = void Function(Pointer<Utf8>);

typedef _OcrFileC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _OcrFileDart = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);

typedef _OcrBytesC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<Utf8>);
typedef _OcrBytesDart = Pointer<Utf8> Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Utf8>);

typedef _OcrBgraC = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Uint8>, Int32, Int32, Int32, Pointer<Utf8>);
typedef _OcrBgraDart = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Uint8>, int, int, int, Pointer<Utf8>);

typedef _OcrRgbaC = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Uint8>, Int32, Int32, Int32, Pointer<Utf8>);
typedef _OcrRgbaDart = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Uint8>, int, int, int, Pointer<Utf8>);

typedef _CaptureC = Pointer<DpgImage> Function(Int32, Int32, Int32, Int32);typedef _CaptureDart = Pointer<DpgImage> Function(int, int, int, int);
typedef _CaptureAllC = Pointer<DpgImage> Function();
typedef _CaptureAllDart = Pointer<DpgImage> Function();
typedef _ImgFreeC = Void Function(Pointer<DpgImage>);
typedef _ImgFreeDart = void Function(Pointer<DpgImage>);

typedef _RecRectsC = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Uint8>, Int32, Int32, Int32, Pointer<Utf8>, Pointer<Utf8>);
typedef _RecRectsDart = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Uint8>, int, int, int, Pointer<Utf8>, Pointer<Utf8>);

// ---- 平台集成: 单实例 / 托盘 / 开机自启 ----
typedef _IntVoidC = Int32 Function();
typedef _IntVoidDart = int Function();
typedef _StrStrToIntC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _StrStrToIntDart = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _IntStrToIntC = Int32 Function(Int32, Pointer<Utf8>);
typedef _IntStrToIntDart = int Function(int, Pointer<Utf8>);
typedef _StrToIntC = Int32 Function(Pointer<Utf8>);
typedef _StrToIntDart = int Function(Pointer<Utf8>);
typedef _Str3ToPtrC = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Str3ToPtrDart = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Str2ToPtrC = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _Str2ToPtrDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _PtrStrToIntC = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _PtrStrToIntDart = int Function(Pointer<Void>, Pointer<Utf8>);

// ---- 离线翻译 ----
typedef _MtNewC = Pointer<Void> Function(Pointer<Utf8>);
typedef _MtNewDart = Pointer<Void> Function(Pointer<Utf8>);
typedef _MtInfoC = Pointer<Utf8> Function(Pointer<Void>);
typedef _MtInfoDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _MtBatchC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _MtBatchDart = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _VoidVoidC = Void Function();
typedef _VoidVoidDart = void Function();
typedef _IntToIntC = Int32 Function(Int32);
typedef _IntToIntDart = int Function(int);
typedef _TwoIntC = Int32 Function(Int32, Int32);
typedef _TwoIntDart = int Function(int, int);

class NativeDpg {
  NativeDpg._(this._lib) {
    engineNew = _lib.lookupFunction<_EngineNewC, _EngineNewDart>('dpg_engine_new');
    engineFree = _lib.lookupFunction<_PtrOnlyC, _PtrOnlyDart>('dpg_engine_free');
    engineInfo = _lib.lookupFunction<_PtrToStrC, _PtrToStrDart>('dpg_engine_info');
    ocrFile = _lib.lookupFunction<_OcrFileC, _OcrFileDart>('dpg_ocr_file');
    ocrBytes = _lib.lookupFunction<_OcrBytesC, _OcrBytesDart>('dpg_ocr_bytes');
    ocrBgra = _lib.lookupFunction<_OcrBgraC, _OcrBgraDart>('dpg_ocr_bgra');
    ocrRgba = _lib.lookupFunction<_OcrRgbaC, _OcrRgbaDart>('dpg_ocr_rgba');
    captureRect = _lib.lookupFunction<_CaptureC, _CaptureDart>('dpg_capture_rect');
    captureAll = _lib.lookupFunction<_CaptureAllC, _CaptureAllDart>('dpg_capture_all');
    imageFree = _lib.lookupFunction<_ImgFreeC, _ImgFreeDart>('dpg_image_free');
    stringFree = _lib.lookupFunction<_StrFreeC, _StrFreeDart>('dpg_string_free');
    recRectsBgra =
        _lib.lookupFunction<_RecRectsC, _RecRectsDart>('dpg_rec_rects_bgra');
    probeHotkey = _lib.lookupFunction<_TwoIntC, _TwoIntDart>('dpg_probe_hotkey');
    singleInstance = _lib.lookupFunction<_IntVoidC, _IntVoidDart>('dpg_single_instance');
    activateExisting = _lib.lookupFunction<_IntVoidC, _IntVoidDart>('dpg_activate_existing');
    trayInit = _lib.lookupFunction<_StrStrToIntC, _StrStrToIntDart>('dpg_tray_init');
    trayPoll = _lib.lookupFunction<_IntVoidC, _IntVoidDart>('dpg_tray_poll');
    trayDispose = _lib.lookupFunction<_VoidVoidC, _VoidVoidDart>('dpg_tray_dispose');
    setAutostart = _lib.lookupFunction<_IntStrToIntC, _IntStrToIntDart>('dpg_set_autostart');
    getAutostart = _lib.lookupFunction<_IntVoidC, _IntVoidDart>('dpg_get_autostart');
    requestShow = _lib.lookupFunction<_IntVoidC, _IntVoidDart>('dpg_request_show');
    createShowEvent =
        _lib.lookupFunction<_VoidVoidC, _VoidVoidDart>('dpg_create_show_event');
    pollShowRequest =
        _lib.lookupFunction<_IntVoidC, _IntVoidDart>('dpg_poll_show_request');
    focusWindow = _lib.lookupFunction<_IntVoidC, _IntVoidDart>('dpg_focus_window');
    pickFile = _lib.lookupFunction<_Str3ToPtrC, _Str3ToPtrDart>('dpg_pick_file');
    pickFolder = _lib.lookupFunction<_Str2ToPtrC, _Str2ToPtrDart>('dpg_pick_folder');
    pathExists = _lib.lookupFunction<_StrToIntC, _StrToIntDart>('dpg_path_exists');
    registerExtraHotkey = _lib
        .lookupFunction<_TwoIntC, _TwoIntDart>('dpg_register_extra_hotkey');
    unregisterExtraHotkey =
        _lib.lookupFunction<_VoidVoidC, _VoidVoidDart>('dpg_unregister_extra_hotkey');
    preloadLangs =
        _lib.lookupFunction<_PtrStrToIntC, _PtrStrToIntDart>('dpg_preload_langs');
    mtNew = _lib.lookupFunction<_MtNewC, _MtNewDart>('dpg_mt_new');
    mtInfo = _lib.lookupFunction<_MtInfoC, _MtInfoDart>('dpg_mt_info');
    mtTranslateBatch =
        _lib.lookupFunction<_MtBatchC, _MtBatchDart>('dpg_mt_translate_batch');
    mtFree = _lib.lookupFunction<_PtrOnlyC, _PtrOnlyDart>('dpg_mt_free');
    lastError = _lib.lookupFunction<_NoArgToStrC, _NoArgToStrDart>('dpg_last_error');
    screenInfo = _lib.lookupFunction<_NoArgToStrC, _NoArgToStrDart>('dpg_screen_info');
    version = _lib.lookupFunction<_NoArgToStrC, _NoArgToStrDart>('dpg_version');
    initPlatform = _lib.lookupFunction<_VoidVoidC, _VoidVoidDart>('dpg_init_platform');
    setCaptureExclusion =
        _lib.lookupFunction<_IntToIntC, _IntToIntDart>('dpg_set_capture_exclusion');
  }

  final DynamicLibrary _lib;

  late final _EngineNewDart engineNew;
  late final _PtrOnlyDart engineFree;
  late final _PtrToStrDart engineInfo;
  late final _OcrFileDart ocrFile;
  late final _OcrBytesDart ocrBytes;
  late final _OcrBgraDart ocrBgra;
  late final _OcrRgbaDart ocrRgba;
  late final _CaptureDart captureRect;
  late final _CaptureAllDart captureAll;
  late final _ImgFreeDart imageFree;
  late final _StrFreeDart stringFree;
  late final _RecRectsDart recRectsBgra;
  late final _TwoIntDart probeHotkey;
  late final _IntVoidDart singleInstance;
  late final _IntVoidDart activateExisting;
  late final _StrStrToIntDart trayInit;
  late final _IntVoidDart trayPoll;
  late final _VoidVoidDart trayDispose;
  late final _IntStrToIntDart setAutostart;
  late final _IntVoidDart getAutostart;
  late final _IntVoidDart requestShow;
  late final _VoidVoidDart createShowEvent;
  late final _IntVoidDart pollShowRequest;
  late final _IntVoidDart focusWindow;
  late final _Str3ToPtrDart pickFile;
  late final _Str2ToPtrDart pickFolder;
  late final _StrToIntDart pathExists;
  late final _TwoIntDart registerExtraHotkey;
  late final _VoidVoidDart unregisterExtraHotkey;
  late final _PtrStrToIntDart preloadLangs;
  late final _MtNewDart mtNew;
  late final _MtInfoDart mtInfo;
  late final _MtBatchDart mtTranslateBatch;
  late final _PtrOnlyDart mtFree;
  late final _NoArgToStrDart lastError;
  late final _NoArgToStrDart screenInfo;
  late final _NoArgToStrDart version;
  late final _VoidVoidDart initPlatform;
  late final _IntToIntDart setCaptureExclusion;

  static DynamicLibrary? _shared;
  static NativeDpg? _instance;

  /// 由 main() 在启动时调用, 指定 dpg_core.dll / libdpg_core.so 的绝对路径
  static void configure(String libraryPath) {
    _shared = DynamicLibrary.open(libraryPath);
    _instance = null;
  }

  /// 每个 isolate 首次访问时打开库
  static NativeDpg get instance {
    if (_instance != null) return _instance!;
    final lib = _shared ?? DynamicLibrary.open(defaultLibraryName);
    _instance = NativeDpg._(lib);
    return _instance!;
  }

  /// 从原始地址重建实例 (跨 isolate 传递引擎指针时使用)
  static NativeDpg attachExisting(DynamicLibrary lib) {
    return NativeDpg._(lib);
  }

  static String get defaultLibraryName {
    if (Platform.isWindows) return 'dpg_core.dll';
    if (Platform.isAndroid) return 'libdpg_core.so';
    if (Platform.isLinux) return 'libdpg_core.so';
    if (Platform.isMacOS) return 'libdpg_core.dylib';
    return 'dpg_core.dll';
  }

  // ---- 辅助 ----

  /// 读取 C 字符串并释放
  static String takeString(Pointer<Utf8> p, NativeDpg n) {
    if (p == nullptr) {
      final err = n.lastError();
      final msg = err == nullptr ? '未知错误' : err.toDartString();
      if (err != nullptr) n.stringFree(err);
      throw DpgException(msg);
    }
    final s = p.toDartString();
    n.stringFree(p);
    return s;
  }
}

class DpgException implements Exception {
  DpgException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 截屏结果 (已从原生内存拷出, 可安全跨 isolate 传递)
class CapturedFrame {
  CapturedFrame({
    required this.bgra,
    required this.width,
    required this.height,
    required this.stride,
    required this.originX,
    required this.originY,
    this.isRgba = false,
  });

  /// 4 字节/像素原始缓冲; `isRgba` 为 false 时是 BGRA, 否则是 RGBA
  final Uint8List bgra;
  final int width;
  final int height;
  final int stride;

  /// 该帧在虚拟桌面中的物理像素原点
  final int originX;
  final int originY;

  /// Android 的 ImageReader 输出 RGBA, Windows GDI 输出 BGRA
  final bool isRgba;
}

/// 执行截屏并把像素拷进 Dart 堆内存
CapturedFrame captureRegion(int x, int y, int w, int h) {
  final n = NativeDpg.instance;
  final ptr = n.captureRect(x, y, w, h);
  if (ptr == nullptr) {
    final err = n.lastError();
    final msg = err == nullptr ? '截屏失败' : err.toDartString();
    if (err != nullptr) n.stringFree(err);
    throw DpgException(msg);
  }
  final img = ptr.ref;
  final len = img.stride * img.height;
  final bytes = Uint8List.fromList(img.data.asTypedList(len));
  final cw = img.width, ch = img.height, st = img.stride;
  n.imageFree(ptr);
  return CapturedFrame(
    bgra: bytes,
    width: cw,
    height: ch,
    stride: st,
    originX: x,
    originY: y,
  );
}

/// BGRA -> RGBA (用于 decodeImageFromPixels)。
/// 已经是 RGBA 的输入直接返回副本。
Uint8List bgraToRgba(Uint8List src, {bool alreadyRgba = false}) {
  if (alreadyRgba) return Uint8List.fromList(src);
  final out = Uint8List(src.length);
  for (var i = 0; i + 3 < src.length; i += 4) {
    out[i] = src[i + 2];
    out[i + 1] = src[i + 1];
    out[i + 2] = src[i];
    out[i + 3] = 255;
  }
  return out;
}

/// 从帧中裁出一个子区域 (保持原始通道顺序, 紧凑 stride)
Uint8List cropBgra(CapturedFrame f, int x, int y, int w, int h) {
  final out = Uint8List(w * h * 4);
  for (var row = 0; row < h; row++) {
    final sy = y + row;
    if (sy < 0 || sy >= f.height) continue;
    final srcStart = sy * f.stride + x * 4;
    final copyW = (x + w <= f.width) ? w : (f.width - x);
    if (copyW <= 0) continue;
    out.setRange(row * w * 4, row * w * 4 + copyW * 4, f.bgra, srcStart);
  }
  return out;
}
