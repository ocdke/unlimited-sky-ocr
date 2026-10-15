// 离线翻译服务
//
// 负责:
//   * 在独立 isolate 中创建 Rust 侧的离线翻译引擎 (按需加载语言对)
//   * 把一批文本送进去翻译, 返回译文数组
//   * 串行化调用 (MarianTranslator 内部持有 Session, 不支持并发)
//
// 语言对目录约定: <modelRoot>/<src>-<tgt>/, 例如 models/translate/en-zh

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native.dart';

class MtService {
  static Pointer<Void>? _engine;
  static String? _libPath;
  static String _infoJson = '{}';
  static String? _lastError;
  static bool _ready = false;

  static Future<void> _queue = Future.value();

  static bool get isReady => _ready;
  static String? get lastError => _lastError;

  static Map<String, dynamic> get info {
    try {
      return jsonDecode(_infoJson) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static List<String> get availablePairs {
    final a = info['available'];
    return a is List ? a.cast<String>() : const [];
  }

  /// 初始化 (只扫描可用语言对, 不加载模型)
  static Future<void> init({
    required String modelRoot,
    required String coreLibPath,
    required String onnxruntimeDll,
    int threads = 0,
  }) async {
    _lastError = null;
    _ready = false;

    final cfg = jsonEncode({
      'model_root': modelRoot,
      'onnxruntime_dll': onnxruntimeDll.isEmpty ? null : onnxruntimeDll,
      'threads': threads,
    });
    try {
      final res = await _spawnMtNew(coreLibPath, cfg);
      final addr = (res[0] as int?) ?? 0;
      if (addr == 0) {
        _lastError = (res.length > 1 ? res[1] as String? : null) ?? '离线翻译引擎创建失败';
        return;
      }
      _engine = Pointer<Void>.fromAddress(addr);
      _libPath = coreLibPath;
      _infoJson = await _spawnMtInfo(coreLibPath, addr);
      _ready = true;
    } catch (e) {
      _lastError = '$e';
    }
  }

  static Future<void> dispose() async {
    final e = _engine;
    final lib = _libPath;
    if (e != null && lib != null) {
      await _spawnMtFree(lib, e.address);
    }
    _engine = null;
    _ready = false;
  }

  /// 批量翻译; 失败时抛异常, 由上层决定是否回退
  static Future<List<String>> translateBatch(
    String pair,
    List<String> texts,
  ) {
    final e = _engine;
    final lib = _libPath;
    if (e == null || lib == null || !_ready) {
      return Future.error(DpgException(_lastError ?? '离线翻译引擎未就绪'));
    }
    if (texts.isEmpty) return Future.value(<String>[]);
    final addr = e.address;
    final payload = jsonEncode(texts);

    final completer = Completer<List<String>>();
    _queue = _queue.then((_) async {
      try {
        final out = await _spawnMtBatch(addr, lib, pair, payload);
        final list = (jsonDecode(out) as List).map((e) => e.toString()).toList();
        completer.complete(list);
      } catch (err, st) {
        completer.completeError(err, st);
      }
    });
    return completer.future;
  }
}

// ============================================================
//  isolate 包装
//
//  与 ocr_service 同理: 闭包必须在**只捕获可发送变量**的函数里创建,
//  否则外层帧里的 Pointer 会连带被发送, 触发
//  "Illegal argument in isolate message: object is unsendable"。
// ============================================================

Future<List<Object?>> _spawnMtNew(String libPath, String cfgJson) {
  return Isolate.run(() => _mtNewWorker(libPath, cfgJson));
}

Future<String> _spawnMtInfo(String libPath, int addr) {
  return Isolate.run(() => _mtInfoWorker(libPath, addr));
}

Future<String> _spawnMtBatch(
    int addr, String libPath, String pair, String textsJson) {
  return Isolate.run(
      () => _mtBatchWorker(addr, libPath, pair, textsJson));
}

Future<void> _spawnMtFree(String libPath, int addr) {
  return Isolate.run(() => _mtFreeWorker(libPath, addr));
}

List<Object?> _mtNewWorker(String libPath, String cfgJson) {
  try {
    final lib = DynamicLibrary.open(libPath);
    final n = NativeDpg.attachExisting(lib);
    final cfg = cfgJson.toNativeUtf8();
    try {
      final ptr = n.mtNew(cfg);
      if (ptr == nullptr) {
        final err = n.lastError();
        final msg = err == nullptr ? '创建失败' : err.toDartString();
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

String _mtInfoWorker(String libPath, int addr) {
  final lib = DynamicLibrary.open(libPath);
  final n = NativeDpg.attachExisting(lib);
  final res = n.mtInfo(Pointer<Void>.fromAddress(addr));
  return NativeDpg.takeString(res, n);
}

String _mtBatchWorker(
    int addr, String libPath, String pair, String textsJson) {
  final lib = DynamicLibrary.open(libPath);
  final n = NativeDpg.attachExisting(lib);
  final engine = Pointer<Void>.fromAddress(addr);
  final pairPtr = pair.toNativeUtf8();
  final textsPtr = textsJson.toNativeUtf8();
  try {
    final res = n.mtTranslateBatch(engine, pairPtr, textsPtr);
    return NativeDpg.takeString(res, n);
  } finally {
    malloc.free(pairPtr);
    malloc.free(textsPtr);
  }
}

void _mtFreeWorker(String libPath, int addr) {
  try {
    final lib = DynamicLibrary.open(libPath);
    final n = NativeDpg.attachExisting(lib);
    n.mtFree(Pointer<Void>.fromAddress(addr));
  } catch (_) {}
}

/// 未使用, 仅确保 Uint8List 导入不被裁剪
// ignore: unused_element
final _keepTypedData = Uint8List(0);
