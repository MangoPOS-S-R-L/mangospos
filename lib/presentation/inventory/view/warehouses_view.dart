// PRD 9 Fase 1B — CRUD de Bodegas.
//
// Lista todas las bodegas del business (incluye inactivas y la virtual
// `__IN_TRANSIT__` mostrada como read-only). Permite crear/editar
// nombre, dirección, marca de bodega principal, y activar/desactivar.
//
// Reglas:
//   - Solo una bodega `is_main = true` por business (lo enforce el repo).
//   - `__IN_TRANSIT__` no se puede editar ni desactivar desde la UI
//     (se gestiona automáticamente vía `ensure_in_transit_warehouse`).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/inventory_state.dart';
import 'widgets/inventory_back_button.dart';

class WarehousesView extends ConsumerStatefulWidget {
  const WarehousesView({super.key});

  @override
  ConsumerState<WarehousesView> createState() => _WarehousesViewState();
}

class _WarehousesViewState extends ConsumerState<WarehousesView> {
  bool _loading = true;
  String? _error;
  String? _businessId;
  List<InventoryWarehouseDetail> _warehouses = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  InventoryRepository get _repo =>
      InventoryRepository(Supabase.instance.client);

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final businessId =
          await resolveBusinessIdOrNull(Supabase.instance.client, 'auto');
      if (businessId == null) {
        setState(() {
          _loading = false;
          _error = 'No se pudo resolver el negocio activo.';
        });
        return;
      }
      final list = await _repo.getAllWarehouses(businessId);
      if (!mounted) return;
      setState(() {
        _businessId = businessId;
        _warehouses = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openForm({InventoryWarehouseDetail? edit}) async {
    final businessId = _businessId;
    if (businessId == null) return;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => _WarehouseFormDialog(
        businessId: businessId,
        repo: _repo,
        edit: edit,
      ),
    );
    if (result == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline,
                            size: 40, color: AppColors.destructive),
                        const SizedBox(height: 12),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.foreground)),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _refresh,
                          child: const Text('Reintentar'),
                        ),
                      ],
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Header(
                        onCreate: () => _openForm(),
                        onRefresh: _refresh,
                      ),
                      const SizedBox(height: 20),
                      _WarehousesTable(
                        warehouses: _warehouses,
                        onEdit: (w) => _openForm(edit: w),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onCreate;
  final VoidCallback onRefresh;
  const _Header({required this.onCreate, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: InventoryBackButton(),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Bodegas',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Almacenes físicos del negocio + bodega virtual de tránsito',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
        Wrap(
          spacing: 12,
          children: [
            OutlinedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Recargar'),
            ),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Nueva bodega'),
            ),
          ],
        ),
      ],
    );
  }
}

class _WarehousesTable extends StatelessWidget {
  final List<InventoryWarehouseDetail> warehouses;
  final void Function(InventoryWarehouseDetail) onEdit;

  const _WarehousesTable({required this.warehouses, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    if (warehouses.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.border),
        ),
        child: Center(
          child: Text(
            'No hay bodegas registradas todavía.',
            style: TextStyle(color: AppColors.mutedForeground),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(flex: 3, child: _h('Nombre')),
                Expanded(flex: 4, child: _h('Dirección')),
                Expanded(flex: 2, child: _h('Estado')),
                const SizedBox(width: 80),
              ],
            ),
          ),
          Divider(color: AppColors.border, height: 1),
          ...warehouses.asMap().entries.map((entry) {
            final w = entry.value;
            final last = entry.key == warehouses.length - 1;
            return _Row(w: w, onEdit: onEdit, isLast: last);
          }),
        ],
      ),
    );
  }

  Widget _h(String t) => Text(
        t,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.mutedForeground,
        ),
      );
}

class _Row extends StatelessWidget {
  final InventoryWarehouseDetail w;
  final void Function(InventoryWarehouseDetail) onEdit;
  final bool isLast;
  const _Row({required this.w, required this.onEdit, required this.isLast});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    w.isInTransit ? 'En tránsito (virtual)' : w.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.foreground,
                      fontStyle:
                          w.isInTransit ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ),
                if (w.isMain) ...[
                  const SizedBox(width: 8),
                  _Badge(text: 'Principal', color: AppColors.primary),
                ],
              ],
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              w.address.isEmpty ? '—' : w.address,
              style: TextStyle(fontSize: 13, color: AppColors.mutedForeground),
            ),
          ),
          Expanded(
            flex: 2,
            child: w.isActive
                ? _Badge(text: 'Activa', color: AppColors.success)
                : _Badge(text: 'Inactiva', color: AppColors.mutedForeground),
          ),
          SizedBox(
            width: 80,
            child: Align(
              alignment: Alignment.centerRight,
              child: w.isInTransit
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: 'Editar',
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () => onEdit(w),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _WarehouseFormDialog extends StatefulWidget {
  final String businessId;
  final InventoryRepository repo;
  final InventoryWarehouseDetail? edit;

  const _WarehouseFormDialog({
    required this.businessId,
    required this.repo,
    this.edit,
  });

  @override
  State<_WarehouseFormDialog> createState() => _WarehouseFormDialogState();
}

class _WarehouseFormDialogState extends State<_WarehouseFormDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _addressCtrl;
  late bool _isMain;
  late bool _isActive;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.edit != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.edit?.name ?? '');
    _addressCtrl = TextEditingController(text: widget.edit?.address ?? '');
    _isMain = widget.edit?.isMain ?? false;
    _isActive = widget.edit?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'El nombre es obligatorio.');
      return;
    }
    if (name == '__IN_TRANSIT__') {
      setState(() => _error = 'Ese nombre está reservado por el sistema.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isEdit) {
        await widget.repo.updateWarehouse(
          businessId: widget.businessId,
          warehouseId: widget.edit!.id,
          name: name,
          address: _addressCtrl.text.trim().isEmpty
              ? null
              : _addressCtrl.text.trim(),
          isMain: _isMain,
          isActive: _isActive,
        );
      } else {
        await widget.repo.createWarehouse(
          businessId: widget.businessId,
          name: name,
          address: _addressCtrl.text.trim().isEmpty
              ? null
              : _addressCtrl.text.trim(),
          isMain: _isMain,
          isActive: _isActive,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Editar bodega' : 'Nueva bodega'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Nombre *',
                hintText: 'Bodega Principal, Sucursal Centro, etc.',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _addressCtrl,
              decoration: const InputDecoration(
                labelText: 'Dirección (opcional)',
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _isMain,
              onChanged: (v) => setState(() => _isMain = v ?? false),
              title: const Text('Bodega principal'),
              subtitle: const Text(
                  'Solo puede haber una. Se baja la marca de la actual si la cambiás.'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            CheckboxListTile(
              value: _isActive,
              onChanged: (v) => setState(() => _isActive = v ?? true),
              title: const Text('Activa'),
              subtitle: const Text(
                  'Si se desactiva, no aparecerá para recibir mercancía.'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: AppColors.destructive, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : Text(_isEdit ? 'Guardar' : 'Crear'),
        ),
      ],
    );
  }
}
