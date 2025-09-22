import 'package:flutter/material.dart';

class SaleManualView extends StatelessWidget {
  const SaleManualView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text(
          'Sale Manual View',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
