// 控制面板

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../app_controller.dart';
import 'hotkey_field.dart';
import 'watermark.dart';
import '../core/models.dart';
import '../core/ocr_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.c});
  final AppController c;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppController get c => widget.c;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF14161B),
      body: Column(
        children: [
          const _TitleBar(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _statusCard(),
                  const SizedBox(height: 14),
                  _actionCard(),
                  const SizedBox(height: 14),
                  _appearanceCard(),
                  const SizedBox(height: 14),
                  _settingsCard(),
                  const SizedBox(height: 14),
                  _hotkeyCard(),
                  const SizedBox(height: 14),
                  _trayCard(),
                  const SizedBox(height: 14),
                  _pathsCard(),
                  const SizedBox(height: 14),
                  _resultCard(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------

  Widget _card(String title, IconData icon, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1E25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2F3A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 17, color: const Color(0xFF4FC3F7)),
            const SizedBox(width: 8),
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _statusCard() {
    final info = OcrService.info;
    final langs = (info['langs'] as List?)?.length ?? 0;
    final det = info['has_det'] == true;
    final cls = info['has_cls'] == true;
    return _card('引擎状态', Icons.memory, [
      Row(children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.engineReady
                ? const Color(0xFF66BB6A)
                : const Color(0xFFEF5350),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(c.status,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
      ]),
      if (c.error != null) ...[
        const SizedBox(height: 8),
        Text(c.error!,
            style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 12)),
      ],
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _chip('检测模型 ${det ? "已加载" : "缺失"}', det),
        _chip('方向分类 ${cls ? "已加载" : "缺失"}', cls),
        _chip('识别模型 $langs 个', langs > 0),
        _chip('缓存 ${c.translateService.cache.length} 条', true),
        _chip(
          c.offlineReady
              ? '离线翻译 ${c.offlinePairs.length} 个方向'
              : '离线翻译 未启用',
          c.offlineReady,
        ),
      ]),
      if (c.offlineReady && c.offlinePairs.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('可用方向: ${c.offlinePairs.join("  ")}',
            style: const TextStyle(color: Color(0xFF8A93A3), fontSize: 11.5)),
      ],
      if (c.offlineError != null) ...[
        const SizedBox(height: 6),
        Text('离线翻译: ${c.offlineError}',
            style: const TextStyle(color: Color(0xFFFFB74D), fontSize: 11.5)),
      ],
    ]);
  }

  Widget _chip(String label, bool ok) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: ok ? const Color(0xFF17301F) : const Color(0xFF3A1F1F),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: ok ? const Color(0xFF2E7D32) : const Color(0xFF8D3B3B)),
      ),
      child: Text(label,
          style: TextStyle(
              color: ok ? const Color(0xFF9CCC9C) : const Color(0xFFE0A0A0),
              fontSize: 11.5)),
    );
  }

  Widget _actionCard() {
    return _card('开始使用', Icons.play_circle_outline, [
      Wrap(spacing: 10, runSpacing: 10, children: [
        FilledButton.icon(
          onPressed: c.engineReady
              ? () => c.beginCapture(CaptureMode.snip)
              : null,
          icon: const Icon(Icons.crop_free, size: 17),
          label: Text('框选翻译  ${c.settings.hotkeySnip}'),
        ),
        FilledButton.icon(
          onPressed:
              c.engineReady ? () => c.beginCapture(CaptureMode.full) : null,
          icon: const Icon(Icons.fullscreen, size: 17),
          label: Text('全屏翻译  ${c.settings.hotkeyFull}'),
          style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2E7D32)),
        ),
        OutlinedButton.icon(
          onPressed: () async {
            await c.restartEngine();
          },
          icon: const Icon(Icons.refresh, size: 17),
          label: const Text('重载引擎'),
        ),
      ]),
      const SizedBox(height: 10),
      const Divider(color: Color(0xFF2A2F3A), height: 20),
      const Text('实时翻译（不冻屏，鼠标穿透，不影响你操作电脑）',
          style: TextStyle(
              color: Color(0xFF4FC3F7),
              fontSize: 12.5,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Wrap(spacing: 10, runSpacing: 10, children: [
        FilledButton.icon(
          onPressed: c.engineReady
              ? () => c.realtimeActive ? c.stopRealtime() : c.startRealtime()
              : null,
          icon: Icon(c.realtimeActive ? Icons.stop : Icons.sensors, size: 17),
          label: Text(c.realtimeActive
              ? '停止实时翻译'
              : '实时翻译（全屏）  ${c.settings.hotkeyRealtime}'),
          style: FilledButton.styleFrom(
              backgroundColor: c.realtimeActive
                  ? const Color(0xFFB71C1C)
                  : const Color(0xFF00695C)),
        ),
        OutlinedButton.icon(
          onPressed: c.engineReady
              ? () => c.beginRealtimeRegionPick()
              : null,
          icon: const Icon(Icons.highlight_alt, size: 17),
          label: Text('选区实时翻译  ${c.settings.hotkeyRealtimeRegion}'),
        ),
        if (c.realtimeActive)
          OutlinedButton.icon(
            onPressed: c.toggleMouseThrough,
            icon: Icon(c.mouseThrough ? Icons.touch_app : Icons.mouse, size: 17),
            label: Text(c.mouseThrough
                ? '恢复点击  ${c.settings.hotkeyControl}'
                : '恢复穿透  ${c.settings.hotkeyControl}'),
          ),
      ]),
      const SizedBox(height: 8),
      const Text(
        '实时翻译会持续识别并把译文覆盖在原文位置。窗口鼠标穿透，点击直接落到下面的程序，'
        '不会抢焦点；同时已把自身从屏幕捕获中排除，不会把自己的译文再识别一遍。'
        '按停止快捷键或上面的按钮结束。',
        style: TextStyle(color: Color(0xFF8A93A3), fontSize: 12, height: 1.5),
      ),
    ]);
  }

  /// 译文区外观 + 框选准星
  Widget _appearanceCard() {
    final s = c.settings;
    const fonts = [
      'Microsoft YaHei',
      'SimHei',
      'SimSun',
      'KaiTi',
      'Segoe UI',
      'Consolas',
      'Arial',
    ];
    const colors = <String, int>{
      '天蓝': 0xFF4FC3F7,
      '亮绿': 0xFF69F0AE,
      '橙黄': 0xFFFFD54F,
      '品红': 0xFFFF4081,
      '纯白': 0xFFFFFFFF,
    };
    return _card('译文区外观 / 框选准星', Icons.format_paint, [
      _dropdown<String>(
        label: '译文标签样式',
        value: s.labelStyle,
        items: const [
          DropdownMenuItem(
              value: 'auto', child: Text('卡片：不透明底色，完全盖住原文（推荐）', style: _ds)),
          DropdownMenuItem(
              value: 'card', child: Text('卡片：同上', style: _ds)),
          DropdownMenuItem(
              value: 'minimal', child: Text('极简：只有文字+阴影，不遮原文', style: _ds)),
        ],
        onChanged: (v) {
          s.labelStyle = v!;
          c.saveSettings();
          setState(() {});
        },
      ),
      Row(children: [
        Expanded(
          child: _dropdown<String>(
            label: '字体',
            value: fonts.contains(s.fontFamily) ? s.fontFamily : fonts.first,
            items: fonts
                .map((f) => DropdownMenuItem(
                    value: f, child: Text(f, style: TextStyle(fontFamily: f, color: Colors.white, fontSize: 12.5))))
                .toList(),
            onChanged: (v) {
              s.fontFamily = v!;
              c.saveSettings();
              setState(() {});
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _dropdown<int>(
            label: '准星颜色',
            value: colors.containsValue(s.crosshairColor)
                ? s.crosshairColor
                : colors.values.first,
            items: colors.entries
                .map((e) => DropdownMenuItem(
                      value: e.value,
                      child: Row(children: [
                        Container(width: 14, height: 14, color: Color(e.value)),
                        const SizedBox(width: 8),
                        Text(e.key, style: _ds),
                      ]),
                    ))
                .toList(),
            onChanged: (v) {
              s.crosshairColor = v!;
              c.saveSettings();
              setState(() {});
            },
          ),
        ),
      ]),
      _slider('译文字号', s.fontSize, 10, 40, 1, (v) {
        s.fontSize = v;
        c.saveSettings();
        setState(() {});
      }),
      _slider('段落间距（行距倍数）', s.lineHeight, 0.9, 2.5, 0.05, (v) {
        s.lineHeight = v;
        c.saveSettings();
        setState(() {});
      }),
      _slider('字间距（像素）', s.letterSpacing, -1.0, 6.0, 0.1, (v) {
        s.letterSpacing = v;
        c.saveSettings();
        setState(() {});
      }),
      _slider('标签不透明度（0 = 完全透明只剩文字，1.0 = 完全盖住原文）',
          s.labelOpacity, 0.0, 1.0, 0.01, (v) {
        s.labelOpacity = v;
        c.saveSettings();
        setState(() {});
      }),
      _slider('准星线宽', s.crosshairWidth, 1.0, 6.0, 0.5, (v) {
        s.crosshairWidth = v;
        c.saveSettings();
        setState(() {});
      }),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: s.dimOutside,
        onChanged: (v) {
          s.dimOutside = v;
          c.saveSettings();
          setState(() {});
        },
        title: const Text('框选时压暗选区之外', style: _ts),
        subtitle: const Text('默认关闭：冻屏原样显示，所见即所得',
            style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11)),
      ),
      const Divider(color: Color(0xFF2A2F3A), height: 20),
      _slider('实时翻译间隔（毫秒，越小越快但更吃 CPU）',
          s.realtimeIntervalMs.toDouble(), 200, 3000, 50, (v) {
        s.realtimeIntervalMs = v.round();
        c.saveSettings();
        setState(() {});
      }),
      _slider('自动重新扫描整屏的间隔（秒，0 = 只在画面变化时扫描）',
          s.realtimeRescanMs / 1000.0, 0, 30, 0.5, (v) {
        s.realtimeRescanMs = (v * 1000).round();
        c.saveSettings();
        setState(() {});
      }),
      const Padding(
        padding: EdgeInsets.only(bottom: 6),
        child: Text(
            '实时翻译默认只在"画面变了"时重新识别, 所以静止画面上的内容不会反复扫。'
            '想让它定期强制重扫就调上面这个；也可以随时按「立刻重扫屏幕」快捷键手动扫一遍。',
            style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11.5, height: 1.6)),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: s.realtimeUseOffline,
        onChanged: (v) {
          s.realtimeUseOffline = v;
          c.saveSettings();
          setState(() {});
        },
        title: const Text('实时翻译优先使用离线模型', style: _ts),
        subtitle: const Text('离线延迟稳定且不依赖网络；失败会自动回退在线',
            style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11)),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: s.excludeFromCapture,
        onChanged: (v) {
          s.excludeFromCapture = v;
          c.saveSettings();
          setState(() {});
        },
        title: const Text('把译文层从屏幕捕获中排除（推荐开启）', style: _ts),
        subtitle: const Text(
            '开启后译文层对你可见、但对截屏/录屏隐身，避免把自己的译文再识别一遍；'
            '若想录屏时把译文一起拍进去就关掉（需 Windows 10 2004+）',
            style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11)),
      ),
      _slider('实时单轮最大识别行数（越小越快）', s.realtimeMaxLines.toDouble(),
          10, 200, 5, (v) {
        s.realtimeMaxLines = v.round();
        c.saveSettings();
        setState(() {});
      }),
    ]);
  }

  /// 快捷键设置区
  Widget _hotkeyCard() {
    final s = c.settings;
    final conflicts = c.hotkeyConflicts;
    bool bad(String spec) => conflicts.any((e) => e.contains(spec));

    // 改动后自动重新注册 (立即生效, 不用再点按钮)
    void set(String spec, VoidCallback apply) {
      apply();
      c.saveSettings();
      c.reregisterHotkeys();
      setState(() {});
    }

    return _card('快捷键设置（点一下方框，直接按下想要的组合键）', Icons.keyboard, [
      if (conflicts.isNotEmpty) ...[
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0x22EF5350),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0x66EF5350)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('以下快捷键已被其它程序占用，按下去不会有反应，请改绑：',
                  style: TextStyle(color: Color(0xFFEF9A9A), fontSize: 12.5)),
              const SizedBox(height: 3),
              Text(conflicts.join('、'),
                  style: const TextStyle(
                      color: Color(0xFFFFCDD2), fontSize: 12)),
              const SizedBox(height: 4),
              const Text('提示：Ctrl+Alt 配 B G H I J K M N P S U V Y 一般不会冲突',
                  style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11)),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
      Row(children: [
        Expanded(
          child: HotkeyField(
            label: '框选翻译',
            value: s.hotkeySnip,
            conflict: bad(s.hotkeySnip),
            onChanged: (v) => set(v, () => s.hotkeySnip = v),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: HotkeyField(
            label: '全屏翻译（一次）',
            value: s.hotkeyFull,
            conflict: bad(s.hotkeyFull),
            onChanged: (v) => set(v, () => s.hotkeyFull = v),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: HotkeyField(
            label: '实时翻译 开/关（全屏）',
            value: s.hotkeyRealtime,
            conflict: bad(s.hotkeyRealtime),
            onChanged: (v) => set(v, () => s.hotkeyRealtime = v),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: HotkeyField(
            label: '选区实时翻译',
            value: s.hotkeyRealtimeRegion,
            conflict: bad(s.hotkeyRealtimeRegion),
            onChanged: (v) => set(v, () => s.hotkeyRealtimeRegion = v),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: HotkeyField(
            label: '立刻重扫屏幕（实时模式）',
            value: s.hotkeyRescan,
            conflict: bad(s.hotkeyRescan),
            hint: '静止画面上想重新识别一遍时按它',
            onChanged: (v) => set(v, () => s.hotkeyRescan = v),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: HotkeyField(
            label: '冻结识屏并操控译文',
            value: s.hotkeyRealtimeFreeze,
            conflict: bad(s.hotkeyRealtimeFreeze),
            hint: '停住画面，然后左键切换原文/译文、右键出复制菜单',
            onChanged: (v) => set(v, () => s.hotkeyRealtimeFreeze = v),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: HotkeyField(
            label: '退出实时翻译并回主界面',
            value: s.hotkeyRealtimeExit,
            conflict: bad(s.hotkeyRealtimeExit),
            onChanged: (v) => set(v, () => s.hotkeyRealtimeExit = v),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: HotkeyField(
            label: '打开主界面',
            value: s.hotkeyPanel,
            conflict: bad(s.hotkeyPanel),
            onChanged: (v) => set(v, () => s.hotkeyPanel = v),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: HotkeyField(
            label: '临时恢复鼠标点击',
            value: s.hotkeyControl,
            conflict: bad(s.hotkeyControl),
            hint: '实时翻译时窗口是穿透的，用它临时把点击收回来',
            onChanged: (v) => set(v, () => s.hotkeyControl = v),
          ),
        ),
        const Spacer(),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        OutlinedButton.icon(
          onPressed: () async {
            await c.reregisterHotkeys();
            if (mounted) {
              setState(() {});
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('快捷键已重新注册')));
            }
          },
          icon: const Icon(Icons.refresh, size: 15),
          label: const Text('重新注册'),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('改完立即生效。若某个组合显示红色感叹号，说明已被别的程序占用。',
              style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11.5)),
        ),
      ]),
    ]);
  }

  Widget _settingsCard() {    final s = c.settings;
    return _card('识别与翻译设置', Icons.tune, [
      Row(children: [
        Expanded(
          child: _dropdown<String>(
            label: '识别语言',
            value: s.ocrLang,
            items: OcrLang.all
                .map((e) => DropdownMenuItem(
                    value: e.code, child: Text(e.label, style: _ds)))
                .toList(),
            onChanged: (v) {
              s.ocrLang = v!;
              c.saveSettings();
              if (c.ocr.lines.isNotEmpty) c.reRecognize();
              setState(() {});
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _dropdown<String>(
            label: '目标语言',
            value: s.targetLang,
            items: TargetLang.all
                .map((e) => DropdownMenuItem(
                    value: e.code, child: Text(e.label, style: _ds)))
                .toList(),
            onChanged: (v) {
              s.targetLang = v!;
              c.saveSettings();
              c.translateService.cache.clear();
              if (c.ocr.lines.isNotEmpty) c.reRecognize();
              setState(() {});
              c.retranslate();
            },
          ),
        ),
      ]),
      const SizedBox(height: 12),
      _dropdown<TranslateProvider>(
        label: '翻译引擎',
        value: s.provider,
        items: TranslateProvider.values
            .map((e) => DropdownMenuItem(
                value: e, child: Text(e.label, style: _ds)))
            .toList(),
        // (onChanged 在下面)
        onChanged: (v) {
          s.provider = v!;
          c.saveSettings();
          if (s.localAi) c.checkLocalAi();
          setState(() {});
        },
      ),
      if (s.provider == TranslateProvider.google ||
          s.provider == TranslateProvider.openai ||
          s.provider == TranslateProvider.deepl) ...[
        const SizedBox(height: 12),
        _textField('HTTP 代理 (如 127.0.0.1:7897, 留空=直连)', s.proxy, (v) {
          s.proxy = v;
          c.saveSettings();
        }),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('提示: 谷歌/OpenAI/DeepL 在国内需要代理；腾讯交互翻译可直连。',
              style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11.5)),
        ),
      ],
      if (s.provider == TranslateProvider.openai) ...[
        const SizedBox(height: 12),
        const Text('快速选择服务商（点一下自动填好地址和模型）',
            style: TextStyle(color: Color(0xFF9AA4B2), fontSize: 11.5)),
        const SizedBox(height: 7),
        Wrap(spacing: 7, runSpacing: 7, children: [
          for (final a in AiPreset.all)
            InkWell(
              onTap: () {
                s.openaiBaseUrl = a.baseUrl;
                s.openaiModel = a.model;
                c.saveSettings();
                c.translateService.cache.clear();
                setState(() {});
              },
              borderRadius: BorderRadius.circular(7),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: s.openaiBaseUrl == a.baseUrl
                      ? const Color(0x334FC3F7)
                      : const Color(0xFF1B1E25),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                      color: s.openaiBaseUrl == a.baseUrl
                          ? const Color(0xFF4FC3F7)
                          : const Color(0xFF2A2F3A)),
                ),
                child: Text(a.name,
                    style: const TextStyle(fontSize: 11.5)),
              ),
            ),
        ]),
        const SizedBox(height: 4),
        for (final a in AiPreset.all)
          if (s.openaiBaseUrl == a.baseUrl)
            Text('  ' + a.note,
                style: const TextStyle(
                    color: Color(0xFF6B7280), fontSize: 10.5)),
        const SizedBox(height: 4),
        // 本地模型的状态提示: 没装 / 没启动 / 模型没导入 都能一眼看出来
        if (s.localAi) _localAiStatus(),
        const SizedBox(height: 10),
        _textField('API Base URL', s.openaiBaseUrl, (v) {
          s.openaiBaseUrl = v;
          c.saveSettings();
        }),
        const SizedBox(height: 8),
        _textField('模型名', s.openaiModel, (v) {
          s.openaiModel = v;
          c.saveSettings();
        }),
        const SizedBox(height: 8),
        _textField('API Key', s.openaiKey, (v) {
          s.openaiKey = v;
          c.saveSettings();
        }, obscure: true),
      ],
      if (s.provider == TranslateProvider.deepl) ...[
        const SizedBox(height: 12),
        _textField('DeepL API Key', s.deeplKey, (v) {
          s.deeplKey = v;
          c.saveSettings();
        }, obscure: true),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: s.deeplFree,
          onChanged: (v) {
            s.deeplFree = v;
            c.saveSettings();
            setState(() {});
          },
          title: const Text('使用 DeepL Free 端点', style: _ts),
        ),
      ],
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: s.offlineEnabled,
        onChanged: (v) {
          s.offlineEnabled = v;
          c.saveSettings();
          c.restartEngine();
          setState(() {});
        },
        title: const Text('在线失败时回退到离线模型 (离线兜底)', style: _ts),
        subtitle: const Text(
            '离线模型放在「离线翻译模型目录」下, 每个语言对一个子目录 (如 en-zh、zh-en)',
            style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11)),
      ),
      const Divider(color: Color(0xFF2A2F3A), height: 26),
      _dropdown<String>(
        label: '检测预处理预设 (影响速度/精度)',
        value: s.detPreset,
        items: const [
          DropdownMenuItem(
              value: 'official',
              child: Text('官方 PaddleOCR (resize_long 960 + ImageNet 归一化)',
                  style: _ds)),
          DropdownMenuItem(
              value: 'rapid',
              child:
                  Text('RapidOCR (limit_side 736 + 0.5/0.5 归一化)', style: _ds)),
        ],
        onChanged: (v) {
          s.detPreset = v!;
          c.saveSettings();
          c.restartEngine();
          setState(() {});
        },
      ),
      const SizedBox(height: 12),
      _slider('检测长边 (越小越快, 影响小字识别)', s.detLimitSide.toDouble(), 480,
          1600, 32, (v) {
        s.detLimitSide = v.round();
        c.saveSettings();
        setState(() {});
      }),
      _slider('最小文本高度 (像素, 0=不过滤。调大可大幅提速)', s.minLineHeight, 0, 40,
          1, (v) {
        s.minLineHeight = v;
        c.saveSettings();
        setState(() {});
      }),
      _slider('最大识别行数 (0=不限)', s.maxLines.toDouble(), 0, 200, 10, (v) {
        s.maxLines = v.round();
        c.saveSettings();
        setState(() {});
      }),
      _slider('文本置信度下限', s.textScore, 0.1, 0.95, 0.05, (v) {
        s.textScore = v;
        c.saveSettings();
        setState(() {});
      }),
      const Divider(color: Color(0xFF2A2F3A), height: 22),
      _dropdown<int>(
        label: 'OCR 降噪强度（识别不到内容就调低）',
        value: s.noiseLevel,
        items: const [
          DropdownMenuItem(
              value: 0, child: Text('关闭：什么都保留（最全，可能夹杂图标碎片）', style: _ds)),
          DropdownMenuItem(
              value: 1, child: Text('宽松：只丢明显碎片（推荐）', style: _ds)),
          DropdownMenuItem(
              value: 2, child: Text('标准：再丢掉单字符行', style: _ds)),
          DropdownMenuItem(
              value: 3, child: Text('严格：再要求有效字符占比', style: _ds)),
        ],
        onChanged: (v) {
          s.noiseLevel = v!;
          c.saveSettings();
          setState(() {});
        },
      ),
      const Padding(
        padding: EdgeInsets.only(top: 4, bottom: 6),
        child: Text(
            '「标准」和「严格」会把只有一个字的行（菜单项、数字、单位）当成噪声丢掉，'
            '中日文界面下容易漏内容。默认「宽松」只丢纯符号和重复字符。',
            style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11.5, height: 1.6)),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: s.autoMultilang,
        onChanged: (v) {
          s.autoMultilang = v;
          c.saveSettings();
          setState(() {});
        },
        title: const Text('多语种自动重试 (低置信行换模型重认)', style: _ts),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text(
            '提示：「自动检测」用中文模型打底、再对低置信行换模型重试，所以中英日内容最准；'
            '韩语、俄语等建议在上面的「识别语言」里直接指定，准确率会明显更高。'
            '改完会立刻按新语种重新识别一次。',
            style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11.5, height: 1.6)),
      ),
    ]);
  }

  /// 托盘与开机自启
  Widget _trayCard() {
    final s = c.settings;
    return _card('托盘与开机启动', Icons.power_settings_new, [
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: c.autoStartEnabled,
        onChanged: (v) async {
          final ok = await c.setAutoStart(v);
          if (mounted) {
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(ok
                    ? (v ? '已设置开机自启（不需要管理员权限）' : '已取消开机自启')
                    : '设置失败，请查看上方错误提示')));
          }
        },
        title: const Text('开机自动启动', style: _ts),
        subtitle: const Text('写入当前用户的启动项，登录后自动运行（可在任务管理器→启动 里看到）',
            style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11)),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: s.showTray,
        onChanged: (v) {
          s.showTray = v;
          c.saveSettings();
          c.refreshTray();
          setState(() {});
        },
        title: const Text('在通知区显示托盘图标', style: _ts),
        subtitle: const Text('左键点图标显示主界面，右键有「显示主界面 / 退出」',
            style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11)),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: s.closeToTray,
        onChanged: (v) {
          s.closeToTray = v;
          c.saveSettings();
          setState(() {});
        },
        title: const Text('点关闭按钮时最小化到托盘（不退出）', style: _ts),
        subtitle: const Text('关掉它则点 X 直接退出程序',
            style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11)),
      ),
      const Divider(color: Color(0xFF2A2F3A), height: 22),
      Row(children: [
        OutlinedButton.icon(
          onPressed: () async {
            await c.showPanel();
          },
          icon: const Icon(Icons.open_in_new, size: 15),
          label: const Text('显示主界面'),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: () async {
            await c.quitApp();
          },
          icon: const Icon(Icons.logout, size: 15),
          label: const Text('完全退出程序'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFFAB91),
            side: const BorderSide(color: Color(0x66FF7043)),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      const Text(
        '提示：程序启动要读取上百兆模型，请等窗口出现。重复双击不会开出第二个实例，'
        '只会把已有窗口拉到前面。',
        style: TextStyle(color: Color(0xFF8A93A3), fontSize: 11.5, height: 1.6),
      ),
    ]);
  }

  /// 本地 AI 状态条: 检测 Ollama 是否在跑、模型是否已导入
  Widget _localAiStatus() {
    final s = c.settings;
    final st = c.localAiStatus;
    final color = st.ok
        ? const Color(0xFF66BB6A)
        : (st.checking ? const Color(0xFFFFB74D) : const Color(0xFFEF5350));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1E25),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
              st.ok
                  ? Icons.check_circle
                  : (st.checking ? Icons.hourglass_top : Icons.error_outline),
              size: 14,
              color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(st.message,
                style: TextStyle(color: color, fontSize: 11.5)),
          ),
          if (!st.checking)
            InkWell(
              onTap: () => c.checkLocalAi(),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text('重新检测',
                    style: TextStyle(
                        color: Color(0xFF4FC3F7), fontSize: 11.5)),
              ),
            ),
        ]),
        if (!st.ok && !st.checking && st.hint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 5, left: 20),
            child: Text(st.hint,
                style: const TextStyle(
                    color: Color(0xFF8A93A3), fontSize: 10.5, height: 1.55)),
          ),
        const SizedBox(height: 9),
        // ---- 手动指定路径: 自动探测不到时全靠这个 ----
        _pathRow(
          label: 'Ollama 程序目录',
          value: s.localAiExeDir,
          hint: '留空 = 自动探测',
          onPick: () async {
            final r = await c.pickDirPath(
                title: '选择 Ollama 安装目录（里面有 ollama.exe）',
                initial: s.localAiExeDir);
            if (r != null) {
              s.localAiExeDir = r;
              await c.saveSettings();
              await c.repairLocalAi();
              setState(() {});
            }
          },
          onClear: () {
            s.localAiExeDir = '';
            c.saveSettings();
            c.repairLocalAi();
            setState(() {});
          },
        ),
        _pathRow(
          label: '模型存放目录',
          value: s.localAiModelsDir,
          hint: 'Ollama 的 models 目录（含 blobs / manifests）',
          onPick: () async {
            final r = await c.pickDirPath(
                title: '选择 Ollama 的模型存放目录',
                initial: s.localAiModelsDir);
            if (r != null) {
              s.localAiModelsDir = r;
              await c.saveSettings();
              await c.repairLocalAi();
              setState(() {});
            }
          },
          onClear: () {
            s.localAiModelsDir = '';
            c.saveSettings();
            c.repairLocalAi();
            setState(() {});
          },
        ),
        _pathRow(
          label: '模型文件 (.gguf)',
          value: s.localAiGguf,
          hint: '选好后点右边「导入模型」，会自动复制进 Ollama',
          onPick: () async {
            final r = await c.pickFilePath(
                kind: 'gguf',
                title: '选择 GGUF 翻译模型文件',
                initial: s.localAiGguf);
            if (r != null) {
              s.localAiGguf = r;
              await c.saveSettings();
              setState(() {});
            }
          },
          onClear: () {
            s.localAiGguf = '';
            c.saveSettings();
            setState(() {});
          },
        ),
        const SizedBox(height: 9),
        Row(children: [
          OutlinedButton.icon(
            onPressed: st.checking ? null : () => c.repairLocalAi(),
            icon: const Icon(Icons.build_circle_outlined, size: 15),
            label: const Text('一键修复'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF4FC3F7),
              side: const BorderSide(color: Color(0x664FC3F7)),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: st.checking
                ? null
                : () async {
                    final ok = await c.importLocalModel();
                    if (mounted) {
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok
                              ? '模型导入成功，可以开始翻译了'
                              : (c.error ?? '导入失败'))));
                    }
                  },
            icon: const Icon(Icons.download_for_offline_outlined, size: 15),
            label: const Text('导入模型'),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: st.checking ? null : () => c.checkLocalAi(),
            icon: const Icon(Icons.refresh, size: 14),
            label: const Text('仅检测', style: TextStyle(fontSize: 12)),
          ),
        ]),
      ]),
    );
  }

  /// 一行"路径 + 浏览 + 清除"
  Widget _pathRow({
    required String label,
    required String value,
    required String hint,
    required Future<void> Function() onPick,
    required VoidCallback onClear,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: const TextStyle(
                    color: Color(0xFF9AA4B2), fontSize: 11.5)),
          ),
          Expanded(
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: const Color(0xFF14171D),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF2A2F3A)),
              ),
              child: Text(
                value.isEmpty ? '（未指定）' : value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: value.isEmpty
                      ? const Color(0xFF6B7280)
                      : Colors.white,
                  fontSize: 11.5,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            height: 30,
            child: OutlinedButton(
              onPressed: () => onPick(),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12)),
              child: const Text('浏览…', style: TextStyle(fontSize: 12)),
            ),
          ),
          if (value.isNotEmpty) ...[
            const SizedBox(width: 4),
            IconButton(
              onPressed: onClear,
              icon: const Icon(Icons.close, size: 14),
              tooltip: '清除',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ]),
        if (hint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 110, top: 2),
            child: Text(hint,
                style: const TextStyle(
                    color: Color(0xFF6B7280), fontSize: 10.5)),
          ),
      ]),
    );
  }

  Widget _pathsCard() {
    final s = c.settings;
    return _card('模型与路径', Icons.folder_open, [
      _textField('内核动态库 (dpg_core.dll)', s.coreLibPath, (v) {
        s.coreLibPath = v;
        c.saveSettings();
      }),
      const SizedBox(height: 8),
      _textField('ONNX Runtime (onnxruntime.dll)', s.onnxruntimeDll, (v) {
        s.onnxruntimeDll = v;
        c.saveSettings();
      }),
      const SizedBox(height: 8),
      _textField('模型根目录', s.modelRoot, (v) {
        s.modelRoot = v;
        c.saveSettings();
      }),
      const SizedBox(height: 8),
      _textField('离线翻译模型目录 (含 en-zh / zh-en 等子目录)',
          s.offlineModelRoot, (v) {
        s.offlineModelRoot = v;
        c.saveSettings();
        c.restartEngine();
      }),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () async {
          await c.restartEngine();
        },
        icon: const Icon(Icons.restart_alt, size: 16),
        label: const Text('重新加载内核与模型'),
      ),
      if (c.canSelfUninstall) ...[
        const Divider(color: Color(0xFF2A2F3A), height: 26),
        Row(children: [
          Expanded(
            child: Text(
              '卸载会删除程序文件和快捷方式，并询问是否同时删除模型'
              '（${c.settings.modelRoot}）。删除的内容会先进回收站。',
              style: const TextStyle(color: Color(0xFF8A93A3), fontSize: 11.5, height: 1.5),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF1B1E25),
                  title: const Text('卸载 Unlimited sky OCR 全屏实时翻译器',
                      style: TextStyle(color: Colors.white, fontSize: 15)),
                  content: const Text(
                    '将关闭当前程序并启动卸载向导。\n\n'
                    '卸载向导会：\n'
                    '  · 删除桌面和开始菜单快捷方式\n'
                    '  · 删除程序文件\n'
                    '  · 询问是否一并删除模型文件\n\n'
                    '删除的内容会先放进回收站，误删可以还原。',
                    style: TextStyle(color: Color(0xFFB9C3CE), fontSize: 12.5, height: 1.6),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFEF5350)),
                      child: const Text('卸载'),
                    ),
                  ],
                ),
              );
              if (ok == true) await c.uninstallApp();
            },
            icon: const Icon(Icons.delete_outline, size: 15),
            label: const Text('卸载软件'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFEF9A9A),
              side: const BorderSide(color: Color(0x66EF5350)),
            ),
          ),
        ]),
      ],
    ]);
  }

  Widget _resultCard() {
    final lines = c.ocr.lines;
    return _card('最近一次结果', Icons.list_alt, [
      if (lines.isEmpty)
        const Text('还没有识别结果。按热键开始吧。',
            style: TextStyle(color: Color(0xFF8A93A3), fontSize: 12.5))
      else ...[
        Row(children: [
          Expanded(
            child: Text(c.status,
                style: const TextStyle(
                    color: Color(0xFF8A93A3), fontSize: 12)),
          ),
          TextButton.icon(
            onPressed: c.copyAll,
            icon: const Icon(Icons.copy_all, size: 15),
            label: const Text('复制全部'),
          ),
        ]),
        const SizedBox(height: 6),
        ...List.generate(lines.length, (i) {
          final src = lines[i].text;
          final dst = c.translations[i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 26,
                  child: Text('${i + 1}',
                      style: const TextStyle(
                          color: Color(0xFF5A6273), fontSize: 11.5)),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(src,
                          style: const TextStyle(
                              color: Color(0xFFB9C3CE), fontSize: 12)),
                      if (dst != null && dst != src)
                        Text(dst,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
                Text('${(lines[i].score * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                        color: Color(0xFF5A6273), fontSize: 11)),
              ],
            ),
          );
        }),
      ],
    ]);
  }

  // ------------------------------------------------------------

  static const _ts = TextStyle(color: Colors.white, fontSize: 13);
  static const _ds = TextStyle(color: Colors.white, fontSize: 12.5);

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: Color(0xFF8A93A3), fontSize: 11.5)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF12141A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF2A2F3A)),
          ),
          child: DropdownButton<T>(
            value: value,
            items: items,
            onChanged: onChanged,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            dropdownColor: const Color(0xFF1B1E25),
          ),
        ),
      ],
    );
  }

  Widget _textField(String label, String value, ValueChanged<String> onChanged,
      {bool obscure = false}) {
    return TextFormField(
      initialValue: value,
      obscureText: obscure,
      onFieldSubmitted: onChanged,
      onTapOutside: (_) {},
      style: _ts,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF8A93A3), fontSize: 12),
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF12141A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF2A2F3A)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF2A2F3A)),
        ),
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max, double step,
      ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: Color(0xFF8A93A3), fontSize: 11.5)),
            ),
            Text(
              step >= 1 ? value.round().toString() : value.toStringAsFixed(2),
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ]),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / step).round(),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 40,
        color: const Color(0xFF101216),
        padding: const EdgeInsets.only(left: 14, right: 6),
        child: Row(
          children: [
            const Icon(Icons.translate, size: 16, color: Color(0xFF4FC3F7)),
            const SizedBox(width: 8),
            const Text('Unlimited sky OCR 全屏实时翻译器',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
            const SkyWatermark(),
            const Spacer(),
            IconButton(
              iconSize: 15,
              icon: const Icon(Icons.remove, color: Colors.white70),
              onPressed: () => windowManager.minimize(),
            ),
            IconButton(
              iconSize: 15,
              icon: const Icon(Icons.close, color: Colors.white70),
              onPressed: () => windowManager.close(),
            ),
          ],
        ),
      ),
    );
  }
}
