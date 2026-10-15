// OCR 引擎服务: 跨 isolate 调用原生内核, 避免阻塞 UI 线程

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'native.dart';

/// 支持的识别语言 (与下载脚本中的模型一一对应)
const kRecLangs = <String>[
  'ch', 'en', 'latin', 'cyrillic', 'korean', 'arabic',
  'devanagari', 'el', 'eslav', 'th', 'ta', 'te',
];

class OcrService {
  static Pointer<Void>? _engine;
  static String? _libPath;
  static bool _ready = false;
  static String? _lastError;
  static String _infoJson = '{}';

  /// OCR 调用串行化: ONNX Runtime Session 不支持并发 Run
  static Future<void> _queue = Future.value();

  static bool get isReady => _ready;
  static String? get lastError => _lastError;
  static String get infoJson => _infoJson;

  static Map<String, dynamic> get info {
    try {
      return jsonDecode(_infoJson) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// 构建 Rust 侧 EngineConfig 的 JSON
  static String buildConfigJson(AppSettings s) {
    final root = s.modelRoot;
    final ocr = p.join(root, 'ocr', 'PP-OCRv5');
    final det = <String, dynamic>{
      'resize_mode': s.detPreset == 'rapid' ? 'limit_side' : 'resize_long',
      'limit_side': s.detLimitSide,
      'limit_type': 'min',
      'mean': s.detPreset == 'rapid' ? [0.5, 0.5, 0.5] : [0.485, 0.456, 0.406],
      'std': s.detPreset == 'rapid' ? [0.5, 0.5, 0.5] : [0.229, 0.224, 0.225],
      'thresh': 0.3,
      'box_thresh': s.detPreset == 'rapid' ? 0.5 : 0.6,
      'unclip_ratio': s.detPreset == 'rapid' ? 1.6 : 1.5,
      'max_candidates': 1000,
      'min_size': 3.0,
      'use_dilation': s.detPreset == 'rapid',
      'min_component_pixels': 6,
    };
    final cls = <String, dynamic>{
      'img_h': 80,
      'img_w': 160,
      'norm': s.clsPreset == 'official' ? 'imagenet' : 'half',
      'keep_ratio': s.clsPreset != 'official',
      'thresh': 0.9,
    };
    return jsonEncode({
      'onnxruntime_dll': s.onnxruntimeDll,
      'det_model': p.join(ocr, 'det', 'ch_PP-OCRv5_det_mobile.onnx'),
      'cls_model': p.join(ocr, 'cls', 'ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx'),
      'rec_models': kRecLangs
          .map((l) => {
                'lang': l,
                'model': p.join(ocr, 'rec', '${l}_PP-OCRv5_rec_mobile.onnx'),
                'dict': p.join(ocr, 'rec', 'dicts', '$l.txt'),
              })
          .toList(),
      'intra_threads': s.intraThreads,
      'default_lang': 'ch',
      'auto_candidates': const ['latin', 'korean', 'cyrillic', 'eslav', 'el'],
      'det': det,
      'cls': cls,
      'rec': {
        'img_h': 48,
        'img_w_min': 320,
        'batch_num': 8,
        'max_width': 3200,
      },
    });
  }

  /// 初始化原生库与引擎
  static Future<void> init(AppSettings s) async {
    _lastError = null;
    _ready = false;
    _libPath = s.coreLibPath;

    if (s.coreLibPath.isEmpty || !File(s.coreLibPath).existsSync()) {
      _lastError = '未找到内核动态库: ${s.coreLibPath}';
      return;
    }
    if (s.onnxruntimeDll.isEmpty || !File(s.onnxruntimeDll).existsSync()) {
      _lastError = '未找到 onnxruntime 动态库: ${s.onnxruntimeDll}';
      return;
    }
    if (s.modelRoot.isEmpty) {
      _lastError = '未设置模型目录';
      return;
    }

    try {
      NativeDpg.configure(s.coreLibPath);
    } catch (e) {
      _lastError = '加载内核失败: $e';
      return;
    }

    final cfgJson = buildConfigJson(s);
    final libPath = s.coreLibPath;
    final res = await _spawnCreateEngine(libPath, cfgJson);
    final addr = (res[0] as int?) ?? 0;
    if (addr == 0) {
      _lastError = (res.length > 1 ? res[1] as String? : null) ?? '创建引擎失败';
      return;
    }
    _engine = Pointer<Void>.fromAddress(addr);

    try {
      _infoJson = await _spawnEngineInfo(libPath, addr);
    } catch (_) {}

    _ready = true;
  }

  static Future<void> dispose() async {
    final e = _engine;
    final lib = _libPath;
    if (e != null && lib != null) {
      await _spawnFreeEngine(lib, e.address);
    }
    _engine = null;
    _ready = false;
  }

  /// 后台预加载识别模型 (不阻塞界面)
  static void preload(String lang) {
    final addr = _engine?.address;
    final lib = _libPath;
    if (addr == null || lib == null || !_ready) return;
    // 串到已有的队列后面, 避免和正在进行的识别抢 session
    _queue = _queue.then((_) async {
      try {
        await _spawnPreload(addr, lib, lang);
      } catch (_) {}
    });
  }

  /// 只识别指定矩形, 不做检测。
  ///
  /// 实时翻译的主力: 画面只有几行变化时复用上一轮的框, 直接跳过检测,
  /// 单轮开销可以降一个数量级。
  ///
  /// [rects] 为 `[x, y, w, h]` 列表 (整帧坐标)。
  static Future<OcrResult> recognizeRects(
    Uint8List bgra,
    int width,
    int height,
    int stride,
    List<List<double>> rects, {
    String lang = 'auto',
  }) async {
    final addr = _engine?.address;
    final lib = _libPath;
    if (addr == null || lib == null || !_ready) {
      throw DpgException(_lastError ?? 'OCR 引擎未就绪');
    }
    if (rects.isEmpty) return OcrResult.empty();
    final rectsJson = jsonEncode(rects);

    final completer = Completer<OcrResult>();
    _queue = _queue.then((_) async {
      try {
        final sw = Stopwatch()..start();
        final out = await _spawnRecRects(
            addr, lib, bgra, width, height, stride, rectsJson, lang);
        final j = jsonDecode(out) as Map<String, dynamic>;
        final res = OcrResult.fromJson(j);
        completer.complete(OcrResult(
          lines: res.lines,
          imageWidth: width,
          imageHeight: height,
          detMs: 0,
          clsMs: 0,
          recMs: sw.elapsedMilliseconds.toDouble(),
          totalMs: sw.elapsedMilliseconds.toDouble(),
        ));
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// 对 BGRA 缓冲做 OCR (Windows GDI 截屏路径)
  static Future<OcrResult> recognizeBgra(
    Uint8List bgra,
    int width,
    int height,
    int stride, {
    String lang = 'auto',
    double textScore = 0.5,
    bool autoMultilang = true,
    int? detLimitSide,
    double minLineHeight = 0,
    int maxLines = 0,
    bool useDet = true,
    int noiseLevel = 1,
  }) =>
      _recognize(
        bgra,
        width,
        height,
        stride,
        isRgba: false,
        lang: lang,
        textScore: textScore,
        autoMultilang: autoMultilang,
        detLimitSide: detLimitSide,
        minLineHeight: minLineHeight,
        maxLines: maxLines,
        useDet: useDet,
        noiseLevel: noiseLevel,
      );

  /// 对 RGBA 缓冲做 OCR (Android ImageReader 截屏路径)
  static Future<OcrResult> recognizeRgba(
    Uint8List rgba,
    int width,
    int height,
    int stride, {
    String lang = 'auto',
    double textScore = 0.5,
    bool autoMultilang = true,
    int? detLimitSide,
    double minLineHeight = 0,
    int maxLines = 0,
    bool useDet = true,
    int noiseLevel = 1,
  }) =>
      _recognize(
        rgba,
        width,
        height,
        stride,
        isRgba: true,
        lang: lang,
        textScore: textScore,
        autoMultilang: autoMultilang,
        detLimitSide: detLimitSide,
        minLineHeight: minLineHeight,
        maxLines: maxLines,
        useDet: useDet,
        noiseLevel: noiseLevel,
      );

  static Future<OcrResult> _recognize(
    Uint8List pixels,
    int width,
    int height,
    int stride, {
    required bool isRgba,
    required String lang,
    required double textScore,
    required bool autoMultilang,
    required int? detLimitSide,
    required double minLineHeight,
    required int maxLines,
    required bool useDet,
    required int noiseLevel,
  }) {
    final e = _engine;
    final lib = _libPath;
    if (e == null || lib == null || !_ready) {
      return Future.error(DpgException(_lastError ?? 'OCR 引擎未就绪'));
    }
    final addr = e.address;
    final libPath = lib;
    final opts = jsonEncode({
      'lang': lang,
      'use_det': useDet,
      'use_cls': true,
      'text_score': textScore,
      'auto_multilang': autoMultilang,
      'det_limit_side': detLimitSide,
      'min_line_height': minLineHeight > 0 ? minLineHeight : null,
      'max_lines': maxLines > 0 ? maxLines : null,
      // 0=关闭 1=宽松 2=标准 3=严格
      'noise_level': noiseLevel,
    });

    // 串行化, 避免 ONNX Runtime Session 并发。
    // 注意: isolate 闭包必须在 `_spawnOcr*` 里创建 —— 本帧含有 Pointer / Completer
    // 等不可发送对象, 在这里直接创建闭包会让整个作用域被连带发送。
    final completer = Completer<OcrResult>();
    _queue = _queue.then((_) async {
      try {
        final jsonStr = isRgba
            ? await _spawnOcrRgba(
                addr, libPath, pixels, width, height, stride, opts)
            : await _spawnOcr(
                addr, libPath, pixels, width, height, stride, opts);
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        completer.complete(OcrResult.fromJson(map));
      } catch (err, st) {
        completer.completeError(err, st);
      }
    });
    return completer.future;
  }

  static Future<OcrResult> recognizeFile(
    String path, {
    String lang = 'auto',
    double textScore = 0.5,
    bool autoMultilang = true,
  }) async {
    final e = _engine;
    final lib = _libPath;
    if (e == null || lib == null || !_ready) {
      throw DpgException(_lastError ?? 'OCR 引擎未就绪');
    }
    final opts = jsonEncode({
      'lang': lang,
      'text_score': textScore,
      'auto_multilang': autoMultilang,
    });
    final jsonStr = await _spawnOcrFile(e.address, lib, path, opts);
    return OcrResult.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
  }
}

// ============================================================
//  isolate 启动包装
//
//  这些函数的**所有局部变量与参数都必须是可跨 isolate 发送的**
//  (int / String / Uint8List 等)。Dart 创建闭包时会把外层作用域打包进
//  闭包 context 一起发送, 一旦该作用域里存在 Pointer / Completer /
//  ReceivePort 这类不可发送对象, 就会抛:
//      "Illegal argument in isolate message: object is unsendable"
//  因此绝不能把 Isolate.run 直接写在持有引擎指针的函数里。
// ============================================================

Future<List<Object?>> _spawnCreateEngine(String libPath, String cfgJson) {
  return Isolate.run(() => _createEngine(libPath, cfgJson));
}

Future<String> _spawnEngineInfo(String libPath, int engineAddr) {
  return Isolate.run(() => _engineInfo(libPath, engineAddr));
}

Future<void> _spawnFreeEngine(String libPath, int engineAddr) {
  return Isolate.run(() => _freeEngine(libPath, engineAddr));
}

Future<String> _spawnOcr(
  int engineAddr,
  String libPath,
  Uint8List bgra,
  int width,
  int height,
  int stride,
  String optsJson,
) {
  return Isolate.run(
      () => _ocrWorker(engineAddr, libPath, bgra, width, height, stride, optsJson));
}

Future<String> _spawnOcrRgba(
  int engineAddr,
  String libPath,
  Uint8List rgba,
  int width,
  int height,
  int stride,
  String optsJson,
) {
  return Isolate.run(() =>
      _ocrRgbaWorker(engineAddr, libPath, rgba, width, height, stride, optsJson));
}

Future<String> _spawnOcrFile(
  int engineAddr,
  String libPath,
  String path,
  String optsJson,
) {
  return Isolate.run(() => _ocrFileWorker(engineAddr, libPath, path, optsJson));
}

Future<void> _spawnPreload(int engineAddr, String libPath, String lang) {
  return Isolate.run(() => _preloadWorker(engineAddr, libPath, lang));
}

void _preloadWorker(int engineAddr, String libPath, String lang) {
  final lib = DynamicLibrary.open(libPath);
  final n = NativeDpg.attachExisting(lib);
  final p = lang.toNativeUtf8();
  try {
    n.preloadLangs(Pointer<Void>.fromAddress(engineAddr), p);
  } finally {
    malloc.free(p);
  }
}

Future<String> _spawnRecRects(  int engineAddr,
  String libPath,
  Uint8List bgra,
  int width,
  int height,
  int stride,
  String rectsJson,
  String lang,
) {
  return Isolate.run(() => _recRectsWorker(
      engineAddr, libPath, bgra, width, height, stride, rectsJson, lang));
}

String _recRectsWorker(
  int engineAddr,
  String libPath,
  Uint8List bgra,
  int w,
  int h,
  int stride,
  String rectsJson,
  String lang,
) {
  final lib = DynamicLibrary.open(libPath);
  final n = NativeDpg.attachExisting(lib);
  final engine = Pointer<Void>.fromAddress(engineAddr);
  final ptr = malloc<Uint8>(bgra.length);
  final rj = rectsJson.toNativeUtf8();
  final lg = lang.toNativeUtf8();
  try {
    ptr.asTypedList(bgra.length).setAll(0, bgra);
    final res =
        n.recRectsBgra(engine, ptr, w, h, stride, rj, lg);
    return NativeDpg.takeString(res, n);
  } finally {
    malloc.free(ptr);
    malloc.free(rj);
    malloc.free(lg);
  }
}

// ============================================================
//  isolate 内部实现 (只使用可跨 isolate 传递的参数类型)
// ============================================================

/// 返回 `[引擎地址, 错误信息]`。
/// 错误信息必须通过返回值回传 —— 子 isolate 里的静态变量改动主 isolate 看不到。
List<Object?> _createEngine(String libPath, String cfgJson) {
  try {
    final lib = DynamicLibrary.open(libPath);
    final n = NativeDpg.attachExisting(lib);
    final cfg = cfgJson.toNativeUtf8();
    try {
      final ptr = n.engineNew(cfg);
      if (ptr == nullptr) {
        final err = n.lastError();
        final msg = err == nullptr ? '创建引擎失败' : err.toDartString();
        if (err != nullptr) n.stringFree(err);
        return <Object?>[0, msg];
      }
      return <Object?>[ptr.address, null];
    } finally {
      malloc.free(cfg);
    }
  } catch (e) {
    return <Object?>[0, '加载内核失败: $e'];
  }
}

void _freeEngine(String libPath, int addr) {
  try {
    final lib = DynamicLibrary.open(libPath);
    final n = NativeDpg.attachExisting(lib);
    n.engineFree(Pointer<Void>.fromAddress(addr));
  } catch (_) {}
}

String _engineInfo(String libPath, int addr) {
  final lib = DynamicLibrary.open(libPath);
  final n = NativeDpg.attachExisting(lib);
  final res = n.engineInfo(Pointer<Void>.fromAddress(addr));
  return NativeDpg.takeString(res, n);
}

String _ocrWorker(int engineAddr, String libPath, Uint8List bgra, int w, int h,
    int stride, String optsJson) {
  final lib = DynamicLibrary.open(libPath);
  final n = NativeDpg.attachExisting(lib);
  final engine = Pointer<Void>.fromAddress(engineAddr);
  final data = malloc.allocate<Uint8>(bgra.length);
  final optPtr = optsJson.toNativeUtf8();
  try {
    data.asTypedList(bgra.length).setAll(0, bgra);
    final res = n.ocrBgra(engine, data, w, h, stride, optPtr);
    return NativeDpg.takeString(res, n);
  } finally {
    malloc.free(optPtr);
    malloc.free(data);
  }
}

String _ocrRgbaWorker(int engineAddr, String libPath, Uint8List rgba, int w,
    int h, int stride, String optsJson) {
  final lib = DynamicLibrary.open(libPath);
  final n = NativeDpg.attachExisting(lib);
  final engine = Pointer<Void>.fromAddress(engineAddr);
  final data = malloc.allocate<Uint8>(rgba.length);
  final optPtr = optsJson.toNativeUtf8();
  try {
    data.asTypedList(rgba.length).setAll(0, rgba);
    final res = n.ocrRgba(engine, data, w, h, stride, optPtr);
    return NativeDpg.takeString(res, n);
  } finally {
    malloc.free(optPtr);
    malloc.free(data);
  }
}

String _ocrFileWorker(int engineAddr, String libPath, String path, String optsJson) {  final lib = DynamicLibrary.open(libPath);
  final n = NativeDpg.attachExisting(lib);
  final engine = Pointer<Void>.fromAddress(engineAddr);
  final pathPtr = path.toNativeUtf8();
  final optPtr = optsJson.toNativeUtf8();
  try {
    final res = n.ocrFile(engine, pathPtr, optPtr);
    return NativeDpg.takeString(res, n);
  } finally {
    malloc.free(pathPtr);
    malloc.free(optPtr);
  }
}
