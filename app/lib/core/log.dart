// 轻量日志: 写到 %LOCALAPPDATA%\UnlimitedSkyOCR\dpg.log
//
// 刻意用固定路径而不是 getApplicationSupportDirectory() —— 后者跟着
// exe 版本信息里的公司名/产品名走, 改个名字日志就"消失"了, 排查问题时很坑。

import 'dart:io';

class Log {
  static File? _f;
  static final List<String> _pending = [];
  static bool _ready = false;

  static Future<void> init() async {
    try {
      final base = Platform.environment['LOCALAPPDATA'] ??
          Directory.systemTemp.path;
      final dir = Directory('$base${Platform.pathSeparator}UnlimitedSkyOCR');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _f = File('${dir.path}${Platform.pathSeparator}dpg.log');
      if (_f!.existsSync() && _f!.lengthSync() > 1024 * 1024) {
        _f!.writeAsStringSync(''); // 超过 1MB 清空
      }
      _ready = true;
      for (final l in _pending) {
        _f!.writeAsStringSync(l, mode: FileMode.append);
      }
      _pending.clear();
      log('---- 启动 v1.0 ----');
    } catch (_) {
      _ready = false;
    }
  }

  static void log(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final line = '[$ts] $msg\n';
    if (!_ready || _f == null) {
      if (_pending.length < 200) _pending.add(line);
      return;
    }
    try {
      _f!.writeAsStringSync(line, mode: FileMode.append);
    } catch (_) {}
  }

  static String get path => _f?.path ?? '(未初始化)';
}
