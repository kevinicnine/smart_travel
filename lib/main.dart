import 'dart:async';

import 'package:flutter/material.dart';
import 'pages/start_page.dart';
import 'services/location_sync_service.dart';
import 'state/user_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UserState.load();
  runApp(const SmartTravelApp());
}

class SmartTravelApp extends StatefulWidget {
  const SmartTravelApp({super.key});

  @override
  State<SmartTravelApp> createState() => _SmartTravelAppState();
}

class _SmartTravelAppState extends State<SmartTravelApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(LocationSyncService.instance.initialize());
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Travel (Desktop project)',
      home: StartPage(),
    ); // ← 這一行多補了一個括號
  }
}
