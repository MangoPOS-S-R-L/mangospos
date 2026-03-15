import 'package:flutter/material.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/widgets/area_assignments_page.dart';

class PrintingOrdersView extends StatelessWidget {
  const PrintingOrdersView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  Widget build(BuildContext context) {
    return PrintingAreaAssignmentsPage(
      businessId: businessId,
      title: 'Asignar impresora por comandas',
      listTitle: 'Lista de areas de comandas',
      actionLabel: 'Agregar area de comandas',
      addAreaDialogTitle: 'Agregar area de comandas',
      areaMetaBuilder: (PrintArea area, List<PrinterConfig> printers) {
        if (printers.isNotEmpty) {
          return '${printers.length} impresoras';
        }
        return 'Sin impresora';
      },
    );
  }
}
