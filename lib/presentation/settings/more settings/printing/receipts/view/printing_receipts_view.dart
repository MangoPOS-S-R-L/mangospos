import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/areas/viewmodel/print_areas_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/widgets/printer_configuration_dialog.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/widgets/printing_ui.dart';
import 'package:mangopos/services/session/session_controller.dart';

class PrintingReceiptsView extends ConsumerStatefulWidget {
  const PrintingReceiptsView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  ConsumerState<PrintingReceiptsView> createState() =>
      _PrintingReceiptsViewState();
}

class _PrintingReceiptsViewState extends ConsumerState<PrintingReceiptsView> {
  PrintArea? _cashierArea;
  PrintArea? _fiscalArea;
  PrintArea? _closureArea;
  // Printing v2 (Slice 1.5): listas en vez de IDs únicos. Permite asignar
  // N impresoras por tipo de comprobante, lo que destrabba la UX del
  // selector de Pre-Cuenta (que solo aparece con >1 destino).
  List<String> _prebillPrinterIds = const [];
  List<String> _receiptPrinterIds = const [];
  List<String> _closurePrinterIds = const [];
  String _receiptItemDisplayMode = PosSettingsRepository.receiptItemsGrouped;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  String get _resolvedBusinessId {
    if (widget.businessId != 'auto' && widget.businessId.isNotEmpty) {
      return widget.businessId;
    }
    return ref.read(sessionProvider).activeBusinessId ?? '';
  }

  Future<void> _bootstrap() async {
    final businessId = _resolvedBusinessId;
    final areasCtrl = ref.read(printingAreasViewModelProvider.notifier);
    final printersCtrl = ref.read(printingPrintersViewModelProvider.notifier);
    final settingsRepo = ref.read(posSettingsRepositoryProvider);
    await printersCtrl.load(businessId: widget.businessId, force: true);
    final bootstrap = await areasCtrl.bootstrapReceiptAssignments(
      businessId: widget.businessId,
    );
    final receiptItemDisplayMode = businessId.isEmpty
        ? PosSettingsRepository.receiptItemsGrouped
        : await settingsRepo.getReceiptItemDisplayMode(businessId);
    if (!mounted) return;
    setState(() {
      _cashierArea = bootstrap.cashierArea;
      _fiscalArea = bootstrap.fiscalArea;
      _closureArea = bootstrap.closureArea;
      _prebillPrinterIds = bootstrap.prebillPrinterIds;
      _receiptPrinterIds = bootstrap.receiptPrinterIds;
      _closurePrinterIds = bootstrap.closurePrinterIds;
      _receiptItemDisplayMode = receiptItemDisplayMode;
    });
  }

  Future<void> _saveAssignment({
    required PrintArea area,
    required String printerId,
    required bool printsPrebills,
    required bool printsReceipts,
  }) async {
    setState(() => _busy = true);
    final ok = await ref
        .read(printingAreasViewModelProvider.notifier)
        .linkAreaPrinter(
          areaId: area.id,
          printerId: printerId,
          printsOrders: false,
          printsPrebills: printsPrebills,
          printsReceipts: printsReceipts,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      await _bootstrap();
      if (!mounted) return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Asignación guardada.' : 'No se pudo guardar la asignación.',
        ),
      ),
    );
  }

  Future<void> _removeAssignment({
    required PrintArea area,
    required String printerId,
    required bool removesPrebills,
    required bool removesReceipts,
    ValueSetter<String?>? onRemoved,
  }) async {
    setState(() => _busy = true);
    final ok = await ref
        .read(printingAreasViewModelProvider.notifier)
        .unlinkAreaPrinter(
          areaId: area.id,
          printerId: printerId,
          removeOrders: false,
          removePrebills: removesPrebills,
          removeReceipts: removesReceipts,
        );
    if (!mounted) return;
    setState(() {
      _busy = false;
      onRemoved?.call(null);
    });
    if (ok) {
      await _bootstrap();
      if (!mounted) return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Asignación eliminada.' : 'No se pudo eliminar la asignación.',
        ),
      ),
    );
  }

  Future<void> _configurePrinter(PrinterDevice printer) async {
    final vmCtrl = ref.read(printingPrintersViewModelProvider.notifier);
    final changed = await showPrinterConfigurationDialog(
      context,
      printer: printer,
      vmCtrl: vmCtrl,
    );
    if (changed == true) {
      await _bootstrap();
    }
  }

  Future<void> _updateReceiptItemDisplayMode(String mode) async {
    final businessId = _resolvedBusinessId;
    if (businessId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo resolver el negocio activo.')),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      await ref
          .read(posSettingsRepositoryProvider)
          .setReceiptItemDisplayMode(businessId: businessId, mode: mode);
      if (!mounted) return;
      setState(() => _receiptItemDisplayMode = mode);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Formato de artículos guardado.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo guardar el formato.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Abre el picker de impresoras y AGREGA la elegida a la asignación
  /// (no la reemplaza). Excluye del picker las que ya están asignadas.
  Future<void> _addPrinter({
    required PrintArea area,
    required String dialogTitle,
    required bool printsPrebills,
    required bool printsReceipts,
    required List<String> alreadyAssignedIds,
  }) async {
    final available =
        List<PrinterDevice>.from(
          ref.read(printingPrintersViewModelProvider).items,
        )
          ..removeWhere((p) => alreadyAssignedIds.contains(p.id))
          ..sort((a, b) {
            if (a.online == b.online) return a.name.compareTo(b.name);
            return a.online ? -1 : 1;
          });

    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No quedan impresoras disponibles para asignar a este comprobante.',
          ),
        ),
      );
      return;
    }

    final selected = await showDialog<PrinterDevice>(
      context: context,
      builder: (dialogContext) =>
          _ReceiptPrinterPickerDialog(title: dialogTitle, printers: available),
    );
    if (selected == null) return;

    await _saveAssignment(
      area: area,
      printerId: selected.id,
      printsPrebills: printsPrebills,
      printsReceipts: printsReceipts,
    );
  }

  @override
  Widget build(BuildContext context) {
    final printersState = ref.watch(printingPrintersViewModelProvider);
    final printers = printersState.items;
    final loading =
        printersState.isLoading || _cashierArea == null || _fiscalArea == null;

    final printersById = {for (final p in printers) p.id: p};

    List<PrinterDevice> resolve(List<String> ids) {
      return ids
          .map((id) => printersById[id])
          .whereType<PrinterDevice>()
          .toList(growable: false);
    }

    final prebillPrinters = resolve(_prebillPrinterIds);
    final receiptPrinters = resolve(_receiptPrinterIds);
    final closurePrinters = resolve(_closurePrinterIds);

    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
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
        title: const Text('Impresora de comprobantes'),
      ),
      body: PrintingPageShell(
      title: 'Asignar impresora por comprobantes',
      icon: Icons.print_outlined,
      listTitle: 'Lista de comprobantes',
      action: PrintingPrimaryButton(
        label: 'Agregar impresora',
        icon: Icons.add_circle,
        onPressed: () => context.go(AppRoutes.printingPrinters),
      ),
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : printers.isEmpty
          ? const PrintingEmptyState(
              label: 'Primero agrega una impresora para poder asignarla.',
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = constraints.maxWidth < 560
                    ? constraints.maxWidth
                    : 560.0;
                return Wrap(
                  spacing: 22,
                  runSpacing: 22,
                  children: [
                    SizedBox(
                      width: cardWidth,
                      child: _ReceiptItemModeCard(
                        value: _receiptItemDisplayMode,
                        busy: _busy,
                        onChanged: _updateReceiptItemDisplayMode,
                      ),
                    ),
                    SizedBox(
                      width: cardWidth,
                      child: _DocumentAssignmentCard(
                        title: 'C.Final',
                        trailingLabel: 'Area fiscal',
                        assigned: receiptPrinters,
                        busy: _busy,
                        onAdd: () => _addPrinter(
                          area: _fiscalArea!,
                          dialogTitle:
                              'Selecciona impresora para comprobante final',
                          printsPrebills: false,
                          printsReceipts: true,
                          alreadyAssignedIds: _receiptPrinterIds,
                        ),
                        onDelete: (printer) => _removeAssignment(
                          area: _fiscalArea!,
                          printerId: printer.id,
                          removesPrebills: false,
                          removesReceipts: true,
                        ),
                        onConfigure: _configurePrinter,
                      ),
                    ),
                    SizedBox(
                      width: cardWidth,
                      child: _DocumentAssignmentCard(
                        title: 'Prefactura',
                        trailingLabel: 'Area caja',
                        assigned: prebillPrinters,
                        busy: _busy,
                        onAdd: () => _addPrinter(
                          area: _cashierArea!,
                          dialogTitle: 'Selecciona impresora para prefactura',
                          printsPrebills: true,
                          printsReceipts: false,
                          alreadyAssignedIds: _prebillPrinterIds,
                        ),
                        onDelete: (printer) => _removeAssignment(
                          area: _cashierArea!,
                          printerId: printer.id,
                          removesPrebills: true,
                          removesReceipts: false,
                        ),
                        onConfigure: _configurePrinter,
                      ),
                    ),
                    if (_closureArea != null)
                      SizedBox(
                        width: cardWidth,
                        child: _DocumentAssignmentCard(
                          title: 'Cierre de caja',
                          trailingLabel: 'Area cierre',
                          assigned: closurePrinters,
                          busy: _busy,
                          onAdd: () => _addPrinter(
                            area: _closureArea!,
                            dialogTitle:
                                'Selecciona impresora para cierre de caja',
                            printsPrebills: false,
                            printsReceipts: true,
                            alreadyAssignedIds: _closurePrinterIds,
                          ),
                          onDelete: (printer) => _removeAssignment(
                            area: _closureArea!,
                            printerId: printer.id,
                            removesPrebills: false,
                            removesReceipts: true,
                          ),
                          onConfigure: _configurePrinter,
                        ),
                      ),
                  ],
                );
              },
            ),
      ),
    );
  }
}

class _ReceiptItemModeCard extends StatelessWidget {
  const _ReceiptItemModeCard({
    required this.value,
    required this.busy,
    required this.onChanged,
  });

  final String value;
  final bool busy;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return PrintingCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PrintingSoftHeader(
            leading: Icon(
              Icons.view_list_outlined,
              color: MangoColors.darkGray,
            ),
            title: 'Formato de artículos',
          ),
          const SizedBox(height: 12),
          const Text(
            'Elige si en recibos y precuentas los artículos iguales se agrupan o se muestran en líneas separadas.',
            style: TextStyle(fontSize: 13, color: MangoColors.muted),
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment<String>(
                value: PosSettingsRepository.receiptItemsGrouped,
                label: Text('Agrupar'),
                icon: Icon(Icons.merge_type_outlined),
              ),
              ButtonSegment<String>(
                value: PosSettingsRepository.receiptItemsSeparate,
                label: Text('Separar'),
                icon: Icon(Icons.view_stream_outlined),
              ),
            ],
            selected: {value},
            onSelectionChanged: busy
                ? null
                : (selection) {
                    if (selection.isNotEmpty) {
                      onChanged(selection.first);
                    }
                  },
          ),
          const SizedBox(height: 14),
          Text(
            value == PosSettingsRepository.receiptItemsGrouped
                ? 'Ej: 3 Coca-Cola en una sola línea.'
                : 'Ej: Coca-Cola repetida en varias líneas.',
            style: const TextStyle(fontSize: 13, color: MangoColors.muted),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta de asignación de impresoras por comprobante. Soporta múltiples
/// impresoras (Printing v2 — Slice 1.5): cada una se muestra en su propio
/// panel con botones individuales de eliminar/configurar, y un botón
/// "Agregar otra" al final para sumar más.
class _DocumentAssignmentCard extends StatelessWidget {
  const _DocumentAssignmentCard({
    required this.title,
    required this.trailingLabel,
    required this.assigned,
    required this.busy,
    required this.onAdd,
    required this.onDelete,
    required this.onConfigure,
  });

  final String title;
  final String trailingLabel;
  final List<PrinterDevice> assigned;
  final bool busy;
  final VoidCallback onAdd;
  final ValueChanged<PrinterDevice> onDelete;
  final ValueChanged<PrinterDevice> onConfigure;

  @override
  Widget build(BuildContext context) {
    return PrintingCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PrintingSoftHeader(
            leading: const Icon(
              Icons.receipt_long_outlined,
              color: MangoColors.darkGray,
            ),
            title: title,
            trailing: Text(
              trailingLabel,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: MangoColors.primaryOrange,
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (assigned.isEmpty)
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: busy ? null : onAdd,
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFFEAF1FB),
                  foregroundColor: MangoColors.primaryOrange,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('Agregar impresora'),
              ),
            )
          else ...[
            for (final p in assigned) ...[
              _AssignedPrinterRow(
                printer: p,
                busy: busy,
                onDelete: () => onDelete(p),
                onConfigure: () => onConfigure(p),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: busy ? null : onAdd,
                style: OutlinedButton.styleFrom(
                  foregroundColor: MangoColors.primaryOrange,
                  side: const BorderSide(color: MangoColors.primaryOrange),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('Agregar otra impresora'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AssignedPrinterRow extends StatelessWidget {
  const _AssignedPrinterRow({
    required this.printer,
    required this.busy,
    required this.onDelete,
    required this.onConfigure,
  });

  final PrinterDevice printer;
  final bool busy;
  final VoidCallback onDelete;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    return PrintingDashedPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.print_outlined,
                size: 22,
                color: MangoColors.darkGray,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      printer.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    Text(
                      _transportLabel(printer.type),
                      style: const TextStyle(
                        fontSize: 12,
                        color: MangoColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              PrintingStatusCluster(online: printer.online),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFD4D4D4)),
          const SizedBox(height: 12),
          Text(
            'IP: ${printer.ip?.isNotEmpty == true ? printer.ip! : 'No configurada'}',
            style: const TextStyle(
              fontSize: 13,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            printer.type == PrinterType.usb
                ? 'USB: ${printer.devicePath?.isNotEmpty == true ? printer.devicePath! : (printer.mac?.isNotEmpty == true ? printer.mac! : 'No disponible')}'
                : 'MAC: ${printer.mac?.isNotEmpty == true ? printer.mac! : 'No disponible'}',
            style: const TextStyle(
              fontSize: 13,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              PrintingActionButton(
                label: 'Eliminar',
                icon: Icons.delete_outline,
                foreground: const Color(0xFFEF5350),
                background: const Color(0xFFFFF1F1),
                onPressed: busy ? null : onDelete,
              ),
              const SizedBox(width: 10),
              PrintingActionButton(
                label: 'Conf. imp.',
                icon: Icons.settings_outlined,
                foreground: const Color(0xFF376E86),
                background: const Color(0xFFE7EFF1),
                onPressed: busy ? null : onConfigure,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _transportLabel(PrinterType type) => switch (type) {
        PrinterType.network => 'Red / LAN',
        PrinterType.bluetooth => 'Bluetooth',
        PrinterType.usb => 'USB',
      };
}

class _ReceiptPrinterPickerDialog extends StatelessWidget {
  const _ReceiptPrinterPickerDialog({
    required this.title,
    required this.printers,
  });

  final String title;
  final List<PrinterDevice> printers;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SizedBox(
        width: 520,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                ),
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: printers.length,
                  separatorBuilder: (_, index) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final printer = printers[index];
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(printer),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFD4D4D4)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.print_outlined),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    printer.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: MangoColors.darkGray,
                                    ),
                                  ),
                                  Text(
                                    printer.type == PrinterType.usb
                                        ? 'USB: ${printer.devicePath?.isNotEmpty == true ? printer.devicePath! : (printer.mac?.isNotEmpty == true ? printer.mac! : 'Sin identificador USB')}'
                                        : (printer.ip?.isNotEmpty == true
                                              ? 'IP: ${printer.ip}'
                                              : 'Sin IP configurada'),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: MangoColors.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PrintingStatusCluster(online: printer.online),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cerrar'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
