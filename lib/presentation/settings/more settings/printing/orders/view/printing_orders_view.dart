import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/areas/viewmodel/print_areas_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';

class PrintingOrdersView extends ConsumerStatefulWidget {
  final String businessId;
  const PrintingOrdersView({super.key, this.businessId = 'auto'});

  @override
  ConsumerState<PrintingOrdersView> createState() => _PrintingOrdersViewState();
}

class _PrintingOrdersViewState extends ConsumerState<PrintingOrdersView> {
  // Mapeo de área -> impresora seleccionada
  final Map<String, String?> _selectedPrinters = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Cargar áreas y impresoras
      ref
          .read(printingAreasViewModelProvider.notifier)
          .load(businessId: widget.businessId);
      ref
          .read(printingPrintersViewModelProvider.notifier)
          .load(businessId: widget.businessId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final areasState = ref.watch(printingAreasViewModelProvider);
    final printersState = ref.watch(printingPrintersViewModelProvider);
    final areasCtrl = ref.read(printingAreasViewModelProvider.notifier);

    // Lista de impresoras disponibles
    final availablePrinters = printersState.items;

    return Container(
      color: const Color(0xFFF7F7F7),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: MangoColors.darkGray,
                padding: const EdgeInsets.symmetric(horizontal: 0),
              ),
              onPressed: () => context.go(AppRoutes.printingBase),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Regresar'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Asignar Impresión de Comandas',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: MangoColors.darkGray,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Configura qué cocinas envían comandas a cada impresora',
                        style: TextStyle(fontSize: 14, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton.icon(
                  onPressed: () => _showAddAreaDialog(context, areasCtrl),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Agregar Área'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF42A5F5),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (areasState.isLoading && areasState.items.isEmpty)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (areasState.items.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE3F2FD),
                          borderRadius: BorderRadius.circular(100),
                        ),
                        child: const Icon(
                          Icons.restaurant_menu,
                          size: 64,
                          color: Color(0xFF42A5F5),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'No hay áreas de cocina configuradas',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: MangoColors.darkGray,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Agrega tu primera área para empezar',
                        style: TextStyle(fontSize: 14, color: Colors.black54),
                      ),
                      const SizedBox(height: 24),
                      OutlinedButton.icon(
                        onPressed: () => _showAddAreaDialog(context, areasCtrl),
                        icon: const Icon(Icons.add),
                        label: const Text('Agregar Primera Área'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF42A5F5),
                          side: const BorderSide(
                            color: Color(0xFF42A5F5),
                            width: 2,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 24,
                    mainAxisSpacing: 24,
                    childAspectRatio: 2.5,
                  ),
                  itemCount: areasState.items.length,
                  itemBuilder: (_, index) {
                    final area = areasState.items[index];
                    return _KitchenAreaCard(
                      area: area,
                      printers: availablePrinters,
                      selectedPrinter: _selectedPrinters[area.id],
                      onPrinterChanged: (printerId) {
                        setState(() {
                          _selectedPrinters[area.id] = printerId;
                        });
                        if (printerId != null) {
                          // Guardar la asignación en la base de datos
                          areasCtrl.linkAreaPrinter(
                            areaId: area.id,
                            printerId: printerId,
                            printsOrders: true,
                          );
                        }
                      },
                      onDelete: () =>
                          _confirmDeleteArea(context, area, areasCtrl),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showAddAreaDialog(
    BuildContext context,
    PrintingAreasViewModel areasCtrl,
  ) {
    final nameController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Container(
          width: 500,
          padding: const EdgeInsets.all(24),
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE3F2FD),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.add_circle_outline,
                        color: Color(0xFF42A5F5),
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Agregar Área de Cocina',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.black54),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const Text(
                  'Nombre del Área',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: MangoColors.darkGray,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: nameController,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Ej: Cocina Principal, Bar, Parrilla...',
                    hintStyle: const TextStyle(color: Colors.black38),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(
                        color: Color(0xFF42A5F5),
                        width: 2,
                      ),
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Por favor ingresa un nombre';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: MangoColors.darkGray,
                        side: const BorderSide(color: Color(0xFFE0E0E0)),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('Cancelar'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: () async {
                        if (formKey.currentState!.validate()) {
                          final success = await areasCtrl.createArea(
                            name: nameController.text.trim(),
                          );
                          if (success && dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Área agregada exitosamente'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            }
                          }
                        }
                      },
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Agregar'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF42A5F5),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _confirmDeleteArea(
    BuildContext context,
    PrintArea area,
    PrintingAreasViewModel areasCtrl,
  ) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Eliminar Área'),
        content: Text(
          '¿Estás seguro de que deseas eliminar "${area.name}"?\n\nEsta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              final success = await areasCtrl.deleteArea(area.id);
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
              if (success && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Área eliminada exitosamente'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            },
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }
}

class _KitchenAreaCard extends StatelessWidget {
  final PrintArea area;
  final List<PrinterDevice> printers;
  final String? selectedPrinter;
  final Function(String?) onPrinterChanged;
  final VoidCallback onDelete;

  const _KitchenAreaCard({
    required this.area,
    required this.printers,
    required this.selectedPrinter,
    required this.onPrinterChanged,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFE3F2FD),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.restaurant_menu,
                  color: Color(0xFF42A5F5),
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      area.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Área de preparación',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: Colors.red,
                onPressed: onDelete,
                tooltip: 'Eliminar área',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Impresora asignada:',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE0E0E0)),
            ),
            child: DropdownButtonFormField<String>(
              value: selectedPrinter,
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                border: InputBorder.none,
                hintText: 'Seleccionar impresora',
                hintStyle: TextStyle(fontSize: 14, color: Colors.black38),
              ),
              style: const TextStyle(fontSize: 14, color: MangoColors.darkGray),
              icon: const Icon(Icons.arrow_drop_down, color: Colors.black54),
              isExpanded: true,
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('Seleccionar impresora'),
                ),
                ...printers.map((printer) {
                  return DropdownMenuItem<String>(
                    value: printer.id,
                    child: Row(
                      children: [
                        Icon(
                          Icons.print,
                          size: 16,
                          color: printer.online ? Colors.green : Colors.grey,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(printer.name)),
                      ],
                    ),
                  );
                }).toList(),
              ],
              onChanged: onPrinterChanged,
            ),
          ),
        ],
      ),
    );
  }
}
