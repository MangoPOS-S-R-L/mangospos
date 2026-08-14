import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/data/models/printing.dart' show PrinterConfig;
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/theme/app_colors.dart';

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
        _error = 'Error al cargar cajas: $e';
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

  @override
  Widget build(BuildContext context) {
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
                        itemCount: _registers.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final reg = _registers[index];
                          final regId = reg['id'] as String;
                          final regName = reg['name'] as String? ?? 'Caja';
                          final currentPrinterId =
                              reg['receipt_printer_id'] as String?;

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
                                    const Icon(
                                      Icons.point_of_sale,
                                      color: MangoColors.primaryOrange,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        regName,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
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
