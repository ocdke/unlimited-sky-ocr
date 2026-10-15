// 帧差检测
//
// 实时翻译每秒要看好几次屏幕。整屏 2560x1440 做一次 OCR 要 1.5 秒,
// 但绝大多数时候画面根本没变 —— 全屏重识别纯属浪费, 表现出来就是"卡好几秒才动一下"。
//
// 这里把画面切成 cols x rows 的网格, 每格取样求均值, 和上一帧比较,
// 只把"变了"的格子并成一个脏矩形交出去。画面没动时一轮只要几毫秒。

import 'dart:typed_data';
import 'dart:ui';

class FrameDiff {
  FrameDiff({this.cols = 64, this.rows = 36});

  final int cols;
  final int rows;

  Float32List? _prev;
  int _w = 0, _h = 0, _stride = 0;

  /// 网格格子的亮度均值
  Float32List _sample(Uint8List px, int w, int h, int stride, int bpp) {
    final out = Float32List(cols * rows);
    final bw = w / cols;
    final bh = h / rows;
    for (var by = 0; by < rows; by++) {
      final y0 = (by * bh).floor();
      final y1 = ((by + 1) * bh).ceil().clamp(y0 + 1, h);
      final ys = ((y1 - y0) / 3).floor().clamp(1, 1 << 20);
      for (var bx = 0; bx < cols; bx++) {
        final x0 = (bx * bw).floor();
        final x1 = ((bx + 1) * bw).ceil().clamp(x0 + 1, w);
        final xs = ((x1 - x0) / 3).floor().clamp(1, 1 << 20);
        var sum = 0, n = 0;
        for (var y = y0; y < y1; y += ys) {
          var o = y * stride + x0 * bpp;
          for (var x = x0; x < x1; x += xs, o += xs * bpp) {
            // 取 G 通道足够反映亮度变化, 且省两次内存读
            sum += px[o + 1];
            n++;
          }
        }
        out[by * cols + bx] = n == 0 ? 0 : sum / n;
      }
    }
    return out;
  }

  /// 结果
  /// * [changed] 画面是否有实质变化
  /// * [dirty] 变化区域 (图像像素坐标); changed 为 true 时有效
  /// * [ratio] 变化格子占比, 用于日志/调参
  /// * [outsideRatio] 文字区域**之外**的变化占比 —— 用来判断是不是换了窗口
  ({
    bool changed,
    Rect dirty,
    double ratio,
    double outsideRatio,
  }) compare(
    Uint8List px,
    int w,
    int h,
    int stride, {
    int bpp = 4,
    double blockThreshold = 14.0,
    double minRatio = 0.005,
    /// 上一次识别到文字的区域 (图像像素坐标)。
    ///
    /// 动态壁纸、视频、闪烁的光标会让大片像素一直变, 但**文字其实一动没动**。
    /// 给了这个掩码以后, 只有落在文字区域里的变化才算数 —— 否则实时模式会
    /// 每 120ms 就整屏重来一遍, 显卡白烧。
    List<Rect>? textRects,
    /// 文字区域之外的变化超过这个比例, 就认为换了窗口/冒出新内容, 照样重扫
    double outsideLimit = 0.15,
  }) {
    final cur = _sample(px, w, h, stride, bpp);
    final prev = _prev;
    _w = w;
    _h = h;
    _stride = stride;

    if (prev == null || prev.length != cur.length) {
      _prev = cur;
      return (
        changed: true,
        dirty: Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ratio: 1.0,
        outsideRatio: 1.0,
      );
    }

    final bw = w / cols;
    final bh = h / rows;
    final useMask = textRects != null && textRects.isNotEmpty;

    // 哪些格子压在文字上 —— 只算一次, 后面复用
    List<bool>? inText;
    if (useMask) {
      inText = List<bool>.filled(cols * rows, false);
      for (final r in textRects!) {
        final bx0 = (r.left / bw).floor().clamp(0, cols - 1);
        final bx1 = (r.right / bw).ceil().clamp(1, cols);
        final by0 = (r.top / bh).floor().clamp(0, rows - 1);
        final by1 = (r.bottom / bh).ceil().clamp(1, rows);
        for (var by = by0; by < by1; by++) {
          for (var bx = bx0; bx < bx1; bx++) {
            inText[by * cols + bx] = true;
          }
        }
      }
    }

    var dirtyCount = 0;
    var outsideCount = 0;
    var minX = cols, minY = rows, maxX = -1, maxY = -1;

    for (var by = 0; by < rows; by++) {
      final rowOff = by * cols;
      for (var bx = 0; bx < cols; bx++) {
        final i = rowOff + bx;
        final d = (cur[i] - prev[i]).abs();
        if (d <= blockThreshold) continue;
        final onText = !useMask || inText![i];
        if (!onText) outsideCount++;
        // 没给掩码时一切照旧; 给了掩码就只关心文字区域内的变化
        if (!onText) continue;
        dirtyCount++;
        if (bx < minX) minX = bx;
        if (bx > maxX) maxX = bx;
        if (by < minY) minY = by;
        if (by > maxY) maxY = by;
      }
    }

    _prev = cur;

    final total = cols * rows;
    final ratio = dirtyCount / total;
    final outsideRatio = outsideCount / total;

    // 文字区域之外大面积变化 → 多半换了窗口或冒出新内容, 照样要重扫
    final layoutChanged = useMask && outsideRatio > outsideLimit;

    if ((maxX < 0 && !layoutChanged) || (!layoutChanged && ratio < minRatio)) {
      return (
        changed: false,
        dirty: Rect.zero,
        ratio: ratio,
        outsideRatio: outsideRatio,
      );
    }

    if (layoutChanged && maxX < 0) {
      return (
        changed: true,
        dirty: Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ratio: ratio,
        outsideRatio: outsideRatio,
      );
    }

    // 往外扩一格, 避免文字刚好跨在边界上被切掉
    final x0 = ((minX - 1).clamp(0, cols - 1)) * bw;
    final y0 = ((minY - 1).clamp(0, rows - 1)) * bh;
    final x1 = ((maxX + 2).clamp(1, cols)) * bw;
    final y1 = ((maxY + 2).clamp(1, rows)) * bh;
    return (
      changed: true,
      dirty: Rect.fromLTRB(
        x0.floorToDouble(),
        y0.floorToDouble(),
        x1.ceilToDouble().clamp(1, w.toDouble()),
        y1.ceilToDouble().clamp(1, h.toDouble()),
      ),
      ratio: ratio,
      outsideRatio: outsideRatio,
    );
  }

  /// 强制下一帧视为"全变"(例如刚启动或窗口尺寸变了)
  void reset() => _prev = null;
}
