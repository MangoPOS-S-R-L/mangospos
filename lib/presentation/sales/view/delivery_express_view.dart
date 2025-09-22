import 'package:flutter/material.dart';

class DeliveryExpressView extends StatelessWidget {
  const DeliveryExpressView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text(
          'Delivery Express',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
