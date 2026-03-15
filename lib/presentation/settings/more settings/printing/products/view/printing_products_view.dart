import 'package:flutter/material.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/areas/view/print_areas_view.dart';

class PrintingProductsView extends StatelessWidget {
  const PrintingProductsView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  Widget build(BuildContext context) {
    return PrintingAreasView(businessId: businessId);
  }
}
