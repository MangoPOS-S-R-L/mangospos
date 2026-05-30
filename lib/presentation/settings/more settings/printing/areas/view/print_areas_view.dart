import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/widgets/area_assignments_page.dart';

class PrintingAreasView extends StatelessWidget {
  const PrintingAreasView({super.key, this.businessId = 'auto'});

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
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: const Text('Áreas de impresión'),
      ),
      body: PrintingAreaAssignmentsPage(
        businessId: businessId,
        title: 'Asignar impresora por area donde se preparan los productos',
        listTitle: 'Lista de areas de produccion',
        actionLabel: 'Agregar area donde se prepara el producto',
        addAreaDialogTitle: 'Agregar area donde se prepara el producto',
        areaMetaBuilder: (PrintArea area, List<PrinterConfig> printers) {
          return '${printers.length} impresoras';
        },
      ),
    );
  }
}
