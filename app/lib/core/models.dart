// 数据模型

import 'dart:ui' show Rect, Offset;

/// 一行 OCR 结果
class OcrLine {
  OcrLine({
    required this.text,
    required this.score,
    required this.detScore,
    required this.points,
    required this.lang,
    required this.rotated,
  });

  final String text;
  final double score;
  final double detScore;

  /// 4 个角点 (原图像素坐标): 左上/右上/右下/左下
  final List<Offset> points;
  final String lang;
  final bool rotated;

  /// 外接矩形
  Rect get bounds {
    var l = double.infinity, t = double.infinity;
    var r = double.negativeInfinity, b = double.negativeInfinity;
    for (final p in points) {
      if (p.dx < l) l = p.dx;
      if (p.dy < t) t = p.dy;
      if (p.dx > r) r = p.dx;
      if (p.dy > b) b = p.dy;
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  static OcrLine fromJson(Map<String, dynamic> j) {
    final pts = (j['points'] as List)
        .map((e) => Offset(
              (e[0] as num).toDouble(),
              (e[1] as num).toDouble(),
            ))
        .toList();
    return OcrLine(
      text: (j['text'] ?? '') as String,
      score: (j['score'] as num?)?.toDouble() ?? 0,
      detScore: (j['det_score'] as num?)?.toDouble() ?? 0,
      points: pts,
      lang: (j['lang'] ?? '') as String,
      rotated: (j['rotated'] ?? false) as bool,
    );
  }
}

/// 按字符脚本判断一段文字属于哪种语言 (返回短码: zh/ja/ko/ru/el/ar/th/hi/en/auto)
///
/// 不能用"识别时用了哪个模型"来判断: 中文模型同时覆盖英文/日文,
/// 识别英文时 `lang` 仍然是 "ch"。必须看文字本身。
String detectScript(String text) {
  var cjk = 0, kana = 0, hangul = 0, cyrillic = 0, greek = 0;
  var arabic = 0, thai = 0, devanagari = 0, latin = 0;
  for (final r in text.runes) {
    if ((r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3400 && r <= 0x4DBF)) {
      cjk++;
    } else if (r >= 0x3040 && r <= 0x30FF) {
      kana++;
    } else if ((r >= 0xAC00 && r <= 0xD7AF) || (r >= 0x1100 && r <= 0x11FF)) {
      hangul++;
    } else if (r >= 0x0400 && r <= 0x04FF) {
      cyrillic++;
    } else if (r >= 0x0370 && r <= 0x03FF) {
      greek++;
    } else if (r >= 0x0600 && r <= 0x06FF) {
      arabic++;
    } else if (r >= 0x0E00 && r <= 0x0E7F) {
      thai++;
    } else if (r >= 0x0900 && r <= 0x097F) {
      devanagari++;
    } else if ((r >= 0x41 && r <= 0x5A) ||
        (r >= 0x61 && r <= 0x7A) ||
        (r >= 0xC0 && r <= 0x24F)) {
      latin++;
    }
  }
  // 日文含大量汉字, 必须先判假名
  if (kana > 0) return 'ja';
  if (hangul > 0) return 'ko';
  final scores = <String, int>{
    'zh': cjk,
    'ru': cyrillic,
    'el': greek,
    'ar': arabic,
    'th': thai,
    'hi': devanagari,
    'en': latin,
  };
  var best = 'auto';
  var n = 0;
  scores.forEach((k, v) {
    if (v > n) {
      n = v;
      best = k;
    }
  });
  return n == 0 ? 'auto' : best;
}

class OcrResult {
  OcrResult({
    required this.lines,
    required this.imageWidth,
    required this.imageHeight,
    required this.detMs,
    required this.clsMs,
    required this.recMs,
    required this.totalMs,
  });

  final List<OcrLine> lines;
  final int imageWidth;
  final int imageHeight;
  final double detMs;
  final double clsMs;
  final double recMs;
  final double totalMs;

  static OcrResult fromJson(Map<String, dynamic> j) {
    return OcrResult(
      lines: ((j['lines'] ?? []) as List)
          .map((e) => OcrLine.fromJson(e as Map<String, dynamic>))
          .toList(),
      imageWidth: (j['image_width'] as num?)?.toInt() ?? 0,
      imageHeight: (j['image_height'] as num?)?.toInt() ?? 0,
      detMs: (j['det_ms'] as num?)?.toDouble() ?? 0,
      clsMs: (j['cls_ms'] as num?)?.toDouble() ?? 0,
      recMs: (j['rec_ms'] as num?)?.toDouble() ?? 0,
      totalMs: (j['total_ms'] as num?)?.toDouble() ?? 0,
    );
  }

  static OcrResult empty() => OcrResult(
        lines: const [],
        imageWidth: 0,
        imageHeight: 0,
        detMs: 0,
        clsMs: 0,
        recMs: 0,
        totalMs: 0,
      );

  /// 出现最多的识别语种, 用作离线翻译的源语言提示
  String get dominantLang {
    if (lines.isEmpty) return 'auto';
    final count = <String, int>{};
    for (final l in lines) {
      if (l.lang.isEmpty) continue;
      count[l.lang] = (count[l.lang] ?? 0) + 1;
    }
    if (count.isEmpty) return 'auto';
    var best = 'auto';
    var n = -1;
    count.forEach((k, v) {
      if (v > n) {
        n = v;
        best = k;
      }
    });
    return best;
  }

  /// 根据**识别出的文字内容**推断源语言。
  ///
  /// 不能用 [dominantLang] 来做这件事: 中文模型同时覆盖英文/日文,
  /// 识别英文时 `lang` 仍然是 "ch", 据此会误判成中文, 进而与目标语言相同
  /// 而被判定为"无需翻译"。这里按字符脚本统计, 更可靠。
  String get detectedSourceLang {
    final b = StringBuffer();
    for (final l in lines) {
      b.write(l.text);
      b.write('\n');
    }
    return detectScript(b.toString());
  }

  /// 每一行各自的语言 (全屏实时翻译时中英混排很常见, 必须逐行判断)
  List<String> get lineLangs =>
      lines.map((l) => detectScript(l.text)).toList();
}

/// 支持的语言 (PP-OCRv5 模型族)
class OcrLang {
  const OcrLang(this.code, this.label, [this.modelOverride]);

  /// 下拉框的值。必须唯一 —— 之前「中文」和「日语」共用一个值,
  /// Flutter 的下拉框会串到第一项去。
  final String code;
  final String label;

  /// 实际加载哪个识别模型 (留空 = 和 code 相同)
  final String? modelOverride;

  /// 传给推理内核的模型名
  String get model => modelOverride ?? code;

  static const auto = OcrLang('auto', '自动检测（多语种混排时用）');
  static const ch = OcrLang('ch', '中文（简体 / 繁体）');

  /// PP-OCRv5 的中文模型字典里带完整平假名和片假名,
  /// 所以日语直接用 ch 模型, 实测识别置信度 0.99 以上。
  static const ja = OcrLang('ja', '日语（假名 + 汉字）', 'ch');
  static const en = OcrLang('en', '英语');
  static const korean = OcrLang('korean', '韩语');
  static const cyrillic = OcrLang('cyrillic', '俄语');
  static const latin = OcrLang('latin', '拉丁语系（法 / 德 / 西等）');
  static const arabic = OcrLang('arabic', '阿拉伯语');
  static const devanagari = OcrLang('devanagari', '天城文（印地语等）');
  static const el = OcrLang('el', '希腊语');
  static const eslav = OcrLang('eslav', '东斯拉夫语（乌克兰语等）');
  static const th = OcrLang('th', '泰语');
  static const ta = OcrLang('ta', '泰米尔语');
  static const te = OcrLang('te', '泰卢固语');

  /// 语种码 -> 模型名
  static String modelFor(String code) {
    for (final l in all) {
      if (l.code == code) return l.model;
    }
    return code;
  }

  /// 语种码 -> 显示名
  static String labelFor(String code) {
    for (final l in all) {
      if (l.code == code) return l.label;
    }
    return code;
  }

  /// 下拉框顺序: 常用语言放前面
  static const all = <OcrLang>[
    auto,
    ch,
    ja,
    en,
    korean,
    cyrillic,
    latin,
    arabic,
    devanagari,
    el,
    eslav,
    th,
    ta,
    te,
  ];
}

/// 翻译目标语言
class TargetLang {
  const TargetLang(this.code, this.label);
  final String code;
  final String label;

  static const all = <TargetLang>[
    TargetLang('zh-CN', '简体中文'),
    TargetLang('zh-TW', '繁体中文'),
    TargetLang('en', '英语'),
    TargetLang('ja', '日语'),
    TargetLang('ko', '韩语'),
    TargetLang('ru', '俄语'),
    TargetLang('fr', '法语'),
    TargetLang('de', '德语'),
    TargetLang('es', '西班牙语'),
    TargetLang('pt', '葡萄牙语'),
    TargetLang('it', '意大利语'),
    TargetLang('ar', '阿拉伯语'),
    TargetLang('th', '泰语'),
    TargetLang('vi', '越南语'),
    TargetLang('hi', '印地语'),
  ];
  /// 语言代码 -> 显示名
  static String labelFor(String code) {
    for (final l in all) {
      if (l.code == code) return l.label;
    }
    return code;
  }

}

/// 翻译服务类型
enum TranslateProvider {
  tencent('tencent', '腾讯交互翻译 (免密钥, 国内直连, 可批量)'),
  google('google', '谷歌翻译 (免密钥, 国内需配代理)'),
  openai('openai', 'AI 大模型翻译 (DeepSeek / OpenAI / 硅基流动等, 需 Key)'),
  deepl('deepl', 'DeepL (需 API Key)'),
  none('none', '仅识别不翻译');

  const TranslateProvider(this.code, this.label);
  final String code;
  final String label;
}

/// AI 翻译服务商预设 (都是 OpenAI 兼容接口, 只是地址和模型名不同)
class AiPreset {
  const AiPreset(this.name, this.baseUrl, this.model, this.note,
      {this.local = false});
  final String name;
  final String baseUrl;
  final String model;
  final String note;

  /// 跑在本机 (Ollama 等) —— 不需要 Key, 但一次请求要等十几秒
  final bool local;

  static const all = <AiPreset>[
    AiPreset('本机 Ollama · Hunyuan-MT-7B（推荐，免费离线）',
        'http://127.0.0.1:11434/v1', 'hunyuan-mt',
        '跑在你自己显卡上，不联网、不花钱 · 需要先装 Ollama 并导入模型',
        local: true),
    AiPreset('DeepSeek 深度求索', 'https://api.deepseek.com/v1', 'deepseek-chat',
        '国内直连, 便宜, 质量好 · key 在 platform.deepseek.com 申请'),
    AiPreset('硅基流动 SiliconFlow', 'https://api.siliconflow.cn/v1',
        'Qwen/Qwen3-8B', '国内直连, 有免费额度 · cloud.siliconflow.cn'),
    AiPreset('智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4', 'glm-4-flash',
        '国内直连, flash 型号免费 · open.bigmodel.cn'),
    AiPreset('月之暗面 Kimi', 'https://api.moonshot.cn/v1',
        'moonshot-v1-8k', '国内直连 · platform.moonshot.cn'),
    AiPreset('通义千问 DashScope', 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        'qwen-turbo', '国内直连 · dashscope.console.aliyun.com'),
    AiPreset('OpenAI', 'https://api.openai.com/v1', 'gpt-4o-mini',
        '国内需要配代理 · platform.openai.com'),
  ];
}

/// 本地 AI 的检测结果
class LocalAiStatus {
  const LocalAiStatus({
    required this.checking,
    required this.ok,
    required this.message,
    required this.hint,
  });
  final bool checking;
  final bool ok;
  final String message;
  final String hint;
}

/// 应用设置
class AppSettings {
  AppSettings({
    this.ocrLang = 'auto',
    this.targetLang = 'zh-CN',
    this.provider = TranslateProvider.tencent,
    this.textScore = 0.5,
    this.autoMultilang = true,
    this.detLimitSide = 960,
    this.intraThreads = 0,
    this.hotkeySnip = 'Ctrl+Alt+Q',
    this.hotkeyFull = 'Ctrl+Alt+W',
    this.hotkeyPanel = 'Ctrl+Alt+P',
    this.hotkeyRealtime = 'Ctrl+Alt+S',
    this.hotkeyRealtimeRegion = 'Ctrl+Alt+T',
    this.hotkeyControl = 'Ctrl+Alt+V',
    this.hotkeyRescan = 'Ctrl+Alt+N',
    this.hotkeyRealtimeFreeze = 'Ctrl+Alt+H',
    this.hotkeyRealtimeExit = 'Ctrl+Alt+G',
    this.openaiBaseUrl = 'https://api.openai.com/v1',
    this.openaiKey = '',
    this.openaiModel = 'gpt-4o-mini',
    this.deeplKey = '',
    this.deeplFree = true,
    this.fontSize = 16,
    this.labelOpacity = 1.0,
    this.showOriginal = true,
    this.modelRoot = '',
    this.coreLibPath = '',
    this.onnxruntimeDll = '',
    this.detPreset = 'official',
    this.clsPreset = 'rapid',
    this.minLineHeight = 0,
    this.maxLines = 0,
    this.proxy = '',
    this.offlineEnabled = true,
    this.offlineModelRoot = '',
    this.fontFamily = 'Microsoft YaHei',
    this.lineHeight = 1.3,
    this.letterSpacing = 0.0,
    this.dimOutside = false,
    this.crosshairWidth = 2.0,
    this.crosshairColor = 0xFF4FC3F7,
    this.realtimeIntervalMs = 120,
    this.realtimeUseOffline = true,
    this.excludeFromCapture = true,
    this.realtimeMaxLines = 80,
    this.labelStyle = 'auto',
    this.noiseLevel = 1,
    this.realtimeRescanMs = 4000,
    this.localAiExeDir = '',
    this.localAiModelsDir = '',
    this.localAiGguf = '',
    this.autoStart = false,
    this.closeToTray = true,
    this.showTray = true,
  });

  String ocrLang;
  String targetLang;
  TranslateProvider provider;
  double textScore;
  bool autoMultilang;
  int detLimitSide;
  int intraThreads;
  String hotkeySnip;
  String hotkeyFull;
  String hotkeyPanel;
  /// 开关实时翻译 (全屏)
  String hotkeyRealtime;
  /// 选区实时翻译
  String hotkeyRealtimeRegion;
  /// 实时模式下临时切换鼠标穿透, 以便点击界面按钮
  String hotkeyControl;
  /// 立刻重新扫描整个屏幕 (实时模式下用)
  String hotkeyRescan;
  /// 瞬间冻结: 停止识别, 并且马上可以点击/右键译文内容
  String hotkeyRealtimeFreeze;
  /// 退出实时翻译并回到主界面
  String hotkeyRealtimeExit;
  String openaiBaseUrl;
  String openaiKey;
  String openaiModel;
  String deeplKey;
  bool deeplFree;
  double fontSize;
  double labelOpacity;
  bool showOriginal;
  String modelRoot;
  String coreLibPath;
  /// onnxruntime.dll 的绝对路径
  String onnxruntimeDll;
  /// 检测预处理预设: 'official' (PaddleOCR resize_long 960 + ImageNet) | 'rapid'
  String detPreset;
  /// 方向分类预处理预设: 'rapid' (0.5/0.5 归一化 + 等比补零) | 'official'
  String clsPreset;
  /// 过滤高度小于该值(像素)的文本; 0 = 不过滤。全屏模式下调大可显著提速
  double minLineHeight;
  /// 单次最多识别行数; 0 = 不限
  int maxLines;
  /// HTTP 代理, 形如 127.0.0.1:7897; 留空表示直连。
  /// 谷歌翻译 / OpenAI 等境外接口在国内需要设置。
  String proxy;
  /// 在线翻译失败时是否自动回退到离线模型
  bool offlineEnabled;
  /// 离线翻译模型根目录 (其下每个子目录是一个语言对, 如 en-zh)
  String offlineModelRoot;

  // ---- 译文区外观 ----
  /// 译文字体
  String fontFamily;
  /// 行距倍数 (段落间距)
  double lineHeight;
  /// 字间距 (px)
  double letterSpacing;
  /// 框选时是否压暗选区之外 (默认不压暗, 保持原屏幕观感)
  bool dimOutside;
  /// 框选十字准星线宽
  double crosshairWidth;
  /// 框选十字准星颜色 (ARGB)
  int crosshairColor;

  // ---- 实时翻译 ----
  /// 实时模式识别间隔 (ms)
  int realtimeIntervalMs;
  /// 实时模式优先使用离线翻译 (更快、不依赖网络)
  bool realtimeUseOffline;

  /// 把本窗口从屏幕捕获中排除 (用户仍能看到)。
  /// 开着可以避免"把自己的译文再识别一遍"的死循环;
  /// 想录屏 / 截图时把译文一起拍进去, 就关掉它。
  bool excludeFromCapture;

  /// 实时模式单轮最多识别多少行 (行太多会拖慢每一轮)
  int realtimeMaxLines;

  /// 译文标签样式:
  /// * 'auto'    框选/结果用卡片式(完全盖住原文), 实时用极简式(只有文字)
  /// * 'minimal' 只有文字 + 阴影, 最不挡视线
  /// * 'card'    不透明底色卡片
  String labelStyle;

  /// OCR 噪声过滤档位: 0=关闭 1=宽松 2=标准 3=严格
  ///
  /// 默认宽松 —— 严格档会丢掉单字行, 中日文界面里那是真内容。
  int noiseLevel;

  /// 实时模式下每隔多久**强制**完整重扫一遍屏幕 (毫秒)。
  /// 0 = 只在画面变化时扫描, 从不强制重扫。
  int realtimeRescanMs;

  /// 当前是不是在用本机跑的翻译服务
  ///
  /// 本地模型一次批量翻译要十几秒, 超时不能按在线 API 的 6 秒算。
  bool get localAi =>
      provider == TranslateProvider.openai &&
      (openaiBaseUrl.contains('127.0.0.1') ||
          openaiBaseUrl.contains('localhost') ||
          openaiBaseUrl.contains('0.0.0.0'));

  /// Ollama 程序所在目录 (留空 = 自动探测 %LOCALAPPDATA%\Programs\Ollama)
  ///
  /// 用户可能把 Ollama 装到别处, 或者干脆用便携版。
  String localAiExeDir;

  /// Ollama 的模型存放目录 (对应 OLLAMA_MODELS)
  ///
  /// 装本地 AI 时如果选了非默认位置, 这里要能对上, 否则 Ollama 会去
  /// 默认目录找一个不存在的模型 —— 表现就是"Ollama 在跑但没找到模型"。
  String localAiModelsDir;

  /// 手动指定的 GGUF 模型文件 (用于一键导入)
  String localAiGguf;

  /// 开机自动启动 (写 HKCU 的 Run 键, 不需要管理员权限)
  bool autoStart;

  /// 点关闭按钮时最小化到托盘, 而不是退出
  bool closeToTray;

  /// 是否显示托盘图标
  bool showTray;

  Map<String, dynamic> toJson() => {
        'ocrLang': ocrLang,
        'targetLang': targetLang,
        'provider': provider.code,
        'textScore': textScore,
        'autoMultilang': autoMultilang,
        'detLimitSide': detLimitSide,
        'intraThreads': intraThreads,
        'hotkeySnip': hotkeySnip,
        'hotkeyFull': hotkeyFull,
        'hotkeyPanel': hotkeyPanel,
        'hotkeyRealtime': hotkeyRealtime,
        'hotkeyRealtimeRegion': hotkeyRealtimeRegion,
        'hotkeyControl': hotkeyControl,
        'hotkeyRescan': hotkeyRescan,
        'hotkeyRealtimeFreeze': hotkeyRealtimeFreeze,
        'hotkeyRealtimeExit': hotkeyRealtimeExit,
        'openaiBaseUrl': openaiBaseUrl,
        'openaiKey': openaiKey,
        'openaiModel': openaiModel,
        'deeplKey': deeplKey,
        'deeplFree': deeplFree,
        'fontSize': fontSize,
        'labelOpacity': labelOpacity,
        'showOriginal': showOriginal,
        'modelRoot': modelRoot,
        'coreLibPath': coreLibPath,
        'onnxruntimeDll': onnxruntimeDll,
        'detPreset': detPreset,
        'clsPreset': clsPreset,
        'minLineHeight': minLineHeight,
        'maxLines': maxLines,
        'proxy': proxy,
        'offlineEnabled': offlineEnabled,
        'offlineModelRoot': offlineModelRoot,
        'fontFamily': fontFamily,
        'lineHeight': lineHeight,
        'letterSpacing': letterSpacing,
        'dimOutside': dimOutside,
        'crosshairWidth': crosshairWidth,
        'crosshairColor': crosshairColor,
        'realtimeIntervalMs': realtimeIntervalMs,
        'realtimeUseOffline': realtimeUseOffline,
        'excludeFromCapture': excludeFromCapture,
        'realtimeMaxLines': realtimeMaxLines,
        'labelStyle': labelStyle,
        'noiseLevel': noiseLevel,
        'realtimeRescanMs': realtimeRescanMs,
        'localAiExeDir': localAiExeDir,
        'localAiModelsDir': localAiModelsDir,
        'localAiGguf': localAiGguf,
        'autoStart': autoStart,
        'closeToTray': closeToTray,
        'showTray': showTray,
      };

  static AppSettings fromJson(Map<String, dynamic> j) {
    final s = AppSettings();
    s.ocrLang = (j['ocrLang'] ?? s.ocrLang) as String;
    s.targetLang = (j['targetLang'] ?? s.targetLang) as String;
    s.provider = TranslateProvider.values.firstWhere(
      (p) => p.code == j['provider'],
      orElse: () => s.provider,
    );
    s.textScore = (j['textScore'] as num?)?.toDouble() ?? s.textScore;
    s.autoMultilang = (j['autoMultilang'] ?? s.autoMultilang) as bool;
    s.detLimitSide = (j['detLimitSide'] as num?)?.toInt() ?? s.detLimitSide;
    s.intraThreads = (j['intraThreads'] as num?)?.toInt() ?? s.intraThreads;
    s.hotkeySnip = (j['hotkeySnip'] ?? s.hotkeySnip) as String;
    s.hotkeyFull = (j['hotkeyFull'] ?? s.hotkeyFull) as String;
    s.hotkeyPanel = (j['hotkeyPanel'] ?? s.hotkeyPanel) as String;
    s.hotkeyRealtime = (j['hotkeyRealtime'] ?? s.hotkeyRealtime) as String;
    s.hotkeyRealtimeRegion =
        (j['hotkeyRealtimeRegion'] ?? s.hotkeyRealtimeRegion) as String;
    s.hotkeyControl = (j['hotkeyControl'] ?? s.hotkeyControl) as String;
    s.hotkeyRescan = (j['hotkeyRescan'] ?? s.hotkeyRescan) as String;
    s.hotkeyRealtimeFreeze =
        (j['hotkeyRealtimeFreeze'] ?? s.hotkeyRealtimeFreeze) as String;
    s.hotkeyRealtimeExit =
        (j['hotkeyRealtimeExit'] ?? s.hotkeyRealtimeExit) as String;
    s.openaiBaseUrl = (j['openaiBaseUrl'] ?? s.openaiBaseUrl) as String;
    s.openaiKey = (j['openaiKey'] ?? s.openaiKey) as String;
    s.openaiModel = (j['openaiModel'] ?? s.openaiModel) as String;
    s.deeplKey = (j['deeplKey'] ?? s.deeplKey) as String;
    s.deeplFree = (j['deeplFree'] ?? s.deeplFree) as bool;
    s.fontSize = (j['fontSize'] as num?)?.toDouble() ?? s.fontSize;
    s.labelOpacity = (j['labelOpacity'] as num?)?.toDouble() ?? s.labelOpacity;
    s.showOriginal = (j['showOriginal'] ?? s.showOriginal) as bool;
    s.modelRoot = (j['modelRoot'] ?? s.modelRoot) as String;
    s.coreLibPath = (j['coreLibPath'] ?? s.coreLibPath) as String;
    s.onnxruntimeDll = (j['onnxruntimeDll'] ?? s.onnxruntimeDll) as String;
    s.detPreset = (j['detPreset'] ?? s.detPreset) as String;
    s.clsPreset = (j['clsPreset'] ?? s.clsPreset) as String;
    s.minLineHeight =
        (j['minLineHeight'] as num?)?.toDouble() ?? s.minLineHeight;
    s.maxLines = (j['maxLines'] as num?)?.toInt() ?? s.maxLines;
    s.proxy = (j['proxy'] ?? s.proxy) as String;
    s.offlineEnabled = (j['offlineEnabled'] ?? s.offlineEnabled) as bool;
    s.offlineModelRoot =
        (j['offlineModelRoot'] ?? s.offlineModelRoot) as String;
    s.fontFamily = (j['fontFamily'] ?? s.fontFamily) as String;
    s.lineHeight = (j['lineHeight'] as num?)?.toDouble() ?? s.lineHeight;
    s.letterSpacing =
        (j['letterSpacing'] as num?)?.toDouble() ?? s.letterSpacing;
    s.dimOutside = (j['dimOutside'] ?? s.dimOutside) as bool;
    s.crosshairWidth =
        (j['crosshairWidth'] as num?)?.toDouble() ?? s.crosshairWidth;
    s.crosshairColor =
        (j['crosshairColor'] as num?)?.toInt() ?? s.crosshairColor;
    s.realtimeIntervalMs =
        (j['realtimeIntervalMs'] as num?)?.toInt() ?? s.realtimeIntervalMs;
    s.realtimeUseOffline =
        (j['realtimeUseOffline'] ?? s.realtimeUseOffline) as bool;
    s.excludeFromCapture =
        (j['excludeFromCapture'] ?? s.excludeFromCapture) as bool;
    s.realtimeMaxLines =
        (j['realtimeMaxLines'] as num?)?.toInt() ?? s.realtimeMaxLines;
    s.labelStyle = (j['labelStyle'] ?? s.labelStyle) as String;
    s.noiseLevel = (j['noiseLevel'] as num?)?.toInt() ?? s.noiseLevel;
    s.realtimeRescanMs =
        (j['realtimeRescanMs'] as num?)?.toInt() ?? s.realtimeRescanMs;
    s.localAiExeDir = (j['localAiExeDir'] ?? s.localAiExeDir) as String;
    s.localAiModelsDir =
        (j['localAiModelsDir'] ?? s.localAiModelsDir) as String;
    s.localAiGguf = (j['localAiGguf'] ?? s.localAiGguf) as String;
    s.autoStart = (j['autoStart'] ?? s.autoStart) as bool;
    s.closeToTray = (j['closeToTray'] ?? s.closeToTray) as bool;
    s.showTray = (j['showTray'] ?? s.showTray) as bool;
    return s;
  }
}
