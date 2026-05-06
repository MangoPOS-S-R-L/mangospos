// PRD 9 Fase 1C — CRUD de Proveedores (versión extendida del módulo
// Inventario). Cubre todos los campos del schema `suppliers`: nombre,
// RNC, contacto, teléfono, email, dirección, condiciones de pago, notas
// y flag activo.
//
// La vista anterior `purchases_list_view.dart` solo permitía crear con
// 4 campos básicos; esta es la fuente de verdad del CRUD a partir de
// PRD 9. PurchasesRepository.getSuppliers sigue funcionando para el
// dropdown de OCs.

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

class SuppliersView extends ConsumerStatefulWidget {
  const SuppliersView({super.key});

  @override
  ConsumerState<SuppliersView> createState() => _SuppliersViewState();
}

class _SuppliersViewState extends ConsumerState<SuppliersView> {
  bool _loading = true;
  String? _error;
  String? _businessId;
  List<InventorySupplierDetail> _suppliers = const [];
  String _query = '';

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
      final list = await _repo.getAllSuppliers(businessId);
      if (!mounted) return;
      setState(() {
        _businessId = businessId;
        _suppliers = list;
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

  Future<void> _openForm({InventorySupplierDetail? edit}) async {
    final businessId = _businessId;
    if (businessId == null) return;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => _SupplierFormDialog(
        businessId: businessId,
        repo: _repo,
        edit: edit,
      ),
    );
    if (result == true) await _refresh();
  }

  List<InventorySupplierDetail> get _filtered {
    if (_query.trim().isEmpty) return _suppliers;
    final q = _query.trim().toLowerCase();
    return _suppliers.where((s) {
      return s.name.toLowerCase().contains(q) ||
          s.rnc.toLowerCase().contains(q) ||
          s.contactName.toLowerCase().contains(q) ||
          s.phone.toLowerCase().contains(q) ||
          s.email.toLowerCase().contains(q);
    }).toList(growable: false);
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
                        onSearch: (v) => setState(() => _query = v),
                        query: _query,
                      ),
                      const SizedBox(height: 20),
                      _SuppliersTable(
                        suppliers: _filtered,
                        onEdit: (s) => _openForm(edit: s),
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
  final ValueChanged<String> onSearch;
  final String query;

  const _Header({
    required this.onCreate,
    required this.onRefresh,
    required this.onSearch,
    required this.query,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Proveedores',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppColors.foreground,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Catálogo de proveedores con RNC, contacto y condiciones de pago',
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
                  label: const Text('Nuevo proveedor'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: 360,
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Buscar por nombre, RNC, contacto, teléfono o email',
              isDense: true,
            ),
            onChanged: onSearch,
          ),
        ),
      ],
    );
  }
}

class _SuppliersTable extends StatelessWidget {
  final List<InventorySupplierDetail> suppliers;
  final void Function(InventorySupplierDetail) onEdit;

  const _SuppliersTable({required this.suppliers, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    if (suppliers.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.border),
        ),
        child: Center(
          child: Text(
            'No hay proveedores que mostrar.',
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
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(flex: 3, child: _h('Nombre / RNC')),
                Expanded(flex: 3, child: _h('Contacto')),
                Expanded(flex: 2, child: _h('Términos')),
                Expanded(flex: 1, child: _h('Estado')),
                const SizedBox(width: 60),
              ],
            ),
          ),
          Divider(color: AppColors.border, height: 1),
          ...suppliers.asMap().entries.map((entry) {
            final s = entry.value;
            final last = entry.key == suppliers.length - 1;
            return _SupplierRow(s: s, onEdit: onEdit, isLast: last);
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

class _SupplierRow extends StatelessWidget {
  final InventorySupplierDetail s;
  final void Function(InventorySupplierDetail) onEdit;
  final bool isLast;
  const _SupplierRow(
      {required this.s, required this.onEdit, required this.isLast});

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.foreground,
                  ),
                ),
                if (s.rnc.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'RNC ${s.rnc}',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (s.contactName.isNotEmpty)
                  Text(
                    s.contactName,
                    style: TextStyle(
                        fontSize: 13, color: AppColors.foreground),
                  ),
                if (s.phone.isNotEmpty || s.email.isNotEmpty)
                  Text(
                    [if (s.phone.isNotEmpty) s.phone, if (s.email.isNotEmpty) s.email]
                        .join(' · '),
                    style: TextStyle(
                        fontSize: 11, color: AppColors.mutedForeground),
                  ),
                if (s.contactName.isEmpty && s.phone.isEmpty && s.email.isEmpty)
                  Text('—',
                      style: TextStyle(
                          fontSize: 13, color: AppColors.mutedForeground)),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              s.paymentTerms.isEmpty ? '—' : s.paymentTerms,
              style:
                  TextStyle(fontSize: 12, color: AppColors.mutedForeground),
            ),
          ),
          Expanded(
            flex: 1,
            child: s.isActive
                ? _Badge(text: 'Activo', color: AppColors.success)
                : _Badge(text: 'Inactivo', color: AppColors.mutedForeground),
          ),
          SizedBox(
            width: 60,
            child: Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Editar',
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => onEdit(s),
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

class _SupplierFormDialog extends StatefulWidget {
  final String businessId;
  final InventoryRepository repo;
  final InventorySupplierDetail? edit;

  const _SupplierFormDialog({
    required this.businessId,
    required this.repo,
    this.edit,
  });

  @override
  State<_SupplierFormDialog> createState() => _SupplierFormDialogState();
}

class _SupplierFormDialogState extends State<_SupplierFormDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _rncCtrl;
  late final TextEditingController _contactCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _termsCtrl;
  late final TextEditingController _notesCtrl;
  late bool _isActive;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.edit != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.edit?.name ?? '');
    _rncCtrl = TextEditingController(text: widget.edit?.rnc ?? '');
    _contactCtrl =
        TextEditingController(text: widget.edit?.contactName ?? '');
    _phoneCtrl = TextEditingController(text: widget.edit?.phone ?? '');
    _emailCtrl = TextEditingController(text: widget.edit?.email ?? '');
    _addressCtrl = TextEditingController(text: widget.edit?.address ?? '');
    _termsCtrl =
        TextEditingController(text: widget.edit?.paymentTerms ?? '');
    _notesCtrl = TextEditingController(text: widget.edit?.notes ?? '');
    _isActive = widget.edit?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _rncCtrl.dispose();
    _contactCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    _termsCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  String? _orNull(String v) => v.trim().isEmpty ? null : v.trim();

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'El nombre es obligatorio.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isEdit) {
        await widget.repo.updateSupplierDetailed(
          supplierId: widget.edit!.id,
          name: name,
          rnc: _orNull(_rncCtrl.text),
          contactName: _orNull(_contactCtrl.text),
          phone: _orNull(_phoneCtrl.text),
          email: _orNull(_emailCtrl.text),
          address: _orNull(_addressCtrl.text),
          paymentTerms: _orNull(_termsCtrl.text),
          notes: _orNull(_notesCtrl.text),
          isActive: _isActive,
        );
      } else {
        await widget.repo.createSupplierDetailed(
          businessId: widget.businessId,
          name: name,
          rnc: _orNull(_rncCtrl.text),
          contactName: _orNull(_contactCtrl.text),
          phone: _orNull(_phoneCtrl.text),
          email: _orNull(_emailCtrl.text),
          address: _orNull(_addressCtrl.text),
          paymentTerms: _orNull(_termsCtrl.text),
          notes: _orNull(_notesCtrl.text),
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
      title: Text(_isEdit ? 'Editar proveedor' : 'Nuevo proveedor'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Nombre *'),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _rncCtrl,
                      decoration: const InputDecoration(
                          labelText: 'RNC', hintText: '000-00000-0'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _contactCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Contacto'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _phoneCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Teléfono'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _emailCtrl,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _addressCtrl,
                decoration: const InputDecoration(labelText: 'Dirección'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _termsCtrl,
                decoration: const InputDecoration(
                  labelText: 'Condiciones de pago',
                  hintText: 'Ej: 30 días, contado, 50% anticipo',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notesCtrl,
                decoration: const InputDecoration(labelText: 'Notas'),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _isActive,
                onChanged: (v) => setState(() => _isActive = v ?? true),
                title: const Text('Proveedor activo'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style:
                      TextStyle(color: AppColors.destructive, fontSize: 12),
                ),
              ],
            ],
          ),
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
