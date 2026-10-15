// 快捷键录制输入框
//
// 点一下进入录制状态, 直接按下想要的组合键即可, 不用手打 "Ctrl+Alt+Q"。
// Esc 取消。
//
// 同一时刻**只能有一个**输入框处于录制状态: 用一个全局 notifier 记录
// "当前是谁在录", 别的框发现不是自己就自动退出录制 —— 否则点了 A 再点 B,
// A 还停在录制态, 一次按键会被两个框同时吃掉。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 当前正在录制的输入框标识 (null = 没有)
final ValueNotifier<Object?> recordingHotkeyField = ValueNotifier(null);

class HotkeyField extends StatefulWidget {
  const HotkeyField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.conflict = false,
    this.hint,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  /// 该组合已被其它程序占用 (标红提示)
  final bool conflict;
  final String? hint;

  @override
  State<HotkeyField> createState() => _HotkeyFieldState();
}

class _HotkeyFieldState extends State<HotkeyField> {
  final FocusNode _focus = FocusNode(debugLabel: 'hotkey');
  bool _recording = false;

  @override
  void initState() {
    super.initState();
    recordingHotkeyField.addListener(_onGlobalChange);
    _focus.addListener(() {
      // 失焦就停止录制 (点了别处/切走了)
      if (!_focus.hasFocus && _recording) _stop();
    });
  }

  @override
  void dispose() {
    recordingHotkeyField.removeListener(_onGlobalChange);
    if (recordingHotkeyField.value == this) recordingHotkeyField.value = null;
    _focus.dispose();
    super.dispose();
  }

  void _onGlobalChange() {
    // 别人开始录了, 我就退出
    if (_recording && recordingHotkeyField.value != this) {
      setState(() => _recording = false);
    }
  }

  void _start() {
    recordingHotkeyField.value = this; // 抢占用权, 其它框会自动退出
    setState(() => _recording = true);
    _focus.requestFocus();
  }

  void _stop() {
    if (recordingHotkeyField.value == this) recordingHotkeyField.value = null;
    if (mounted) setState(() => _recording = false);
  }

  @override
  Widget build(BuildContext context) {
    final border = _recording
        ? const Color(0xFF4FC3F7)
        : widget.conflict
            ? const Color(0xFFEF5350)
            : const Color(0xFF2A2F3A);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label,
            style: const TextStyle(color: Color(0xFF9AA4B2), fontSize: 11.5)),
        const SizedBox(height: 5),
        if (_recording)
          Focus(
            focusNode: _focus,
            onKeyEvent: (node, ev) {
              if (ev is! KeyDownEvent) return KeyEventResult.handled;
              final combo = _comboFromEvent(ev);
              if (combo == null) return KeyEventResult.handled;
              if (combo == '__cancel__') {
                _stop();
                return KeyEventResult.handled;
              }
              _stop();
              widget.onChanged(combo);
              return KeyEventResult.handled;
            },
            child: _box(border, const Text('请按下组合键… (Esc 取消)',
                style: TextStyle(color: Color(0xFF4FC3F7), fontSize: 12.5))),
          )
        else
          InkWell(
            onTap: _start,
            borderRadius: BorderRadius.circular(7),
            child: _box(
              border,
              Row(children: [
                Expanded(
                  child: Text(
                    widget.value.isEmpty ? '未设置' : widget.value,
                    style: TextStyle(
                      color: widget.value.isEmpty
                          ? const Color(0xFF6B7280)
                          : Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (widget.conflict)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.warning_amber_rounded,
                        size: 15, color: Color(0xFFEF5350)),
                  ),
                const Icon(Icons.edit, size: 13, color: Color(0xFF6B7280)),
              ]),
            ),
          ),
        if (widget.hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(widget.hint!,
                style: const TextStyle(color: Color(0xFF6B7280), fontSize: 10.5)),
          ),
      ],
    );
  }

  Widget _box(Color border, Widget child) => Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: const Color(0xFF1B1E25),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: border, width: _recording ? 1.6 : 1),
        ),
        child: child,
      );

  /// 把按键事件转成 "Ctrl+Alt+Q" 这种串; 纯修饰键返回 null, Esc 返回 __cancel__
  static String? _comboFromEvent(KeyDownEvent ev) {
    final key = ev.logicalKey;
    final modifiers = <LogicalKeyboardKey>{
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.controlRight,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.altRight,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.metaRight,
    };
    if (key == LogicalKeyboardKey.escape) return '__cancel__';
    // 纯按修饰键不算完成, 继续等主键
    if (modifiers.contains(key)) return null;

    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final parts = <String>[];
    final ctrl = pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight);
    final alt = pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight);
    final shift = pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    final meta = pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight);
    if (ctrl) parts.add('Ctrl');
    if (alt) parts.add('Alt');
    if (shift) parts.add('Shift');
    if (meta) parts.add('Meta');

    final name = _keyName(key);
    if (name == null) return null;
    // 至少得有一个修饰键, 否则会抢走普通打字
    if (parts.isEmpty) return null;
    parts.add(name);
    return parts.join('+');
  }

  /// 逻辑键 -> 我们支持的键名
  ///
  /// 只收字母 / 数字 / F1-F12 / 空格 —— 标点键在组合热键里既难按又容易
  /// 被输入法吃掉。
  static String? _keyName(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    if (label.length == 1) {
      final c = label.toUpperCase();
      if (RegExp(r'^[A-Z0-9]$').hasMatch(c)) return c;
    }
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (RegExp(r'^F([1-9]|1[0-2])$').hasMatch(label)) return label;
    return null;
  }
}
