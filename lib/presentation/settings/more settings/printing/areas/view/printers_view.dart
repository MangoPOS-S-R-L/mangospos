import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/areas/viewmodel/printers_viewmodel.dart';

class PrintingPrintersView extends ConsumerWidget {
  /// Compatibilidad con tu router actual: recibe businessId pero por defecto usa 'auto'
  final String businessId;
  const PrintingPrintersView({super.key, this.businessId = 'auto'});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(printingPrintersViewModelProvider(businessId));
    final vmCtrl = ref.read(printingPrintersViewModelProvider(businessId).notifier);

    if (vm.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (vm.errorMessage != null && vm.items.isEmpty) {
      return _ErrorBox(
        message: vm.errorMessage!,
        onRetry: vmCtrl.refresh,
      );
    }

    final errorMessage = vm.errorMessage;

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
              OutlinedButton.icon(
                onPressed: vmCtrl.discoverOnLAN,
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Buscar en la red'),
              ),
              FilledButton.icon(
                onPressed: () => _showAddPrinterDialog(context, vmCtrl),
                icon: const Icon(Icons.add),
                label: const Text('Agregar impresora'),
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
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  itemCount: vm.items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final p = vm.items[i];
                    final selected = vm.selectedIds.contains(p.id);
                    final ip = p.ip ?? '';
                    final mac = p.mac ?? '';
                    return InkWell(
                      onLongPress: () => vmCtrl.toggleSelect(p.id),
                      child: Container(
                        decoration: BoxDecoration(
                          color: selected ? const Color(0xFFFFF3E6) : MangoColors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: MangoColors.cardBorder),
                          boxShadow: const [
                            BoxShadow(color: Color(0x12000000), blurRadius: 8, offset: Offset(0, 3)),
                          ],
                        ),
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              const Icon(Icons.print, size: 22),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  p.name,
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                                ),
                              ),
                              Tooltip(
                                message: p.online ? 'En línea' : 'Desconectada',
                                child: Icon(
                                  Icons.fiber_manual_record,
                                  size: 16,
                                  color: p.online ? MangoColors.successGreen : Colors.redAccent,
                                ),
                              ),
                            ]),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 16,
                              runSpacing: 8,
                              children: [
                                _MetaChip(label: 'IP', value: ip.isEmpty ? '—' : ip),
                                _MetaChip(label: 'MAC', value: mac.isEmpty ? '—' : mac),
                                _MetaChip(label: 'Tipo', value: p.type.label),
                              ],
                            ),

                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () => vmCtrl.printSample(p.id),
                                  icon: const Icon(Icons.receipt_long_outlined),
                                  label: const Text('Imprimir muestra'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () =>
                                      _showPrinterInfo(context, p.name, ip, mac, p.type.label),
                                  icon: const Icon(Icons.settings_outlined),
                                  label: const Text('Configurar'),
                                ),
                                TextButton.icon(
                                  onPressed: () => _confirmDeletePrinter(context, onConfirm: () {
                                    vmCtrl.deletePrinter(p.id);
                                  }),
                                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                                  label: const Text('Eliminar', style: TextStyle(color: Colors.red)),
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

  void _showAddPrinterDialog(BuildContext context, PrintingPrintersViewModel vmCtrl) {
    final nameCtrl = TextEditingController();
    final ipCtrl = TextEditingController();
    final macCtrl = TextEditingController();
    String type = 'network';

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Agregar impresora'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Nombre')),
            TextField(controller: ipCtrl, decoration: const InputDecoration(labelText: 'IP')),
            TextField(controller: macCtrl, decoration: const InputDecoration(labelText: 'MAC')),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              value: type,
              items: const [
                DropdownMenuItem(value: 'network', child: Text('Red (TCP/IP)')),
                DropdownMenuItem(value: 'bluetooth', child: Text('Bluetooth')),
                DropdownMenuItem(value: 'usb', child: Text('USB')),
              ],
              onChanged: (v) => type = v ?? 'network',
              decoration: const InputDecoration(labelText: 'Tipo'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () async {
              final created = await vmCtrl.createPrinter(
                name: nameCtrl.text,
                ip: ipCtrl.text,
                mac: macCtrl.text,
                type: type,
              );
              if (created && context.mounted) Navigator.pop(context);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  void _confirmDeletePrinter(BuildContext context, {required VoidCallback onConfirm}) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Eliminar impresora'),
        content: const Text('Esta acción no se puede deshacer. ¿Deseas continuar?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
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

  void _showPrinterInfo(BuildContext context, String name, String ip, String mac, String type) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(name),
        content: Text('IP: ${ip.isEmpty ? "—" : ip}\nMAC: ${mac.isEmpty ? "—" : mac}\nTipo: $type'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
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
            Icon(Icons.print_disabled_outlined, size: 56, color: Colors.black45),
            SizedBox(height: 10),
            Text(
              'No hay impresoras vinculadas.\nAgrega una para comenzar.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final String value;
  const _MetaChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text('$label: $value'),
      side: const BorderSide(color: MangoColors.cardBorder),
      backgroundColor: MangoColors.white,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
