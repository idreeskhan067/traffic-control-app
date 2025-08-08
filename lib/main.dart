import 'package:flutter/material.dart';
import 'screens/login_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Traffic Control App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const LoginScreen(),
      routes: {
        '/dashboard': (context) => const Scaffold(
              body: Center(child: Text('Dashboard Placeholder')),
            ),
      },
    );
  }
}
