import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/areas/viewmodel/print_areas_viewmodel.dart';

class PrintingAreasView extends ConsumerWidget {
  final String businessId;
  const PrintingAreasView({super.key, this.businessId = 'auto'});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(printingAreasViewModelProvider);
    final vmCtrl = ref.read(printingAreasViewModelProvider.notifier);

    if (vm.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (vm.errorMessage != null && vm.items.isEmpty) {
      return _ErrorBox(message: vm.errorMessage!, onRetry: vmCtrl.refresh);
    }

    final errorMessage = vm.errorMessage;

    final isWide = MediaQuery.of(context).size.width >= 900;
    final cross = isWide ? 3 : 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (errorMessage != null && vm.items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: _InlineError(message: errorMessage),
          ),
        // Acciones de cabecera
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _showAddAreaDialog(context, vmCtrl),
                icon: const Icon(Icons.add),
                label: const Text('Agregar área'),
              ),
              if (vm.selectedIds.isNotEmpty)
                Text(
                  '${vm.selectedIds.length} seleccionada(s)',
                  style: const TextStyle(color: Colors.black54),
                ),
            ],
          ),
        ),

        const SizedBox(height: 4),
        const Divider(height: 1, color: MangoColors.cardBorder),

        Expanded(
          child: vm.items.isEmpty
              ? const _EmptyHint()
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cross,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    childAspectRatio: 1.9,
                  ),
                  itemCount: vm.items.length,
                  itemBuilder: (_, i) {
                    final a = vm.items[i];
                    final selected = vm.selectedIds.contains(a.id);

                    return InkWell(
                      onLongPress: () => vmCtrl.toggleSelect(a.id),
                      child: Container(
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFFFFF3E6)
                              : MangoColors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: MangoColors.cardBorder),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x12000000),
                              blurRadius: 8,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.room_service_outlined,
                                  size: 22,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    a.name,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  '${a.productsCount} productos',
                                  style: const TextStyle(color: Colors.black54),
                                ),
                              ],
                            ),
                            const Spacer(),
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () => _showAssignPrinterDialog(
                                    context,
                                    ref,
                                    vmCtrl,
                                    a.id,
                                    businessId,
                                  ),
                                  icon: const Icon(Icons.print_outlined),
                                  label: const Text('Asignar impresora'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () =>
                                      _showAreaConfig(context, a.name),
                                  icon: const Icon(Icons.settings_outlined),
                                  label: const Text('Configurar'),
                                ),
                                TextButton.icon(
                                  onPressed: () => _confirmDeleteArea(
                                    context,
                                    onConfirm: () {
                                      vmCtrl.deleteArea(a.id);
                                    },
                                  ),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.red,
                                  ),
                                  label: const Text(
                                    'Eliminar',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showAddAreaDialog(BuildContext context, PrintingAreasViewModel vmCtrl) {
    final nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nueva área'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(labelText: 'Nombre del área'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () async {
              final created = await vmCtrl.createArea(name: nameCtrl.text);
              if (created && context.mounted) Navigator.pop(context);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteArea(
    BuildContext context, {
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Eliminar área'),
        content: const Text(
          'Esta acción no se puede deshacer. ¿Deseas continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              onConfirm();
              Navigator.pop(context);
            },
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }

  void _showAreaConfig(BuildContext context, String areaName) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(areaName),
        content: const Text(
          'Configuraciones del área (copias, tipos de impresión, etc.)',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  /// Diálogo simple para asignar impresora a un área:
  /// Lista las impresoras disponibles del mismo negocio y permite seleccionar una.
  void _showAssignPrinterDialog(
    BuildContext context,
    WidgetRef ref,
    PrintingAreasViewModel vmCtrl,
    String areaId,
    String businessId,
  ) {
    final printersState = ref.read(printingPrintersViewModelProvider);
    final printers = printersState.items;

    showDialog(
      context: context,
      builder: (_) {
        String? selectedId;
        return AlertDialog(
          title: const Text('Asignar impresora'),
          content: printersState.isLoading
              ? const SizedBox(
                  height: 120,
                  child: Center(child: CircularProgressIndicator()),
                )
              : printers.isEmpty
              ? const Text('No hay impresoras registradas.')
              : SizedBox(
                  width: 380,
                  child: DropdownButtonFormField<String>(
                    value: selectedId,
                    items: printers.map((p) {
                      final ipValue = p.ip ?? '';
                      final ipLabel = ipValue.isEmpty ? 'sin IP' : ipValue;
                      return DropdownMenuItem<String>(
                        value: p.id,
                        child: Text('${p.name}  ($ipLabel)'),
                      );
                    }).toList(),
                    onChanged: (v) => selectedId = v,
                    decoration: const InputDecoration(
                      labelText: 'Selecciona una impresora',
                    ),
                  ),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: printers.isEmpty || printersState.isLoading
                  ? null
                  : () async {
                      if (selectedId == null) return;
                      await vmCtrl.linkAreaPrinter(
                        areaId: areaId,
                        printerId: selectedId!,
                      );
                      if (context.mounted) Navigator.pop(context);
                    },
              child: const Text('Asignar'),
            ),
          ],
        );
      },
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
