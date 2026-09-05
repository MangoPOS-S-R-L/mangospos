// F2 — Bandeja de requisiciones.
//
// Tres pestañas que son tres roles distintos mirando la misma tabla:
//   · «Por despachar» le habla al almacén (Santiago): lo que le pidieron.
//   · «Por recibir» le habla a quien pidió (la cocina): lo que ya salió.
//   · «Historial» es lo cerrado.
//
// El stock lo mueve el despacho, no la solicitud. Acá se ve el documento.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/inventory_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../services/requisition_pdf.dart';
import '../state/requisitions_state.dart';
import 'requisition_dispatch_dialog.dart';
import 'requisition_form_dialog.dart';
import 'widgets/inventory_back_button.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

class RequisitionsView extends ConsumerStatefulWidget {
  const RequisitionsView({super.key});

  @override
  ConsumerState<RequisitionsView> createState() => _RequisitionsViewState();
}

class _RequisitionsViewState extends ConsumerState<RequisitionsView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _loading = true;
  String? _error;
  String? _businessId;
  List<Requisition> _requisitions = const [];
  List<InventoryWarehouseDetail> _warehouses = const [];

  InventoryRepository get _repo => ref.read(inventoryRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );
      if (businessId == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'No se pudo resolver el negocio activo.';
        });
        return;
      }
      _businessId = businessId;
      _warehouses = await _repo.getAllWarehouses(businessId);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = FriendlyError.from(e);
      });
    }
  }

  Future<void> _load() async {
    final businessId = _businessId;
    if (businessId == null) return;
    try {
      final rows = await _repo.listRequisitions(businessId: businessId);
      if (!mounted) return;
      setState(() {
        _requisitions = rows;
        _loading = false;
        // El repositorio devuelve vacío —no error— cuando falta la migración.
        // Decirlo es mejor que una lista vacía que parece "no hay pedidos".
        _error = _repo.requisitionsSupported
            ? null
            : 'Las requisiciones necesitan la migración '
                '20260902_0001_requisitions aplicada en Supabase.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = FriendlyError.from(e);
      });
    }
  }

  List<Requisition> get _porDespachar => _requisitions
      .where((r) => r.status.esperaDespacho)
      .toList(growable: false);

  List<Requisition> get _porRecibir => _requisitions
      .where((r) => r.status.esperaRecepcion)
      .toList(growable: false);

  List<Requisition> get _historial =>
      _requisitions.where((r) => r.status.cerrada).toList(growable: false);

  Future<void> _nueva() async {
    final businessId = _businessId;
    if (businessId == null) return;
    final creada = await showRequisitionFormDialog(
      context,
      businessId: businessId,
      repo: _repo,
      warehouses: _warehouses,
    );
    if (creada) await _load();
  }

  Future<void> _despachar(Requisition req) async {
    final hecho = await showRequisitionDispatchDialog(
      context,
      repo: _repo,
      requisition: req,
    );
    if (hecho) await _load();
  }

  Future<void> _recibir(Requisition req) async {
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Recibir ${req.code}'),
        content: Text(
          'Confirma que llegó a ${req.toWarehouseName} lo que despachó '
          '${req.fromWarehouseName}. La mercancía entra al inventario de la '
          'bodega destino.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Recibir'),
          ),
        ],
      ),
    );
    if (confirmado != true) return;
    try {
      await _repo.receiveRequisition(requisitionId: req.id);
      if (!mounted) return;
      AppToast.success(context, '${req.code} recibida.');
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, _mensajeDeError(e));
    }
  }

  Future<void> _cancelar(Requisition req) async {
    final ctrl = TextEditingController();
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cancelar ${req.code}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Solo se puede cancelar antes de despachar. Después ya hay '
              'mercancía en camino y lo que corresponde es una devolución.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'Motivo (opcional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancelar pedido'),
          ),
        ],
      ),
    );
    if (confirmado != true) return;
    try {
      await _repo.cancelRequisition(
        requisitionId: req.id,
        reason: ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
      );
      if (!mounted) return;
      AppToast.info(context, '${req.code} cancelada.');
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, _mensajeDeError(e));
    }
  }

  /// Arma el documento A4 con las dos firmas. Las líneas y el nombre del
  /// negocio se piden en el momento: la bandeja no los necesita para pintar.
  Future<void> _imprimir(Requisition req) async {
    try {
      final lineas = await _repo.getRequisitionLines(req.id);
      final businessName = await _repo.getBusinessName(req.businessId);
      // El responsable de cada bodega firma su lado. Si la bodega no tiene
      // responsable asignado, la línea sale en blanco para firmarla a mano.
      String? keeper(String warehouseId) {
        for (final w in _warehouses) {
          if (w.id == warehouseId) {
            return w.keeperName.isEmpty ? null : w.keeperName;
          }
        }
        return null;
      }

      await exportRequisitionPdf(
        req: req,
        lines: lineas,
        businessName: businessName,
        areaKeeperName: keeper(req.toWarehouseId),
        warehouseKeeperName: keeper(req.fromWarehouseId),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo generar el documento: $e');
    }
  }

  /// Los RPC levantan códigos, no frases. Traducirlos acá evita que el
  /// usuario vea `NOT_WAREHOUSE_KEEPER` y no sepa qué hacer.
  String _mensajeDeError(Object e) {
    final texto = e.toString();
    if (texto.contains('NOT_WAREHOUSE_KEEPER')) {
      return 'Solo el responsable de la bodega de origen puede despachar '
          'esta requisición.';
    }
    if (texto.contains('INSUFFICIENT_ROLE')) {
      return 'Tu rol no permite mover mercancía entre bodegas.';
    }
    if (texto.contains('INVALID_STATUS_TRANSITION')) {
      return 'Alguien ya cambió el estado de esta requisición. Refrescá para '
          'ver cómo quedó.';
    }
    if (texto.contains('INSUFFICIENT_STOCK')) {
      return 'No hay suficiente existencia en la bodega de origen para lo que '
          'se está despachando.';
    }
    return texto;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: const InventoryBackButton(),
        title: const Text('Requisiciones'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.mutedForeground,
          indicatorColor: AppColors.primary,
          isScrollable: true,
          tabs: [
            Tab(text: 'Por despachar (${_porDespachar.length})'),
            Tab(text: 'Por recibir (${_porRecibir.length})'),
            Tab(text: 'Historial (${_historial.length})'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
            tooltip: 'Refrescar',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _nueva,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Pedir mercancía'),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _error != null
              ? _MensajeCentral(
                  icono: Icons.error_outline_rounded,
                  titulo: 'No se pudo cargar',
                  detalle: _error!,
                  accion: _bootstrap,
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _lista(
                      _porDespachar,
                      vacio: 'Nadie ha pedido mercancía.',
                      pista: 'Cuando la cocina pida, aparece acá para que el '
                          'almacén la despache.',
                    ),
                    _lista(
                      _porRecibir,
                      vacio: 'No hay mercancía en camino.',
                      pista: 'Lo que el almacén despache aparece acá hasta '
                          'que se confirme que llegó.',
                    ),
                    _lista(
                      _historial,
                      vacio: 'Todavía no hay requisiciones cerradas.',
                      pista: '',
                    ),
                  ],
                ),
    );
  }

  Widget _lista(
    List<Requisition> items, {
    required String vacio,
    required String pista,
  }) {
    if (items.isEmpty) {
      return _MensajeCentral(
        icono: Icons.inbox_outlined,
        titulo: vacio,
        detalle: pista,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _RequisitionCard(
          req: items[i],
          onDespachar: () => _despachar(items[i]),
          onRecibir: () => _recibir(items[i]),
          onCancelar: () => _cancelar(items[i]),
          onImprimir: () => _imprimir(items[i]),
        ),
      ),
    );
  }
}

class _RequisitionCard extends StatelessWidget {
  final Requisition req;
  final VoidCallback onDespachar;
  final VoidCallback onRecibir;
  final VoidCallback onCancelar;
  final VoidCallback onImprimir;

  const _RequisitionCard({
    required this.req,
    required this.onDespachar,
    required this.onRecibir,
    required this.onCancelar,
    required this.onImprimir,
  });

  Color get _colorEstado {
    switch (req.status) {
      case RequisitionStatus.pending:
        return AppColors.primary;
      case RequisitionStatus.partial:
        return AppColors.warning;
      case RequisitionStatus.dispatched:
        return AppColors.primary;
      case RequisitionStatus.received:
        return AppColors.success;
      case RequisitionStatus.cancelled:
        return AppColors.mutedForeground;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                req.code,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _colorEstado.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Text(
                  req.status.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: _colorEstado,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Documento A4 para firmar',
                icon: Icon(
                  Icons.picture_as_pdf_outlined,
                  size: 20,
                  color: AppColors.mutedForeground,
                ),
                onPressed: onImprimir,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.arrow_forward_rounded,
                size: 15,
                color: AppColors.mutedForeground,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${req.fromWarehouseName}  →  ${req.toWarehouseName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ),
            ],
          ),
          if ((req.notes ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              req.notes!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.mutedForeground,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              if (req.status.esperaDespacho) ...[
                FilledButton.icon(
                  onPressed: onDespachar,
                  icon: const Icon(Icons.local_shipping_outlined, size: 18),
                  label: const Text('Despachar'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onCancelar,
                  child: const Text('Cancelar'),
                ),
              ] else if (req.status.esperaRecepcion)
                FilledButton.icon(
                  onPressed: onRecibir,
                  icon: const Icon(Icons.inventory_2_outlined, size: 18),
                  label: const Text('Recibir'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MensajeCentral extends StatelessWidget {
  final IconData icono;
  final String titulo;
  final String detalle;
  final VoidCallback? accion;

  const _MensajeCentral({
    required this.icono,
    required this.titulo,
    required this.detalle,
    this.accion,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, size: 44, color: AppColors.mutedForeground),
            const SizedBox(height: 12),
            Text(
              titulo,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
            if (detalle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                detalle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
            if (accion != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: accion,
                child: const Text('Reintentar'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
