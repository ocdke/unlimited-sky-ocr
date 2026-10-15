// 翻译层: 在线多引擎 + 缓存 + 批量/去重
//
// 设计:
//   * `Translator` 抽象接口, 便于后续接入 Rust 侧离线模型
//   * 在线 Provider 全部免密钥可用 (Bing / Google), 也支持 key 型 (DeepL / LLM)
//   * 统一缓存 (provider, from, to, text) -> 译文, 命中即 0 延迟
//   * 自动去重: 同一屏里相同文本只请求一次

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'models.dart';
import 'mt_service.dart';

class TranslateException implements Exception {
  TranslateException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class Translator {
  String get name;
  bool get needsKey;
  /// 是否支持一次请求翻译多段文本
  bool get supportsBatch;

  /// 返回与 [texts] 等长的译文列表; 失败段落返回原文
  Future<List<String>> translate(
    List<String> texts, {
    required String from,
    required String to,
  });

  /// 流式翻译: 每翻好几行就回吐一次, 让界面能边翻边显示。
  ///
  /// 大模型是按 token 一个个吐的, 一次整屏几十行要十几秒 —— 等全部生成完
  /// 再显示, 用户看到的就是"卡住不动"。流式能让第一行在 1 秒内出现。
  /// 不支持流式的实现返回 null, 调用方自动退回 [translate]。
  Stream<List<String>>? translateStream(
    List<String> texts, {
    required String from,
    required String to,
  }) =>
      null;
}

// ============================================================
//  缓存
// ============================================================

class TranslateCache {
  TranslateCache({this.capacity = 4000});
  final int capacity;
  final _map = <String, String>{};

  String _key(String provider, String from, String to, String text) =>
      '$provider\u0000$from\u0000$to\u0000$text';

  String? get(String provider, String from, String to, String text) {
    final k = _key(provider, from, to, text);
    final v = _map.remove(k);
    if (v != null) _map[k] = v; // LRU: 重新插入到末尾
    return v;
  }

  void put(String provider, String from, String to, String text, String value) {
    final k = _key(provider, from, to, text);
    _map.remove(k);
    _map[k] = value;
    while (_map.length > capacity) {
      _map.remove(_map.keys.first);
    }
  }

  void clear() => _map.clear();
  int get length => _map.length;
}

// ============================================================
//  语言代码映射
// ============================================================

String _deeplLang(String code) {
  switch (code) {
    case 'zh-CN':
      return 'ZH';
    case 'zh-TW':
      return 'ZH';
    case 'en':
      return 'EN-US';
    case 'pt':
      return 'PT-BR';
    default:
      return code.toUpperCase();
  }
}

// ============================================================
//  HTTP 客户端 (支持代理)
// ============================================================

/// 按设置创建 HTTP 客户端。
///
/// Dart 的 HttpClient 默认**不读取系统代理**, 因此谷歌 / OpenAI / DeepL
/// 在国内必须显式配置代理才能访问。
http.Client createHttpClient(String proxy) {
  final hc = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final p = proxy.trim();
  if (p.isNotEmpty) {
    final hostPort = p.replaceFirst(RegExp(r'^https?://'), '');
    hc.findProxy = (uri) => 'PROXY $hostPort';
  }
  return IOClient(hc);
}

// ============================================================
//  腾讯交互翻译 (免密钥, 国内直连, 支持批量)
// ============================================================

class TencentTranslator implements Translator {
  TencentTranslator({http.Client? client}) : _c = client ?? http.Client();
  final http.Client _c;

  /// 这个后端一次性返回全部结果, 不支持流式 (默认实现即返回 null)
  @override
  Stream<List<String>>? translateStream(
    List<String> texts, {
    required String from,
    required String to,
  }) =>
      null;

  @override
  String get name => '腾讯交互翻译';
  @override
  bool get needsKey => false;
  @override
  bool get supportsBatch => true;

  static const _lang = {
    'zh-CN': 'zh',
    'zh-TW': 'zh-TW',
    'en': 'en',
    'ja': 'ja',
    'ko': 'ko',
    'ru': 'ru',
    'fr': 'fr',
    'de': 'de',
    'es': 'es',
    'pt': 'pt',
    'it': 'it',
    'ar': 'ar',
    'th': 'th',
    'vi': 'vi',
    'hi': 'hi',
  };

  @override
  Future<List<String>> translate(List<String> texts,
      {required String from, required String to}) async {
    if (texts.isEmpty) return [];
    final sl = (from == 'auto' || from.isEmpty) ? 'auto' : (_lang[from] ?? 'auto');
    final tl = _lang[to] ?? 'zh';
    final body = utf8.encode(jsonEncode({
      'header': {
        'fn': 'auto_translation',
        'client_key': 'browser-chrome-110.0.0',
        'client_version': '1.0.0',
      },
      'type': 'plain',
      'model_category': 'normal',
      'source': {'lang': sl, 'text_list': texts},
      'target': {'lang': tl},
    }));
    final r = await _c
        .post(
          Uri.parse('https://transmart.qq.com/api/imt'),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw TranslateException('腾讯翻译失败 (HTTP ${r.statusCode})');
    }
    final data = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final code = (data['header'] as Map?)?['ret_code'];
    if (code != 'succ') {
      throw TranslateException('腾讯翻译返回错误: $code');
    }
    final list = (data['auto_translation'] as List?) ?? const [];
    final out = list.map((e) => e?.toString() ?? '').toList();
    while (out.length < texts.length) {
      out.add('');
    }
    return out;
  }
}

// ============================================================
//  谷歌翻译 (免密钥, 单段)
// ============================================================

class GoogleTranslator implements Translator {
  GoogleTranslator({http.Client? client}) : _c = client ?? http.Client();
  final http.Client _c;

  /// 这个后端一次性返回全部结果, 不支持流式 (默认实现即返回 null)
  @override
  Stream<List<String>>? translateStream(
    List<String> texts, {
    required String from,
    required String to,
  }) =>
      null;

  @override
  String get name => '谷歌翻译';
  @override
  bool get needsKey => false;
  @override
  bool get supportsBatch => false;

  Future<String> _one(String text, String from, String to) async {
    final sl = (from == 'auto' || from.isEmpty) ? 'auto' : from;
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': sl,
      'tl': to,
      'dt': 't',
      'q': text,
    });
    final r = await _c.get(uri).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw TranslateException('谷歌翻译失败 (HTTP ${r.statusCode})');
    }
    final data = jsonDecode(utf8.decode(r.bodyBytes));
    final segs = (data as List)[0] as List;
    final buf = StringBuffer();
    for (final s in segs) {
      if (s is List && s.isNotEmpty && s[0] != null) {
        buf.write(s[0].toString());
      }
    }
    return buf.toString();
  }

  @override
  Future<List<String>> translate(List<String> texts,
      {required String from, required String to}) async {
    // 并发但限制在 6 路, 避免触发限流
    final out = List<String>.filled(texts.length, '');
    const concurrency = 6;
    for (var i = 0; i < texts.length; i += concurrency) {
      final end = (i + concurrency > texts.length) ? texts.length : i + concurrency;
      final futures = <Future<void>>[];
      for (var k = i; k < end; k++) {
        final idx = k;
        futures.add(_one(texts[idx], from, to)
            .then((v) => out[idx] = v)
            .catchError((_) => out[idx] = texts[idx]));
      }
      await Future.wait(futures);
    }
    return out;
  }
}

// ============================================================
//  OpenAI 兼容大模型 (质量最佳)
// ============================================================

/// 语言代码 -> 自然语言名称
///
/// 送进大模型的必须是"简体中文"这种语言名, 不能是 "zh-CN" 这种代码 ——
/// 模型看到代号会翻译得莫名其妙, 甚至把代号原样吐回来。
const Map<String, String> kLangNames = {
  'zh-CN': '简体中文',
  'zh-TW': '繁体中文',
  'zh': '中文',
  'en': '英语',
  'ja': '日语',
  'ko': '韩语',
  'ru': '俄语',
  'fr': '法语',
  'de': '德语',
  'es': '西班牙语',
  'pt': '葡萄牙语',
  'it': '意大利语',
  'ar': '阿拉伯语',
  'th': '泰语',
  'vi': '越南语',
  'hi': '印地语',
  'tr': '土耳其语',
  'nl': '荷兰语',
  'pl': '波兰语',
  'uk': '乌克兰语',
};

String langNameOf(String code) => kLangNames[code] ?? code;

class OpenAiTranslator implements Translator {
  OpenAiTranslator({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    http.Client? client,
  }) : _c = client ?? http.Client();

  final String baseUrl;
  final String apiKey;
  final String model;
  final http.Client _c;

  @override
  String get name => 'LLM ($model)';
  @override
  bool get needsKey => true;
  @override
  bool get supportsBatch => true;

  /// 提示词刻意贴住 Hunyuan-MT 的训练格式 ("把下面的文本翻译成X，不要额外解释。"),
  /// 再补上行号约束 —— 屏幕 OCR 是一行一行来的, 行数必须对得上。
  ///
  /// 行号不能省: 大模型偶尔会合并两行短文本, 带行号就能发现并纠正。
  String _systemPrompt(String to) => '把下面的每一行文本翻译成${langNameOf(to)}，'
      '不要额外解释。保持行号顺序逐行输出，格式为 "编号. 译文"。'
      '不要合并、拆分或省略任何行。'
      '数字、代码、URL、专有名词保持原样。'
      '只输出译文，不要任何说明或代码块。';

  String _numbered(List<String> texts) {
    final b = StringBuffer();
    for (var i = 0; i < texts.length; i++) {
      b.writeln('${i + 1}. ${texts[i].replaceAll('\n', ' ')}');
    }
    return b.toString();
  }

  /// 把模型吐出来的文本按 "编号. 译文" 解析进 [out], 返回新填了几个
  int _applyLines(String content, int total, List<String> out) {
    var n = 0;
    for (final line in content.split('\n')) {
      final m = RegExp(r'^\s*(\d+)\s*[.、:：)]\s*(.*)$').firstMatch(line);
      if (m == null) continue;
      final idx = int.tryParse(m.group(1)!);
      if (idx == null || idx < 1 || idx > total) continue;
      final v = m.group(2)!.trim();
      if (v.isEmpty) continue;
      if (out[idx - 1] != v) {
        out[idx - 1] = v;
        n++;
      }
    }
    return n;
  }

  /// 流式翻译: 模型每吐完一行就回吐一次结果。
  ///
  /// 大模型是一个 token 一个 token 生成的, 整屏几十行要十几秒。
  /// 等全部生成完再显示, 用户看到的就是"卡住不动"; 流式能让第一行
  /// 在一秒内出现, 之后源源不断地补上来。
  @override
  Stream<List<String>> translateStream(List<String> texts,
      {required String from, required String to}) async* {
    if (texts.isEmpty) {
      yield <String>[];
      return;
    }
    final url = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';
    final req = http.Request('POST', Uri.parse(url));
    req.headers['Content-Type'] = 'application/json';
    if (apiKey.isNotEmpty) req.headers['Authorization'] = 'Bearer $apiKey';
    req.body = jsonEncode({
      'model': model,
      'temperature': 0,
      'stream': true,
      'messages': [
        {'role': 'system', 'content': _systemPrompt(to)},
        {'role': 'user', 'content': _numbered(texts)},
      ],
    });

    final resp = await _c.send(req).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw TranslateException('LLM 翻译失败 (HTTP ${resp.statusCode})');
    }

    final out = List<String>.from(texts);
    final buf = StringBuffer();
    var lastEmit = 0;
    var got = 0;

    await for (final chunk in resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!chunk.startsWith('data:')) continue;
      final payload = chunk.substring(5).trim();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') break;
      try {
        final j = jsonDecode(payload) as Map<String, dynamic>;
        final ch = (j['choices'] as List?)?.first as Map?;
        final delta = ch?['delta'] as Map?;
        final piece = delta?['content'] as String?;
        if (piece != null && piece.isNotEmpty) buf.write(piece);
      } catch (_) {
        continue; // 心跳之类的非 JSON 行, 忽略
      }
      // 攒够新行就回吐
      final content = buf.toString();
      final done = '\n'.allMatches(content).length;
      if (done > lastEmit) {
        lastEmit = done;
        got += _applyLines(content, texts.length, out);
        if (got > 0) yield List<String>.from(out);
      }
    }
    // 结尾可能没有换行符, 再收一次尾
    got += _applyLines(buf.toString(), texts.length, out);
    if (got > 0) yield List<String>.from(out);
  }

  @override
  Future<List<String>> translate(List<String> texts,
      {required String from, required String to}) async {
    if (texts.isEmpty) return [];
    final numbered = StringBuffer();
    for (var i = 0; i < texts.length; i++) {
      numbered.writeln('${i + 1}. ${texts[i].replaceAll('\n', ' ')}');
    }
    final sys = _systemPrompt(to);
    final url = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';
    final r = await _c
        .post(
          Uri.parse(url),
          headers: {
            'Content-Type': 'application/json',
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'model': model,
            'temperature': 0,
            'messages': [
              {'role': 'system', 'content': sys},
              {'role': 'user', 'content': numbered.toString()},
            ],
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) {
      throw TranslateException('LLM 翻译失败 (HTTP ${r.statusCode})');
    }
    final data = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final content =
        ((data['choices'] as List).first as Map)['message']['content'] as String;

    // 解析 "编号. 译文"
    final out = List<String>.from(texts);
    final n = _applyLines(content, texts.length, out);
    if (n == 0) {
      throw TranslateException('LLM 返回格式无法解析, 已回退原文');
    }
    return out;
  }
}

// ============================================================
//  DeepL
// ============================================================

class DeepLTranslator implements Translator {
  DeepLTranslator({required this.apiKey, required this.free, http.Client? client})
      : _c = client ?? http.Client();
  final String apiKey;
  final bool free;
  final http.Client _c;

  /// 这个后端一次性返回全部结果, 不支持流式 (默认实现即返回 null)
  @override
  Stream<List<String>>? translateStream(
    List<String> texts, {
    required String from,
    required String to,
  }) =>
      null;

  @override
  String get name => 'DeepL';
  @override
  bool get needsKey => true;
  @override
  bool get supportsBatch => true;

  @override
  Future<List<String>> translate(List<String> texts,
      {required String from, required String to}) async {
    if (texts.isEmpty) return [];
    final host = free ? 'api-free.deepl.com' : 'api.deepl.com';
    final r = await _c
        .post(
          Uri.https(host, '/v2/translate'),
          headers: {
            'Authorization': 'DeepL-Auth-Key $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'text': texts,
            'target_lang': _deeplLang(to),
            if (from != 'auto' && from.isNotEmpty) 'source_lang': _deeplLang(from),
          }),
        )
        .timeout(const Duration(seconds: 40));
    if (r.statusCode != 200) {
      throw TranslateException('DeepL 翻译失败 (HTTP ${r.statusCode})');
    }
    final tr = (jsonDecode(utf8.decode(r.bodyBytes))
        as Map<String, dynamic>)['translations'] as List;
    return tr.map((e) => (e as Map)['text']?.toString() ?? '').toList();
  }
}

/// 仅识别不翻译
class NoopTranslator implements Translator {
  /// 这个后端一次性返回全部结果, 不支持流式 (默认实现即返回 null)
  @override
  Stream<List<String>>? translateStream(
    List<String> texts, {
    required String from,
    required String to,
  }) =>
      null;

  @override
  String get name => '不翻译';
  @override
  bool get needsKey => false;
  @override
  bool get supportsBatch => true;
  @override
  Future<List<String>> translate(List<String> texts,
          {required String from, required String to}) async =>
      List<String>.from(texts);
}

// ============================================================
//  离线翻译 (Marian / OPUS-MT, 由 Rust 内核推理)
// ============================================================

class OfflineTranslator implements Translator {
  OfflineTranslator();

  /// 识别阶段推断出的源语言 (OCR 每行都带回实际使用的识别模型)
  String sourceHint = 'auto';

  /// 这个后端一次性返回全部结果, 不支持流式 (默认实现即返回 null)
  @override
  Stream<List<String>>? translateStream(
    List<String> texts, {
    required String from,
    required String to,
  }) =>
      null;

  @override
  String get name => '离线翻译';
  @override
  bool get needsKey => false;
  @override
  bool get supportsBatch => true;

  /// 把 BCP-47 / OCR 语种码归一到模型目录用的短码
  static String normalize(String code) {
    final c = code.toLowerCase();
    final base = c.split(RegExp(r'[-_]')).first;
    switch (base) {
      case 'zh':
      case 'cmn':
      case 'chi':
      case 'ch':
        return 'zh';
      case 'en':
        return 'en';
      case 'ja':
      case 'japan':
        return 'ja';
      case 'ko':
      case 'korean':
        return 'ko';
      case 'ru':
      case 'cyrillic':
        return 'ru';
      case 'fr':
      case 'latin':
        return 'fr';
      case 'de':
        return 'de';
      case 'es':
        return 'es';
      default:
        return base;
    }
  }

  @override
  Future<List<String>> translate(List<String> texts,
      {required String from, required String to}) async {
    final rawSrc = (from == 'auto' || from.isEmpty) ? sourceHint : from;
    final src = normalize(rawSrc);
    final tgt = normalize(to);
    if (src == tgt) {
      // 源与目标一致, 无需翻译
      return List<String>.from(texts);
    }
    final available = MtService.availablePairs;
    final pair = '$src-$tgt';
    if (!available.contains(pair)) {
      throw TranslateException(
          '没有 $pair 方向的离线模型 (已安装: ${available.isEmpty ? "无" : available.join("、")})');
    }
    return MtService.translateBatch(pair, texts);
  }
}

// ============================================================
//  翻译编排器
// ============================================================

class TranslateService {
  final TranslateCache cache = TranslateCache();
  Translator? _translator;
  String _signature = '';

  /// 离线兜底翻译器; 为 null 表示未启用或不可用
  OfflineTranslator? offline;

  /// 上一次翻译是否走了离线兜底
  bool usedOffline = false;

  /// 识别阶段推断出的源语言, 供离线翻译选语言对
  String sourceHint = 'auto';

  Translator build(AppSettings s) {
    final client = createHttpClient(s.proxy);
    switch (s.provider) {
      case TranslateProvider.tencent:
        return TencentTranslator(client: client);
      case TranslateProvider.google:
        return GoogleTranslator(client: client);
      case TranslateProvider.openai:
        return OpenAiTranslator(
          baseUrl: s.openaiBaseUrl,
          apiKey: s.openaiKey,
          model: s.openaiModel,
          client: client,
        );
      case TranslateProvider.deepl:
        return DeepLTranslator(
            apiKey: s.deeplKey, free: s.deeplFree, client: client);
      case TranslateProvider.none:
        return NoopTranslator();
    }
  }

  /// 流式批量翻译: 每翻好几行就回调一次 [onPartial]。
  ///
  /// 返回 null 表示当前翻译器不支持流式 (腾讯/谷歌/DeepL 都是一次性返回),
  /// 调用方应该退回普通 [translateLines]。
  Stream<List<String>>? translateLinesStream(
    List<String> texts, {
    required String from,
    required String to,
  }) {
    final t = _translator;
    if (t == null) return null;
    return t.translateStream(texts, from: from, to: to);
  }

  void ensure(AppSettings s) {
    final sig = '${s.provider.code}|${s.openaiBaseUrl}|${s.openaiModel}'
        '|${s.openaiKey.hashCode}|${s.deeplKey.hashCode}|${s.deeplFree}'
        '|${s.proxy}';
    if (_translator == null || sig != _signature) {
      _translator = build(s);
      _signature = sig;
    }
  }

  Translator get translator => _translator ?? NoopTranslator();

  /// 翻译一组文本行: 去重 + 缓存 + 分批
  Future<Map<int, String>> translateLines(
    List<String> texts, {
    required String from,
    required String to,
  }) async {
    final result = <int, String>{};
    if (texts.isEmpty) return result;

    final t = translator;
    final provider = t.name;
    usedOffline = false;

    // 沿用识别阶段推断出的源语言
    final off = offline;
    if (off != null) off.sourceHint = sourceHint;

    // 1. 去重 + 查缓存
    final pending = <String, List<int>>{};
    for (var i = 0; i < texts.length; i++) {
      final src = texts[i];
      if (src.trim().isEmpty) continue;
      final hit = cache.get(provider, from, to, src);
      if (hit != null) {
        result[i] = hit;
        continue;
      }
      pending.putIfAbsent(src, () => []).add(i);
    }
    if (pending.isEmpty) return result;

    // 2. 请求 (在线优先, 失败自动回退离线)
    final unique = pending.keys.toList();
    final translated = <String, String>{};

    Future<List<String>> callWithFallback(List<String> part) async {
      try {
        return await t.translate(part, from: from, to: to);
      } catch (e) {
        lastError = '$e';
        final o = offline;
        if (o == null) rethrow;
        try {
          final r = await o.translate(part, from: from, to: to);
          usedOffline = true;
          lastError = null;
          return r;
        } catch (e2) {
          lastError = '$e；离线兜底也失败: $e2';
          rethrow;
        }
      }
    }

    if (t.supportsBatch) {
      const chunk = 24;
      for (var i = 0; i < unique.length; i += chunk) {
        final end = (i + chunk > unique.length) ? unique.length : i + chunk;
        final part = unique.sublist(i, end);
        List<String> out;
        try {
          out = await callWithFallback(part);
        } catch (_) {
          out = part; // 最终兜底: 原样返回
        }
        for (var k = 0; k < part.length; k++) {
          translated[part[k]] =
              (k < out.length && out[k].isNotEmpty) ? out[k] : part[k];
        }
      }
    } else {
      // 批量不支持时逐条 (Google 内部已并发)
      List<String> out;
      try {
        out = await callWithFallback(unique);
      } catch (_) {
        out = unique;
      }
      for (var k = 0; k < unique.length; k++) {
        translated[unique[k]] =
            (k < out.length && out[k].isNotEmpty) ? out[k] : unique[k];
      }
    }

    // 3. 回填 + 写缓存
    //    翻译失败时不要写缓存 —— 否则会把原文当成"译文"缓存下来,
    //    下次命中缓存直接返回原文, 看起来像"翻译没执行"。
    final ok = lastError == null;
    for (final entry in pending.entries) {
      final dst = translated[entry.key] ?? entry.key;
      if (ok) {
        cache.put(provider, from, to, entry.key, dst);
      }
      for (final idx in entry.value) {
        result[idx] = dst;
      }
    }
    return result;
  }

  String? lastError;
}
