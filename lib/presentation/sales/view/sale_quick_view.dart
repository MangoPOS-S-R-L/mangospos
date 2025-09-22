import 'package:flutter/material.dart';

class SaleQuickView extends StatelessWidget {
  const SaleQuickView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text(
          'Venta Rapida',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
