import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

class PrintingReceiptsView extends ConsumerStatefulWidget {
  final String businessId;
  const PrintingReceiptsView({super.key, this.businessId = 'auto'});

  @override
  ConsumerState<PrintingReceiptsView> createState() =>
      _PrintingReceiptsViewState();
}

class _PrintingReceiptsViewState extends ConsumerState<PrintingReceiptsView> {
  // Datos de ejemplo - deberás conectar esto con tu backend
  final List<ReceiptType> receiptTypes = [
    ReceiptType(
      code: 'B01',
      name: 'Crédito Fiscal',
      description: 'Para clientes con RNC',
      selectedPrinter: null,
    ),
    ReceiptType(
      code: 'B02',
      name: 'Consumidor Final',
      description: 'Para consumidores sin RNC',
      selectedPrinter: null,
    ),
    ReceiptType(
      code: 'B14',
      name: 'Gubernamental',
      description: 'Para entidades gubernamentales',
      selectedPrinter: null,
    ),
    ReceiptType(
      code: 'B15',
      name: 'Regímenes Especiales',
      description: 'Para zonas francas y otros',
      selectedPrinter: null,
    ),
  ];

  final List<String> availablePrinters = [
    'Impresora Principal',
    'Impresora Backup',
    'Impresora Fiscal',
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
              onPressed: () => context.go(AppRoutes.printingBase),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Regresar'),
            ),
            const SizedBox(height: 12),
            const Text(
              'Asignar Impresión de Comprobantes',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Configura qué impresora emite cada tipo de comprobante fiscal',
              style: TextStyle(fontSize: 14, color: Colors.black54),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 24,
                  mainAxisSpacing: 24,
                  childAspectRatio: 2.5,
                ),
                itemCount: receiptTypes.length,
                itemBuilder: (_, index) {
                  final receipt = receiptTypes[index];
                  return _ReceiptTypeCard(
                    receipt: receipt,
                    printers: availablePrinters,
                    onPrinterChanged: (printer) {
                      setState(() {
                        receipt.selectedPrinter = printer;
                      });
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ReceiptType {
  final String code;
  final String name;
  final String description;
  String? selectedPrinter;

  ReceiptType({
    required this.code,
    required this.name,
    required this.description,
    this.selectedPrinter,
  });
}

class _ReceiptTypeCard extends StatelessWidget {
  final ReceiptType receipt;
  final List<String> printers;
  final Function(String?) onPrinterChanged;

  const _ReceiptTypeCard({
    required this.receipt,
    required this.printers,
    required this.onPrinterChanged,
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
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.receipt_long,
                  color: Color(0xFF66BB6A),
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${receipt.code} - ${receipt.name}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      receipt.description,
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
              value: receipt.selectedPrinter,
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
                    value: printer,
                    child: Text(printer),
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
