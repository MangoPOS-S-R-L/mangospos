import 'package:flutter/material.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/widgets/area_assignments_page.dart';

class PrintingAreasView extends StatelessWidget {
  const PrintingAreasView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  Widget build(BuildContext context) {
    return PrintingAreaAssignmentsPage(
      businessId: businessId,
      title: 'Asignar impresora por area donde se preparan los productos',
      listTitle: 'Lista de areas de produccion',
      actionLabel: 'Agregar area donde se prepara el producto',
      addAreaDialogTitle: 'Agregar area donde se prepara el producto',
      areaMetaBuilder: (PrintArea area, List<PrinterConfig> printers) {
        return '${printers.length} impresoras';
      },
    );
  }
}
