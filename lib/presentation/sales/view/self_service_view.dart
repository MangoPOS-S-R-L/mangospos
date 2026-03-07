import 'package:flutter/material.dart';

class SelfServiceView extends StatelessWidget {
  const SelfServiceView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text(
          'Self service no disponible',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
