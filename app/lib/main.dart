// Unlimited sky OCR 全屏实时翻译器 — 应用入口

import 'package:flutter/material.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_controller.dart';
import 'core/log.dart';
import 'ui/capture_overlay.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Log.init();
  await windowManager.ensureInitialized();
  await hotKeyManager.unregisterAll();

  const opts = WindowOptions(
    size: Size(1040, 780),
    minimumSize: Size(880, 620),
    center: true,
    title: 'Unlimited sky OCR 全屏实时翻译器',
    backgroundColor: Color(0xFF14161B),
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );

  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setResizable(true);
  });

  final controller = AppController();
  // 先渲染界面再初始化引擎, 让用户看到加载状态
  runApp(DpgApp(controller: controller));
  await controller.bootstrap();
}

class DpgApp extends StatefulWidget {
  const DpgApp({super.key, required this.controller});
  final AppController controller;

  @override
  State<DpgApp> createState() => _DpgAppState();
}

class _DpgAppState extends State<DpgApp> with WindowListener {
  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // 自己接管关闭: 按设置决定是最小化到托盘还是真退出
    windowManager.setPreventClose(true);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    await controller.handleCloseRequest();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unlimited sky OCR 全屏实时翻译器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4FC3F7),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF14161B),
        fontFamily: 'Microsoft YaHei',
      ),
      home: AnimatedBuilder(
        animation: controller,
        builder: (ctx, _) {
          if (controller.phase == AppPhase.panel) {
            return HomePage(c: controller);
          }
          return CaptureOverlay(c: controller);
        },
      ),
    );
  }
}
