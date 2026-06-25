import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/core/printing/device_identity.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/diagnostics/bluetooth_diagnostics_screen.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/widgets/printer_configuration_dialog.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/widgets/printing_ui.dart';

class PrintingPrintersView extends ConsumerStatefulWidget {
  const PrintingPrintersView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  ConsumerState<PrintingPrintersView> createState() =>
      _PrintingPrintersViewState();
}

class _PrintingPrintersViewState extends ConsumerState<PrintingPrintersView> {
  bool get _isWindows => !kIsWeb && Platform.isWindows;
  Map<String, PrinterUsageSummary> _usageSummaries = const {};

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _bootstrap(force: true));
  }

  @override
  void didUpdateWidget(covariant PrintingPrintersView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.businessId != widget.businessId) {
      Future.microtask(() => _bootstrap(force: true));
    }
  }

  Future<void> _bootstrap({bool force = false}) async {
    final vmCtrl = ref.read(printingPrintersViewModelProvider.notifier);
    await vmCtrl.load(businessId: widget.businessId, force: force);
    final summaries = await vmCtrl.loadUsageSummaries();
    if (!mounted) return;
    setState(() => _usageSummaries = summaries);
  }

  Future<void> _showAddPrinterDialog(
    BuildContext context,
    PrintingPrintersViewModel vmCtrl,
  ) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) =>
          _AddPrinterDialog(vmCtrl: vmCtrl, isWindows: _isWindows),
    );
    await _bootstrap(force: true);
  }

  Future<void> _confirmDeletePrinter(
    BuildContext context, {
    required PrinterDevice printer,
    required Future<bool> Function() onConfirm,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: MangoColors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Desvincular impresora',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: MangoColors.darkGray,
          ),
        ),
        content: Text(
          'Se eliminará ${printer.name} de la configuración de impresión.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Desvincular'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!context.mounted) return;
    final ok = await onConfirm();
    if (!mounted) return;
    await _bootstrap(force: true);
    final state = ref.read(printingPrintersViewModelProvider);
    AppToast.info(
      context,
      ok
          ? 'Impresora desvinculada.'
          : (state.errorMessage ?? 'No se pudo desvincular la impresora.'),
    );
  }

  Future<void> _openPrinterConfiguration(PrinterDevice printer) async {
    final vmCtrl = ref.read(printingPrintersViewModelProvider.notifier);
    final changed = await showPrinterConfigurationDialog(
      context,
      printer: printer,
      vmCtrl: vmCtrl,
    );
    if (changed == true) {
      await _bootstrap(force: true);
    }
  }

  Widget _scaffold(BuildContext context, Widget body) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Regresar',
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: const Text('Impresoras'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bluetooth_searching),
            tooltip: 'Diagnóstico Bluetooth',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const BluetoothDiagnosticsScreen(),
              ),
            ),
          ),
        ],
      ),
      body: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(printingPrintersViewModelProvider);
    final vmCtrl = ref.read(printingPrintersViewModelProvider.notifier);

    if (vm.isLoading && vm.items.isEmpty) {
      return _scaffold(
        context,
        const Center(
          child: CircularProgressIndicator(color: MangoColors.primaryOrange),
        ),
      );
    }

    if (vm.errorMessage != null && vm.items.isEmpty) {
      return _scaffold(
        context,
        _ErrorBox(
          message: vm.errorMessage!,
          onRetry: () => _bootstrap(force: true),
        ),
      );
    }

    return _scaffold(
      context,
      Stack(
      children: [
        PrintingPageShell(
          title: 'Impresoras',
          icon: Icons.print_outlined,
          listTitle: 'Lista de impresoras vinculadas',
          action: PrintingPrimaryButton(
            label: 'Agregar impresora',
            icon: Icons.add_circle,
            onPressed: vm.isDiscovering
                ? null
                : () => _showAddPrinterDialog(context, vmCtrl),
          ),
          child: vm.items.isEmpty
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: const [
                    _HardwareIdBanner(),
                    PrintingEmptyState(
                      label:
                          'No hay impresoras vinculadas todavia.\nAgrega una para comenzar.',
                    ),
                  ],
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final cardWidth = constraints.maxWidth < 480
                        ? constraints.maxWidth
                        : 380.0;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _HardwareIdBanner(),
                        Wrap(
                          spacing: 20,
                          runSpacing: 20,
                          children: vm.items.map((printer) {
                        final summary =
                            _usageSummaries[printer.id] ??
                            const PrinterUsageSummary();
                        return SizedBox(
                          width: cardWidth,
                          child: _PrinterOverviewCard(
                            printer: printer,
                            usageSummary: summary,
                            onPrintSample: () async {
                              final ok = await vmCtrl.testPrint(printer.id);
                              if (!mounted) return;
                              final state = ref.read(
                                printingPrintersViewModelProvider,
                              );
                              AppToast.info(
                                context,
                                ok
                                    ? 'Muestra enviada a ${printer.name}.'
                                    : (state.errorMessage ??
                                          'No se pudo imprimir la muestra.'),
                              );
                            },
                            onConfigure: () =>
                                _openPrinterConfiguration(printer),
                            onDelete: () => _confirmDeletePrinter(
                              context,
                              printer: printer,
                              onConfirm: () => vmCtrl.deletePrinter(printer.id),
                            ),
                          ),
                        );
                          }).toList(),
                        ),
                      ],
                    );
                  },
                ),
        ),
        if (vm.isDiscovering)
          Container(
            color: Colors.black.withValues(alpha: 0.7),
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
                      'Esto puede tomar hasta 10 segundos...',
                      style: TextStyle(fontSize: 14, color: MangoColors.muted),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: const LinearProgressIndicator(
                        minHeight: 8,
                        backgroundColor: MangoColors.bgLight,
                        color: MangoColors.primaryOrange,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
      ),
    );
  }
}

class _PrinterOverviewCard extends StatelessWidget {
  const _PrinterOverviewCard({
    required this.printer,
    required this.usageSummary,
    required this.onPrintSample,
    required this.onConfigure,
    required this.onDelete,
  });

  final PrinterDevice printer;
  final PrinterUsageSummary usageSummary;
  final VoidCallback onPrintSample;
  final VoidCallback onConfigure;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ip = printer.ip?.isNotEmpty == true ? printer.ip! : 'No configurada';
    final mac = printer.mac?.isNotEmpty == true
        ? printer.mac!
        : 'No disponible';

    return PrintingCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.print_outlined, color: MangoColors.darkGray),
              const SizedBox(width: 12),
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
                      'IP: $ip   MAC: $mac',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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
          const SizedBox(height: 16),
          Row(
            children: [
              PrintingMetricBadge(
                label:
                    '${usageSummary.assignedAreas.toString().padLeft(2, '0')} Areas asignadas',
                background: const Color(0xFFEAF1FB),
                foreground: MangoColors.primaryOrange,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              PrintingMetricBadge(
                label:
                    '${usageSummary.receiptAssignments.toString().padLeft(2, '0')} Comprobantes',
                background: const Color(0xFFF6F0DD),
                foreground: const Color(0xFFE4A928),
              ),
              const SizedBox(width: 8),
              PrintingMetricBadge(
                label:
                    '${usageSummary.prebillAssignments.toString().padLeft(2, '0')} Precuentas',
                background: const Color(0xFFEDF4EC),
                foreground: const Color(0xFF68C35B),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, color: Color(0xFFD4D4D4)),
          const SizedBox(height: 14),
          Row(
            children: [
              PrintingActionButton(
                label: 'Imprimir muestra',
                icon: Icons.print_outlined,
                foreground: MangoColors.darkGray,
                background: Colors.transparent,
                onPressed: onPrintSample,
              ),
              const SizedBox(width: 8),
              PrintingActionButton(
                label: 'Conf. impresora',
                icon: Icons.settings_outlined,
                foreground: MangoColors.darkGray,
                background: Colors.transparent,
                onPressed: onConfigure,
              ),
              const SizedBox(width: 8),
              PrintingActionButton(
                label: 'Desvincular',
                icon: Icons.not_interested_outlined,
                foreground: const Color(0xFFEF5350),
                background: Colors.transparent,
                onPressed: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AddPrinterDialog extends ConsumerStatefulWidget {
  const _AddPrinterDialog({required this.vmCtrl, required this.isWindows});

  final PrintingPrintersViewModel vmCtrl;
  final bool isWindows;

  @override
  ConsumerState<_AddPrinterDialog> createState() => _AddPrinterDialogState();
}

class _AddPrinterDialogState extends ConsumerState<_AddPrinterDialog> {
  int _step = 1;
  String _selectedType = '';
  final _nameCtrl = TextEditingController();
  final _ipCtrl = TextEditingController();
  final _macCtrl = TextEditingController();
  bool _isSearching = false;
  List<Map<String, dynamic>> _foundPrinters = [];
  Map<String, dynamic>? _selectedPrinter;

  // PRD 5 F2 — escaneo extensivo (120s) con resultados en streaming.
  StreamSubscription? _intensiveSub;
  Timer? _intensiveCountdown;
  bool _isIntensiveSearching = false;
  int _intensiveSecondsLeft = 0;

  @override
  void dispose() {
    _intensiveSub?.cancel();
    _intensiveCountdown?.cancel();
    _nameCtrl.dispose();
    _ipCtrl.dispose();
    _macCtrl.dispose();
    super.dispose();
  }

  Future<void> _searchNetworkIntensive() async {
    await _intensiveSub?.cancel();
    _intensiveCountdown?.cancel();

    setState(() {
      _isIntensiveSearching = true;
      _intensiveSecondsLeft = 120;
    });

    _intensiveCountdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _intensiveSecondsLeft = _intensiveSecondsLeft > 0
            ? _intensiveSecondsLeft - 1
            : 0;
      });
      if (_intensiveSecondsLeft <= 0) t.cancel();
    });

    _intensiveSub = widget.vmCtrl
        .scanIntensiveStream(duration: const Duration(seconds: 120))
        .listen(
      (d) {
        if (!mounted) return;
        final ip = d.ip;
        final id = d.idHint;
        // Dedupe contra los ya encontrados.
        final isDup = _foundPrinters.any((p) {
          if (ip != null && p['ip'] == ip) return true;
          if (id != null && p['id'] == id) return true;
          return false;
        });
        if (isDup) return;
        setState(() {
          _foundPrinters.add({
            'ip': ip,
            'mac': d.mac,
            'name': d.name,
            'id': id,
            'type': d.type.name,
            'devicePath': id,
          });
        });
      },
      onDone: _stopIntensive,
      onError: (_) {
        if (mounted) {
          AppToast.error(context, 'No se pudo completar la búsqueda.');
        }
        _stopIntensive();
      },
    );
  }

  void _stopIntensive() {
    _intensiveSub?.cancel();
    _intensiveSub = null;
    _intensiveCountdown?.cancel();
    if (mounted) {
      setState(() {
        _isIntensiveSearching = false;
        _intensiveSecondsLeft = 0;
      });
    }
  }

  /// PRD 5 F2.5: ¿Esta impresora se compartirá desde este dispositivo?
  /// Verdadero para Bluetooth (siempre) y para una USB descubierta.
  bool _isLocalSharedPrinter() {
    if (_selectedType == 'bluetooth') return true;
    final type = (_selectedPrinter?['type'] as String?)?.toLowerCase();
    if (type == 'usb' || type == 'bluetooth') return true;
    return false;
  }

  Widget _buildIntensiveScanButton() {
    if (_isIntensiveSearching) {
      final mm = (_intensiveSecondsLeft ~/ 60).toString().padLeft(1, '0');
      final ss = (_intensiveSecondsLeft % 60).toString().padLeft(2, '0');
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(
                'Buscando impresoras... quedan $mm:$ss',
                style: const TextStyle(
                  fontSize: 13,
                  color: MangoColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _stopIntensive,
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('Detener búsqueda'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFEF4444),
            ),
          ),
        ],
      );
    }

    return TextButton.icon(
      onPressed: _isSearching ? null : _searchNetworkIntensive,
      icon: const Icon(Icons.travel_explore, size: 18),
      label: const Text('Búsqueda más completa (2 min)'),
      style: TextButton.styleFrom(
        foregroundColor: const Color(0xFF22C55E),
      ),
    );
  }

  Future<void> _searchNetwork() async {
    setState(() {
      _isSearching = true;
      _foundPrinters = [];
      _selectedPrinter = null;
    });

    try {
      final results = await widget.vmCtrl.scanOnLANUnified();
      _foundPrinters = results
          .map(
            (d) => {
              'ip': d.ip,
              'mac': d.mac,
              'name': d.name,
              'id': d.idHint,
              'type': d.type.name,
              'devicePath': d.idHint,
            },
          )
          .toList();
      setState(() => _isSearching = false);
    } catch (e) {
      setState(() => _isSearching = false);
      if (mounted) {
        AppToast.error(context, 'Error al buscar: $e');
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
      final results = await widget.vmCtrl.scanBluetooth();
      _foundPrinters = results
          .map(
            (d) => {
              'ip': d.ip,
              'mac': d.mac,
              'name': d.name,
              'id': d.idHint,
              'type': d.type.name,
              'devicePath': d.idHint,
            },
          )
          .toList();
      setState(() => _isSearching = false);
    } catch (e) {
      setState(() => _isSearching = false);
      if (mounted) {
        AppToast.error(context, 'Error al buscar: $e');
      }
    }
  }

  Future<void> _savePrinter() async {
    final ip = _selectedPrinter?['ip'] as String? ?? _ipCtrl.text.trim();
    final mac = _selectedPrinter?['mac'] as String? ?? _macCtrl.text.trim();
    final type = _selectedPrinter?['type'] as String? ?? _selectedType;

    final created = await widget.vmCtrl.createPrinter(
      name: _nameCtrl.text,
      ip: ip.isEmpty ? null : ip,
      mac: mac.isEmpty ? null : mac,
      devicePath: _selectedPrinter?['devicePath'] as String?,
      type: type,
    );
    if (created && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    // En móvil: dialog ocupa casi todo el ancho. En tablet/desktop: máximo 600.
    final isCompact = size.width < 600;
    final maxDialogWidth = isCompact ? size.width : 600.0;
    // viewInsets.bottom = teclado abierto. Le quitamos al alto disponible
    // para que el footer siga visible mientras el usuario tipea.
    final maxDialogHeight = size.height - media.viewInsets.bottom - 48;
    final horizontalPadding = isCompact ? 20.0 : 32.0;
    final verticalPadding = isCompact ? 20.0 : 32.0;
    final sectionGap = isCompact ? 20.0 : 32.0;

    return Dialog(
      backgroundColor: MangoColors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: EdgeInsets.symmetric(
        horizontal: isCompact ? 12 : 40,
        vertical: 24,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxDialogWidth,
          maxHeight: maxDialogHeight,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            verticalPadding,
            horizontalPadding,
            verticalPadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Agreguemos una impresora',
                      style: TextStyle(
                        fontSize: isCompact ? 20 : 24,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF22C55E),
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
              SizedBox(height: sectionGap),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _StepIndicator(
                    number: 1,
                    active: _step == 1,
                    completed: _step > 1,
                  ),
                  Container(
                    width: isCompact ? 48 : 80,
                    height: 2,
                    color: _step > 1
                        ? const Color(0xFF22C55E)
                        : const Color(0xFFE5E7EB),
                  ),
                  _StepIndicator(
                    number: 2,
                    active: _step == 2,
                    completed: _step > 2,
                  ),
                  Container(
                    width: isCompact ? 48 : 80,
                    height: 2,
                    color: _step > 2
                        ? const Color(0xFF22C55E)
                        : const Color(0xFFE5E7EB),
                  ),
                  _StepIndicator(
                    number: 3,
                    active: _step == 3,
                    completed: false,
                  ),
                ],
              ),
              SizedBox(height: sectionGap),
              // Contenido scrollable: ocupa el espacio entre el header
              // fijo y los botones fijos. En pantallas pequeñas o cuando
              // el teclado está abierto, el usuario puede arrastrar para
              // ver lo que no entra; los botones nunca desaparecen.
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_step == 1) _buildStep1(),
                      if (_step == 2) _buildStep2(),
                      if (_step == 3) _buildStep3(),
                    ],
                  ),
                ),
              ),
              SizedBox(height: sectionGap),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_step > 1)
                    TextButton(
                      onPressed: () => setState(() => _step--),
                      child: const Text('Atras'),
                    ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF22C55E),
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(
                        horizontal: isCompact ? 24 : 32,
                        vertical: isCompact ? 14 : 16,
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
                          AppToast.info(
                            context,
                            'Por favor selecciona una impresora',
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
          'Como deseas sincronizar tu dispositivo?',
          style: TextStyle(color: MangoColors.muted),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: _ConnectionOption(
                iconPath: 'assets/images/impresion_wifi.png',
                title: 'Por RED / USB',
                subtitle:
                    'Busca impresoras en tu red Wi-Fi o conectadas por USB',
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
              color: Color(0xFF22C55E),
              strokeWidth: 6,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Buscando Impresoras...',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Color(0xFF22C55E),
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
              foregroundColor: const Color(0xFF22C55E),
              side: const BorderSide(color: Color(0xFF22C55E)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: _selectedType == 'bluetooth'
                ? _searchBluetooth
                : _searchNetwork,
            child: const Text('Buscar nuevamente'),
          ),
          if (_selectedType != 'bluetooth') ...[
            const SizedBox(height: 8),
            _buildIntensiveScanButton(),
          ],
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
          // En mobile dejamos que el scroll del Dialog padre maneje la
          // lista (NeverScrollable + shrinkWrap), si no, dos scrolls
          // anidados confunden el gesto del usuario y la lista no se
          // puede arrastrar. En desktop preservamos el maxHeight para que
          // no empuje al footer fuera de vista.
          Builder(
            builder: (context) {
              final isCompact = MediaQuery.of(context).size.width < 600;
              final list = ListView.builder(
                shrinkWrap: true,
                physics: isCompact
                    ? const NeverScrollableScrollPhysics()
                    : null,
                itemCount: _foundPrinters.length,
                itemBuilder: (context, index) {
                  final printer = _foundPrinters[index];
                  return _PrinterFoundCard(
                    printer: printer,
                    selected: _selectedPrinter == printer,
                    onTap: () {
                      setState(() {
                        _selectedPrinter = printer;
                        // Pre-completar nombre si está vacío
                        if (_nameCtrl.text.trim().isEmpty) {
                          _nameCtrl.text = printer['name'] ?? '';
                        }
                      });
                    },
                  );
                },
              );
              if (isCompact) return list;
              return ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: list,
              );
            },
          ),
          if (_selectedType != 'bluetooth') ...[
            const SizedBox(height: 12),
            const Text(
              '¿No ves tu impresora? Probá una búsqueda más completa.',
              style: TextStyle(fontSize: 12, color: MangoColors.muted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            _buildIntensiveScanButton(),
          ],
        ],
      ],
    );
  }

  Widget _buildStep3() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Informacion de la impresora',
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
              border: Border.all(color: const Color(0xFF22C55E)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.check_circle, color: Color(0xFF22C55E)),
                    SizedBox(width: 8),
                    Text(
                      'Impresora detectada',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF22C55E),
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
              borderSide: const BorderSide(color: Color(0xFF22C55E), width: 2),
            ),
          ),
        ),
        if (_selectedType == 'network' && _selectedPrinter == null) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _ipCtrl,
            decoration: InputDecoration(
              labelText: 'Direccion IP',
              hintText: 'Ej: 192.168.0.10',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(0xFF22C55E),
                  width: 2,
                ),
              ),
            ),
            keyboardType: TextInputType.number,
          ),
        ],
        if (_isLocalSharedPrinter()) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7ED),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFED7AA)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.devices_other,
                  color: Color(0xFF1D4ED8),
                  size: 20,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Esta impresora se compartirá desde este dispositivo. '
                    'Otros equipos del negocio podrán usarla cuando este equipo '
                    'esté encendido y conectado a la red.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xFF1E40AF),
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
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
                  color: Color(0xFF22C55E),
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({
    required this.number,
    required this.active,
    required this.completed,
  });

  final int number;
  final bool active;
  final bool completed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active || completed
            ? const Color(0xFF22C55E)
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
  const _ConnectionOption({
    required this.iconPath,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String iconPath;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

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
            color: selected ? const Color(0xFF22C55E) : const Color(0xFFE5E7EB),
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
              style: const TextStyle(fontSize: 12, color: Color(0xFF22C55E)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

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

class _PrinterFoundCard extends StatelessWidget {
  const _PrinterFoundCard({
    required this.printer,
    required this.selected,
    required this.onTap,
  });

  final Map<String, dynamic> printer;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ip = printer['ip'] as String? ?? '—';
    final mac = printer['mac'] as String? ?? '—';
    final type = printer['type'] as String? ?? 'network';
    final name = printer['name'] as String? ?? 'Impresora';
    final isUsb = type == 'usb';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE8F5E9) : const Color(0xFFF9FAFB),
          border: Border.all(
            color: selected ? const Color(0xFF22C55E) : const Color(0xFFE5E7EB),
            width: 2,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              isUsb ? Icons.usb : Icons.print,
              color: selected
                  ? const Color(0xFF22C55E)
                  : const Color(0xFF6B7280),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isUsb ? name : 'IP: $ip',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  Text(
                    isUsb ? 'Conexion USB (Local)' : 'MAC: $mac',
                    style: const TextStyle(
                      fontSize: 12,
                      color: MangoColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, color: Color(0xFF22C55E)),
          ],
        ),
      ),
    );
  }
}

/// PRD 5 F5.2 — banner que detecta si el device está usando un UUID v4
/// aleatorio en lugar del UUID hardware del OS y ofrece adoptarlo.
///
/// El UUID hardware sobrevive reinstalaciones/rebuilds del binario, por
/// lo que adoptarlo evita que `printers.host_device_id` quede huérfano
/// la próxima vez que el cajero actualice la app.
class _HardwareIdBanner extends ConsumerStatefulWidget {
  const _HardwareIdBanner();

  @override
  ConsumerState<_HardwareIdBanner> createState() => _HardwareIdBannerState();
}

class _HardwareIdBannerState extends ConsumerState<_HardwareIdBanner> {
  bool _checked = false;
  bool _shouldShow = false;
  bool _adopting = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_check);
  }

  Future<void> _check() async {
    try {
      final businessId = await BusinessResolver.ensure('auto');
      final hw = await DeviceIdentity.readHardwareId();
      final adopted = await DeviceIdentity.isUsingHardwareId(businessId);
      final currentId = await DeviceIdentity.getOrCreateId(businessId);
      if (!mounted) return;
      setState(() {
        _checked = true;
        _shouldShow =
            hw != null && !adopted && currentId.toLowerCase() != hw.toLowerCase();
      });
    } catch (_) {
      if (mounted) setState(() => _checked = true);
    }
  }

  Future<void> _adopt() async {
    setState(() => _adopting = true);
    try {
      final businessId = await BusinessResolver.ensure('auto');
      final result = await DeviceIdentity.adoptHardwareId(businessId);
      if (!mounted) return;
      if (result == null) {
        AppToast.info(
          context,
          'Este dispositivo no expone identidad de hardware o ya está adoptada.',
        );
      } else {
        AppToast.success(
          context,
          'Identidad adoptada. Las impresoras siguen vinculadas tras reinstalaciones.',
        );
        setState(() => _shouldShow = false);
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'No se pudo adoptar la identidad: $e');
      }
    } finally {
      if (mounted) setState(() => _adopting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked || !_shouldShow) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        border: Border.all(color: const Color(0xFFFED7AA)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, color: MangoColors.primaryOrange),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Vincula este dispositivo de forma permanente',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: MangoColors.darkGray,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Adoptar la identidad del hardware evita que las impresoras se desvinculen tras reinstalar o actualizar la app.',
                  style: TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: _adopting ? null : _adopt,
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: _adopting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Adoptar', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
