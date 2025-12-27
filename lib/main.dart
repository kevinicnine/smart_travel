import 'package:flutter/material.dart';
import 'pages/start_page.dart';
import 'state/user_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UserState.load();
  runApp(const SmartTravelApp());
}

class SmartTravelApp extends StatelessWidget {
  const SmartTravelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Travel (Desktop project)',
      home: StartPage(),
    ); // ← 這一行多補了一個括號
  }
}
