// 覆盖层 —— 全部基于**真实画面**的透明层
//
// 设计原则 (按用户要求):
//   * 不做"截图 -> 贴图 -> 在贴图上识别"。窗口是全屏透明的, 你看到的就是真实屏幕;
//     OCR 也是在选定的那一刻重新读真实屏幕像素。
//   * 框选体验对齐 Snipaste: 十字准星 + 尺寸标注 + 四角标记, 不做整屏压暗。
//   * 实时翻译要沉浸: 只画译文, 没有底色卡片、没有边框、没有任何常驻顶栏。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/models.dart';
import 'watermark.dart';

/// 译文标签的命中区 (用于点击/右键)
class _LabelHit {
  _LabelHit(this.index, this.rect, this.text, this.showingOriginal);
  final int index;
  final Rect rect;
  final String text;
  final bool showingOriginal;
}

class CaptureOverlay extends StatefulWidget {
  const CaptureOverlay({super.key, required this.c});

  final AppController c;

  @override
  State<CaptureOverlay> createState() => _CaptureOverlayState();
}

class _CaptureOverlayState extends State<CaptureOverlay> {
  final FocusNode _focus = FocusNode();
  Offset? _dragStart;
  Rect? _dragRect;
  Offset? _cursor;
  List<_LabelHit> _hits = const [];

  AppController get c => widget.c;
  bool get isRealtime => c.phase == AppPhase.realtime;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focus..requestFocus(),
      autofocus: true,
      onKeyEvent: (e) {
        if (e is! KeyDownEvent) return;
        if (e.logicalKey == LogicalKeyboardKey.escape) {
          if (isRealtime) {
            // 鼠标穿透时我们是"隐身"的, 此时的 Esc 属于下面的程序
            if (!c.mouseThrough) c.stopRealtime();
          } else {
            c.exitOverlay();
          }
        }
      },
      child: LayoutBuilder(builder: (ctx, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        _hits = _layoutLabels(size);

        return Stack(
          children: [
            Positioned.fill(
              child: MouseRegion(
                cursor: _cursorFor(),
                onHover: (e) => setState(() => _cursor = e.localPosition),
                onExit: (_) => setState(() => _cursor = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _onTapUp,
                  onSecondaryTapUp: _onSecondaryTapUp,
                  onPanStart: _canSelect ? _onPanStart : null,
                  onPanUpdate: _canSelect ? _onPanUpdate : null,
                  onPanEnd: _canSelect ? _onPanEnd : null,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _OverlayPainter(
                    controller: c,
                    dragRect: _dragRect,
                    cursor: _cursor,
                    hits: _hits,
                    immersive: isRealtime && c.mouseThrough,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
            // 实时模式默认不显示任何常驻界面 (沉浸);
            // 只有临时关闭鼠标穿透、需要点击时才浮出一条极简控制条
            if (isRealtime && !c.mouseThrough) _realtimeControls(ctx),
            if (!isRealtime && c.phase != AppPhase.selecting) _resultBar(ctx),
          ],
        );
      }),
    );
  }

  bool get _canSelect => c.phase == AppPhase.selecting;

  /// 只有"正在框选"时才隐藏系统光标 (用画出来的十字准星代替)
  MouseCursor _cursorFor() {
    if (isRealtime) {
      return c.mouseThrough ? MouseCursor.defer : SystemMouseCursors.basic;
    }
    if (c.phase == AppPhase.selecting) return SystemMouseCursors.none;
    return SystemMouseCursors.basic;
  }

  // ------------------------------------------------------------
  //  交互
  // ------------------------------------------------------------

  void _onPanStart(DragStartDetails d) {
    setState(() {
      _dragStart = d.localPosition;
      _dragRect = Rect.fromPoints(d.localPosition, d.localPosition);
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_dragStart == null) return;
    setState(() => _dragRect = Rect.fromPoints(_dragStart!, d.localPosition));
  }

  void _onPanEnd(DragEndDetails d) {
    final r = _dragRect;
    setState(() {
      _dragStart = null;
      _dragRect = null;
    });
    if (r == null) return;
    // 覆盖层本来就是整屏 1:1, 本地坐标即屏幕坐标 (dpr 由窗口逻辑尺寸决定)
    final mq = MediaQuery.of(context);
    final scale = mq.devicePixelRatio;
    final sel = Rect.fromLTRB(
      r.left * scale,
      r.top * scale,
      r.right * scale,
      r.bottom * scale,
    );
    c.onSelectionDone(sel);
  }

  /// 左键: 点中标签则切换 原文/译文
  void _onTapUp(TapUpDetails d) {
    final hit = _hitTest(d.localPosition);
    if (hit != null) c.toggleLabelDisplay(hit.index);
  }

  /// 右键: 弹出菜单
  Future<void> _onSecondaryTapUp(TapUpDetails d) async {
    final hit = _hitTest(d.localPosition);
    if (hit == null) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final pos = RelativeRect.fromLTRB(
      d.globalPosition.dx,
      d.globalPosition.dy,
      overlay.size.width - d.globalPosition.dx,
      overlay.size.height - d.globalPosition.dy,
    );
    final sel = await showMenu<String>(
      context: context,
      position: pos,
      color: const Color(0xF01B1E25),
      items: const [
        PopupMenuItem(value: 'orig', height: 36, child: Text('仅显示原文（可复制）')),
        PopupMenuItem(value: 'trans', height: 36, child: Text('仅显示翻译结果（可复制）')),
        PopupMenuDivider(height: 6),
        PopupMenuItem(value: 'copy_orig', height: 36, child: Text('复制原文')),
        PopupMenuItem(value: 'copy_trans', height: 36, child: Text('复制译文')),
        PopupMenuItem(value: 'copy_all', height: 36, child: Text('复制全部')),
        PopupMenuDivider(height: 6),
        PopupMenuItem(value: 'all_orig', height: 36, child: Text('全部显示原文')),
        PopupMenuItem(value: 'all_trans', height: 36, child: Text('全部显示译文')),
      ],
    );
    switch (sel) {
      case 'orig':
        c.setLabelDisplay(hit.index, true);
      case 'trans':
        c.setLabelDisplay(hit.index, false);
      case 'copy_orig':
        await c.copyLine(hit.index, original: true);
      case 'copy_trans':
        await c.copyLine(hit.index, original: false);
      case 'copy_all':
        await c.copyAll();
      case 'all_orig':
        c.setAllLabelsDisplay(true);
      case 'all_trans':
        c.setAllLabelsDisplay(false);
    }
  }

  _LabelHit? _hitTest(Offset p) {
    for (var i = _hits.length - 1; i >= 0; i--) {
      if (_hits[i].rect.contains(p)) return _hits[i];
    }
    return null;
  }

  // ------------------------------------------------------------
  //  标签布局
  //
  //  覆盖层与屏幕是 1:1 的 (窗口被设成整屏物理尺寸, dpr 由系统缩放决定),
  //  所以分两步: 图像物理坐标 -> 本地逻辑坐标 (除以 dpr)。
  // ------------------------------------------------------------

  double get _dpr => MediaQuery.of(context).devicePixelRatio;

  List<_LabelHit> _layoutLabels(Size size) {
    final out = <_LabelHit>[];
    final s = c.settings;
    final dpr = _dpr;
    // 只有显式选择"极简"才不画底色。
    // 实时翻译同样必须遮住原文 —— 否则原文和译文叠在一起没法看。
    final minimal = s.labelStyle == 'minimal';

    for (var i = 0; i < c.ocr.lines.length; i++) {
      final text = c.labelText(i);
      if (text.trim().isEmpty) continue;
      final b = c.ocr.lines[i].bounds;
      final src = Rect.fromLTRB(
          b.left / dpr, b.top / dpr, b.right / dpr, b.bottom / dpr);
      if (src.width <= 0 || src.height <= 0) continue;

      final maxW = math.min(
          math.max(src.width * 1.8, 180.0), size.width * 0.92);
      final tp = LabelCache.get(text, s, maxW, outline: minimal);
      final box = tp.size;

      const padH = 9.0, padV = 6.0;
      final w = minimal
          ? box.width
          : math.max(src.width + 12, box.width + padH * 2);
      final h = minimal
          ? box.height
          : math.max(src.height + 8, box.height + padV * 2);

      var r = Rect.fromCenter(center: src.center, width: w, height: h);
      if (r.left < 2) r = r.shift(Offset(2 - r.left, 0));
      if (r.right > size.width - 2) {
        r = r.shift(Offset(size.width - 2 - r.right, 0));
      }
      if (r.top < 2) r = r.shift(Offset(0, 2 - r.top));
      if (r.bottom > size.height - 2) {
        r = r.shift(Offset(0, size.height - 2 - r.bottom));
      }
      out.add(_LabelHit(i, r, text, c.isShowingOriginal(i)));
    }
    return out;
  }

  // ------------------------------------------------------------
  //  控制条 (只在需要时出现)
  // ------------------------------------------------------------

  /// 实时模式的极简控制条 —— 仅当临时关闭鼠标穿透时才显示
  Widget _realtimeControls(BuildContext ctx) {
    final mq = MediaQuery.of(ctx);
    return Positioned(
      left: 0,
      right: 0,
      top: mq.padding.top + 12,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xCC15181E),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 6, left: 4),
                child: Text(
                  c.realtimePaused
                      ? '已冻结 · 左键切换原文/译文 · 右键菜单'
                      : '实时中',
                  style: TextStyle(
                    color: c.realtimePaused
                        ? const Color(0xFFFFD54F)
                        : const Color(0xFFB9C3CE),
                    fontSize: 12,
                  ),
                ),
              ),
              _miniBtn(
                c.realtimePaused ? '继续' : '冻结',
                c.realtimePaused ? Icons.play_arrow : Icons.pause,
                c.toggleRealtimeFreeze,
              ),
              _miniBtn('回主界面', Icons.home, c.exitRealtimeToPanel),
              _miniBtn('恢复穿透', Icons.mouse, c.toggleMouseThrough),
              // 实时模式下也能直接换语种, 下一轮就生效
              _langPicker(
                label: '识别',
                value: c.settings.ocrLang,
                width: 150,
                items: OcrLang.all
                    .map((e) => DropdownMenuItem(
                        value: e.code,
                        child: Text(e.label,
                            style: const TextStyle(fontSize: 11.5))))
                    .toList(),
                onChanged: (v) => c.setOcrLang(v),
              ),
              _langPicker(
                label: '译为',
                value: c.settings.targetLang,
                width: 90,
                items: TargetLang.all
                    .map((e) => DropdownMenuItem(
                        value: e.code,
                        child: Text(e.label,
                            style: const TextStyle(fontSize: 11.5))))
                    .toList(),
                onChanged: (v) => c.setTargetLang(v),
              ),
              if (!c.captureExcluded)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Text('⚠ 未能排除自身捕获',
                      style:
                          TextStyle(color: Color(0xFFFFB74D), fontSize: 11.5)),
                ),
              const SkyWatermark(compact: true),
            ],
          ),
        ),
      ),
    );
  }

  /// 紧凑的语言选择器 (覆盖层顶栏/底栏用)
  Widget _langPicker({
    required String label,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String> onChanged,
    double width = 150,
  }) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      margin: const EdgeInsets.only(left: 6),
      decoration: BoxDecoration(
        color: const Color(0x1AFFFFFF),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label,
            style: const TextStyle(color: Color(0xFF8A93A3), fontSize: 11)),
        const SizedBox(width: 6),
        SizedBox(
          width: width,
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isDense: true,
              isExpanded: true,
              dropdownColor: const Color(0xFF1B1E25),
              iconSize: 16,
              style: const TextStyle(color: Colors.white, fontSize: 11.5),
              items: items,
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ),
      ]),
    );
  }

  /// 结果模式的操作条
  Widget _resultBar(BuildContext ctx) {
    final mq = MediaQuery.of(ctx);
    return Positioned(
      left: 0,
      right: 0,
      bottom: mq.padding.bottom + 24,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xE015181E),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: const Color(0x22FFFFFF)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8, left: 4),
                child: Text(
                  c.error ?? c.status,
                  style: TextStyle(
                    color: c.error != null
                        ? const Color(0xFFFF8A80)
                        : const Color(0xFFB9C3CE),
                    fontSize: 12,
                  ),
                ),
              ),
              // 换语言后立刻按新语种重识别, 不用回主界面
              _langPicker(
                label: '识别',
                value: c.settings.ocrLang,
                width: 168,
                items: OcrLang.all
                    .map((e) => DropdownMenuItem(
                        value: e.code,
                        child: Text(e.label,
                            style: const TextStyle(fontSize: 11.5))))
                    .toList(),
                onChanged: (v) => c.setOcrLang(v),
              ),
              _langPicker(
                label: '译为',
                value: c.settings.targetLang,
                width: 96,
                items: TargetLang.all
                    .map((e) => DropdownMenuItem(
                        value: e.code,
                        child: Text(e.label,
                            style: const TextStyle(fontSize: 11.5))))
                    .toList(),
                onChanged: (v) => c.setTargetLang(v),
              ),
              _miniBtn('重新框选', Icons.crop_free, c.reselect),
              _miniBtn('全部译文', Icons.translate,
                  () => c.setAllLabelsDisplay(false)),
              _miniBtn('全部原文', Icons.abc, () => c.setAllLabelsDisplay(true)),
              _miniBtn('复制', Icons.copy_all, c.copyAll),
              _miniBtn('退出', Icons.close, c.exitOverlay),
              const SkyWatermark(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniBtn(String label, IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: const Color(0x1AFFFFFF),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

// ============================================================
//  TextPainter 缓存
//
//  实时模式每轮都要重排所有标签, 88 行时新建 88 个 TextPainter 开销明显,
//  直接导致界面卡顿。按 (文字 + 样式) 缓存, 文字没变就复用。
// ============================================================

class LabelCache {
  static final Map<String, TextPainter> _cache = {};
  static final Map<String, double> _maxW = {};
  static const int _maxEntries = 600;

  static TextPainter get(
      String text, dynamic settings, double maxWidth,
      {required bool outline}) {
    final key = '$text|${settings.fontSize}|${settings.fontFamily}'
        '|${settings.lineHeight}|${settings.letterSpacing}|$outline';
    final hit = _cache[key];
    // 只有"布局宽度够用"才能复用, 否则长文本会被截断
    if (hit != null && (_maxW[key] ?? 0) >= maxWidth - 0.5) return hit;

    final style = TextStyle(
      color: Colors.white,
      fontSize: settings.fontSize,
      fontFamily: settings.fontFamily,
      height: settings.lineHeight,
      letterSpacing: settings.letterSpacing,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: outline
            ? style.copyWith(
                shadows: const [
                  Shadow(
                      color: Color(0xF2000000),
                      blurRadius: 3,
                      offset: Offset(0, 1)),
                  Shadow(
                      color: Color(0xE6000000),
                      blurRadius: 9,
                      offset: Offset(0, 0)),
                ],
              )
            : style,
      ),
      textDirection: TextDirection.ltr,
      maxLines: 8,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);

    if (_cache.length > _maxEntries) {
      _cache.clear();
      _maxW.clear();
    }
    _cache[key] = tp;
    _maxW[key] = maxWidth;
    return tp;
  }

  static void clear() {
    _cache.clear();
    _maxW.clear();
  }
}

// ============================================================
//  画笔
// ============================================================

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.controller,
    required this.hits,
    this.dragRect,
    this.cursor,
    this.immersive = false,
  });

  final AppController controller;
  final List<_LabelHit> hits;
  final Rect? dragRect;
  final Offset? cursor;

  /// 沉浸模式: 只画译文 + 准星, 其它一律不画
  final bool immersive;

  @override
  void paint(Canvas canvas, Size size) {
    final isRealtime = controller.phase == AppPhase.realtime;
    final selecting = controller.phase == AppPhase.selecting;

    // 1. 选区 (框选阶段/结果阶段)
    final active = dragRect ?? _selectionLocal();
    if (active != null && !isRealtime) {
      _drawSelection(canvas, active, dragging: dragRect != null);
    }

    // 2. 十字准星 (Snipaste 风格: 全屏细线 + 交点标记)
    if (selecting && cursor != null) {
      _drawCrosshair(canvas, size, cursor!);
    }

    // 3. 译文标签
    for (final h in hits) {
      _drawLabel(canvas, h);
    }
  }

  // ---- 选区 ----

  void _drawSelection(Canvas canvas, Rect r, {required bool dragging}) {
    final col = Color(controller.settings.crosshairColor);
    final w = controller.settings.crosshairWidth;

    // 选区内部轻轻提亮一点点, 让"选中范围"一眼可辨, 但绝不压暗其它区域
    canvas.drawRect(r, Paint()..color = const Color(0x0DFFFFFF));

    canvas.drawRect(
        r,
        Paint()
          ..color = const Color(0xB3000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w + 2.5);
    canvas.drawRect(
        r,
        Paint()
          ..color = col
          ..style = PaintingStyle.stroke
          ..strokeWidth = w);

    // 四角 L 形标记
    const len = 16.0;
    void corner(Offset p, Offset d1, Offset d2) {
      for (final d in [d1, d2]) {
        canvas.drawLine(p, p + d,
            Paint()
              ..color = const Color(0xCC000000)
              ..strokeWidth = w + 3.5);
        canvas.drawLine(p, p + d,
            Paint()
              ..color = col
              ..strokeWidth = w + 1.2);
      }
    }

    corner(r.topLeft, const Offset(len, 0), const Offset(0, len));
    corner(r.topRight, const Offset(-len, 0), const Offset(0, len));
    corner(r.bottomLeft, const Offset(len, 0), const Offset(0, -len));
    corner(r.bottomRight, const Offset(-len, 0), const Offset(0, -len));

    // 尺寸标注 (Snipaste 那样贴在边上)
    final label = '${(r.width).round()} × ${(r.height).round()}';
    _badge(canvas, Offset(r.left, r.top - 24), label);
  }

  // ---- 准星 ----

  void _drawCrosshair(Canvas canvas, Size size, Offset p) {
    final col = Color(controller.settings.crosshairColor);
    final w = controller.settings.crosshairWidth;
    final halo = Paint()
      ..color = const Color(0xAA000000)
      ..strokeWidth = w + 2.5;
    final line = Paint()
      ..color = col
      ..strokeWidth = w;

    canvas.drawLine(Offset(0, p.dy), Offset(size.width, p.dy), halo);
    canvas.drawLine(Offset(p.dx, 0), Offset(p.dx, size.height), halo);
    canvas.drawLine(Offset(0, p.dy), Offset(size.width, p.dy), line);
    canvas.drawLine(Offset(p.dx, 0), Offset(p.dx, size.height), line);

    canvas.drawCircle(p, 3.5, Paint()..color = const Color(0xCC000000));
    canvas.drawCircle(p, 2.2, Paint()..color = col);

    // 左上角实时坐标提示, 便于精确定位
    _badge(canvas, Offset(p.dx + 14, p.dy + 14),
        '${p.dx.round()}, ${p.dy.round()}');
  }

  void _badge(Canvas canvas, Offset at, String text) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    final r = Rect.fromLTWH(at.dx, at.dy, tp.width + 12, tp.height + 5);
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)),
        Paint()..color = const Color(0xD9000000));
    tp.paint(canvas, Offset(r.left + 6, r.top + 2.5));
  }

  Rect? _selectionLocal() {
    final s = controller.selection;
    if (s == null) return null;
    final dpr = controller.windowDpr;
    return Rect.fromLTRB(
        s.left / dpr, s.top / dpr, s.right / dpr, s.bottom / dpr);
  }

  // ---- 标签 ----

  void _drawLabel(Canvas canvas, _LabelHit h) {
    final s = controller.settings;
    final minimal = s.labelStyle == 'minimal';
    final tp = LabelCache.get(h.text, s, h.rect.width, outline: minimal);

    if (!minimal) {
      // 卡片式: 不透明底完全盖住原文。
      // 不透明度用户可以调到 0 (只剩文字, 原文透出来), 所以这里不夹取。
      final op = s.labelOpacity.clamp(0.0, 1.0);
      if (op > 0.01) {
        final rr = RRect.fromRectAndRadius(h.rect, const Radius.circular(5));
        canvas.drawRRect(rr, Paint()..color = Color.fromRGBO(12, 14, 19, op));
      }
      tp.paint(canvas, h.rect.topLeft + const Offset(9, 6));
      return;
    }

    // 极简式: 只有文字 + 阴影, 任何背景上都读得清, 不挡视线
    tp.paint(canvas, h.rect.topLeft);  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) =>
      old.dragRect != dragRect ||
      old.cursor != cursor ||
      old.hits != hits ||
      old.immersive != immersive ||
      old.controller.phase != controller.phase ||
      old.controller.translations != controller.translations ||
      old.controller.labelShowOriginal != controller.labelShowOriginal;
}
