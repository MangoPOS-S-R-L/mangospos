import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/widgets/area_assignments_page.dart';

class PrintingOrdersView extends StatelessWidget {
  const PrintingOrdersView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Regresar',
          onPressed: () => Navigator.of(context).canPop()
              ? Navigator.of(context).pop()
              : context.go(AppRoutes.printingBase),
        ),
        title: const Text('Comandas por impresora'),
      ),
      body: PrintingAreaAssignmentsPage(
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
      ),
    );
  }
}
