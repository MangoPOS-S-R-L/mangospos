import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/models/tax.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../viewmodel/taxes_viewmodel.dart';

class TaxesView extends ConsumerStatefulWidget {
  final String businessId; // puede ser 'auto'
  const TaxesView({super.key, required this.businessId});

  @override
  ConsumerState<TaxesView> createState() => _TaxesViewState();
}

class _TaxesViewState extends ConsumerState<TaxesView> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(taxesVmProvider.notifier).load(businessId: widget.businessId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(taxesVmProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: MangoColors.sidebarBg,
      appBar: AppBar(
        title: const Text('Impuestos'),
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: .4,
        actions: [
          IconButton(
            tooltip: 'Refrescar',
            onPressed: () => ref.read(taxesVmProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _InfoBanner(),
            const SizedBox(height: 12),
            _ServiceFeeSectionToggles(businessId: widget.businessId),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: MangoColors.primaryOrange,
                    foregroundColor: MangoColors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => const _TaxFormDialog(),
                    );
                    if (ok == true && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Impuesto agregado')),
                      );
                    }
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Agregar impuesto'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: (v) =>
                        ref.read(taxesVmProvider.notifier).setSearch(v),
                    decoration: InputDecoration(
                      hintText: 'Buscar por nombre o %',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: MangoColors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: MangoColors.cardBorder),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: MangoColors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: MangoColors.cardBorder),
                ),
                child: vm.data.isLoading && vm.filtered.isEmpty
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: MangoColors.primaryOrange,
                        ),
                      )
                    : vm.data.hasError
                    ? Center(
                        child: Text(
                          'Error: ${vm.data.error}',
                          style: text.bodyMedium?.copyWith(color: Colors.red),
                        ),
                      )
                    : const _TaxesTable(),
              ),
            ),
            if (vm.data.isLoading) const SizedBox(height: 8),
            if (vm.data.isLoading)
              const LinearProgressIndicator(
                minHeight: 2,
                color: MangoColors.primaryOrange,
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: MangoColors.primaryOrange, size: 20),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Todos los impuestos se aplicarán al crear el pedido.',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: MangoColors.darkGray,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaxesTable extends ConsumerWidget {
  const _TaxesTable();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(taxesVmProvider);
    final text = Theme.of(context).textTheme;

    if (vm.filtered.isEmpty) {
      return Center(
        child: Text(
          'No hay impuestos',
          style: text.bodyMedium?.copyWith(color: MangoColors.muted),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: vm.filtered.length + 1,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: MangoColors.cardBorder),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(
              children: [
                _th('NOMBRE DEL IMPUESTO', flex: 3),
                _th('PORCENTAJE DE IMPUESTO'),
                _th('ACCIÓN', alignEnd: true),
              ],
            ),
          );
        }

        final t = vm.filtered[i - 1];
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.name,
                        style: text.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: MangoColors.darkGray,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: t.isActive
                            ? MangoColors.successGreen.withOpacity(0.1)
                            : MangoColors.muted.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Activo',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: t.isActive
                                  ? MangoColors.successGreen
                                  : MangoColors.muted,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Switch(
                            value: t.isActive,
                            onChanged: (v) => ref
                                .read(taxesVmProvider.notifier)
                                .toggleActive(t.id, v),
                            activeThumbColor: MangoColors.successGreen,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _td('${t.rate.toStringAsFixed(0)} %'),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: MangoColors.darkGray,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => _TaxFormDialog(editing: t),
                        );
                        if (ok == true && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Impuesto actualizado'),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.edit, size: 18),
                      label: const Text('Actualizar'),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Eliminar',
                      onPressed: () async {
                        final ok = await _confirm(
                          context,
                          '¿Eliminar "${t.name}"?',
                        );
                        if (ok == true) {
                          await ref.read(taxesVmProvider.notifier).remove(t.id);
                        }
                      },
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.red,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _th(String t, {int flex = 1, bool alignEnd = false}) => Expanded(
    flex: flex,
    child: Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: Text(
        t,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: MangoColors.darkGray,
        ),
      ),
    ),
  );

  Widget _td(String t, {int flex = 1}) => Expanded(
    flex: flex,
    child: Text(t, overflow: TextOverflow.ellipsis),
  );
}

class _TaxFormDialog extends ConsumerStatefulWidget {
  final Tax? editing;
  const _TaxFormDialog({this.editing});

  @override
  ConsumerState<_TaxFormDialog> createState() => _TaxFormDialogState();
}

class _TaxFormDialogState extends ConsumerState<_TaxFormDialog> {
  final _name = TextEditingController();
  final _rate = TextEditingController();
  bool _isActive = true;
  bool _applyOnZone = true;
  bool _applyOnManual = true;
  bool _applyOnQuick = true;


  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e != null) {
      _name.text = e.name;
      _rate.text = e.rate.toStringAsFixed(0);
      _isActive = e.isActive;
      _applyOnZone = e.applyOnZone;
      _applyOnManual = e.applyOnManual;
      _applyOnQuick = e.applyOnQuick;
    }

  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.editing != null;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
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
            // Header
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: MangoColors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  Text(
                    isEdit ? 'Editar impuesto' : 'Agregar impuesto',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close),
                    color: MangoColors.darkGray,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: MangoColors.cardBorder),

            // Content
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _name,
                          decoration: InputDecoration(
                            labelText: 'Nombre',
                            hintText: 'Ejem: ITBIS',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: MangoColors.cardBorder,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _rate,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: 'Porcentaje',
                            hintText: 'Ejem: 18',
                            suffixText: '%',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: MangoColors.cardBorder,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: MangoColors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: MangoColors.cardBorder),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Estado del impuesto',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: MangoColors.darkGray,
                          ),
                        ),
                        Row(
                          children: [
                            Text(
                              _isActive ? 'Activo' : 'Inactivo',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: _isActive
                                    ? MangoColors.successGreen
                                    : MangoColors.muted,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Switch(
                              value: _isActive,
                              onChanged: (v) => setState(() => _isActive = v),
                              activeThumbColor: MangoColors.successGreen,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Aplicar en áreas de venta',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: MangoColors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: MangoColors.cardBorder),
                    ),
                    child: Column(
                      children: [
                        _dialogToggleRow(
                          label: 'Ventas por zona (mesas)',
                          value: _applyOnZone,
                          onChanged: (v) => setState(() => _applyOnZone = v),
                        ),
                        const Divider(height: 1, color: MangoColors.cardBorder),
                        _dialogToggleRow(
                          label: 'Venta manual',
                          value: _applyOnManual,
                          onChanged: (v) => setState(() => _applyOnManual = v),
                        ),
                        const Divider(height: 1, color: MangoColors.cardBorder),
                        _dialogToggleRow(
                          label: 'Venta rápida',
                          value: _applyOnQuick,
                          onChanged: (v) => setState(() => _applyOnQuick = v),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),


            // Footer
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: MangoColors.white,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: MangoColors.darkGray,
                        side: BorderSide(color: MangoColors.cardBorder),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.pop(context, false),
                      icon: const Icon(Icons.close),
                      label: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: MangoColors.primaryOrange,
                        foregroundColor: MangoColors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () async {
                        final name = _name.text.trim();
                        final rate = double.tryParse(_rate.text.trim());

                        if (name.isEmpty || rate == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Completa nombre y porcentaje'),
                            ),
                          );
                          return;
                        }

                        final vm = ref.read(taxesVmProvider.notifier);

                        if (isEdit) {
                          await vm.update(
                            widget.editing!.id,
                            name: name,
                            rate: rate,
                            isActive: _isActive,
                            applyOnZone: _applyOnZone,
                            applyOnManual: _applyOnManual,
                            applyOnQuick: _applyOnQuick,
                          );
                        } else {
                          await vm.create(
                            name: name,
                            rate: rate,
                            isActive: _isActive,
                            applyOnZone: _applyOnZone,
                            applyOnManual: _applyOnManual,
                            applyOnQuick: _applyOnQuick,
                          );
                        }


                        if (mounted) Navigator.pop(context, true);
                      },
                      icon: Icon(
                        widget.editing == null ? Icons.add : Icons.save_rounded,
                      ),
                      label: Text(
                        widget.editing == null ? 'Agregar' : 'Editar impuesto',
                      ),
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

  Widget _dialogToggleRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: MangoColors.successGreen,
          ),
        ],
      ),
    );
  }
}


class _ServiceFeeSectionToggles extends ConsumerStatefulWidget {
  final String businessId;
  const _ServiceFeeSectionToggles({required this.businessId});

  @override
  ConsumerState<_ServiceFeeSectionToggles> createState() =>
      _ServiceFeeSectionTogglesState();
}

class _ServiceFeeSectionTogglesState
    extends ConsumerState<_ServiceFeeSectionToggles> {
  bool _loading = true;
  bool _onZone = true;
  bool _onManual = true;
  bool _onQuick = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String> _resolveBusinessId() async {
    if (widget.businessId != 'auto') return widget.businessId;
    return BusinessResolver.ensure(widget.businessId);
  }

  Future<void> _load() async {
    try {
      final bid = await _resolveBusinessId();
      final row = await Supabase.instance.client
          .from('business_settings')
          .select(
            'service_fee_on_zone,service_fee_on_manual,service_fee_on_quick',
          )
          .eq('business_id', bid)
          .maybeSingle();

      if (mounted) {
        setState(() {
          _onZone = (row?['service_fee_on_zone'] as bool?) ?? true;
          _onManual = (row?['service_fee_on_manual'] as bool?) ?? true;
          _onQuick = (row?['service_fee_on_quick'] as bool?) ?? false;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(String column, bool value) async {
    try {
      final bid = await _resolveBusinessId();
      await Supabase.instance.client
          .from('business_settings')
          .update({column: value}).eq('business_id', bid);

      // Invalida el cache del viewmodel de ventas para que
      // recargue la config la próxima vez que se abra una venta.
      ref.read(currentOrderProvider.notifier).invalidateTaxSettings();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al guardar: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.percent,
                color: MangoColors.primaryOrange,
                size: 20,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Propina de ley (10%) por sección',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: MangoColors.darkGray,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Elige en qué tipos de venta se aplica la propina de ley.',
            style: TextStyle(fontSize: 13, color: MangoColors.muted),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(
                  color: MangoColors.primaryOrange,
                  strokeWidth: 2,
                ),
              ),
            )
          else ...[
            _SectionToggleRow(
              label: 'Ventas por zona (mesas)',
              subtitle: 'Dine-in / mesas del salón',
              icon: Icons.table_restaurant,
              value: _onZone,
              onChanged: (v) {
                setState(() => _onZone = v);
                _toggle('service_fee_on_zone', v);
              },
            ),
            const Divider(height: 1, color: MangoColors.cardBorder),
            _SectionToggleRow(
              label: 'Venta manual',
              subtitle: 'Ventas de mostrador / walk-in',
              icon: Icons.point_of_sale,
              value: _onManual,
              onChanged: (v) {
                setState(() => _onManual = v);
                _toggle('service_fee_on_manual', v);
              },
            ),
            const Divider(height: 1, color: MangoColors.cardBorder),
            _SectionToggleRow(
              label: 'Venta rápida',
              subtitle: 'Quick sale / venta express',
              icon: Icons.flash_on,
              value: _onQuick,
              onChanged: (v) {
                setState(() => _onQuick = v);
                _toggle('service_fee_on_quick', v);
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionToggleRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SectionToggleRow({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 20, color: MangoColors.darkGray),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: MangoColors.darkGray,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: value
                  ? MangoColors.successGreen.withValues(alpha: 0.1)
                  : MangoColors.muted.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value ? 'Activo' : 'Inactivo',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color:
                        value ? MangoColors.successGreen : MangoColors.muted,
                  ),
                ),
                const SizedBox(width: 6),
                Switch(
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: MangoColors.successGreen,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<bool?> _confirm(BuildContext ctx, String title) async {
  return showDialog<bool>(
    context: ctx,
    builder: (d) => AlertDialog(
      backgroundColor: MangoColors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: MangoColors.darkGray,
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: MangoColors.darkGray,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () => Navigator.pop(d, false),
          child: const Text('No'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: MangoColors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () => Navigator.pop(d, true),
          child: const Text('Sí, eliminar'),
        ),
      ],
    ),
  );
}
