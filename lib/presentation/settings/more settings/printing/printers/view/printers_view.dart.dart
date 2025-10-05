// lib/presentation/settings/more settings/printing/printers/view/printers_view.dart
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';

class PrintingPrintersView extends ConsumerStatefulWidget {
  final String businessId;
  const PrintingPrintersView({super.key, this.businessId = 'auto'});

  @override
  ConsumerState<PrintingPrintersView> createState() =>
      _PrintingPrintersViewState();
}

class _PrintingPrintersViewState extends ConsumerState<PrintingPrintersView> {
  bool get _isWindows => !kIsWeb && Platform.isWindows;
  bool _isSearching = false;
  int _searchProgress = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref
          .read(printingPrintersViewModelProvider.notifier)
          .load(businessId: widget.businessId);
    });
  }

  @override
  void didUpdateWidget(covariant PrintingPrintersView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.businessId != widget.businessId) {
      Future.microtask(() {
        ref
            .read(printingPrintersViewModelProvider.notifier)
            .load(businessId: widget.businessId, force: true);
      });
    }
  }

  Future<void> _startNetworkSearch() async {
    if (_isSearching) return;

    setState(() {
      _isSearching = true;
      _searchProgress = 0;
    });

    for (int i = 0; i <= 100; i++) {
      if (!mounted || !_isSearching) break;
      await Future.delayed(const Duration(milliseconds: 450));
      if (mounted) {
        setState(() {
          _searchProgress = i;
        });
      }
    }

    final vmCtrl = ref.read(printingPrintersViewModelProvider.notifier);
    // Escaneo (no persistente) solo para mostrar progreso general
    await vmCtrl.scanOnLANUnified();

    if (mounted && _searchProgress < 100) {
      await Future.delayed(
        Duration(milliseconds: (100 - _searchProgress) * 150),
      );
    }

    if (mounted) {
      setState(() {
        _isSearching = false;
        _searchProgress = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(printingPrintersViewModelProvider);
    final vmCtrl = ref.read(printingPrintersViewModelProvider.notifier);

    if (vm.isLoading && vm.items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: MangoColors.primaryOrange),
      );
    }

    if (vm.errorMessage != null && vm.items.isEmpty) {
      return _ErrorBox(
        message: vm.errorMessage!,
        onRetry: () => vmCtrl.refresh(),
      );
    }

    final errorMessage = vm.errorMessage;

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (errorMessage != null && vm.items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: _InlineError(message: errorMessage),
              ),

            // Header con botón de agregar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Impresoras configuradas',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF32AD40),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _isSearching
                        ? null
                        : () => _showAddPrinterDialog(context, vmCtrl),
                    icon: const Icon(Icons.add, size: 20),
                    label: const Text('Agregar impresora'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
            const Divider(height: 1, color: MangoColors.cardBorder),

            Expanded(
              child: vm.items.isEmpty
                  ? const _EmptyHint()
                  : ListView.separated(
                      padding: const EdgeInsets.all(20),
                      itemCount: vm.items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 16),
                      itemBuilder: (context, i) {
                        final p = vm.items[i];
                        final selected = vm.selectedIds.contains(p.id);
                        final ip = p.ip ?? '';
                        final mac = p.mac ?? '';

                        return _PrinterCard(
                          printer: p,
                          ip: ip,
                          mac: mac,
                          selected: selected,
                          onLongPress: () => vmCtrl.toggleSelect(p.id),
                          // ⛳️ Cambiado: usar testPrint (sirve en Web / Desktop / Mobile)
                          onPrintSample: () async {
                            final ok = await vmCtrl.testPrint(p.id);
                            final state = ref.read(
                              printingPrintersViewModelProvider,
                            );
                            final msg = ok
                                ? 'Muestra enviada a la impresora'
                                : (state.errorMessage ??
                                      'No se pudo imprimir la muestra');
                            if (context.mounted) {
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(SnackBar(content: Text(msg)));
                            }
                          },
                          onConfigure: () => _showPrinterInfo(
                            context,
                            p.name,
                            ip,
                            mac,
                            p.type.label,
                          ),
                          onDelete: () => _confirmDeletePrinter(
                            context,
                            onConfirm: () => vmCtrl.deletePrinter(p.id),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),

        if (_isSearching)
          Container(
            color: Colors.black.withOpacity(0.7),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 400),
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: MangoColors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.wifi_tethering,
                      size: 48,
                      color: MangoColors.primaryOrange,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Buscando impresoras en la red',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: MangoColors.darkGray,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Esto puede tomar hasta 45 segundos...',
                      style: TextStyle(fontSize: 14, color: MangoColors.muted),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: _searchProgress / 100,
                        minHeight: 8,
                        backgroundColor: MangoColors.bgLight,
                        color: MangoColors.primaryOrange,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${_searchProgress}%',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: MangoColors.darkGray,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showAddPrinterDialog(
    BuildContext context,
    PrintingPrintersViewModel vmCtrl,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) =>
          _AddPrinterDialog(vmCtrl: vmCtrl, isWindows: _isWindows),
    );
  }

  void _confirmDeletePrinter(
    BuildContext context, {
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: MangoColors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Eliminar impresora',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: MangoColors.darkGray,
          ),
        ),
        content: const Text(
          'Esta acción no se puede deshacer. ¿Deseas continuar?',
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: MangoColors.darkGray,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: MangoColors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              onConfirm();
              Navigator.pop(dialogContext);
            },
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }

  void _showPrinterInfo(
    BuildContext context,
    String name,
    String ip,
    String mac,
    String type,
  ) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: MangoColors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          name,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: MangoColors.darkGray,
          ),
        ),
        content: Text(
          'IP: ${ip.isEmpty ? "—" : ip}\nMAC: ${mac.isEmpty ? "—" : mac}\nTipo: $type',
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: MangoColors.darkGray,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }
}

class _PrinterCard extends StatelessWidget {
  final dynamic printer;
  final String ip;
  final String mac;
  final bool selected;
  final VoidCallback onLongPress;
  final VoidCallback onPrintSample;
  final VoidCallback onConfigure;
  final VoidCallback onDelete;

  const _PrinterCard({
    required this.printer,
    required this.ip,
    required this.mac,
    required this.selected,
    required this.onLongPress,
    required this.onPrintSample,
    required this.onConfigure,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? MangoColors.primaryOrange.withOpacity(0.05)
              : MangoColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? MangoColors.primaryOrange
                : MangoColors.cardBorder,
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.print,
                    size: 24,
                    color: Color(0xFF6B7280),
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
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: MangoColors.darkGray,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            'IP: ${ip.isEmpty ? "—" : ip}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: MangoColors.muted,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'MAC: ${mac.isEmpty ? "—" : mac}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: MangoColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    Icon(
                      Icons.wifi,
                      size: 18,
                      color: printer.online
                          ? const Color(0xFF10B981)
                          : const Color(0xFF6B7280),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.circle,
                      size: 10,
                      color: printer.online
                          ? const Color(0xFF10B981)
                          : Colors.redAccent,
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                PopupMenuButton(
                  icon: const Icon(Icons.more_vert, color: MangoColors.muted),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      onTap: onPrintSample,
                      child: const Row(
                        children: [
                          Icon(Icons.receipt_long_outlined, size: 18),
                          SizedBox(width: 12),
                          Text('Imprimir muestra'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      onTap: onConfigure,
                      child: const Row(
                        children: [
                          Icon(Icons.settings_outlined, size: 18),
                          SizedBox(width: 12),
                          Text('Configurar'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      onTap: onDelete,
                      child: const Row(
                        children: [
                          Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: Colors.red,
                          ),
                          SizedBox(width: 12),
                          Text('Eliminar', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AddPrinterDialog extends ConsumerStatefulWidget {
  final PrintingPrintersViewModel vmCtrl;
  final bool isWindows;

  const _AddPrinterDialog({required this.vmCtrl, required this.isWindows});

  @override
  ConsumerState<_AddPrinterDialog> createState() => _AddPrinterDialogState();
}

// ←— AHORA ES ConsumerState, por eso existe `ref`
class _AddPrinterDialogState extends ConsumerState<_AddPrinterDialog> {
  int _step = 1;
  String _selectedType = '';
  final _nameCtrl = TextEditingController();
  final _ipCtrl = TextEditingController();
  final _macCtrl = TextEditingController();
  bool _isSearching = false;
  List<Map<String, dynamic>> _foundPrinters = [];
  Map<String, dynamic>? _selectedPrinter;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ipCtrl.dispose();
    _macCtrl.dispose();
    super.dispose();
  }

  Future<void> _searchNetwork() async {
    setState(() {
      _isSearching = true;
      _foundPrinters = [];
      _selectedPrinter = null;
    });

    try {
      final results = await widget.vmCtrl
          .scanOnLANUnified(); // ← NO guarda en BD
      _foundPrinters = results
          .map(
            (d) => {'ip': d.ip, 'mac': d.mac, 'name': d.name, 'id': d.idHint},
          )
          .toList();
      setState(() => _isSearching = false);
    } catch (e) {
      setState(() => _isSearching = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error al buscar: $e')));
      }
    }
  }

  Future<void> _searchBluetooth() async {
    setState(() {
      _isSearching = true;
      _foundPrinters = [];
      _selectedPrinter = null;
    });

    try {
      final results = await widget.vmCtrl.scanBluetooth(); // ← NO guarda
      _foundPrinters = results
          .map(
            (d) => {'ip': d.ip, 'mac': d.mac, 'name': d.name, 'id': d.idHint},
          )
          .toList();
      setState(() => _isSearching = false);
    } catch (e) {
      setState(() => _isSearching = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error al buscar: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: MangoColors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 600,
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    'Agreguemos una impresora',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF32AD40),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  color: MangoColors.muted,
                  tooltip: 'Cerrar',
                ),
              ],
            ),
            const SizedBox(height: 32),

            // Indicador de pasos
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _StepIndicator(
                  number: 1,
                  active: _step == 1,
                  completed: _step > 1,
                ),
                Container(
                  width: 80,
                  height: 2,
                  color: _step > 1
                      ? const Color(0xFF32AD40)
                      : const Color(0xFFE5E7EB),
                ),
                _StepIndicator(
                  number: 2,
                  active: _step == 2,
                  completed: _step > 2,
                ),
                Container(
                  width: 80,
                  height: 2,
                  color: _step > 2
                      ? const Color(0xFF32AD40)
                      : const Color(0xFFE5E7EB),
                ),
                _StepIndicator(number: 3, active: _step == 3, completed: false),
              ],
            ),

            const SizedBox(height: 32),

            if (_step == 1) _buildStep1(),
            if (_step == 2) _buildStep2(),
            if (_step == 3) _buildStep3(),

            const SizedBox(height: 32),

            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_step > 1)
                  TextButton(
                    onPressed: () => setState(() => _step--),
                    child: const Text('Atrás'),
                  ),
                const SizedBox(width: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF32AD40),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    if (_step == 1 && _selectedType.isNotEmpty) {
                      setState(() => _step = 2);
                      if (_selectedType == 'network') {
                        await _searchNetwork();
                      } else if (_selectedType == 'bluetooth') {
                        await _searchBluetooth();
                      }
                    } else if (_step == 2) {
                      if (_selectedType == 'network' &&
                          _selectedPrinter == null &&
                          _foundPrinters.isNotEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Por favor selecciona una impresora'),
                          ),
                        );
                        return;
                      }
                      setState(() => _step = 3);
                    } else if (_step == 3) {
                      await _savePrinter();
                    }
                  },
                  child: Text(_step == 3 ? 'Guardar' : 'Siguiente'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep1() {
    return Column(
      children: [
        const Text(
          'Selecciona una red',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: MangoColors.darkGray,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '¿Cómo deseas sincronizar tu dispositivo?',
          style: TextStyle(color: MangoColors.muted),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: _ConnectionOption(
                iconPath: 'assets/images/impresion_wifi.png',
                title: 'Por RED',
                subtitle:
                    'Activa la red Wi-Fi de tu dispositivo para sincronizar',
                selected: _selectedType == 'network',
                onTap: () => setState(() => _selectedType = 'network'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _ConnectionOption(
                iconPath: 'assets/images/impresion_bluetooth.png',
                title: 'Por Bluetooth',
                subtitle:
                    'Activa Bluetooth y mantén visible tu dispositivo para sincronizar',
                selected: _selectedType == 'bluetooth',
                onTap: () => setState(() => _selectedType = 'bluetooth'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStep2() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'Selecciona una impresora',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: MangoColors.darkGray,
          ),
        ),
        const SizedBox(height: 32),
        if (_isSearching) ...[
          const SizedBox(
            width: 80,
            height: 80,
            child: CircularProgressIndicator(
              color: Color(0xFF32AD40),
              strokeWidth: 6,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Buscando Impresoras...',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Color(0xFF32AD40),
            ),
          ),
        ] else if (_foundPrinters.isEmpty) ...[
          const Icon(Icons.search_off, size: 80, color: MangoColors.muted),
          const SizedBox(height: 24),
          const Text(
            'No se encontraron impresoras',
            style: TextStyle(fontSize: 16, color: MangoColors.muted),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF32AD40),
              side: const BorderSide(color: Color(0xFF32AD40)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: _searchNetwork,
            child: const Text('Buscar nuevamente'),
          ),
        ] else ...[
          const Text(
            'Impresoras encontradas',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _foundPrinters.length,
              itemBuilder: (context, index) {
                final printer = _foundPrinters[index];
                return _PrinterFoundCard(
                  printer: printer,
                  selected: _selectedPrinter == printer,
                  onTap: () => setState(() => _selectedPrinter = printer),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStep3() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Información de la impresora',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: MangoColors.darkGray,
          ),
        ),
        const SizedBox(height: 24),
        if (_selectedPrinter != null) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF32AD40)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.check_circle, color: Color(0xFF32AD40)),
                    SizedBox(width: 8),
                    Text(
                      'Impresora detectada',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF32AD40),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('IP: ${_selectedPrinter!['ip'] ?? "—"}'),
                const SizedBox(height: 4),
                Text('MAC: ${_selectedPrinter!['mac'] ?? "—"}'),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        TextField(
          controller: _nameCtrl,
          decoration: InputDecoration(
            labelText: 'Nombre de la impresora',
            hintText: 'Ej: Impresora Cocina',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF32AD40), width: 2),
            ),
          ),
        ),
        if (_selectedType == 'network' && _selectedPrinter == null) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _ipCtrl,
            decoration: InputDecoration(
              labelText: 'Dirección IP',
              hintText: 'Ej: 192.168.0.10',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(0xFF32AD40),
                  width: 2,
                ),
              ),
            ),
            keyboardType: TextInputType.number,
          ),
        ],
        if (_selectedType == 'bluetooth') ...[
          const SizedBox(height: 16),
          TextField(
            controller: _macCtrl,
            decoration: InputDecoration(
              labelText: 'ID/MAC Bluetooth',
              hintText: 'Ej: AA:BB:CC:DD:EE:FF',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(0xFF32AD40),
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _savePrinter() async {
    // Si hay una impresora detectada, usar sus datos; si no, tomar los campos manuales
    final ip = _selectedPrinter?['ip'] as String? ?? _ipCtrl.text.trim();
    final mac = _selectedPrinter?['mac'] as String? ?? _macCtrl.text.trim();

    final created = await widget.vmCtrl.createPrinter(
      name: _nameCtrl.text,
      ip: ip.isEmpty ? null : ip,
      mac: mac.isEmpty ? null : mac,
      type: _selectedType,
    );
    if (created && mounted) Navigator.pop(context);
  }
}

class _StepIndicator extends StatelessWidget {
  final int number;
  final bool active;
  final bool completed;

  const _StepIndicator({
    required this.number,
    required this.active,
    required this.completed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active || completed
            ? const Color(0xFF32AD40)
            : const Color(0xFFE5E7EB),
      ),
      child: Center(
        child: Text(
          '$number',
          style: TextStyle(
            color: active || completed ? Colors.white : const Color(0xFF9CA3AF),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ConnectionOption extends StatelessWidget {
  final String iconPath;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ConnectionOption({
    required this.iconPath,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE8F5E9) : const Color(0xFFF9FAFB),
          border: Border.all(
            color: selected ? const Color(0xFF32AD40) : const Color(0xFFE5E7EB),
            width: 2,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Image.asset(iconPath, width: 80, height: 80),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 12, color: Color(0xFF32AD40)),
              textAlign: TextAlign.center,
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
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.print_disabled_outlined,
              size: 56,
              color: MangoColors.muted,
            ),
            SizedBox(height: 10),
            Text(
              'No hay impresoras vinculadas.\nAgrega una para comenzar.',
              textAlign: TextAlign.center,
              style: TextStyle(color: MangoColors.muted),
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
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
                foregroundColor: MangoColors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
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
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
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

class _PrinterFoundCard extends StatelessWidget {
  final Map<String, dynamic> printer;
  final bool selected;
  final VoidCallback onTap;

  const _PrinterFoundCard({
    required this.printer,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ip = printer['ip'] as String? ?? '—';
    final mac = printer['mac'] as String? ?? '—';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE8F5E9) : const Color(0xFFF9FAFB),
          border: Border.all(
            color: selected ? const Color(0xFF32AD40) : const Color(0xFFE5E7EB),
            width: 2,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              Icons.print,
              color: selected
                  ? const Color(0xFF32AD40)
                  : const Color(0xFF6B7280),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'IP: $ip',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  Text(
                    'MAC: $mac',
                    style: const TextStyle(
                      fontSize: 12,
                      color: MangoColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, color: Color(0xFF32AD40)),
          ],
        ),
      ),
    );
  }
}
