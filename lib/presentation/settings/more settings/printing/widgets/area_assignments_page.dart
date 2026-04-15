import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/presentation/settings/more settings/printing/areas/viewmodel/print_areas_viewmodel.dart';
import 'package:mangopos/presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/presentation/settings/more settings/printing/widgets/printer_configuration_dialog.dart';
import 'package:mangopos/presentation/settings/more settings/printing/widgets/printing_ui.dart';

typedef AreaMetaBuilder =
    String Function(PrintArea area, List<PrinterConfig> printers);

class PrintingAreaAssignmentsPage extends ConsumerStatefulWidget {
  const PrintingAreaAssignmentsPage({
    super.key,
    required this.businessId,
    required this.title,
    required this.listTitle,
    required this.actionLabel,
    required this.addAreaDialogTitle,
    required this.areaMetaBuilder,
    this.excludedAreaCodes = const ['cashier', 'fiscal'],
  });

  final String businessId;
  final String title;
  final String listTitle;
  final String actionLabel;
  final String addAreaDialogTitle;
  final AreaMetaBuilder areaMetaBuilder;
  final List<String> excludedAreaCodes;

  @override
  ConsumerState<PrintingAreaAssignmentsPage> createState() =>
      _PrintingAreaAssignmentsPageState();
}

class _PrintingAreaAssignmentsPageState
    extends ConsumerState<PrintingAreaAssignmentsPage> {
  final Map<String, List<PrinterConfig>> _assignedByArea = {};
  final Map<String, List<PrintAreaPrinter>> _assignmentsByArea = {};
  final Set<String> _loadingAreaIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final areasCtrl = ref.read(printingAreasViewModelProvider.notifier);
    final printersCtrl = ref.read(printingPrintersViewModelProvider.notifier);
    await areasCtrl.load(businessId: widget.businessId, force: true);
    await printersCtrl.load(businessId: widget.businessId, force: true);
    final areas = ref.read(printingAreasViewModelProvider).items;
    final visibleAreas = areas
        .where((area) => !widget.excludedAreaCodes.contains(area.code))
        .toList();
    if (mounted) {
      setState(() {
        _assignedByArea.clear();
        _loadingAreaIds.clear();
      });
    }
    for (final area in visibleAreas) {
      await _loadAssignedPrinters(area.id);
    }
  }

  Future<void> _loadAssignedPrinters(String areaId) async {
    setState(() => _loadingAreaIds.add(areaId));
    try {
      final repo = ref.read(printingAreasRepositoryProvider);
      final printers = await repo.getPrintersForArea(areaId);
      if (!mounted) return;
      final assignments = await repo.getAreaPrinterAssignments(areaId);
      setState(() {
        _assignedByArea[areaId] = printers;
        _assignmentsByArea[areaId] = assignments;
        _loadingAreaIds.remove(areaId);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingAreaIds.remove(areaId));
    }
  }

  Future<void> _showAddAreaDialog() async {
    final ctrl = TextEditingController();
    final areasCtrl = ref.read(printingAreasViewModelProvider.notifier);
    final created = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(widget.addAreaDialogTitle),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nombre del área'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () async {
              final ok = await areasCtrl.createArea(name: ctrl.text);
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop(ok);
              }
            },
            child: const Text('Agregar'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (created == true) {
      await _bootstrap();
    }
  }

  Future<void> _selectPrinterForArea(PrintArea area) async {
    final areasCtrl = ref.read(printingAreasViewModelProvider.notifier);
    final printersCtrl = ref.read(printingPrintersViewModelProvider.notifier);
    final printers =
        List<PrinterDevice>.from(
          ref.read(printingPrintersViewModelProvider).items,
        )..sort((a, b) {
          if (a.online == b.online) return a.name.compareTo(b.name);
          return a.online ? -1 : 1;
        });

    final selectedPrinter = await showDialog<PrinterDevice>(
      context: context,
      builder: (dialogContext) => _PrinterPickerDialog(
        title: 'Asignar impresora a ${area.name}',
        printers: printers,
      ),
    );

    if (selectedPrinter == null) return;
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final ok = await areasCtrl.linkAreaPrinter(
      areaId: area.id,
      printerId: selectedPrinter.id,
      printsOrders: true,
    );
    if (!mounted) return;

    if (ok) {
      await _loadAssignedPrinters(area.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Impresora ${selectedPrinter.name} asignada a ${area.name}.',
          ),
        ),
      );
    } else {
      final message =
          ref.read(printingAreasViewModelProvider).errorMessage ??
          'No se pudo asignar la impresora.';
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }

    await printersCtrl.load(businessId: widget.businessId, force: true);
  }

  Future<void> _removePrinterAssignment(
    PrintArea area,
    PrinterConfig printer,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar asignación'),
        content: Text('Se quitará ${printer.name} del área ${area.name}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref
        .read(printingAreasViewModelProvider.notifier)
        .unlinkAreaPrinter(
          areaId: area.id,
          printerId: printer.id,
          removeOrders: true,
          removePrebills: false,
          removeReceipts: false,
        );
    if (!mounted) return;

    if (ok) {
      await _loadAssignedPrinters(area.id);
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Asignación eliminada.'
              : (ref.read(printingAreasViewModelProvider).errorMessage ??
                    'No se pudo eliminar la asignación.'),
        ),
      ),
    );
  }

  Future<void> _configurePrinter(PrinterConfig printer) async {
    final printersCtrl = ref.read(printingPrintersViewModelProvider.notifier);
    final changed = await showPrinterConfigurationDialog(
      context,
      printer: PrinterDevice.fromConfig(printer),
      vmCtrl: printersCtrl,
    );
    if (changed == true) {
      await printersCtrl.load(businessId: widget.businessId, force: true);
      await _bootstrap();
    }
  }

  @override
  Widget build(BuildContext context) {
    final areasState = ref.watch(printingAreasViewModelProvider);
    final visibleAreas = areasState.items
        .where((area) => !widget.excludedAreaCodes.contains(area.code))
        .toList();

    if (areasState.isLoading && visibleAreas.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (areasState.errorMessage != null && visibleAreas.isEmpty) {
      return Center(child: Text(areasState.errorMessage!));
    }

    return PrintingPageShell(
      title: widget.title,
      icon: Icons.print_outlined,
      listTitle: widget.listTitle,
      action: PrintingPrimaryButton(
        label: widget.actionLabel,
        icon: Icons.add_circle,
        onPressed: _showAddAreaDialog,
      ),
      child: visibleAreas.isEmpty
          ? const PrintingEmptyState(
              label:
                  'No hay áreas registradas todavía.\nAgrega una para comenzar.',
              icon: Icons.storefront_outlined,
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = constraints.maxWidth < 520
                    ? constraints.maxWidth
                    : 470.0;
                return Wrap(
                  spacing: 20,
                  runSpacing: 20,
                  children: visibleAreas.map((area) {
                    final assignedPrinters =
                        _assignedByArea[area.id] ?? const [];
                    final isLoading = _loadingAreaIds.contains(area.id);
                    return SizedBox(
                      width: cardWidth,
                      child: PrintingCardFrame(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            PrintingSoftHeader(
                              leading: const Icon(
                                Icons.storefront_outlined,
                                color: MangoColors.darkGray,
                              ),
                              title: area.name,
                              trailing: Text(
                                widget.areaMetaBuilder(area, assignedPrinters),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: MangoColors.darkGray,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: TextButton.icon(
                                onPressed: () => _selectPrinterForArea(area),
                                style: TextButton.styleFrom(
                                  backgroundColor: const Color(0xFFEAF1FB),
                                  foregroundColor: const Color(0xFF4280E9),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                icon: const Icon(Icons.add_circle_outline),
                                label: const Text('Agregar impresora'),
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (isLoading)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 32),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else if (assignedPrinters.isEmpty)
                              const PrintingDashedPanel(
                                child: PrintingEmptyState(
                                  label:
                                      'No hay impresoras vinculadas en esta área.',
                                ),
                              )
                            else
                              Column(
                                children: assignedPrinters.map((printer) {
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: PrintingDashedPanel(
                                      child: _AssignedPrinterCard(
                                        printer: printer,
                                        assignment: (() {
                                          final matches =
                                              (_assignmentsByArea[area.id] ??
                                                      const [])
                                                  .where(
                                                    (a) =>
                                                        a.printerId ==
                                                        printer.id,
                                                  )
                                                  .toList(growable: false);
                                          return matches.isEmpty
                                              ? null
                                              : matches.first;
                                        })(),
                                        onDelete: () =>
                                            _removePrinterAssignment(
                                              area,
                                              printer,
                                            ),
                                        onConfigure: () =>
                                            _configurePrinter(printer),
                                        onToggleModes:
                                            (sendToKitchen, markReady) async {
                                              final ok = await ref
                                                  .read(
                                                    printingAreasViewModelProvider
                                                        .notifier,
                                                  )
                                                  .updateAreaPrinterModes(
                                                    areaId: area.id,
                                                    printerId: printer.id,
                                                    printsOrders: sendToKitchen,
                                                    printsReceipts: markReady,
                                                  );
                                              if (ok) {
                                                await _loadAssignedPrinters(
                                                  area.id,
                                                );
                                              }
                                            },
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
    );
  }
}

class _AssignedPrinterCard extends StatelessWidget {
  const _AssignedPrinterCard({
    required this.printer,
    required this.assignment,
    required this.onDelete,
    required this.onConfigure,
    required this.onToggleModes,
  });

  final PrinterConfig printer;
  final PrintAreaPrinter? assignment;
  final VoidCallback onDelete;
  final VoidCallback onConfigure;
  final Future<void> Function(bool sendToKitchen, bool markReady) onToggleModes;

  @override
  Widget build(BuildContext context) {
    final deviceRef = printer.devicePath?.isNotEmpty == true
        ? printer.devicePath!
        : (printer.mac?.isNotEmpty == true ? printer.mac! : 'No disponible');
    final isUsb = printer.printerType == PrinterType.usb;

    return Column(
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
                  const Text(
                    'Genérica',
                    style: TextStyle(fontSize: 12, color: MangoColors.muted),
                  ),
                ],
              ),
            ),
            PrintingStatusCluster(online: printer.online),
            const SizedBox(width: 10),
            OutlinedButton(
              onPressed: onConfigure,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF4280E9),
                side: const BorderSide(color: Color(0xFF4280E9)),
                minimumSize: const Size(44, 38),
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Icon(Icons.print_outlined),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Divider(height: 1, color: Color(0xFFD4D4D4)),
        const SizedBox(height: 12),
        Text(
          'IP: ${printer.ipAddress?.isNotEmpty == true ? printer.ipAddress! : 'No configurada'}',
          style: const TextStyle(fontSize: 13, color: MangoColors.darkGray),
        ),
        const SizedBox(height: 6),
        Text(
          isUsb ? 'USB: $deviceRef' : 'MAC: $deviceRef',
          style: const TextStyle(fontSize: 13, color: MangoColors.darkGray),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            children: [
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Imprimir al enviar a cocina'),
                subtitle: const Text('Comanda sale al enviar desde la mesa.'),
                value: assignment?.printsOrders == true,
                onChanged: (value) =>
                    onToggleModes(value, assignment?.printsReceipts == true),
              ),
              const Divider(height: 1),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Imprimir al marcar listo'),
                subtitle: const Text(
                  'Comanda sale desde la pantalla de cocina.',
                ),
                value: assignment?.printsReceipts == true,
                onChanged: (value) =>
                    onToggleModes(assignment?.printsOrders == true, value),
              ),
            ],
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
              onPressed: onDelete,
            ),
            const SizedBox(width: 10),
            PrintingActionButton(
              label: 'Conf. imp.',
              icon: Icons.settings_outlined,
              foreground: const Color(0xFF376E86),
              background: const Color(0xFFE7EFF1),
              onPressed: onConfigure,
            ),
          ],
        ),
      ],
    );
  }
}

class _PrinterPickerDialog extends StatelessWidget {
  const _PrinterPickerDialog({required this.title, required this.printers});

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
              const SizedBox(height: 16),
              if (printers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('No hay impresoras disponibles.'),
                )
              else
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
                                          ? 'USB: ${printer.devicePath?.isNotEmpty == true ? printer.devicePath! : (printer.mac?.isNotEmpty == true ? printer.mac! : 'Sin identificador USB')} '
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
