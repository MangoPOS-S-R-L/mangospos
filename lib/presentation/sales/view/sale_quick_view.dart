import 'package:flutter/material.dart';
import 'manual_sale_view.dart';

class SaleQuickView extends StatelessWidget {
  const SaleQuickView({super.key});

  @override
  Widget build(BuildContext context) {
    return const ManualSaleView(quickMode: true);
  }
}
