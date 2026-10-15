// 基础单元测试: 验证不依赖原生库的纯 Dart 逻辑

import 'package:dpg_app/core/models.dart';
import 'package:dpg_app/core/translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppSettings JSON 往返', () {
    final s = AppSettings();
    s.ocrLang = 'korean';
    s.targetLang = 'zh-CN';
    s.provider = TranslateProvider.openai;
    s.detLimitSide = 1280;

    final back = AppSettings.fromJson(s.toJson());
    expect(back.ocrLang, 'korean');
    expect(back.targetLang, 'zh-CN');
    expect(back.provider, TranslateProvider.openai);
    expect(back.detLimitSide, 1280);
  });

  test('OcrResult 反序列化', () {
    final r = OcrResult.fromJson({
      'lines': [
        {
          'text': 'Hello',
          'score': 0.98,
          'det_score': 0.9,
          'points': [
            [10, 20],
            [110, 20],
            [110, 50],
            [10, 50]
          ],
          'lang': 'ch',
          'rotated': false,
        }
      ],
      'image_width': 200,
      'image_height': 100,
      'det_ms': 12.5,
      'cls_ms': 1.0,
      'rec_ms': 8.0,
      'total_ms': 21.5,
    });
    expect(r.lines.length, 1);
    expect(r.lines.first.text, 'Hello');
    expect(r.lines.first.bounds.width, 100);
    expect(r.lines.first.bounds.height, 30);
    expect(r.totalMs, 21.5);
  });

  test('翻译缓存 LRU 命中', () {
    final c = TranslateCache(capacity: 2);
    c.put('bing', 'auto', 'zh-CN', 'a', '甲');
    c.put('bing', 'auto', 'zh-CN', 'b', '乙');
    expect(c.get('bing', 'auto', 'zh-CN', 'a'), '甲');
    c.put('bing', 'auto', 'zh-CN', 'c', '丙');
    // a 刚被访问过, 应仍在; b 被淘汰
    expect(c.get('bing', 'auto', 'zh-CN', 'a'), '甲');
    expect(c.get('bing', 'auto', 'zh-CN', 'b'), isNull);
    expect(c.get('bing', 'auto', 'zh-CN', 'c'), '丙');
  });

  test('不翻译模式原样返回', () async {
    final t = NoopTranslator();
    final out = await t.translate(['a', 'b'], from: 'auto', to: 'zh-CN');
    expect(out, ['a', 'b']);
  });

  // ---- 离线翻译的源语言推断 ----
  // 这是实战中踩到的坑: 中文识别模型同时覆盖英文, 识别英文时 lang 仍为 "ch",
  // 若按"识别模型名"推断源语言就会把英文误判成中文, 与目标语言相同后被判定
  // "无需翻译"而直接返回原文。必须按识别出的文字内容判断。

  OcrResult mk(List<String> texts, {String lang = 'ch'}) => OcrResult(
        lines: texts
            .map((t) => OcrLine(
                  text: t,
                  score: 1,
                  detScore: 1,
                  points: const [
                    Offset(0, 0),
                    Offset(10, 0),
                    Offset(10, 10),
                    Offset(0, 10)
                  ],
                  lang: lang,
                  rotated: false,
                ))
            .toList(),
        imageWidth: 100,
        imageHeight: 100,
        detMs: 0,
        clsMs: 0,
        recMs: 0,
        totalMs: 0,
      );

  test('英文文本即使来自中文识别模型也应判为 en', () {
    final r = mk([
      'Full screen OCR recognition and translation.',
      'Press Escape to exit.',
    ]);
    // 模型名是 ch, 但内容全是拉丁字母
    expect(r.dominantLang, 'ch');
    expect(r.detectedSourceLang, 'en');
  });

  test('中文文本判为 zh', () {
    final r = mk(['全屏识别翻译软件', '识别速度很快']);
    expect(r.detectedSourceLang, 'zh');
  });

  test('日文优先于汉字判定 (含假名)', () {
    final r = mk(['全画面OCR認識と翻訳', 'これはテストです']);
    expect(r.detectedSourceLang, 'ja');
  });

  test('韩文 / 俄文 / 泰文', () {
    expect(mk(['전체 화면 OCR']).detectedSourceLang, 'ko');
    expect(mk(['Полноэкранное распознавание']).detectedSourceLang, 'ru');
    expect(mk(['การรู้จำอักขระ']).detectedSourceLang, 'th');
  });

  test('纯数字符号无法判断时返回 auto', () {
    expect(mk(['12345', '---']).detectedSourceLang, 'auto');
  });

  test('离线翻译器: 源与目标相同则原样返回', () async {
    final t = OfflineTranslator()..sourceHint = 'zh';
    final out = await t.translate(['你好'], from: 'auto', to: 'zh-CN');
    expect(out, ['你好']);
  });

  test('离线翻译器: 语言码归一化', () {
    expect(OfflineTranslator.normalize('ch'), 'zh');
    expect(OfflineTranslator.normalize('zh-CN'), 'zh');
    expect(OfflineTranslator.normalize('en-US'), 'en');
    expect(OfflineTranslator.normalize('korean'), 'ko');
  });
}
