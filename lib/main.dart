import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/attachments.dart';
import 'core/paths.dart';
import 'data/database.dart';
import 'state/app_state.dart';
import 'state/settings_store.dart';
import 'state/tts.dart';
import 'stock/stock_source.dart';
import 'ui/stock/stock_chart_panel.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureAndroidImagePicker();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    mewSystemUiOverlayStyle(WidgetsBinding.instance.platformDispatcher.platformBrightness),
  );

  // 缠论公式原文供 K 线面板与工具共用；面板只画中枢，不跑完整分析。
  setStockFormulaLoader(() => rootBundle.loadString('assets/stock/chan_formula.txt'));
  // 让 AI 的工具能驱动 K 线面板（stock_panel_show）。
  installStockPanelBridge();
  // 恢复上次看的标的（首次启动是上证指数）。
  await stockPanel.restore();

  await AppPaths.init();
  // 启用 K 线磁盘缓存：冷启动先显示上次的图，再后台刷新。
  StockSource.diskRoot = AppPaths.support;
  await Attachments.recoverLostChatPhotos();
  final store = await SettingsStore.load();
  final db = await AppDatabase.open();
  await db.recordAppLaunch();
  final app = AppState(store: store, db: db);
  await app.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: app),
        ChangeNotifierProvider(create: (_) => TtsService()),
      ],
      child: const MewHubApp(),
    ),
  );
}
