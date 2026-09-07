import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/data/models/printing.dart' show PrinterConfig;
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/theme/app_colors.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

class CashRegistersView extends ConsumerStatefulWidget {
  const CashRegistersView({super.key});

  @override
  ConsumerState<CashRegistersView> createState() => _CashRegistersViewState();
}

class _CashRegistersViewState extends ConsumerState<CashRegistersView> {
  List<Map<String, dynamic>> _registers = [];
  List<PrinterConfig> _printers = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final businessId = await resolveBusinessIdOrNull(client, 'auto');
      if (businessId == null) {
        setState(() {
          _loading = false;
          _error = 'No se pudo identificar el negocio.';
        });
        return;
      }

      final cashierRepo = ref.read(cashierRepositoryProvider);
      final printingRepo = PrintingRepository(client);

      final registers = await cashierRepo.getCashRegistersWithPrinter(businessId);
      final printers = await printingRepo.getPrinters(businessId);

      setState(() {
        _registers = registers;
        _printers = printers.where((p) => p.isActive).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = FriendlyError.humanize('Error al cargar cajas: $e');
      });
    }
  }

  Future<void> _assignPrinter(String registerId, String? printerId) async {
    try {
      final cashierRepo = ref.read(cashierRepositoryProvider);
      await cashierRepo.updateRegisterPrinter(
        cashRegisterId: registerId,
        printerId: printerId,
      );
      await _load();
      if (mounted) {
        AppToast.success(context, 'Impresora asignada correctamente.');
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Error al asignar impresora: $e');
      }
    }
  }

  /// Alta de registradora. Es lo que permite tener dos cajas fisicas: cada
  /// una con su fila en `cash_registers` y por tanto su propia impresora de
  /// recibos y su propio cierre.
  Future<void> _createRegister() async {
    final name = await _promptName(
      title: 'Nueva caja registradora',
      initial: '',
      confirmLabel: 'Crear',
    );
    if (name == null) return;

    try {
      final client = Supabase.instance.client;
      final businessId = await resolveBusinessIdOrNull(client, 'auto');
      if (businessId == null) {
        if (mounted) {
          AppToast.error(context, 'No se pudo identificar el negocio.');
        }
        return;
      }
      await ref.read(cashierRepositoryProvider).createCashRegister(
            businessId: businessId,
            name: name,
          );
      await _load();
      if (mounted) {
        AppToast.success(context, 'Caja "$name" creada.');
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(
          context,
          FriendlyError.humanize('Error al crear la caja: $e'),
        );
      }
    }
  }

  Future<void> _renameRegister(String registerId, String currentName) async {
    final name = await _promptName(
      title: 'Renombrar caja',
      initial: currentName,
      confirmLabel: 'Guardar',
    );
    if (name == null || name == currentName) return;

    try {
      await ref.read(cashierRepositoryProvider).updateCashRegisterName(
            cashRegisterId: registerId,
            name: name,
          );
      // Si es la registradora de este equipo, el nombre cacheado quedaria
      // viejo en el encabezado de Caja hasta el proximo arranque.
      final vm = ref.read(cashierViewModelProvider);
      if (vm.currentRegisterId == registerId) {
        await vm.selectRegisterForDevice(
          registerId: registerId,
          registerName: name,
        );
      }
      await _load();
      if (mounted) {
        AppToast.success(context, 'Caja renombrada.');
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(
          context,
          FriendlyError.humanize('Error al renombrar: $e'),
        );
      }
    }
  }

  /// Baja logica. Se niega en los tres casos en que dejaria el POS roto o
  /// partiria un arqueo: caja abierta en esa registradora, es la del equipo,
  /// o es la ultima activa del negocio.
  Future<void> _toggleActive(String registerId, bool isActive) async {
    try {
      if (isActive) {
        final vm = ref.read(cashierViewModelProvider);
        if (vm.currentRegisterId == registerId) {
          AppToast.error(
            context,
            'Esta es la caja de este equipo. Cambia a otra antes de desactivarla.',
          );
          return;
        }

        final activas =
            _registers.where((r) => r['is_active'] == true).length;
        if (activas <= 1) {
          AppToast.error(context, 'Debe quedar al menos una caja activa.');
          return;
        }

        final abiertas = await ref
            .read(cashierRepositoryProvider)
            .getOpenSessionsForRegister(registerId);
        if (abiertas.isNotEmpty) {
          if (mounted) {
            AppToast.error(
              context,
              'Esa caja tiene una sesion abierta. Cierrala antes de desactivarla.',
            );
          }
          return;
        }
      }

      await ref.read(cashierRepositoryProvider).setCashRegisterActive(
            cashRegisterId: registerId,
            isActive: !isActive,
          );
      await _load();
      if (mounted) {
        AppToast.success(
          context,
          isActive ? 'Caja desactivada.' : 'Caja activada.',
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(
          context,
          FriendlyError.humanize('Error al cambiar el estado: $e'),
        );
      }
    }
  }

  /// Ata este equipo a la registradora elegida: a partir de aqui su factura,
  /// su cierre y sus movimientos salen por la impresora de ESTA caja.
  Future<void> _useOnThisDevice(String registerId, String registerName) async {
    try {
      await ref.read(cashierViewModelProvider).selectRegisterForDevice(
            registerId: registerId,
            registerName: registerName,
          );
      if (mounted) {
        setState(() {});
        AppToast.success(context, 'Este equipo ahora opera "$registerName".');
      }
    } on CashRegisterException catch (e) {
      if (mounted) AppToast.error(context, e.message);
    } catch (e) {
      if (mounted) {
        AppToast.error(
          context,
          FriendlyError.humanize('No se pudo cambiar la caja: $e'),
        );
      }
    }
  }

  Future<String?> _promptName({
    required String title,
    required String initial,
    required String confirmLabel,
  }) async {
    final controller = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Nombre',
            hintText: 'Ej. Caja 2 / Barra / Delivery',
          ),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return null;
    return name;
  }

  /// Con una sola caja, "sin asignar" es lo normal (manda la config global).
  /// Con dos o mas deja de serlo: la caja sin impresora propia cae al
  /// fallback por area y puede terminar imprimiendo por la impresora de la
  /// OTRA caja, que es justo lo que se quiere evitar.
  bool get _showPrinterHint {
    final activas =
        _registers.where((r) => r['is_active'] == true).toList(growable: false);
    if (activas.length < 2) return false;
    return activas.any((r) => r['receipt_printer_id'] == null);
  }

  @override
  Widget build(BuildContext context) {
    final deviceRegisterId = ref.watch(
      cashierViewModelProvider.select((vm) => vm.currentRegisterId),
    );
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Regresar',
          onPressed: () => Navigator.of(context).canPop()
              ? Navigator.of(context).pop()
              : context.go(AppRoutes.settings),
        ),
        title: const Text('Cajas Registradoras'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _createRegister,
            tooltip: 'Nueva caja',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Actualizar',
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: MangoColors.primaryOrange),
            )
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _load,
                        child: const Text('Reintentar'),
                      ),
                    ],
                  ),
                )
              : _registers.isEmpty
                  ? const Center(
                      child: Text('No hay cajas registradoras configuradas.'),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      color: MangoColors.primaryOrange,
                      child: ListView.separated(
                        padding: const EdgeInsets.all(16),
                        // +1 por el aviso de cajas sin impresora, que va
                        // como primer elemento cuando aplica.
                        itemCount: _registers.length + (_showPrinterHint ? 1 : 0),
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, rawIndex) {
                          if (_showPrinterHint && rawIndex == 0) {
                            return _MissingPrinterHint(
                              total: _registers
                                  .where((r) => r['is_active'] == true)
                                  .length,
                            );
                          }
                          final index =
                              rawIndex - (_showPrinterHint ? 1 : 0);
                          final reg = _registers[index];
                          final regId = reg['id'] as String;
                          final regName = reg['name'] as String? ?? 'Caja';
                          final currentPrinterId =
                              reg['receipt_printer_id'] as String?;
                          final isActive = reg['is_active'] == true;
                          final isThisDevice = deviceRegisterId == regId;

                          return Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.point_of_sale,
                                      color: isActive
                                          ? MangoColors.primaryOrange
                                          : Colors.grey,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        regName,
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          color: isActive
                                              ? null
                                              : Colors.grey,
                                        ),
                                      ),
                                    ),
                                    if (isThisDevice)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.success
                                              .withValues(alpha: 0.12),
                                          borderRadius:
                                              BorderRadius.circular(20),
                                        ),
                                        child: Text(
                                          'En este equipo',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.success,
                                          ),
                                        ),
                                      )
                                    else if (!isActive)
                                      const Text(
                                        'Inactiva',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    PopupMenuButton<String>(
                                      tooltip: 'Opciones',
                                      onSelected: (value) {
                                        if (value == 'rename') {
                                          _renameRegister(regId, regName);
                                        } else if (value == 'toggle') {
                                          _toggleActive(regId, isActive);
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(
                                          value: 'rename',
                                          child: Text('Renombrar'),
                                        ),
                                        PopupMenuItem(
                                          value: 'toggle',
                                          child: Text(
                                            isActive
                                                ? 'Desactivar'
                                                : 'Activar',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                // La registradora es del EQUIPO: define por
                                // que impresora salen factura, cierre y
                                // movimientos de esta estacion.
                                if (!isThisDevice && isActive)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      onPressed: () =>
                                          _useOnThisDevice(regId, regName),
                                      icon: const Icon(
                                        Icons.desktop_windows_outlined,
                                        size: 18,
                                      ),
                                      label: const Text('Usar en este equipo'),
                                    ),
                                  ),
                                const SizedBox(height: 12),
                                const Text(
                                  'Impresora de recibos',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                DropdownButtonFormField<String?>(
                                  initialValue: _printers.any(
                                          (p) => p.id == currentPrinterId)
                                      ? currentPrinterId
                                      : null,
                                  decoration: InputDecoration(
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    hintText: 'Sin asignar (usa config global)',
                                  ),
                                  items: [
                                    const DropdownMenuItem<String?>(
                                      value: null,
                                      child: Text(
                                        'Sin asignar (config global)',
                                        style: TextStyle(color: Colors.grey),
                                      ),
                                    ),
                                    ..._printers.map(
                                      (p) => DropdownMenuItem<String?>(
                                        value: p.id,
                                        child: Row(
                                          children: [
                                            Icon(
                                              p.type == 'network'
                                                  ? Icons.wifi
                                                  : p.type == 'usb'
                                                      ? Icons.usb
                                                      : Icons.bluetooth,
                                              size: 16,
                                              color: Colors.grey,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(p.name),
                                            if (p.ip != null) ...[
                                              const SizedBox(width: 4),
                                              Text(
                                                '(${p.ip})',
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: (printerId) {
                                    _assignPrinter(regId, printerId);
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

class _MissingPrinterHint extends StatelessWidget {
  final int total;

  const _MissingPrinterHint({required this.total});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.print_disabled_outlined,
              color: AppColors.warning, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Tienes $total cajas activas y alguna esta sin impresora. '
              'Asignale una a cada caja: las que queden "sin asignar" usan '
              'la configuracion global y pueden imprimir por la impresora '
              'de la otra caja.',
              style: const TextStyle(fontSize: 13, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
