import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/areas/viewmodel/print_areas_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';

class PrintingReceiptsView extends ConsumerStatefulWidget {
  final String businessId;
  const PrintingReceiptsView({super.key, this.businessId = 'auto'});

  @override
  ConsumerState<PrintingReceiptsView> createState() =>
      _PrintingReceiptsViewState();
}

class _PrintingReceiptsViewState extends ConsumerState<PrintingReceiptsView> {
  PrintArea? _cashierArea;
  PrintArea? _fiscalArea;
  String? _selectedPrebillPrinter;
  String? _selectedReceiptPrinter;
  bool _savingPrebill = false;
  bool _savingReceipt = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final areasCtrl = ref.read(printingAreasViewModelProvider.notifier);
    final printersCtrl = ref.read(printingPrintersViewModelProvider.notifier);

    await printersCtrl.load(businessId: widget.businessId);
    final bootstrap = await areasCtrl.bootstrapReceiptAssignments(
      businessId: widget.businessId,
    );

    if (!mounted) return;
    setState(() {
      _cashierArea = bootstrap.cashierArea;
      _fiscalArea = bootstrap.fiscalArea;
      _selectedPrebillPrinter = bootstrap.selectedPrebillPrinter;
      _selectedReceiptPrinter = bootstrap.selectedReceiptPrinter;
    });
  }

  Future<void> _savePrebillPrinter() async {
    final areasCtrl = ref.read(printingAreasViewModelProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final area = _cashierArea;
    final printerId = _selectedPrebillPrinter;

    if (area == null || printerId == null || printerId.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Selecciona una impresora para precuenta.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _savingPrebill = true);
    final ok = await areasCtrl.linkAreaPrinter(
      areaId: area.id,
      printerId: printerId,
      printsOrders: false,
      printsPrebills: true,
      printsReceipts: false,
    );
    if (!mounted) return;
    setState(() => _savingPrebill = false);

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Impresora de precuenta guardada.'
              : 'No se pudo guardar la impresora de precuenta.',
        ),
        backgroundColor: ok ? const Color(0xFF22C55E) : Colors.red,
      ),
    );
  }

  Future<void> _saveReceiptPrinter() async {
    final areasCtrl = ref.read(printingAreasViewModelProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final area = _fiscalArea;
    final printerId = _selectedReceiptPrinter;

    if (area == null || printerId == null || printerId.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Selecciona una impresora para recibo/factura.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _savingReceipt = true);
    final ok = await areasCtrl.linkAreaPrinter(
      areaId: area.id,
      printerId: printerId,
      printsOrders: false,
      printsPrebills: false,
      printsReceipts: true,
    );
    if (!mounted) return;
    setState(() => _savingReceipt = false);

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Impresora de recibo/factura guardada.'
              : 'No se pudo guardar la impresora de recibo/factura.',
        ),
        backgroundColor: ok ? const Color(0xFF22C55E) : Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final printersState = ref.watch(printingPrintersViewModelProvider);
    final printers = printersState.items;
    final loading = _cashierArea == null || _fiscalArea == null;

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
              'Asignar Impresión de Comprobantes',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Configura una impresora para precuenta y otra para recibos/facturas. Igual de limpio que comandas, sin duplicar áreas innecesarias.',
              style: TextStyle(fontSize: 14, color: Colors.black54),
            ),
            const SizedBox(height: 24),
            if (loading || printersState.isLoading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (printers.isEmpty)
              const Expanded(
                child: Center(
                  child: Text(
                    'Primero crea al menos una impresora.',
                    style: TextStyle(color: Colors.black54),
                  ),
                ),
              )
            else
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  crossAxisSpacing: 24,
                  mainAxisSpacing: 24,
                  childAspectRatio: 1.7,
                  children: [
                    _ReceiptAssignmentCard(
                      title: 'Precuenta',
                      subtitle:
                          'Se usa cuando el cliente pide ver la cuenta antes de pagar.',
                      areaName: _cashierArea?.name ?? 'Caja',
                      printers: printers,
                      selectedPrinter: _selectedPrebillPrinter,
                      saving: _savingPrebill,
                      onChanged: (value) {
                        setState(() => _selectedPrebillPrinter = value);
                      },
                      onSave: _savePrebillPrinter,
                    ),
                    _ReceiptAssignmentCard(
                      title: 'Recibo / Factura',
                      subtitle:
                          'Se usa al cobrar y emitir el comprobante final.',
                      areaName: _fiscalArea?.name ?? 'Fiscal',
                      printers: printers,
                      selectedPrinter: _selectedReceiptPrinter,
                      saving: _savingReceipt,
                      onChanged: (value) {
                        setState(() => _selectedReceiptPrinter = value);
                      },
                      onSave: _saveReceiptPrinter,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReceiptAssignmentCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String areaName;
  final List<PrinterDevice> printers;
  final String? selectedPrinter;
  final bool saving;
  final ValueChanged<String?> onChanged;
  final Future<void> Function() onSave;

  const _ReceiptAssignmentCard({
    required this.title,
    required this.subtitle,
    required this.areaName,
    required this.printers,
    required this.selectedPrinter,
    required this.saving,
    required this.onChanged,
    required this.onSave,
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
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 8),
          Text(
            'Área lógica: $areaName',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 18),
          DropdownButtonFormField<String>(
            initialValue: selectedPrinter,
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
              ),
            ),
            items: printers
                .map(
                  (printer) => DropdownMenuItem<String>(
                    value: printer.id,
                    child: Text(printer.name),
                  ),
                )
                .toList(),
            onChanged: saving ? null : onChanged,
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: saving ? null : onSave,
              icon: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_outlined, size: 18),
              label: Text(saving ? 'Guardando...' : 'Guardar'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF42A5F5),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
