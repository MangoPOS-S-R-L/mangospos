import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

class PrintingProductsView extends ConsumerStatefulWidget {
  final String businessId;
  const PrintingProductsView({super.key, this.businessId = 'auto'});

  @override
  ConsumerState<PrintingProductsView> createState() =>
      _PrintingProductsViewState();
}

class _PrintingProductsViewState extends ConsumerState<PrintingProductsView> {
  // Datos de ejemplo - deberás conectar esto con tu backend
  final List<PrinterWithCategories> printers = [
    PrinterWithCategories(
      name: 'Default Thermal Printer',
      type: 'Impresión por Ventana',
      categories: ['Bebidas', 'Postres'],
    ),
    PrinterWithCategories(
      name: 'Impresora Cocina',
      type: 'Red/IP',
      categories: ['Bebidas', 'Postres'],
    ),
    PrinterWithCategories(
      name: 'Impresora Bar',
      type: 'USB Directo',
      categories: ['Bebidas', 'Postres'],
    ),
  ];

  @override
  Widget build(BuildContext context) {
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
              onPressed: () => context.go(AppRoutes.settings),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Regresar'),
            ),
            const SizedBox(height: 12),
            const Text(
              'Asignar Impresión de Productos',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Selecciona qué productos se imprimen en cada impresora',
              style: TextStyle(fontSize: 14, color: Colors.black54),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: 0.9,
                ),
                itemCount: printers.length,
                itemBuilder: (_, index) {
                  final printer = printers[index];
                  return _PrinterCard(
                    printer: printer,
                    onAddCategory: () =>
                        _showAddCategoryDialog(context, printer),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddCategoryDialog(
    BuildContext context,
    PrinterWithCategories printer,
  ) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Agregar categoría a ${printer.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Selecciona las categorías de productos:'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: ['Bebidas', 'Postres', 'Comidas', 'Entradas', 'Pizzas']
                  .map((cat) {
                    final isSelected = printer.categories.contains(cat);
                    return FilterChip(
                      label: Text(cat),
                      selected: isSelected,
                      onSelected: (selected) {
                        setState(() {
                          if (selected) {
                            printer.categories.add(cat);
                          } else {
                            printer.categories.remove(cat);
                          }
                        });
                        Navigator.of(dialogContext).pop();
                      },
                    );
                  })
                  .toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }
}

class PrinterWithCategories {
  final String name;
  final String type;
  final List<String> categories;

  PrinterWithCategories({
    required this.name,
    required this.type,
    required this.categories,
  });
}

class _PrinterCard extends StatelessWidget {
  final PrinterWithCategories printer;
  final VoidCallback onAddCategory;

  const _PrinterCard({required this.printer, required this.onAddCategory});

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Color(0xFFFFF4E6),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.print,
                    color: Color(0xFFFF9800),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        printer.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: MangoColors.darkGray,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        printer.type,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Body
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Categorías de productos asignadas:',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: printer.categories.map((category) {
                          return Chip(
                            label: Text(
                              category,
                              style: const TextStyle(fontSize: 11),
                            ),
                            backgroundColor: const Color(0xFFF5F5F5),
                            deleteIcon: const Icon(Icons.close, size: 14),
                            onDeleted: () {
                              // Aquí implementarías la lógica para eliminar
                            },
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            labelPadding: const EdgeInsets.symmetric(
                              horizontal: 6,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: onAddCategory,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Agregar'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF2196F3),
                        side: const BorderSide(color: Color(0xFF2196F3)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
