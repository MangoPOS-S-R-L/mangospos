import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/areas/viewmodel/print_areas_viewmodel.dart';

class PrintingAreasView extends ConsumerStatefulWidget {
  final String businessId;
  const PrintingAreasView({super.key, this.businessId = 'auto'});

  @override
  ConsumerState<PrintingAreasView> createState() => _PrintingAreasViewState();
}

class _PrintingAreasViewState extends ConsumerState<PrintingAreasView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    final vm = ref.watch(printingAreasViewModelProvider);
    final vmCtrl = ref.read(printingAreasViewModelProvider.notifier);

    if (vm.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (vm.errorMessage != null && vm.items.isEmpty) {
      return _ErrorBox(message: vm.errorMessage!, onRetry: vmCtrl.refresh);
    }

    final errorMessage = vm.errorMessage;

    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: Colors.black87,
                padding: EdgeInsets.zero,
              ),
              onPressed: () => context.go(AppRoutes.settings),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Regresar'),
            ),
          ),
          // Header con título y botón
          Container(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                const Text(
                  'Lista de áreas de producción',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.black87,
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () => _showAddAreaDialog(context, vmCtrl),
                  icon: const Icon(Icons.add_circle, size: 20),
                  label: const Text(
                    'Agregar área donde se prepara el producto',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2196F3),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
          ),

          if (errorMessage != null && vm.items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: _InlineError(message: errorMessage),
            ),

          // Lista de áreas en horizontal
          Expanded(
            child: vm.items.isEmpty
                ? const _EmptyHint()
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 8,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: vm.items.map((area) {
                        // Usamos un ValueKey para identificar cada área
                        return Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: _AreaCard(
                            key: ValueKey('area_${area.id}'),
                            area: area,
                            onAddPrinter: () async {
                              final result = await _showEditPrinterDialog(
                                context,
                                ref,
                                vmCtrl,
                                area,
                                widget.businessId,
                              );
                              // Si se guardó exitosamente, refrescamos la vista completa
                              if (result == true) {
                                vmCtrl.refresh();
                              }
                            },
                            onDeleteArea: () => _confirmDeleteArea(
                              context,
                              onConfirm: () => vmCtrl.deleteArea(area.id),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _showAddAreaDialog(BuildContext context, PrintingAreasViewModel vmCtrl) {
    final nameCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          width: 700,
          constraints: const BoxConstraints(maxHeight: 600),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 20, 20),
                child: Row(
                  children: [
                    const Icon(
                      Icons.add_circle_outline,
                      color: Color(0xFF2196F3),
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Agregar área donde se prepara el producto',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
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
              ),

              const Divider(height: 1, color: Color(0xFFE0E0E0)),

              // Content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Nombre del área donde prepara el producto',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: nameCtrl,
                                  autofocus: true,
                                  decoration: InputDecoration(
                                    hintText: 'Ingrese el nombre del área',
                                    hintStyle: const TextStyle(
                                      color: Colors.black38,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                        color: Color(0xFFE0E0E0),
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                        color: Color(0xFFE0E0E0),
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                        color: Color(0xFF2196F3),
                                        width: 2,
                                      ),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Almacén',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                DropdownButtonFormField<String>(
                                  initialValue: 'Almacén Principal',
                                  decoration: InputDecoration(
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                        color: Color(0xFFE0E0E0),
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                        color: Color(0xFFE0E0E0),
                                      ),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 14,
                                    ),
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'Almacén Principal',
                                      child: Text('Almacén Principal'),
                                    ),
                                  ],
                                  onChanged: (v) {},
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Footer
              Container(
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: Color(0xFFE0E0E0))),
                ),
                padding: const EdgeInsets.all(24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.cancel_outlined, size: 20),
                      label: const Text('Cancelar'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.black87,
                        side: const BorderSide(color: Color(0xFFE0E0E0)),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: () async {
                        if (nameCtrl.text.trim().isEmpty) return;
                        final created = await vmCtrl.createArea(
                          name: nameCtrl.text,
                        );
                        if (created && dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                      },
                      icon: const Icon(Icons.add_circle, size: 20),
                      label: const Text('Agregar'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2196F3),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDeleteArea(
    BuildContext context, {
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar área'),
        content: const Text(
          'Esta acción no se puede deshacer. ¿Deseas continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              onConfirm();
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showEditPrinterDialog(
    BuildContext context,
    WidgetRef ref,
    PrintingAreasViewModel vmCtrl,
    dynamic area,
    String businessId,
  ) {
    final printersState = ref.read(printingPrintersViewModelProvider);
    final printers = printersState.items;

    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return _EditPrinterDialog(
          area: area,
          printers: printers,
          isLoading: printersState.isLoading,
          vmCtrl: vmCtrl,
        );
      },
    );
  }
}

class _AreaCard extends ConsumerStatefulWidget {
  final PrintArea area;
  final VoidCallback onAddPrinter;
  final VoidCallback onDeleteArea;

  const _AreaCard({
    super.key,
    required this.area,
    required this.onAddPrinter,
    required this.onDeleteArea,
  });

  @override
  ConsumerState<_AreaCard> createState() => _AreaCardState();
}

class _AreaCardState extends ConsumerState<_AreaCard> {
  List<PrinterConfig> assignedPrinters = [];
  bool isLoadingPrinters = false;

  @override
  void initState() {
    super.initState();
    _loadAssignedPrinters();
  }

  Future<void> _loadAssignedPrinters() async {
    setState(() => isLoadingPrinters = true);
    try {
      final repo = ref.read(printingAreasRepositoryProvider);
      final printers = await repo.getPrintersForArea(widget.area.id);
      if (mounted) {
        setState(() {
          assignedPrinters = printers;
          isLoadingPrinters = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => isLoadingPrinters = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE0E0E0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header del área
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              color: Color(0xFFF5F5F5),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.restaurant, size: 24, color: Colors.black87),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.area.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${assignedPrinters.length} productos',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Contenido: impresoras o estado vacío
          Padding(
            padding: const EdgeInsets.all(20),
            child: isLoadingPrinters
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(),
                    ),
                  )
                : assignedPrinters.isEmpty
                ? _EmptyPrinterState(onTap: widget.onAddPrinter)
                : Column(
                    children: assignedPrinters.map((printer) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _AssignedPrinterItem(printer: printer),
                      );
                    }).toList(),
                  ),
          ),

          // Footer con botón de agregar impresora
          if (assignedPrinters.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: OutlinedButton.icon(
                onPressed: widget.onAddPrinter,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Agregar impresora'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF2196F3),
                  side: const BorderSide(color: Color(0xFF2196F3)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  minimumSize: const Size(double.infinity, 0),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Estado vacío cuando no hay impresoras asignadas
class _EmptyPrinterState extends StatelessWidget {
  final VoidCallback onTap;

  const _EmptyPrinterState({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        decoration: BoxDecoration(
          border: Border.all(
            color: const Color(0xFF2196F3),
            width: 2,
            style: BorderStyle.solid,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.add_circle_outline, size: 48, color: Color(0xFF2196F3)),
            SizedBox(height: 12),
            Text(
              'Da clic para asignar\nuna impresora',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2196F3),
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Item de impresora asignada
class _AssignedPrinterItem extends StatelessWidget {
  final PrinterConfig printer;

  const _AssignedPrinterItem({required this.printer});

  @override
  Widget build(BuildContext context) {
    final name = printer.name;
    final ipAddress = printer.ipAddress ?? '';
    final macAddress = printer.devicePath ?? '';
    final isOnline = printer.isActive;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Row(
        children: [
          const Icon(Icons.print, size: 20, color: Colors.black54),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                    if (isOnline)
                      const Icon(
                        Icons.wifi,
                        size: 14,
                        color: Color(0xFF4CAF50),
                      ),
                    const SizedBox(width: 4),
                    Icon(
                      isOnline ? Icons.check_circle : Icons.circle_outlined,
                      size: 14,
                      color: isOnline ? const Color(0xFF4CAF50) : Colors.grey,
                    ),
                  ],
                ),
                if (ipAddress.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'IP: $ipAddress',
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ],
                if (macAddress.isNotEmpty) ...[
                  Text(
                    'MAC: $macAddress',
                    style: const TextStyle(fontSize: 10, color: Colors.black45),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () {
                  // Eliminar impresora
                },
                icon: const Icon(Icons.delete_outline, size: 18),
                color: Colors.red,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Eliminar',
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () {
                  // Configurar impresora
                },
                icon: const Icon(Icons.settings_outlined, size: 18),
                color: const Color(0xFF2196F3),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Conf. imp.',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EditPrinterDialog extends StatefulWidget {
  final dynamic area;
  final List printers;
  final bool isLoading;
  final PrintingAreasViewModel vmCtrl;

  const _EditPrinterDialog({
    required this.area,
    required this.printers,
    required this.isLoading,
    required this.vmCtrl,
  });

  @override
  State<_EditPrinterDialog> createState() => _EditPrinterDialogState();
}

class _EditPrinterDialogState extends State<_EditPrinterDialog> {
  String? selectedPrinterId;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 700,
        constraints: const BoxConstraints(maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 20, 20),
              child: Row(
                children: [
                  const Icon(
                    Icons.add_circle_outline,
                    color: Color(0xFF2196F3),
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Asignar impresora a: ${widget.area.name}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.black54),
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),

            const Divider(height: 1, color: Color(0xFFE0E0E0)),

            // Content
            Expanded(
              child: widget.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : widget.printers.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'No hay impresoras disponibles',
                          style: TextStyle(color: Colors.black54, fontSize: 15),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(24),
                      itemCount: widget.printers.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final printer = widget.printers[index];
                        final printerId = printer.id;
                        final isSelected = selectedPrinterId == printerId;

                        return _PrinterListItem(
                          printer: printer,
                          isSelected: isSelected,
                          onTap: () {
                            setState(() {
                              selectedPrinterId = isSelected ? null : printerId;
                            });
                          },
                        );
                      },
                    ),
            ),

            // Footer
            Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xFFE0E0E0))),
              ),
              padding: const EdgeInsets.all(24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.cancel_outlined, size: 20),
                    label: const Text('Cancelar'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.black87,
                      side: const BorderSide(color: Color(0xFFE0E0E0)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: selectedPrinterId == null
                        ? null
                        : () async {
                            final success = await widget.vmCtrl.linkAreaPrinter(
                              areaId: widget.area.id,
                              printerId: selectedPrinterId!,
                            );

                            if (context.mounted) {
                              Navigator.of(context).pop(success);
                            }
                          },
                    icon: const Icon(Icons.add_circle, size: 20),
                    label: const Text('Agregar'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2196F3),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      disabledBackgroundColor: Colors.grey.shade300,
                    ),
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

class _PrinterListItem extends StatelessWidget {
  final PrinterDevice printer;
  final bool isSelected;
  final VoidCallback onTap;

  const _PrinterListItem({
    required this.printer,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = printer.name;
    final ipAddress = printer.ip ?? '';
    final macAddress = printer.mac ?? '';
    final isOnline = printer.online;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFE3F2FD) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF2196F3)
                : const Color(0xFFE0E0E0),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            // Icono de impresora
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF2196F3).withOpacity(0.1)
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                Icons.print,
                size: 20,
                color: isSelected ? const Color(0xFF2196F3) : Colors.black54,
              ),
            ),

            const SizedBox(width: 12),

            // Información de la impresora
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      // Indicador de conexión
                      if (isOnline) ...[
                        const Icon(
                          Icons.wifi,
                          size: 16,
                          color: Color(0xFF4CAF50),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Icon(
                        isOnline ? Icons.check_circle : Icons.circle_outlined,
                        size: 16,
                        color: isOnline ? const Color(0xFF4CAF50) : Colors.grey,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (ipAddress.isNotEmpty)
                    Text(
                      'IP: $ipAddress',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.black54,
                      ),
                    ),
                  if (macAddress.isNotEmpty)
                    Text(
                      'MAC: $macAddress',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black45,
                      ),
                    ),
                ],
              ),
            ),

            // Checkbox o indicador de selección
            if (isSelected)
              Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Color(0xFF2196F3),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, size: 16, color: Colors.white),
              )
            else
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFE0E0E0), width: 2),
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(
              Icons.dashboard_customize_outlined,
              size: 56,
              color: Colors.black45,
            ),
            SizedBox(height: 10),
            Text(
              'No hay áreas creadas.\nAgrega una para comenzar.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBox({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Colors.redAccent),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFE5E5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
