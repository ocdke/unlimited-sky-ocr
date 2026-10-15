// 应用状态与流程控制

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'core/frame_diff.dart';
import 'core/log.dart';
import 'core/models.dart';
import 'core/mt_service.dart';
import 'core/native.dart';
import 'core/ocr_service.dart';
import 'core/screen_capture.dart' as cap;
import 'core/translator.dart';

/// 界面阶段
enum AppPhase {
  /// 控制面板
  panel,

  /// 全屏截图中, 等待框选
  selecting,

  /// 正在识别/翻译
  working,

  /// 展示结果
  result,

  /// 实时识别中 (无冻屏, 透明覆盖层)
  realtime,
}

/// 识别模式
enum CaptureMode {
  snip,

  /// 全屏一次性翻译
  full,

  /// 框选一个区域, 然后进入实时翻译
  realtimeRegion,
}

class AppController extends ChangeNotifier {
  AppController();

  AppSettings settings = AppSettings();
  final TranslateService translateService = TranslateService();

  AppPhase phase = AppPhase.panel;
  CaptureMode mode = CaptureMode.snip;

  CapturedFrame? frame;
  ui.Image? frameImage;

  /// 当前窗口的 DPI 缩放 (物理像素 -> 逻辑像素)
  double get windowDpr {
    try {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isNotEmpty) {
        final v = views.first.devicePixelRatio;
        if (v > 0) return v;
      }
    } catch (_) {}
    return 1.0;
  }

  /// 实时模式的帧差检测器 (只识别画面变化的区域)
  final FrameDiff _rtDiff = FrameDiff();
  int realtimeSkipped = 0;
  double realtimeDiffRatio = 0;

  /// 文字区域**之外**的变化占比 (判断是不是换了窗口)
  double realtimeOutsideRatio = 0;
  double realtimeDirtyFrac = 0;

  /// 只重识别变化行的轮数 / 做了完整检测的轮数
  int realtimeRecOnly = 0;
  int realtimeFullScans = 0;
  DateTime _rtLastFullDet = DateTime.fromMillisecondsSinceEpoch(0);

  static int _rtOrder(OcrLine a, OcrLine b) {
    final d = a.bounds.top.compareTo(b.bounds.top);
    return d != 0 ? d : a.bounds.left.compareTo(b.bounds.left);
  }

  /// 框选区域 (图像像素坐标)
  Rect? selection;

  OcrResult ocr = OcrResult.empty();
  Map<int, String> translations = {};

  String status = '就绪';
  String? error;
  double lastTranslateMs = 0;
  bool engineReady = false;

  /// 离线翻译是否可用 (模型目录可扫描 + 引擎创建成功)
  bool offlineReady = false;
  List<String> offlinePairs = const [];
  String? offlineError;
  bool lastUsedOffline = false;

  /// 每行译文的显示状态: true = 显示原文, 缺省/false = 显示译文。
  /// 左键单击译文标签可切换。
  final Map<int, bool> labelShowOriginal = {};

  /// 某行当前应显示的文字
  String labelText(int i) {
    if (i < 0 || i >= ocr.lines.length) return '';
    final src = ocr.lines[i].text;
    final dst = translations[i] ?? src;
    return (labelShowOriginal[i] ?? false) ? src : dst;
  }

  /// 该行是否已切换为显示原文
  bool isShowingOriginal(int i) => labelShowOriginal[i] ?? false;

  void toggleLabelDisplay(int i) {
    labelShowOriginal[i] = !(labelShowOriginal[i] ?? false);
    notifyListeners();
  }

  void setLabelDisplay(int i, bool original) {
    labelShowOriginal[i] = original;
    notifyListeners();
  }

  void setAllLabelsDisplay(bool original) {
    for (var i = 0; i < ocr.lines.length; i++) {
      labelShowOriginal[i] = original;
    }
    notifyListeners();
  }

  /// 复制某一行的原文或译文
  Future<void> copyLine(int i, {required bool original}) async {
    if (i < 0 || i >= ocr.lines.length) return;
    final t = original ? ocr.lines[i].text : (translations[i] ?? ocr.lines[i].text);
    await Clipboard.setData(ClipboardData(text: t));
    status = '已复制${original ? "原文" : "译文"}: $t';
    notifyListeners();
  }

  // ------------------------------------------------------------
  //  实时翻译
  // ------------------------------------------------------------

  bool realtimeActive = false;
  bool realtimePaused = false;
  /// 实时模式的识别区域 (图像坐标); null = 全屏
  Rect? realtimeRegion;
  bool realtimeBusy = false;
  int realtimeRounds = 0;
  double realtimeLastMs = 0;
  /// 鼠标穿透 (true = 点击直接落到下面的窗口, 不干扰用户操作)
  bool mouseThrough = true;
  Timer? _rtTimer;
  bool _rtPickingRegion = false;

  /// 按**每行**的语言分组翻译。
  ///
  /// 全屏实时翻译几乎必然中英混排, 用"全局主导语言"会把英文行也当成中文,
  /// 判定"与目标语言相同"而整片跳过 —— 表现就是英文行没有译文。
  ///
  /// 顺序: 缓存 -> 在线 -> 离线。缓存命中是实时模式能跑快的关键:
  /// 画面稳定时同一批文本反复出现, 不该每次都去请求。
  Future<Map<int, String>> translateLinesPerLang(List<OcrLine> lines,
      {void Function(Map<int, String> partial)? onPartial}) async {
    final out = <int, String>{};
    if (lines.isEmpty) return out;
    final target = OfflineTranslator.normalize(settings.targetLang);

    // 1) 逐行判语言, 先吃缓存
    final byLang = <String, Map<String, List<int>>>{}; // lang -> text -> 行号
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i].text;
      final lang = detectScript(text);
      if (lang == 'auto' || OfflineTranslator.normalize(lang) == target) {
        continue; // 已经是目标语言, 不需要翻译
      }
      final hit = translateService.cache
          .get('lang:$lang', lang, settings.targetLang, text);
      if (hit != null) {
        out[i] = hit;
        continue;
      }
      byLang.putIfAbsent(lang, () => <String, List<int>>{})
          .putIfAbsent(text, () => <int>[])
          .add(i);
    }

    // 2) 已经是目标语言的行不用翻译 —— 原样返回。
    //    整屏扫描里常常一大半是中文, 全送进模型既慢又挤占上下文。
    final tgtScript = detectScript(
        TargetLang.labelFor(settings.targetLang));
    for (final entry in byLang.entries.toList()) {
      final keep = <String, List<int>>{};
      for (final kv in entry.value.entries) {
        if (detectScript(kv.key) == tgtScript) {
          for (final i in kv.value) {
            out[i] = kv.key;
          }
        } else {
          keep[kv.key] = kv.value;
        }
      }
      if (keep.isEmpty) {
        byLang.remove(entry.key);
      } else {
        byLang[entry.key] = keep;
      }
    }

    // 3) 每种语言只对"没缓存的文本"发一次请求
    for (final entry in byLang.entries) {
      final lang = entry.key;
      final texts = entry.value.keys.toList();
      final idxs = entry.value.values.toList();

      List<String> res = texts;
      var ok = false;

      // 在线优先
      if (settings.provider != TranslateProvider.none) {
        try {
          translateService.ensure(settings);
          translateService.sourceHint = lang;
          translateService.offline = null;

          // 流式优先: 本地大模型整屏几十行要十几秒, 边翻边显示才不至于"卡住"
          final st = translateService
              .translateLinesStream(texts, from: lang, to: settings.targetLang);
          if (st != null && onPartial != null) {
            var last = <String>[];
            await for (final part in st.timeout(
                Duration(seconds: settings.localAi ? 180 : 30))) {
              last = part;
              // 把这一批的部分结果映射回全局行号, 立刻刷到界面上
              final merged = Map<int, String>.from(out);
              for (var k = 0; k < idxs.length; k++) {
                for (final gi in idxs[k]) {
                  final v = k < part.length ? part[k] : texts[k];
                  if (v.isNotEmpty) merged[gi] = v;
                }
              }
              onPartial(merged);
            }
            res = [for (var k = 0; k < texts.length; k++) last.length > k ? last[k] : texts[k]];
            ok = res.any((t) => t.isNotEmpty && !texts.contains(t)) ||
                last.isNotEmpty;
          } else {
            final m = await translateService
                .translateLines(texts, from: lang, to: settings.targetLang)
                // 本地大模型跑在自家显卡上, 一次批量翻译几十行要十几秒很正常,
                // 用在线 API 的 6 秒会把结果直接掐掉 —— 所以按来源给不同额度。
                .timeout(Duration(seconds: settings.localAi ? 180 : 6));
            res = [for (var k = 0; k < texts.length; k++) m[k] ?? texts[k]];
            ok = translateService.lastError == null;
          }
        } catch (e) {
          Log.log('在线翻译失败($lang): $e');
        }
      }

      // 离线兜底
      if (!ok && settings.offlineEnabled && offlineReady) {
        try {
          final off = OfflineTranslator()..sourceHint = lang;
          res = await off
              .translate(texts, from: lang, to: settings.targetLang)
              .timeout(const Duration(seconds: 12));
          ok = true;
          usedOffline = true;
        } catch (e) {
          Log.log('离线翻译失败($lang -> $target): $e');
        }
      }

      for (var k = 0; k < texts.length; k++) {
        final dst = k < res.length ? res[k] : texts[k];
        if (ok) {
          translateService.cache
              .put('lang:$lang', lang, settings.targetLang, texts[k], dst);
        }
        for (final i in idxs[k]) {
          out[i] = dst;
        }
      }
    }
    return out;
  }

  bool usedOffline = false;

  /// 实时模式的翻译代次: 翻译是异步的, 结果回来时画面可能已经变了,
  /// 用代次号丢弃过期结果, 避免"旧译文盖新画面"。
  int _rtTranslateGen = 0;

  /// 实时模式下**不等待**翻译完成。
  /// 网络请求动辄几秒, 一旦 await 就会把整个刷新循环拖死 (实测单轮 7.8 秒)。
  /// 实时翻译是否已有请求在飞 (同一时刻只允许一个)
  bool _rtTranslating = false;

  /// 翻译期间又来了新画面时, 记下来等当前这次做完再补一次
  List<OcrLine>? _rtPendingSnapshot;

  /// 上一次送去翻译的文本指纹
  String _rtLastTextKey = '';

  /// 触发一次实时翻译。
  ///
  /// 原来这里只用一个"代数"把过期**结果**丢掉, 但请求该发还是发 ——
  /// 桌面是动态壁纸 / 有闪烁光标时, 画面每轮都在变, 于是每 120ms 就发一次
  /// 翻译请求, 一次要跑二三十秒, 几百个请求全堆在显卡上排队, 最后集体超时。
  /// 表现就是"显卡狂跑但翻译奇慢"。
  ///
  /// 现在两道闸: 文本没变不发; 上一个没做完不发。
  void _kickRealtimeTranslate(List<OcrLine> snapshot) {
    if (!realtimeActive) return;

    // 闸一: 文字一个字都没动就别翻。
    // 动画壁纸、视频、闪烁的光标会让像素一直在变, 但屏幕上的**文字**
    // 往往完全没变 —— 按像素判断会白白重翻几百遍。
    final key = snapshot.map((l) => l.text).join('\u0001');
    if (key == _rtLastTextKey && translations.isNotEmpty) return;

    // 闸二: 上一个请求还在跑就排队, 不要并发发新的。
    if (_rtTranslating) {
      _rtPendingSnapshot = snapshot;
      return;
    }

    _rtLastTextKey = key;
    _rtTranslating = true;
    final gen = ++_rtTranslateGen;

    unawaited(() async {
      try {
        final m = await translateLinesPerLang(snapshot,
            onPartial: (partial) {
          if (gen != _rtTranslateGen || !realtimeActive) return;
          translations = partial;
          notifyListeners();
        });
        if (gen == _rtTranslateGen && realtimeActive) {
          translations = m;
          notifyListeners();
        }
      } catch (e) {
        Log.log('实时翻译异常: $e');
      } finally {
        _rtTranslating = false;
        final pending = _rtPendingSnapshot;
        _rtPendingSnapshot = null;
        // 期间画面又变了就补一次; 文本相同的会被闸一挡掉
        if (pending != null && realtimeActive) {
          _kickRealtimeTranslate(pending);
        }
      }
    }());
  }

  int _dpr() {
    try {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isNotEmpty) {
        final v = views.first.devicePixelRatio;
        if (v > 0) return v.toInt() == v ? v.toInt() : v.ceil();
      }
    } catch (_) {}
    return 1;
  }

  /// 带超时的窗口操作。
  ///
  /// Windows 上 window_manager 的某些调用 (置顶 / 跳过任务栏 / 背景色 /
  /// 透明效果) 会在特定时机不再返回, 一旦 await 卡住, 后面的逻辑全都执行不到。
  /// 这些操作本来就互不依赖, 超时后继续走即可。
  Future<bool> _win(String what, Future<void> Function() op,
      {int timeoutMs = 500}) async {
    try {
      await op().timeout(Duration(milliseconds: timeoutMs));
      Log.log('窗口操作 OK: $what');
      return true;
    } catch (e) {
      Log.log('窗口操作 失败/超时: $what -> $e');
      return false;
    }
  }

  static String _r(Rect? r) => r == null
      ? 'null'
      : '(${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)},'
          '${r.width.toStringAsFixed(0)}x${r.height.toStringAsFixed(0)})';

  /// 进入实时翻译。
  /// [region] 为 null 时全屏识别; 否则只识别该矩形 (图像像素坐标)。
  Future<void> startRealtime({Rect? region}) async {
    Log.log('startRealtime 进入: active=$realtimeActive engineReady=$engineReady region=$region');
    if (realtimeActive || !engineReady) {
      Log.log('startRealtime 提前返回');
      return;
    }
    realtimeRegion = region;
    realtimeActive = true;
    realtimePaused = false;
    realtimeRounds = 0;
    realtimeSkipped = 0;
    realtimeRecOnly = 0;
    realtimeFullScans = 0;
    _rtLastFullDet = DateTime.fromMillisecondsSinceEpoch(0);
    _rtDiff.reset();
    error = null;
    ocr = OcrResult.empty();
    translations = {};
    labelShowOriginal.clear();
    frame = null;
    frameImage?.dispose();
    frameImage = null;

    // 窗口: 覆盖整屏 + 透明 + 置顶 + 鼠标穿透。
    // 先 hide 再改尺寸, 所以你看不到"最大化"的跳变, 覆盖层是悄悄出现的。
    if (!Platform.isAndroid) {
      if (_savedBounds == null) {
        try {
          _savedBounds = await windowManager
              .getBounds()
              .timeout(const Duration(milliseconds: 900));
          Log.log('保存原始窗口: ${_r(_savedBounds)}');
        } catch (e) {
          Log.log('读取原始窗口失败: $e');
        }
      }
      await _enterOverlayWindow();
      await _applyMouseThrough(true);
    }

    phase = AppPhase.realtime;
    status = region == null ? '实时翻译中 (全屏)' : '实时翻译中 (选区)';
    Log.log('startRealtime 完成, phase=$phase 捕获排除=$captureExcluded');
    notifyListeners();
    _scheduleRealtime(60);
  }

  /// 是否成功把自己从捕获中排除 (失败说明系统版本过低)
  bool captureExcluded = false;

  Future<void> _applyMouseThrough(bool through) async {
    if (Platform.isAndroid) return;
    try {
      await windowManager
          .setIgnoreMouseEvents(through)
          .timeout(const Duration(milliseconds: 900));
      mouseThrough = through;
      Log.log('鼠标穿透 -> $through');
    } catch (e) {
      Log.log('设置鼠标穿透失败: $e');
    }
    await _win('alwaysOnTop(keep)', () => windowManager.setAlwaysOnTop(true));
    notifyListeners();
  }

  /// 临时关闭鼠标穿透, 以便点击界面上的按钮
  Future<void> toggleMouseThrough() async {
    await _applyMouseThrough(!mouseThrough);
    status = mouseThrough ? '已恢复鼠标穿透' : '已暂停穿透, 可以点击按钮 (再按一次恢复)';
    notifyListeners();
  }

  void _scheduleRealtime(int delayMs) {
    _rtTimer?.cancel();
    if (!realtimeActive) return;
    _rtTimer = Timer(Duration(milliseconds: delayMs), _realtimeTick);
  }

  Future<void> _realtimeTick() async {
    if (!realtimeActive) return;
    if (realtimePaused || realtimeBusy) {
      _scheduleRealtime(settings.realtimeIntervalMs);
      return;
    }
    realtimeBusy = true;
    final sw = Stopwatch()..start();
    try {
      final f = await cap.captureFullScreen(devicePixelRatio: _dpr().toDouble());
      final region = realtimeRegion ??
          Rect.fromLTWH(0, 0, f.width.toDouble(), f.height.toDouble());

      // ---- 帧差检测 ----
      // 画面没动就直接跳过 (整屏 OCR 要 1 秒以上, 而绝大多数帧都是静止的),
      // 这是"刷新慢、卡好几秒"的根治办法。
      // 把上一次识别到的文字框作为"关心区域"传进去。
      // 动态壁纸 / 视频 / 闪烁光标会让大片像素一直变, 但文字往往一动没动;
      // 不做这个限制的话, 实时模式每 120ms 就整屏重来一遍, 显卡白烧。
      final textRects = <Rect>[
        for (final l in ocr.lines)
          if (l.points.isNotEmpty)
            () {
              var l2 = l.points.first.dx, t2 = l.points.first.dy;
              var r2 = l2, b2 = t2;
              for (final p2 in l.points) {
                if (p2.dx < l2) l2 = p2.dx;
                if (p2.dy < t2) t2 = p2.dy;
                if (p2.dx > r2) r2 = p2.dx;
                if (p2.dy > b2) b2 = p2.dy;
              }
              return Rect.fromLTRB(l2, t2, r2, b2);
            }()
      ];
      final diff = _rtDiff.compare(
        f.bgra,
        f.width,
        f.height,
        f.width * 4,
        textRects: textRects,
      );
      realtimeDiffRatio = diff.ratio;
      realtimeOutsideRatio = diff.outsideRatio;
      final screenArea = f.width * f.height;
      final dirtyFrac =
          (diff.dirty.width * diff.dirty.height) / (screenArea <= 0 ? 1 : screenArea);
      realtimeDirtyFrac = dirtyFrac;

      // 桌面总有零星动画 (光标闪烁、进度条、壁纸微动): 它们各自只占几个格子,
      // 但并成一个包围盒就可能铺满整屏, 于是每轮都在做大片 OCR。
      // 判据: 变化格子占比很小、包围盒却很大 -> 判定为噪声, 忽略。
      final noise = diff.ratio < 0.02 && dirtyFrac > 0.35;

      if ((!diff.changed || noise) && ocr.lines.isNotEmpty && !_rtForceRescan) {
        realtimeSkipped++;
        realtimeLastMs = sw.elapsedMilliseconds.toDouble();
        // 标题里同步一下进度 (纯 Win32 调用, 不触发界面重建)
        _updatePerfTitle();
        // 注意: 这里**不**刷新界面 —— 没有东西要改, 刷了纯属浪费
        _scheduleRealtime(settings.realtimeIntervalMs);
        return;
      }

      // 只识别"变了"的那块 (和实时区域求交); 变化太大就整块重来
      final dirty = diff.dirty;
      final prev = ocr.lines;
      final overlapping =
          prev.where((l) => dirty.overlaps(l.bounds)).toList();
      final rescanMs = settings.realtimeRescanMs;
      final sinceFull =
          DateTime.now().difference(_rtLastFullDet).inMilliseconds;
      // 用户设的强制重扫间隔; 0 = 只在画面变化时扫描, 从不强制
      final forceFull = rescanMs > 0 && sinceFull > rescanMs;

      // 大多数时候画面只有几行在变 (字幕、聊天、日志)。
      // 这种情况复用上一轮的框、只重新识别那几行, **完全跳过检测** ——
      // 检测 + 全量识别是每轮最贵的部分, 跳过它单轮开销能降一个数量级。
      final wantFull =
          overlapping.isEmpty || diff.ratio > 0.06 || forceFull || _rtForceRescan;

      late final OcrResult res;
      final List<OcrLine> lines;

      if (!wantFull) {
        final rects = <List<double>>[];
        for (final l in overlapping) {
          final b = l.bounds;
          final x0 = (b.left - 6).clamp(0.0, f.width.toDouble());
          final y0 = (b.top - 4).clamp(0.0, f.height.toDouble());
          final x1 = (b.right + 6).clamp(0.0, f.width.toDouble());
          final y1 = (b.bottom + 4).clamp(0.0, f.height.toDouble());
          if (x1 - x0 < 4 || y1 - y0 < 4) continue;
          rects.add([x0, y0, x1 - x0, y1 - y0]);
        }
        if (rects.isEmpty) {
          realtimeSkipped++;
          realtimeLastMs = sw.elapsedMilliseconds.toDouble();
          _updatePerfTitle();
          _scheduleRealtime(settings.realtimeIntervalMs);
          return;
        }
        res = await OcrService.recognizeRects(
            f.bgra, f.width, f.height, f.width * 4, rects,
            lang: settings.ocrLang);
        final kept = prev.where((l) => !overlapping.contains(l)).toList();
        lines = <OcrLine>[...kept, ...res.lines]..sort(_rtOrder);
        realtimeRecOnly++;
      } else {
        _rtLastFullDet = DateTime.now();
        realtimeFullScans++;
        if (_rtForceRescan) {
          _rtForceRescan = false;
          _rtDiff.reset(); // 帧差基线也重置, 免得下一轮又判成"没变"
        }
        var target = dirty.intersect(region);
        final regionArea = region.width * region.height;
        if (target.width < 12 ||
            target.height < 12 ||
            target.width * target.height > regionArea * 0.75) {
          target = region;
        }
        final x = target.left.round().clamp(0, f.width - 1);
        final y = target.top.round().clamp(0, f.height - 1);
        final w = target.width.round().clamp(1, f.width - x);
        final h = target.height.round().clamp(1, f.height - y);
        final isFull = (x == 0 && y == 0 && w == f.width && h == f.height);
        final pixels = isFull ? f.bgra : cropBgra(f, x, y, w, h);

        res = f.isRgba
            ? await OcrService.recognizeRgba(pixels, w, h, w * 4,
                lang: OcrLang.modelFor(settings.ocrLang),
                textScore: settings.textScore,
                noiseLevel: settings.noiseLevel,
                autoMultilang: false,
                detLimitSide: settings.detLimitSide,
                minLineHeight: settings.minLineHeight,
                maxLines: settings.realtimeMaxLines)
            : await OcrService.recognizeBgra(pixels, w, h, w * 4,
                lang: OcrLang.modelFor(settings.ocrLang),
                textScore: settings.textScore,
                noiseLevel: settings.noiseLevel,
                autoMultilang: false,
                detLimitSide: settings.detLimitSide,
                minLineHeight: settings.minLineHeight,
                maxLines: settings.realtimeMaxLines);

        final fresh = res.lines
            .map((l) => OcrLine(
                  text: l.text,
                  score: l.score,
                  detScore: l.detScore,
                  points: l.points
                      .map((o) => Offset(o.dx + x, o.dy + y))
                      .toList(),
                  lang: l.lang,
                  rotated: l.rotated,
                ))
            .toList();
        final box =
            Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());
        final kept =
            isFull ? <OcrLine>[] : prev.where((l) => !box.overlaps(l.bounds)).toList();
        lines = <OcrLine>[...kept, ...fresh]..sort(_rtOrder);
      }

      ocr = OcrResult(
        lines: lines,
        imageWidth: f.width,
        imageHeight: f.height,
        detMs: res.detMs,
        clsMs: res.clsMs,
        recMs: res.recMs,
        totalMs: res.totalMs,
      );

      // 翻译: 后台异步进行, **不阻塞刷新循环**。
      // 译文有 LRU 缓存, 画面稳定时几乎瞬间返回。
      translateService.lastError = null;
      usedOffline = false;
      if (lines.isNotEmpty && settings.provider != TranslateProvider.none) {
        if (!identical(_rtLastLines, lines)) {
          _rtLastLines = lines;
          _kickRealtimeTranslate(lines);
        }
      } else {
        translations = {};
      }

      realtimeRounds++;
      realtimeLastMs = sw.elapsedMilliseconds.toDouble();
      status = '实时翻译中 · 第 $realtimeRounds 轮 · '
          '识别 ${res.totalMs.toStringAsFixed(0)}ms · '
          '共 ${realtimeLastMs.toStringAsFixed(0)}ms · ${lines.length} 行'
          '${realtimeSkipped > 0 ? " · 静止跳过 $realtimeSkipped 次" : ""}';
      _rtNeedNotify = true;
      _updatePerfTitle();
    } catch (e) {
      error = '实时翻译出错: $e';
      Log.log('实时轮次异常: $e');
      _rtNeedNotify = true;
    } finally {
      realtimeBusy = false;
      // 画面没变时不刷新界面 —— 刷新本身也是开销, 而且没有任何东西要改
      if (_rtNeedNotify) {
        _rtNeedNotify = false;
        notifyListeners();
      }
      if (realtimeActive) _scheduleRealtime(settings.realtimeIntervalMs);
    }
  }

  bool _rtNeedNotify = false;
  int _lastTitleMs = 0;
  /// 按了"立刻重新扫描"快捷键 -> 下一轮无条件整屏重来
  bool _rtForceRescan = false;
  List<OcrLine>? _rtLastLines;

  /// 把实时性能指标写进窗口标题, 便于外部观察 (也方便排查卡顿)
  void _updatePerfTitle() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTitleMs < 400) return;
    _lastTitleMs = now;
    try {
      windowManager.setTitle(
          'DPG 轮$realtimeRounds 跳过$realtimeSkipped '
          '仅识别$realtimeRecOnly 全扫$realtimeFullScans '
          '差${(realtimeDiffRatio * 100).toStringAsFixed(2)}% '
          '${realtimeLastMs.toStringAsFixed(0)}ms 行${ocr.lines.length}');
    } catch (_) {}
    Log.log('实时轮次 $realtimeRounds: 跳过=$realtimeSkipped '
        '仅识别=$realtimeRecOnly 全扫=$realtimeFullScans '
        '差异=${(realtimeDiffRatio * 100).toStringAsFixed(3)}% '
              '域外=${(realtimeOutsideRatio * 100).toStringAsFixed(1)}% '
        '脏框=${(realtimeDirtyFrac * 100).toStringAsFixed(1)}% '
        '本轮=${realtimeLastMs.toStringAsFixed(0)}ms 行=${ocr.lines.length} '
        '缓存=${translateService.cache.length}');
  }

  void toggleRealtimePause() {
    realtimePaused = !realtimePaused;
    status = realtimePaused ? '实时翻译已暂停' : '实时翻译继续';
    notifyListeners();
  }

  /// 瞬间冻结: 停止识别, 并立刻恢复鼠标点击, 让你可以直接操作译文。
  ///
  /// 冻结后:
  ///   * 左键点某条译文 -> 在原文 / 译文之间切换
  ///   * 右键点某条译文 -> 菜单 (只看原文 / 只看译文 / 复制原文 / 复制译文 / 复制全部)
  /// 再按一次同一个快捷键继续实时识别。
  Future<void> toggleRealtimeFreeze() async {
    if (!realtimeActive) return;
    if (realtimePaused) {
      await _applyMouseThrough(true);
      realtimePaused = false;
      status = '实时翻译继续';
      _scheduleRealtime(60);
    } else {
      realtimePaused = true;
      _rtTimer?.cancel();
      _rtTimer = null;
      await _applyMouseThrough(false); // 关键: 让点击落到我们身上
      status = '已冻结 · 左键切换原文/译文, 右键出菜单 (复制等)';
    }
    notifyListeners();
  }

  /// 立刻重新扫描整个屏幕并刷新翻译。
  ///
  /// 实时模式默认只在"画面变了"的时候才重新识别, 所以静止画面上的内容
  /// 不会被反复扫 —— 按一下这个就能手动强制扫一遍。
  Future<void> forceRescan() async {
    if (!realtimeActive) {
      status = '先开启实时翻译, 再按这个键强制重扫';
      notifyListeners();
      return;
    }
    realtimePaused = false;
    _rtForceRescan = true;
    _rtDiff.reset();
    Log.log('强制重扫整屏');
    status = '正在重新扫描整屏…';
    notifyListeners();
    // 立刻插一轮, 不用等下一个定时器
    _scheduleRealtime(10);
  }

  // ------------------------------------------------------------
  //  原生文件 / 目录选择
  // ------------------------------------------------------------

  /// 弹出系统"打开文件"对话框。取消返回 null。
  Future<String?> pickFilePath({
    String kind = '',
    String title = '选择文件',
    String initial = '',
  }) async {
    try {
      final k = kind.toNativeUtf8();
      final t = title.toNativeUtf8();
      final i = initial.toNativeUtf8();
      try {
        final r = NativeDpg.instance.pickFile(k, t, i);
        if (r == nullptr) return null;
        final out = r.toDartString();
        NativeDpg.instance.stringFree(r);
        return out;
      } finally {
        malloc.free(k);
        malloc.free(t);
        malloc.free(i);
      }
    } catch (e) {
      Log.log('文件对话框失败: $e');
      return null;
    }
  }

  /// 弹出系统"选择文件夹"对话框。取消返回 null。
  Future<String?> pickDirPath({
    String title = '选择文件夹',
    String initial = '',
  }) async {
    try {
      final t = title.toNativeUtf8();
      final i = initial.toNativeUtf8();
      try {
        final r = NativeDpg.instance.pickFolder(t, i);
        if (r == nullptr) return null;
        final out = r.toDartString();
        NativeDpg.instance.stringFree(r);
        return out;
      } finally {
        malloc.free(t);
        malloc.free(i);
      }
    } catch (e) {
      Log.log('目录对话框失败: $e');
      return null;
    }
  }

  // ------------------------------------------------------------
  //  开机自启的校正
  // ------------------------------------------------------------

  /// 自启注册表里记的路径和当前 exe 不一致时改写它。
  ///
  /// 用户经常把装好的目录整个剪切到别的盘 (D:\xxx → E:\yyy), 或者重装到
  /// 新位置 —— 这时 Run 键里还是旧路径, 开机自然起不来, 而且没有任何提示。
  Future<void> _repairAutostart() async {
    if (Platform.isAndroid || !settings.autoStart) return;
    try {
      final real = Platform.resolvedExecutable;
      final registered = await _readAutostartPath();
      if (registered == null) {
        // 开关是开的但注册表里没有 → 补写
        await _writeAutostart(real);
        Log.log('开机自启项缺失, 已按当前路径补写: $real');
      } else if (registered.toLowerCase() != real.toLowerCase()) {
        await _writeAutostart(real);
        Log.log('开机自启路径已校正: $registered → $real');
      }
    } catch (e) {
      Log.log('校正开机自启失败: $e');
    }
  }

  Future<String?> _readAutostartPath() async {
    final r = await Process.run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
      '/v',
      'UnlimitedSkyOCR',
    ], runInShell: false).timeout(const Duration(seconds: 5));
    if (r.exitCode != 0) return null;
    final m = RegExp(r'REG_SZ\s+(.+)$', multiLine: true)
        .firstMatch(r.stdout.toString());
    if (m == null) return null;
    // 值形如 "C:\path\app.exe" --autostart
    return m.group(1)!.trim().replaceAll('"', '').split(' --').first.trim();
  }

  Future<void> _writeAutostart(String exe) async {
    await Process.run('reg', [
      'add',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
      '/v',
      'UnlimitedSkyOCR',
      '/t',
      'REG_SZ',
      '/d',
      '"$exe" --autostart',
      '/f',
    ]).timeout(const Duration(seconds: 5));
  }

  // ------------------------------------------------------------
  //  本地 AI: 路径探测 / 修复 / 手动导入
  // ------------------------------------------------------------

  /// Ollama 程序目录: 优先用用户指定的, 否则探测常见位置
  String _resolveOllamaDir() {
    final cands = <String>[
      if (settings.localAiExeDir.isNotEmpty) settings.localAiExeDir,
      p.join(Platform.environment['LOCALAPPDATA'] ?? '', 'Programs', 'Ollama'),
      p.join(Platform.environment['ProgramFiles'] ?? '', 'Ollama'),
      r'C:\Program Files\Ollama',
    ];
    for (final c in cands) {
      if (c.isEmpty) continue;
      if (File(p.join(c, 'ollama.exe')).existsSync()) return c;
    }
    return '';
  }

  /// 装本地 AI 时可能写到哪儿, 缓存在内存里免得反复读注册表
  String? _cachedOllamaModelsEnv;

  /// 读用户环境变量 OLLAMA_MODELS。
  ///
  /// 这是**最权威**的来源 —— 安装程序把模型装到非默认位置时就是靠它告诉
  /// Ollama 去哪儿找。开机后托盘版 Ollama 恰恰会丢掉这个变量, 所以我们
  /// 得自己读出来, 再用它把 Ollama 重启到正确的目录。
  Future<String> _readOllamaModelsEnv() async {
    if (_cachedOllamaModelsEnv != null) return _cachedOllamaModelsEnv!;
    var out = '';
    try {
      final r = await Process.run(
        'reg',
        ['query', r'HKCU\Environment', '/v', 'OLLAMA_MODELS'],
      ).timeout(const Duration(seconds: 5));
      if (r.exitCode == 0) {
        final m = RegExp(r'REG_(?:EXPAND_)?SZ\s+(.+)$', multiLine: true)
            .firstMatch(r.stdout.toString());
        if (m != null) out = m.group(1)!.trim();
      }
    } catch (_) {}
    _cachedOllamaModelsEnv = out;
    return out;
  }

  /// 模型目录的判定顺序:
  ///   1. 用户在界面上手选的
  ///   2. 注册表里的 OLLAMA_MODELS (安装程序装的)
  ///   3. 安装程序写的 ai_config.json
  ///   4. 默认位置 %USERPROFILE%\.ollama\models
  Future<String> _resolveModelsDirAsync() async {
    if (settings.localAiModelsDir.isNotEmpty) {
      return settings.localAiModelsDir;
    }
    final env = await _readOllamaModelsEnv();
    if (env.isNotEmpty && Directory(env).existsSync()) return env;

    for (final cfg in _aiConfigCandidates()) {
      try {
        if (!File(cfg).existsSync()) continue;
        final j =
            jsonDecode(File(cfg).readAsStringSync()) as Map<String, dynamic>;
        final m = (j['modelsDir'] ?? '') as String;
        if (m.isNotEmpty && Directory(m).existsSync()) return m;
      } catch (_) {}
    }

    final def = p.join(
        Platform.environment['USERPROFILE'] ?? '', '.ollama', 'models');
    if (Directory(def).existsSync()) return def;
    return env.isNotEmpty ? env : '';
  }

  /// 安装程序可能把 ai_config.json 写在这几个地方
  List<String> _aiConfigCandidates() {
    final dirs = <String>[
      p.join(File(Platform.resolvedExecutable).parent.path, 'models', 'ai'),
      p.join(Platform.environment['LOCALAPPDATA'] ?? '', 'Programs',
          'UnlimitedSkyOCR', 'models', 'ai'),
      settings.modelRoot.isEmpty ? '' : p.join(settings.modelRoot, 'ai'),
      if (settings.localAiModelsDir.isNotEmpty)
        p.dirname(settings.localAiModelsDir),
      if (settings.localAiGguf.isNotEmpty) p.dirname(settings.localAiGguf),
    ];
    return [
      for (final d in dirs)
        if (d.isNotEmpty) p.join(d, 'ai_config.json')
    ];
  }

  /// 让 Ollama 在**正确的模型目录**下跑起来。
  ///
  /// 开机后托盘版 Ollama 会自己起来, 但它可能没带上 OLLAMA_MODELS,
  /// 于是跑去默认目录找模型, 结果就是一个都没有 —— 界面提示
  /// "Ollama 在跑但没找到模型", 用户点重新检测也没用。
  Future<bool> _ensureOllamaWithModelsDir(String modelsDir) async {
    final dir = _resolveOllamaDir();
    if (dir.isEmpty) return false;
    final exe = p.join(dir, 'ollama.exe');

    // 先看当前服务能不能看到模型
    if (await _ollamaHasModel()) return true;

    Log.log('Ollama 看不到模型, 用 OLLAMA_MODELS=$modelsDir 重启它');
    // 停掉现有的 (托盘版 + serve)
    for (final name in ['ollama app.exe', 'ollama.exe']) {
      try {
        await Process.run('taskkill', ['/IM', name, '/F'])
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    await Future.delayed(const Duration(milliseconds: 2500));

    final env = Map<String, String>.from(Platform.environment);
    env['OLLAMA_MODELS'] = modelsDir;
    env['OLLAMA_KEEP_ALIVE'] = '10m';
    env['OLLAMA_FLASH_ATTENTION'] = '1';
    env['OLLAMA_MAX_LOADED_MODELS'] = '1';
    await Process.start(exe, ['serve'],
        environment: env,
        mode: ProcessStartMode.detached);
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 1500));
      if (await _ollamaHasModel()) {
        Log.log('Ollama 重启后已能识别模型');
        return true;
      }
    }
    return false;
  }

  Future<bool> _ollamaHasModel() async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final req = await c.getUrl(Uri.parse('$_ollamaBase/api/tags'));
      final resp = await req.close().timeout(const Duration(seconds: 4));
      final body = await resp.transform(utf8.decoder).join();
      c.close(force: true);
      if (resp.statusCode != 200) return false;
      final j = jsonDecode(body) as Map<String, dynamic>;
      final want = settings.openaiModel.split(':').first;
      return (j['models'] as List? ?? [])
          .any((m) => ((m as Map)['name'] ?? '').toString().split(':').first == want);
    } catch (_) {
      return false;
    }
  }

  String get _ollamaBase => settings.openaiBaseUrl
      .replaceAll(RegExp(r'/v1/?$'), '')
      .replaceAll(RegExp(r'/+$'), '');

  /// 用用户选中的 GGUF 导入成 Ollama 模型
  Future<bool> importLocalModel() async {
    final gguf = settings.localAiGguf;
    if (gguf.isEmpty || !File(gguf).existsSync()) {
      error = '请先选择一个存在的 .gguf 模型文件';
      notifyListeners();
      return false;
    }
    final dir = _resolveOllamaDir();
    if (dir.isEmpty) {
      error = '没找到 ollama.exe，请先在下面指定 Ollama 程序目录';
      notifyListeners();
      return false;
    }
    final modelsDir = await _resolveModelsDirAsync();
    // 保证服务在跑, 而且用的是对的模型目录
    if (!await _ollamaHasModel()) {
      await _ensureOllamaWithModelsDir(
          modelsDir.isNotEmpty ? modelsDir : p.join(p.dirname(gguf), '..'));
    }

    localAiStatus = LocalAiStatus(
        checking: true,
        ok: false,
        message: '正在导入模型（要复制一份，4GB 大约 1-2 分钟）…',
        hint: '文件: $gguf');
    notifyListeners();

    try {
      final mf = File(p.join(p.dirname(gguf), 'Modelfile'));
      mf.writeAsStringSync([
        'FROM $gguf',
        'PARAMETER temperature 0.7',
        'PARAMETER top_p 0.6',
        'PARAMETER top_k 20',
        'PARAMETER repeat_penalty 1.05',
        'PARAMETER num_ctx 4096',
        'PARAMETER num_predict 2048',
        '',
      ].join('\n'));
      final name = settings.openaiModel.split(':').first;
      final r = await Process.run(
        p.join(dir, 'ollama.exe'),
        ['create', name, '-f', mf.path],
      ).timeout(const Duration(minutes: 10));
      Log.log('ollama create 退出码 ${r.exitCode}');
      // 不看退出码 —— ollama 把进度写到 stderr, 退出码不可靠。以列表为准。
      await Future.delayed(const Duration(seconds: 1));
      if (await _ollamaHasModel()) {
        await checkLocalAi();
        status = '模型导入成功';
        notifyListeners();
        return true;
      }
      final tail = (r.stderr.toString() + r.stdout.toString())
          .trim()
          .split('\n')
          .take(3)
          .join(' / ');
      error = '导入结束但列表里仍然没有「$name」\n$tail';
      await checkLocalAi();
      return false;
    } catch (e) {
      error = '导入失败: $e';
      notifyListeners();
      return false;
    }
  }

  /// 一键修复: 探测路径 → 必要时用正确的模型目录重启 Ollama
  Future<void> repairLocalAi() async {
    error = null;
    localAiStatus = const LocalAiStatus(
        checking: true, ok: false, message: '正在自动修复…', hint: '');
    notifyListeners();

    final dir = _resolveOllamaDir();
    final modelsDir = await _resolveModelsDirAsync();
    Log.log('本地 AI 自动修复: ollamaDir=$dir modelsDir=$modelsDir');

    if (dir.isEmpty) {
      localAiStatus = const LocalAiStatus(
          checking: false,
          ok: false,
          message: '没找到 ollama.exe',
          hint: '请点下面的「Ollama 程序目录 - 浏览」指定它的安装位置；'
              '或者重新运行安装程序勾选「一起安装本地 AI 翻译」。');
      notifyListeners();
      return;
    }

    if (await _ollamaHasModel()) {
      Log.log('本地 AI 正常, 无需修复');
      await checkLocalAi();
      return;
    }
    Log.log('Ollama 看不到模型${modelsDir.isEmpty ? '（模型目录未知）' : '，准备用 $modelsDir 重启它'}');

    if (modelsDir.isEmpty) {
      final env = await _readOllamaModelsEnv();
      localAiStatus = LocalAiStatus(
          checking: false,
          ok: false,
          message: env.isEmpty
              ? 'Ollama 在跑，但模型目录还没确定'
              : 'Ollama 在跑，但环境变量里的模型目录不存在：$env',
          hint: '请点「模型存放目录 - 浏览」选到 Ollama 的 models 目录'
              '（里面应该有 blobs 和 manifests 两个子目录），'
              '或者直接用「模型文件」选一个 .gguf 让我导入。');
      notifyListeners();
      return;
    }

    final ok = await _ensureOllamaWithModelsDir(modelsDir);
    Log.log('本地 AI 修复结果: ${ok ? "成功" : "失败"}');
    if (!ok) {
      localAiStatus = LocalAiStatus(
          checking: false,
          ok: false,
          message: '在 $modelsDir 里没有找到「${settings.openaiModel}」',
          hint: '这个目录里可能还没导入过模型。'
              '请用下面的「模型文件」选中 .gguf，然后点「导入模型」。');
      notifyListeners();
      return;
    }
    await checkLocalAi();
  }

  // ------------------------------------------------------------
  //  本地 AI (Ollama) 状态检测
  // ------------------------------------------------------------

  LocalAiStatus localAiStatus = const LocalAiStatus(
      checking: true, ok: false, message: '正在检测本地 AI…', hint: '');

  /// 探测 127.0.0.1:11434 是否在跑, 以及目标模型有没有导入
  Future<void> checkLocalAi() async {
    Log.log('检测本地 AI…');
    localAiStatus = LocalAiStatus(
        checking: true,
        ok: false,
        message: '正在检测本地 AI…',
        hint: localAiStatus.hint);
    notifyListeners();
    final base = settings.openaiBaseUrl
        .replaceAll(RegExp(r'/v1/?$'), '')
        .replaceAll(RegExp(r'/+$'), '');
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final req = await c.getUrl(Uri.parse('$base/api/tags'));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final body = await resp.transform(utf8.decoder).join();
      c.close(force: true);
      if (resp.statusCode != 200) {
        localAiStatus = LocalAiStatus(
            checking: false,
            ok: false,
            message: '本地 AI 返回 HTTP ${resp.statusCode}',
            hint: '确认地址填的是 http://127.0.0.1:11434/v1');
      } else {
        final j = jsonDecode(body) as Map<String, dynamic>;
        final names = <String>[
          for (final m in (j['models'] as List? ?? []))
            ((m as Map)['name'] ?? '').toString()
        ];
        final want = settings.openaiModel.split(':').first;
        final hit = names.any((n) => n.split(':').first == want);
        if (hit) {
          localAiStatus = LocalAiStatus(
              checking: false,
              ok: true,
              message: '本地 AI 就绪 · 模型 ${settings.openaiModel}',
              hint: '');
        } else {
          localAiStatus = LocalAiStatus(
              checking: false,
              ok: false,
              message: 'Ollama 在跑, 但没找到模型「${settings.openaiModel}」',
              hint: '已导入的模型: ${names.isEmpty ? '（无）' : names.join(', ')}');
        }
      }
    } catch (e) {
      localAiStatus = LocalAiStatus(
          checking: false,
          ok: false,
          message: '连不上本地 AI (127.0.0.1:11434)',
          hint: '先安装并启动 Ollama, 再导入 Hunyuan-MT-7B 翻译模型, '
              '然后点「重新检测」。');
    }
    notifyListeners();
  }

  /// 用当前设置重新识别一次框选区域 (换了识别语言时用)
  Future<void> reRecognize() async {
    final sel = selection;
    if (sel == null) {
      status = '没有可重识别的区域, 请先框选';
      notifyListeners();
      return;
    }
    if (_busy) return;
    _busy = true;
    phase = AppPhase.working;
    status = '按 ' + OcrLang.labelFor(settings.ocrLang) + ' 重新识别…';
    notifyListeners();
    try {
      await _recognizeAndTranslate(sel);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 切换识别语言 (覆盖层里直接用, 不用回主界面)
  Future<void> setOcrLang(String code) async {
    if (settings.ocrLang == code) return;
    settings.ocrLang = code;
    await saveSettings();
    if (phase == AppPhase.realtime) {
      _rtForceRescan = true;
      _rtDiff.reset();
      _scheduleRealtime(10);
      notifyListeners();
    } else {
      await reRecognize();
    }
  }

  /// 切换目标语言
  Future<void> setTargetLang(String code) async {
    if (settings.targetLang == code) return;
    settings.targetLang = code;
    await saveSettings();
    translateService.cache.clear();
    if (phase == AppPhase.realtime) {
      _rtForceRescan = true;
      _rtDiff.reset();
      _scheduleRealtime(10);
      notifyListeners();
    } else {
      await reRecognize();
    }
  }

  /// 退出实时翻译, 回到主界面
  Future<void> exitRealtimeToPanel() async {
    if (realtimeActive) await stopRealtime();
    await showPanel();
  }

  // ------------------------------------------------------------
  //  卸载
  // ------------------------------------------------------------

  /// 软件安装目录 (卸载时用)
  String get installDir => p.dirname(Platform.resolvedExecutable);

  /// 是否是从"安装"来的版本 (安装器会把卸载程序一起放进来)
  bool get canSelfUninstall =>
      !Platform.isAndroid &&
      File(p.join(installDir, 'sky_uninstall.exe')).existsSync();

  /// 调用随包安装的卸载程序, 然后退出自己。
  ///
  /// 卸载程序是图形界面的, 会自己弹确认框、问是否保留模型文件,
  /// 并把删除的内容放进回收站。这里只负责把它拉起来。
  Future<bool> uninstallApp() async {
    final helper = p.join(installDir, 'sky_uninstall.exe');
    if (!File(helper).existsSync()) {
      error = '找不到卸载程序: $helper';
      notifyListeners();
      return false;
    }
    if (realtimeActive) await stopRealtime();
    try {
      await Process.start(
        helper,
        [
          '--pid', '$pid',
          '--app-dir', installDir,
          '--model-dir', settings.modelRoot,
        ],
        mode: ProcessStartMode.detached,
        workingDirectory: installDir,
      );
      Log.log('已拉起卸载程序, 准备退出');
    } catch (e) {
      error = '启动卸载程序失败: $e';
      notifyListeners();
      return false;
    }
    await Future.delayed(const Duration(milliseconds: 700));
    // 卸载程序会等我们退出后再删文件 (运行中的 exe 删不掉)
    exit(0);
  }

  Future<void> stopRealtime() async {
    _rtTranslating = false;
    _rtPendingSnapshot = null;
    _rtLastTextKey = '';
    Log.log('stopRealtime 被调用');
    realtimeActive = false;
    _rtTimer?.cancel();
    _rtTimer = null;
    try {
      NativeDpg.instance.setCaptureExclusion(0);
    } catch (_) {}
    // 不调 Window.setEffect(disabled): flutter_acrylic 在 Windows 上永远不返回,
    // 每次都要白等一个超时。透明度本来就不是它做的。
    await _applyMouseThrough(false);
    realtimeRegion = null;
    if (!Platform.isAndroid) {
      await _win('fullScreen(false)', () => windowManager.setFullScreen(false));
      await _win('alwaysOnTop(false)', () => windowManager.setAlwaysOnTop(false));
      await _win('skipTaskbar(false)', () => windowManager.setSkipTaskbar(false));
      await _win('resizable(true)', () => windowManager.setResizable(true));
      await _win('background(dark)',
          () => windowManager.setBackgroundColor(const Color(0xFF14161B)));
      if (_savedBounds != null) {
        await _win('restoreBounds', () => windowManager.setBounds(_savedBounds!));
      }
      try {
        NativeDpg.instance.focusWindow();
      } catch (_) {}
    }
    phase = AppPhase.panel;
    ocr = OcrResult.empty();
    translations = {};
    labelShowOriginal.clear();
    status = '实时翻译已停止';
    notifyListeners();
  }

  /// 框选一个区域后进入实时翻译 (不冻屏, 只借用框选界面)
  Future<void> beginRealtimeRegionPick() async {
    _rtPickingRegion = true;
    await beginCapture(CaptureMode.realtimeRegion);
  }

  /// 全屏前的窗口矩形, 用于恢复
  Rect? _savedBounds;

  bool _busy = false;

  // ------------------------------------------------------------

  Future<void> bootstrap() async {
    await _loadSettings();
    await _applyDefaults();

    // 单实例检查要放在加载引擎**之前** —— 启动本来就要读一百多兆模型,
    // 用户看没反应就会连点好几次, 几个实例同时满载会把整机拖住。
    if (!Platform.isAndroid && !await _ensureSingleInstance()) {
      return;
    }

    await _initEngine();
    if (settings.localAi) {
      // 不只是"检测" —— 开机后托盘版 Ollama 会丢掉 OLLAMA_MODELS,
      // 跑去默认目录找一个不存在的模型。这里直接自动把它用正确的模型目录
      // 拉起来, 用户什么都不用点。检测出问题却要人手动修, 等于没修。
      unawaited(repairLocalAi());
    }
    if (!Platform.isAndroid) {
      await _registerHotkeys();
      await _initTray();
      // 程序被移动过 / 重装到别的目录时, 注册表里的自启路径会失效。
      // 每次启动都按当前 exe 路径校正一次, 免得下次开机没反应。
      unawaited(_repairAutostart());
      // 原生热键需要一个消息窗口, 必须等托盘建好
      _registerRescanHotkey();
      _syncAutostartState();
      _preloadRestInBackground();
    } else {
      status = engineReady ? '引擎就绪 · 点击按钮开始识别' : status;
      notifyListeners();
    }
  }

  /// true = 可以继续启动; false = 已有实例, 应立刻退出
  Future<bool> _ensureSingleInstance() async {
    try {
      NativeDpg.configure(settings.coreLibPath);
      NativeDpg.instance.createShowEvent();
      final first = NativeDpg.instance.singleInstance();
      if (first == 1) return true;

      // 举旗让**已在运行的那个**自己把窗口显示出来 —— 跨进程 ShowWindow
      // 受前台窗口权限限制, 常常不生效, 那样用户就会以为"打开了又没了"。
      Log.log('检测到已有实例, 请求它显示窗口后退出');
      NativeDpg.instance.requestShow();
      NativeDpg.instance.activateExisting();
      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e) {
      Log.log('单实例检查失败 (忽略, 继续启动): $e');
    }
    return true;
  }

  // ------------------------------------------------------------
  //  系统托盘
  // ------------------------------------------------------------

  Timer? _trayTimer;

  Future<void> _initTray() async {
    // 轮询定时器**总是**要跑, 即使关掉了托盘图标 ——
    // 单实例的"请显示窗口"请求靠它来响应。
    _trayTimer?.cancel();
    _trayTimer = Timer.periodic(
        const Duration(milliseconds: 400), (_) => _pollTray());
    if (!settings.showTray) return;
    try {
      final tip = 'Unlimited sky OCR 全屏实时翻译器\n左键显示主界面 · 右键菜单'
          .toNativeUtf8();
      final exe = Platform.resolvedExecutable.toNativeUtf8();
      int ok = 0;
      try {
        ok = NativeDpg.instance.trayInit(tip, exe);
      } finally {
        malloc.free(tip);
        malloc.free(exe);
      }
      if (ok != 1) {
        Log.log('托盘创建失败');
        return;
      }
      Log.log('托盘已创建');
    } catch (e) {
      Log.log('托盘初始化异常: $e');
    }
  }

  void _pollTray() {
    try {
      // 别的实例请求显示窗口 (用户重复双击时)
      if (NativeDpg.instance.pollShowRequest() == 1) {
        Log.log('收到其它实例的显示请求');
        showPanel();
        return;
      }
      final cmd = NativeDpg.instance.trayPoll();
      if (cmd == 1) {
        showPanel();
      } else if (cmd == 2) {
        quitApp();
      } else if (cmd == 3) {
        Log.log('原生热键: 立刻重扫屏幕');
        if (realtimeActive) forceRescan();
      }
    } catch (_) {}
  }

  /// 托盘开关变化后重建/移除托盘
  Future<void> refreshTray() async {
    _trayTimer?.cancel();
    _trayTimer = null;
    try {
      NativeDpg.instance.trayDispose();
    } catch (_) {}
    if (settings.showTray) {
      await _initTray();
    }
    notifyListeners();
  }

  /// 真正退出程序 (先把托盘图标摘掉, 否则通知区会留个死图标)
  Future<void> quitApp() async {
    Log.log('退出程序');
    _trayTimer?.cancel();
    try {
      NativeDpg.instance.trayDispose();
    } catch (_) {}
    if (realtimeActive) await stopRealtime();
    await windowManager.setPreventClose(false);
    await windowManager.close();
    exit(0);
  }

  /// 启动后后台补齐其它识别模型, 免得切换语言时第一次卡一下。
  /// 一次只补一个, 避免又变成启动时的满载。
  void _preloadRestInBackground() {
    final wanted = ['en', 'korean', 'cyrillic', 'latin'];
    var i = 0;
    Timer.periodic(const Duration(seconds: 2), (t) {
      if (!engineReady || i >= wanted.length) {
        t.cancel();
        return;
      }
      // 实时翻译时别抢资源
      if (realtimeActive) return;
      OcrService.preload(wanted[i]);
      i++;
    });
  }

  // ------------------------------------------------------------
  //  开机自启
  // ------------------------------------------------------------

  bool autoStartEnabled = false;

  void _syncAutostartState() {
    try {
      autoStartEnabled = NativeDpg.instance.getAutostart() == 1;
      settings.autoStart = autoStartEnabled;
    } catch (_) {}
  }

  /// 设置开机自启, 返回是否成功
  Future<bool> setAutoStart(bool enable) async {
    try {
      final p = Platform.resolvedExecutable.toNativeUtf8();
      int ok = 0;
      try {
        ok = NativeDpg.instance.setAutostart(enable ? 1 : 0, p);
      } finally {
        malloc.free(p);
      }
      if (ok == 1) {
        autoStartEnabled = enable;
        settings.autoStart = enable;
        await saveSettings();
        // 以注册表为准再确认一次
        autoStartEnabled = NativeDpg.instance.getAutostart() == 1;
        status = autoStartEnabled ? '已设置开机自启' : '已取消开机自启';
      } else {
        error = '设置开机自启失败';
      }
      notifyListeners();
      return ok == 1;
    } catch (e) {
      error = '设置开机自启失败: $e';
      notifyListeners();
      return false;
    }
  }

  /// 关闭按钮行为: 最小化到托盘 or 退出
  Future<void> handleCloseRequest() async {
    if (settings.closeToTray && settings.showTray && !Platform.isAndroid) {
      await windowManager.hide();
      status = '已最小化到托盘 (右键托盘图标可退出)';
      notifyListeners();
    } else {
      await quitApp();
    }
  }

  Future<void> _applyDefaults() async {
    // ---------- Android ----------
    if (Platform.isAndroid) {
      try {
        final libs = await cap.androidNativeLibs();
        settings.coreLibPath = libs.coreLib;
        settings.onnxruntimeDll = libs.ortLib;

        status = '正在释放模型...';
        notifyListeners();
        settings.modelRoot = await cap.ensureAndroidModels();

        // 离线翻译模型 (与 OCR 模型一起解包到 filesDir/models 下)
        if (settings.offlineModelRoot.isEmpty ||
            !Directory(settings.offlineModelRoot).existsSync()) {
          final cand = p.join(settings.modelRoot, 'translate');
          if (Directory(cand).existsSync()) {
            settings.offlineModelRoot = cand;
          }
        }
        status = '模型已就绪';
      } catch (e) {
        error = 'Android 初始化失败: $e';
        notifyListeners();
      }
      return;
    }

    // ---------- 桌面 ----------
    // 首次运行时自动探测默认路径
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    if (settings.coreLibPath.isEmpty) {
      final cand = p.join(exeDir, 'dpg_core.dll');
      if (File(cand).existsSync()) settings.coreLibPath = cand;
    }
    if (settings.onnxruntimeDll.isEmpty) {
      final cand = p.join(exeDir, 'onnxruntime.dll');
      if (File(cand).existsSync()) settings.onnxruntimeDll = cand;
    }
    // ---------- Windows ----------
    // 安装程序可以指定模型放在别的磁盘, 它会在 exe 旁边写 sky_config.json
    try {
      final cfg = File(p.join(exeDir, 'sky_config.json'));
      if (cfg.existsSync()) {
        final j = jsonDecode(cfg.readAsStringSync()) as Map<String, dynamic>;
        final mr = j['modelRoot'] as String?;
        if (mr != null && mr.isNotEmpty && Directory(mr).existsSync()) {
          settings.modelRoot = mr;
        }
      }
    } catch (e) {
      Log.log('读取 sky_config.json 失败: $e');
    }

    // 内核和 ONNX Runtime **永远优先用自己 exe 旁边的那份**。
    // 之前只在"保存的路径不存在"时才回退, 结果用户把程序复制到别处后,
    // 设置里残留的旧路径仍然生效, 加载到旧版内核 —— 新符号找不到,
    // 表现为单实例/托盘静默失效。这样改之后程序是"绿色"的, 复制到哪都能跑。
    final localCore = p.join(exeDir, 'dpg_core.dll');
    if (File(localCore).existsSync()) {
      if (settings.coreLibPath != localCore) {
        Log.log('改用本目录内核: $localCore (原: ${settings.coreLibPath})');
      }
      settings.coreLibPath = localCore;
    } else if (settings.coreLibPath.isEmpty ||
        !File(settings.coreLibPath).existsSync()) {
      for (final cand in [
        p.join(Directory.current.path, 'dpg_core.dll'),
      ]) {
        if (File(cand).existsSync()) {
          settings.coreLibPath = cand;
          break;
        }
      }
    }

    final localOrt = p.join(exeDir, 'onnxruntime.dll');
    if (File(localOrt).existsSync()) {
      settings.onnxruntimeDll = localOrt;
    } else if (settings.onnxruntimeDll.isEmpty ||
        !File(settings.onnxruntimeDll).existsSync()) {
      for (final cand in [
        p.join(Directory.current.path, 'onnxruntime.dll'),
      ]) {
        if (File(cand).existsSync()) {
          settings.onnxruntimeDll = cand;
          break;
        }
      }
    }
    if (settings.modelRoot.isEmpty || !Directory(settings.modelRoot).existsSync()) {
      for (final cand in [
        p.join(exeDir, 'models'),
        r'E:\dpg\models',
        p.join(Directory.current.path, 'models'),
      ]) {
        if (Directory(cand).existsSync()) {
          settings.modelRoot = cand;
          break;
        }
      }
    }
    // 离线翻译模型目录: 优先 <模型根目录>/translate, 再尝试几个常见位置
    if (settings.offlineModelRoot.isEmpty ||
        !Directory(settings.offlineModelRoot).existsSync()) {
      final cands = <String>[
        if (settings.modelRoot.isNotEmpty) p.join(settings.modelRoot, 'translate'),
        p.join(exeDir, 'models', 'translate'),
        r'E:\dpg\models\translate',
      ];
      for (final cand in cands) {
        if (Directory(cand).existsSync()) {
          settings.offlineModelRoot = cand;
          break;
        }
      }
    }
  }

  Future<void> _loadSettings() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('settings');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          settings = AppSettings.fromJson(Map<String, dynamic>.from(decoded));
        }
      }
    } catch (_) {}
  }

  Future<void> saveSettings() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('settings', jsonEncode(settings.toJson()));
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _initEngine() async {
    status = '正在加载 OCR 引擎...';
    notifyListeners();
    try {
      await OcrService.init(settings);
      engineReady = OcrService.isReady;
      status = engineReady
          ? '引擎就绪 · ${(OcrService.info['langs'] as List?)?.length ?? 0} 个识别模型'
          : '引擎未就绪';
      error = OcrService.lastError;
    } catch (e) {
      engineReady = false;
      error = '$e';
      status = '引擎初始化失败';
    }
    // 离线翻译引擎 (只扫描语言对, 不加载模型)
    offlineReady = false;
    if (settings.offlineEnabled &&
        settings.offlineModelRoot.isNotEmpty &&
        engineReady) {
      try {
        await MtService.init(
          modelRoot: settings.offlineModelRoot,
          coreLibPath: settings.coreLibPath,
          onnxruntimeDll: settings.onnxruntimeDll,
          threads: settings.intraThreads,
        );
        offlineReady = MtService.isReady;
        offlinePairs = MtService.availablePairs;
        if (!offlineReady && MtService.lastError != null) {
          offlineError = MtService.lastError;
        }
      } catch (e) {
        offlineReady = false;
        offlineError = '$e';
      }
    }
    notifyListeners();
  }

  Future<void> restartEngine() async {
    await OcrService.dispose();
    await _initEngine();
  }

  // ------------------------------------------------------------
  //  全局热键
  // ------------------------------------------------------------

  Future<void> _registerHotkeys() async {
    try {
      await hotKeyManager.unregisterAll();
      _hotkeyConflicts.clear();
      Future<void> reg(String spec, String label, void Function() fn) async {
        // Windows 的 RegisterHotKey 在组合被占用时只返回失败,
        // 上层库往往把这个失败吞掉 —— 于是"注册成功"是假的, 按下去没反应。
        // 先探测一次, 把不可用的告诉用户。
        try {
          final p = _hotkeyProbe(spec);
          if (p != null && NativeDpg.instance.probeHotkey(p.$1, p.$2) == 0) {
            _hotkeyConflicts.add('$label ($spec)');
            Log.log('热键被占用: $label $spec');
          }
        } catch (_) {}
        try {
          await hotKeyManager.register(_parseHotKey(spec),
              keyDownHandler: (_) => fn());
          Log.log('热键注册: $label $spec');
        } catch (e) {
          _hotkeyConflicts.add('$label ($spec)');
          Log.log('热键注册失败: $label $spec -> $e');
        }
      }

      await reg(settings.hotkeySnip, '框选翻译', () {
        // 再按一次 = 退出 (当开关用, 不然用户按了没反应会以为卡住)
        if (phase == AppPhase.panel) {
          beginCapture(CaptureMode.snip);
        } else {
          exitOverlay();
        }
      });
      await reg(settings.hotkeyFull, '全屏翻译', () {
        if (phase == AppPhase.panel) {
          beginCapture(CaptureMode.full);
        } else {
          exitOverlay();
        }
      });
      await reg(settings.hotkeyPanel, '控制面板', () => showPanel());
      await reg(settings.hotkeyRealtime, '实时翻译', () {
        Log.log('热键触发: 实时翻译');
        if (realtimeActive) {
          stopRealtime();
        } else {
          startRealtime();
        }
      });
      await reg(settings.hotkeyRealtimeRegion, '选区实时翻译', () {
        if (realtimeActive) {
          stopRealtime();
        } else {
          beginRealtimeRegionPick();
        }
      });
      await reg(settings.hotkeyControl, '临时恢复点击', () {
        if (realtimeActive) toggleMouseThrough();
      });
      // 「立刻重扫屏幕」用**原生** RegisterHotKey 注册 (见 bootstrap:
      // 必须等托盘窗口建好之后, 否则没有消息窗口可挂)
      await reg(settings.hotkeyRealtimeFreeze, '冻结并操控译文', () {
        if (realtimeActive) toggleRealtimeFreeze();
      });
      await reg(settings.hotkeyRealtimeExit, '退出实时回主界面', () {
        exitRealtimeToPanel();
      });
    } catch (e) {
      error = '热键注册失败: $e';
      Log.log('热键注册整体失败: $e');
      notifyListeners();
    }
    // 冲突列表变了, 让界面刷新
    notifyListeners();
  }

  /// 用原生 RegisterHotKey 注册「立刻重扫屏幕」
  void _registerRescanHotkey() {
    try {
      final p = _hotkeyProbe(settings.hotkeyRescan);
      if (p == null) return;
      final ok = NativeDpg.instance.registerExtraHotkey(p.$1, p.$2);
      if (ok != 1) {
        _hotkeyConflicts.add('立刻重扫屏幕 (${settings.hotkeyRescan})');
        Log.log('原生热键注册失败: ${settings.hotkeyRescan}');
      } else {
        Log.log('原生热键注册: ${settings.hotkeyRescan}');
      }
    } catch (e) {
      Log.log('原生热键注册异常: ');
    }
  }

  /// 已被其它程序占用 / 注册失败的快捷键 (界面上提示用户改绑)
  final List<String> _hotkeyConflicts = [];
  List<String> get hotkeyConflicts => List.unmodifiable(_hotkeyConflicts);

  /// "Ctrl+Alt+Q" -> (mods, 虚拟键码); 解析不了返回 null
  static (int, int)? _hotkeyProbe(String spec) {
    var mods = 0;
    int? vk;
    for (final raw in spec.split('+')) {
      final s = raw.trim().toLowerCase();
      switch (s) {
        case 'ctrl':
        case 'control':
          mods |= 2;
        case 'alt':
          mods |= 1;
        case 'shift':
          mods |= 4;
        case 'meta':
        case 'win':
          mods |= 8;
        case '':
          break;
        default:
          if (s.length == 1) {
            final c = s.toUpperCase().codeUnitAt(0);
            if (c >= 0x41 && c <= 0x5A) vk = c;
            if (c >= 0x30 && c <= 0x39) vk = c;
          } else if (s.startsWith('f')) {
            final n = int.tryParse(s.substring(1));
            if (n != null && n >= 1 && n <= 24) vk = 0x70 + n - 1;
          } else if (s == 'space') {
            vk = 0x20;
          }
      }
    }
    if (vk == null) return null;
    return (mods, vk);
  }

  Future<void> reregisterHotkeys() async {
    await _registerHotkeys();
    _registerRescanHotkey();
  }

  static HotKey _parseHotKey(String spec) {
    final parts = spec
        .split('+')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    final mods = <HotKeyModifier>[];
    KeyboardKey key = LogicalKeyboardKey.keyQ;
    for (final part in parts) {
      switch (part) {
        case 'ctrl':
        case 'control':
          mods.add(HotKeyModifier.control);
          break;
        case 'alt':
          mods.add(HotKeyModifier.alt);
          break;
        case 'shift':
          mods.add(HotKeyModifier.shift);
          break;
        case 'meta':
        case 'win':
          mods.add(HotKeyModifier.meta);
          break;
        default:
          key = _keyFromName(part);
      }
    }
    return HotKey(
      key: key,
      modifiers: mods,
      scope: HotKeyScope.system,
    );
  }

  static KeyboardKey _keyFromName(String name) {
    const map = <String, LogicalKeyboardKey>{
      'q': LogicalKeyboardKey.keyQ,
      'w': LogicalKeyboardKey.keyW,
      'e': LogicalKeyboardKey.keyE,
      'r': LogicalKeyboardKey.keyR,
      't': LogicalKeyboardKey.keyT,
      'a': LogicalKeyboardKey.keyA,
      's': LogicalKeyboardKey.keyS,
      'd': LogicalKeyboardKey.keyD,
      'f': LogicalKeyboardKey.keyF,
      'g': LogicalKeyboardKey.keyG,
      'z': LogicalKeyboardKey.keyZ,
      'x': LogicalKeyboardKey.keyX,
      'c': LogicalKeyboardKey.keyC,
      'v': LogicalKeyboardKey.keyV,
      '1': LogicalKeyboardKey.digit1,
      '2': LogicalKeyboardKey.digit2,
      '3': LogicalKeyboardKey.digit3,
      '4': LogicalKeyboardKey.digit4,
      '5': LogicalKeyboardKey.digit5,
      'space': LogicalKeyboardKey.space,
      'f1': LogicalKeyboardKey.f1,
      'f2': LogicalKeyboardKey.f2,
      'f3': LogicalKeyboardKey.f3,
      'f4': LogicalKeyboardKey.f4,
      'f8': LogicalKeyboardKey.f8,
    };
    return map[name] ?? LogicalKeyboardKey.keyQ;
  }

  // ------------------------------------------------------------
  //  截图
  // ------------------------------------------------------------

  /// 计算屏幕矩形:
  ///   * `physical` — 物理像素, 直接交给 Rust 截屏 (来自 GetSystemMetrics, 精确)
  ///   * `logical`  — 逻辑像素, 用于摆放 Flutter 窗口
  ///
  /// 不使用屏幕插件, 避免 work-area / DPI 语义差异带来的坐标错位。
  (Rect physical, Rect logical)? _screenRects() {
    double dpr = 1.0;
    try {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isNotEmpty) dpr = views.first.devicePixelRatio;
    } catch (_) {}
    return cap.screenRects(dpr);
  }

  /// 进入全屏透明覆盖层。
  ///
  /// 关键点:
  ///   * **先 hide 再改尺寸**, 否则用户会看到窗口"最大化"的跳变过程
  ///   * 用 `setFullScreen` 而不是 `setBounds` —— 普通窗口带边框, 客户区比屏幕
  ///     小一圈, 表现为"四周有一块框选不到"
  ///   * 排除自身捕获必须放在 `show()` **之后**: 查找主窗口需要窗口存在
  Future<void> _enterOverlayWindow() async {
    if (Platform.isAndroid) return;
    final rects = _screenRects();
    if (rects == null) return;
    await _win('hide', () => windowManager.hide());
    // 无边框全屏: 客户区 == 整个屏幕, 四个边角都能框到
    await _win('fullScreen(true)', () => windowManager.setFullScreen(true));
    await _win('setBounds', () => windowManager.setBounds(rects.$2));
    await _win('alwaysOnTop', () => windowManager.setAlwaysOnTop(true));
    await _win('skipTaskbar', () => windowManager.setSkipTaskbar(true));
    await _win('background(transparent)',
        () => windowManager.setBackgroundColor(Colors.transparent));
    // 注意: 这里**不调** Window.setEffect(transparent)。
    // flutter_acrylic 的这个调用在 Windows 上永远不返回, 每次都要等满超时;
    // 实际透明度是 setBackgroundColor(transparent) 达成的, 它只是白等。
    await _win('show', () => windowManager.show());

    // 让我们自己不被屏幕捕获: 准星/选区/译文都不能进 OCR,
    // 否则实时模式会把自己的译文再识别一遍 (死循环)
    var excluded = false;
    for (var i = 0; i < 3 && !excluded; i++) {
      try {
        final ok = NativeDpg.instance
            .setCaptureExclusion(settings.excludeFromCapture ? 1 : 0);
        excluded = ok == 1;
      } catch (_) {}
      if (!excluded) await Future.delayed(const Duration(milliseconds: 120));
    }
    captureExcluded = excluded && settings.excludeFromCapture;
    Rect? got;
    try {
      got = await windowManager
          .getBounds()
          .timeout(const Duration(milliseconds: 900));
    } catch (_) {}
    Log.log('进入覆盖层 排除捕获=${settings.excludeFromCapture}/$excluded '
        '窗口=${_r(got)} 目标=${_r(rects.$2)}');
  }

  Future<void> beginCapture(CaptureMode m) async {
    if (_busy || !engineReady) return;
    _busy = true;
    mode = m;
    try {
      if (!Platform.isAndroid) {
        if (phase == AppPhase.panel) {
          try {
            _savedBounds = await windowManager
                .getBounds()
                .timeout(const Duration(milliseconds: 900));
          } catch (_) {}
        }
        // 全屏透明覆盖层 —— 不截图、不贴图, 你看到的就是真实屏幕
        await _enterOverlayWindow();
        await _applyMouseThrough(false);
      } else {
        await cap.setAppBackground(true);
        await Future.delayed(const Duration(milliseconds: 420));
        await cap.setAppBackground(false);
        await Future.delayed(const Duration(milliseconds: 300));
      }

      selection = null;
      ocr = OcrResult.empty();
      translations = {};
      labelShowOriginal.clear();
      error = null;

      if (m == CaptureMode.full) {
        phase = AppPhase.working;
        notifyListeners();
        await _recognizeAndTranslate(null); // null = 全屏
      } else {
        phase = AppPhase.selecting;
        status = '拖拽框选要翻译的区域 · Esc 退出';
        notifyListeners();
      }
    } catch (e) {
      error = '进入框选失败: $e';
      Log.log('beginCapture 异常: $e');
      await exitOverlay();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 用户完成框选 (imageRect 为屏幕物理像素坐标)
  Future<void> onSelectionDone(Rect imageRect) async {
    // 框选后进入实时翻译: 直接把该区域作为实时识别范围
    if (mode == CaptureMode.realtimeRegion) {
      _rtPickingRegion = false;
      await startRealtime(region: imageRect);
      return;
    }

    selection = imageRect;
    phase = AppPhase.working;
    status = '识别中...';
    notifyListeners();
    await _recognizeAndTranslate(imageRect);
  }

  /// 在真实屏幕上重新框选
  void reselect() {
    selection = null;
    ocr = OcrResult.empty();
    translations = {};
    labelShowOriginal.clear();
    error = null;
    phase = AppPhase.selecting;
    status = '拖拽框选要翻译的区域 · Esc 退出';
    notifyListeners();
  }

  /// 识别 + 翻译。
  ///
  /// [imageRect] 为屏幕物理像素坐标; 传 null 表示整屏。
  ///
  /// 注意: 这里会**重新读取真实屏幕**, 而不是复用之前截的图 ——
  /// 你看到的覆盖层是透明的实时画面, 识别也必须针对当下的真实画面。
  Future<void> _recognizeAndTranslate(Rect? imageRect) async {
    final sw = Stopwatch()..start();
    try {
      final dpr = windowDpr;
      final f = await cap.captureFullScreen(devicePixelRatio: dpr);
      frame = f;

      final region = imageRect ??
          Rect.fromLTWH(0, 0, f.width.toDouble(), f.height.toDouble());
      final x = region.left.round().clamp(0, f.width - 1);
      final y = region.top.round().clamp(0, f.height - 1);
      final w = region.width.round().clamp(1, f.width - x);
      final h = region.height.round().clamp(1, f.height - y);
      selection = Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());

      final Uint8List pixels;
      if (x == 0 && y == 0 && w == f.width && h == f.height) {
        pixels = f.bgra;
      } else {
        pixels = cropBgra(f, x, y, w, h);
      }

      final res = f.isRgba
          ? await OcrService.recognizeRgba(
              pixels,
              w,
              h,
              w * 4,
              lang: OcrLang.modelFor(settings.ocrLang),
              textScore: settings.textScore,
              noiseLevel: settings.noiseLevel,
              autoMultilang: settings.autoMultilang,
              detLimitSide: settings.detLimitSide,
              minLineHeight: settings.minLineHeight,
              maxLines: settings.maxLines,
            )
          : await OcrService.recognizeBgra(
              pixels,
              w,
              h,
              w * 4,
              lang: OcrLang.modelFor(settings.ocrLang),
              textScore: settings.textScore,
              noiseLevel: settings.noiseLevel,
              autoMultilang: settings.autoMultilang,
              detLimitSide: settings.detLimitSide,
              minLineHeight: settings.minLineHeight,
              maxLines: settings.maxLines,
            );

      // 把结果坐标还原到整帧坐标系
      final lines = res.lines
          .map((l) => OcrLine(
                text: l.text,
                score: l.score,
                detScore: l.detScore,
                points: l.points
                    .map((o) => Offset(o.dx + x, o.dy + y))
                    .toList(),
                lang: l.lang,
                rotated: l.rotated,
              ))
          .toList();
      ocr = OcrResult(
        lines: lines,
        imageWidth: res.imageWidth,
        imageHeight: res.imageHeight,
        detMs: res.detMs,
        clsMs: res.clsMs,
        recMs: res.recMs,
        totalMs: res.totalMs,
      );
      // 新一轮结果: 全部默认显示译文 (覆盖原文), 清掉上一轮的切换状态
      labelShowOriginal.clear();

      // 翻译: 逐行判断语言, 分组用各自的语言对
      final t0 = DateTime.now();
      translateService.lastError = null;
      usedOffline = false;
      if (settings.provider != TranslateProvider.none && lines.isNotEmpty) {
        translations = await translateLinesPerLang(lines,
            onPartial: (partial) {
          translations = partial;
          lastUsedOffline = translateService.usedOffline;
          status = '翻译中… 已完成 ${partial.length}/${lines.length} 行';
          notifyListeners();
        });
      } else {
        translations = {};
      }
      lastTranslateMs =
          DateTime.now().difference(t0).inMilliseconds.toDouble();

      sw.stop();
      lastUsedOffline = translateService.usedOffline;
      status = '识别 ${ocr.totalMs.toStringAsFixed(0)} ms · '
          '翻译 ${lastTranslateMs.toStringAsFixed(0)} ms'
          '${lastUsedOffline ? " (离线)" : ""} · '
          '共 ${sw.elapsedMilliseconds} ms · ${lines.length} 行';
      if (settings.provider != TranslateProvider.none &&
          translations.isEmpty &&
          translateService.lastError != null) {
        error = translateService.lastError;
      }
      phase = AppPhase.result;
    } catch (e) {
      error = '$e';
      phase = AppPhase.result;
    }
    notifyListeners();
  }

  /// 重新翻译 (切换目标语言后)
  Future<void> retranslate() async {
    if (ocr.lines.isEmpty) return;
    phase = AppPhase.working;
    notifyListeners();
    final t0 = DateTime.now();
    translateService.lastError = null;
    translateService.ensure(settings);
    translations = await translateService.translateLines(
      ocr.lines.map((e) => e.text).toList(),
      from: 'auto',
      to: settings.targetLang,
    );
    lastTranslateMs = DateTime.now().difference(t0).inMilliseconds.toDouble();
    phase = AppPhase.result;
    notifyListeners();
  }

  /// 复制全部识别+译文
  String buildPlainText() {
    final b = StringBuffer();
    for (var i = 0; i < ocr.lines.length; i++) {
      final src = ocr.lines[i].text;
      final dst = translations[i];
      if (isShowingOriginal(i)) {
        b.writeln(src);
      } else {
        b.writeln(dst ?? src);
      }
      b.writeln();
    }
    return b.toString();
  }

  Future<void> copyAll() async {
    await Clipboard.setData(ClipboardData(text: buildPlainText()));
    status = '已复制到剪贴板';
    notifyListeners();
  }

  // ------------------------------------------------------------
  //  窗口
  // ------------------------------------------------------------

  Future<void> showPanel() async {
    if (realtimeActive) {
      await stopRealtime();
      return;
    }
    if (phase != AppPhase.panel) {
      await exitOverlay();
    } else {
      // 已经在主界面: 只把窗口摆到用户面前。
      // 这一步**纯原生完成**, 不走 platform channel ——
      // windowManager 的 show/focus/置顶在这些场景会卡住, await 到超时
      // 就是"按下快捷键三秒才有反应"。
      try {
        NativeDpg.instance.focusWindow();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> exitOverlay() async {
    try {
      NativeDpg.instance.setCaptureExclusion(0);
    } catch (_) {}
    if (!Platform.isAndroid) {
      await _win('fullScreen(false)', () => windowManager.setFullScreen(false));
      await _win('alwaysOnTop(false)', () => windowManager.setAlwaysOnTop(false));
      await _win('skipTaskbar(false)', () => windowManager.setSkipTaskbar(false));
      await _win('resizable(true)', () => windowManager.setResizable(true));
      await _win('background(dark)',
          () => windowManager.setBackgroundColor(const Color(0xFF14161B)));
      if (_savedBounds != null) {
        await _win('restoreBounds', () => windowManager.setBounds(_savedBounds!));
      }
      // 最后用原生调用把窗口摆到前面 —— 快且不会卡在通道上
      try {
        NativeDpg.instance.focusWindow();
      } catch (_) {}
    }
    frameImage?.dispose();
    frameImage = null;
    frame = null;
    selection = null;
    ocr = OcrResult.empty();
    translations = {};
    labelShowOriginal.clear();
    phase = AppPhase.panel;
    status = '就绪';
    notifyListeners();
  }
}

// ------------------------------------------------------------
//  辅助
// ------------------------------------------------------------
