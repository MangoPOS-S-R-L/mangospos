import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/loyalty_models.dart';
import '../../../data/repositories/loyalty_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../viewmodel/loyalty_providers.dart';

const _green = Color(0xFF16A34A);
const _textSecondary = Color(0xFF6B7280);

/// Ajustes → Fidelización → Tarjeta de Fidelidad.
///
/// Cada tarjeta dice qué productos (o categorías) suman un sello y cuántos
/// sellos dan 1 gratis: «cada 10 cafés, 1 gratis», «cada 5 pizzas, 1 gratis».
/// Los sellos se calculan solos de las ventas cobradas con el cliente
/// asignado; aquí solo se configura la regla.
class LoyaltyProgramsView extends ConsumerStatefulWidget {
  const LoyaltyProgramsView({super.key});

  @override
  ConsumerState<LoyaltyProgramsView> createState() =>
      _LoyaltyProgramsViewState();
}

class _LoyaltyProgramsViewState extends ConsumerState<LoyaltyProgramsView> {
  bool _loading = true;
  String? _error;
  String? _businessId;
  List<LoyaltyStampProgram> _programs = const [];
  List<LoyaltyTargetOption> _products = const [];
  List<LoyaltyTargetOption> _categories = const [];

  LoyaltyRepository get _repo => ref.read(loyaltyRepositoryProvider);

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
      final businessId =
          _businessId ??
          await resolveBusinessIdOrNull(Supabase.instance.client, 'auto');
      if (businessId == null) {
        throw const LoyaltyException('No se pudo resolver el negocio actual.');
      }
      final results = await Future.wait([
        _repo.getPrograms(businessId),
        _repo.getProducts(businessId),
        _repo.getCategories(businessId),
      ]);
      if (!mounted) return;
      setState(() {
        _businessId = businessId;
        _programs = results[0] as List<LoyaltyStampProgram>;
        _products = results[1] as List<LoyaltyTargetOption>;
        _categories = results[2] as List<LoyaltyTargetOption>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = LoyaltyRepository.mapError(e).message;
      });
    }
  }

  Future<void> _openEditor([LoyaltyStampProgram? program]) async {
    final businessId = _businessId;
    if (businessId == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ProgramDialog(
        businessId: businessId,
        program: program,
        products: _products,
        categories: _categories,
      ),
    );
    if (saved == true) await _load();
  }

  Future<void> _toggle(LoyaltyStampProgram program, bool active) async {
    try {
      await _repo.setProgramActive(program.id, active);
      await _load();
      if (!mounted) return;
      AppToast.success(
        context,
        active
            ? '«${program.name}» activada.'
            : '«${program.name}» desactivada. Los sellos no se pierden.',
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, LoyaltyRepository.mapError(e).message);
    }
  }

  String _targetsLabel(LoyaltyStampProgram program) {
    final source = program.byCategory ? _categories : _products;
    final names = <String>[
      for (final id in program.targetIds)
        source
            .firstWhere(
              (o) => o.id == id,
              orElse: () => const LoyaltyTargetOption(id: '', name: '(inactivo)'),
            )
            .name,
    ];
    final shown = names.take(4).join(', ');
    final more = names.length > 4 ? ' y ${names.length - 4} más' : '';
    return program.byCategory
        ? 'Categoría${names.length == 1 ? '' : 's'}: $shown$more'
        : '$shown$more';
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd/MM/yyyy');
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _loading && _programs.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Header(onNew: _businessId == null ? null : _openEditor),
                  const SizedBox(height: 16),
                  const _HowItWorks(),
                  const SizedBox(height: 20),
                  if (_error != null)
                    _Notice(
                      text: _error!,
                      actionLabel: 'Reintentar',
                      onAction: _load,
                    )
                  else if (_programs.isEmpty)
                    _Notice(
                      text:
                          'Todavía no hay tarjetas. Crea la primera: por '
                          'ejemplo «Tarjeta de Fidelidad», compra 5 pizzas y '
                          'la 6ª gratis.',
                      actionLabel: 'Nueva tarjeta',
                      onAction: _openEditor,
                    )
                  else
                    for (final program in _programs)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE5E7EB)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: program.isActive
                                    ? const Color(0xFFE8F8EE)
                                    : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.card_membership_rounded,
                                color: program.isActive
                                    ? _green
                                    : _textSecondary,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    program.name,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${program.ruleLabel}'
                                    '${program.countMode == 'unit' ? '' : ' · una marca por compra'}'
                                    ' · ${_targetsLabel(program)}',
                                    style: const TextStyle(fontSize: 13.5),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Cuenta compras desde '
                                    '${dateFmt.format(program.startsAt)}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: _textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: program.isActive,
                              activeTrackColor: _green,
                              onChanged: (value) => _toggle(program, value),
                            ),
                            IconButton(
                              tooltip: 'Editar',
                              onPressed: () => _openEditor(program),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onNew});
  final VoidCallback? onNew;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF97316), Color(0xFFEA580C)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Tarjetas de sellos',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Cliente frecuente: cada N compras de un producto, 1 gratis.',
                style: TextStyle(fontSize: 14, color: Colors.white),
              ),
            ],
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFFEA580C),
            ),
            onPressed: onNew,
            icon: const Icon(Icons.add),
            label: const Text('Nueva tarjeta'),
          ),
        ],
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 13, color: Color(0xFF374151));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Cómo funciona',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 6),
          Text(
            '1. En la venta, asigna el cliente a la cuenta. Cada compra '
            'cobrada que lleve productos de la tarjeta suma una marca (o cada '
            'unidad, si la tarjeta es «por unidad»).',
            style: style,
          ),
          SizedBox(height: 3),
          Text(
            '2. Al completar la tarjeta, el carrito muestra «1 gratis · '
            'Canjear»: eliges qué producto va gratis y se descuenta.',
            style: style,
          ),
          SizedBox(height: 3),
          Text(
            '3. Si anulas la venta o quitas el premio, las marcas vuelven '
            'solas. Los cartones físicos se pasan con «Ajustar sellos» en '
            'Clientes (ícono de tarjeta).',
            style: style,
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.actionLabel, this.onAction});

  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 12),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

class _ProgramDialog extends ConsumerStatefulWidget {
  const _ProgramDialog({
    required this.businessId,
    required this.program,
    required this.products,
    required this.categories,
  });

  final String businessId;
  final LoyaltyStampProgram? program;
  final List<LoyaltyTargetOption> products;
  final List<LoyaltyTargetOption> categories;

  @override
  ConsumerState<_ProgramDialog> createState() => _ProgramDialogState();
}

class _ProgramDialogState extends ConsumerState<_ProgramDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _stampsCtrl;
  final _searchCtrl = TextEditingController();
  late String _scope;
  late String _countMode;
  late Set<String> _selected;
  late DateTime _startsAt;
  late bool _active;
  bool _saving = false;

  bool get _isEditing => widget.program != null;

  @override
  void initState() {
    super.initState();
    final p = widget.program;
    _nameCtrl = TextEditingController(text: p?.name ?? '');
    _stampsCtrl = TextEditingController(
      text: (p?.stampsRequired ?? 10).toString(),
    );
    _scope = p?.targetScope ?? 'product';
    // Por compra por defecto: así se sella el cartón en caja.
    _countMode = p?.countMode ?? 'visit';
    _selected = {...?p?.targetIds};
    _startsAt = p?.startsAt ?? DateTime.now();
    _active = p?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _stampsCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _startsAt.isAfter(now) ? now : _startsAt,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      helpText: 'Contar compras desde',
    );
    if (picked == null) return;
    setState(() => _startsAt = DateTime(picked.year, picked.month, picked.day));
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final stamps = int.tryParse(_stampsCtrl.text.trim()) ?? 0;
    if (name.isEmpty) {
      AppToast.error(context, 'Ponle un nombre a la tarjeta.');
      return;
    }
    if (stamps < 2 || stamps > 100) {
      AppToast.error(context, 'Las marcas para la gratis van de 2 a 100.');
      return;
    }
    if (_selected.isEmpty) {
      AppToast.error(
        context,
        _scope == 'category'
            ? 'Elige al menos una categoría.'
            : 'Elige al menos un producto.',
      );
      return;
    }
    setState(() => _saving = true);
    try {
      // Al crear, «hoy» cuenta desde este momento (no desde la medianoche):
      // lo vendido antes de crear la tarjeta no suma.
      final today = DateTime.now();
      final startsAt =
          !_isEditing &&
              _startsAt.year == today.year &&
              _startsAt.month == today.month &&
              _startsAt.day == today.day
          ? today
          : _startsAt;
      await ref
          .read(loyaltyRepositoryProvider)
          .saveProgram(
            id: widget.program?.id,
            businessId: widget.businessId,
            name: name,
            targetScope: _scope,
            targetIds: _selected.toList(),
            stampsRequired: stamps,
            countMode: _countMode,
            startsAt: startsAt,
            isActive: _active,
          );
      if (!mounted) return;
      AppToast.success(context, 'Tarjeta «$name» guardada.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.error(context, LoyaltyRepository.mapError(e).message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = _scope == 'category' ? widget.categories : widget.products;
    final query = _searchCtrl.text.trim().toLowerCase();
    final filtered = options
        .where((o) => query.isEmpty || o.name.toLowerCase().contains(query))
        .toList(growable: false);
    final dateFmt = DateFormat('dd/MM/yyyy');
    final stampsPreview = int.tryParse(_stampsCtrl.text.trim());

    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      title: Text(_isEditing ? 'Editar tarjeta' : 'Nueva tarjeta de sellos'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: 'Nombre',
                  hintText: 'Ej: Tarjeta Café',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: TextField(
                      controller: _stampsCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Marcas',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      stampsPreview != null && stampsPreview >= 2
                          ? '${loyaltyRuleLabel(stampsPreview, _countMode)}.'
                          : 'De 2 a 100 marcas para la gratis.',
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '¿Cuándo se pone una marca?',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'visit',
                    label: Text('Por compra'),
                    icon: Icon(Icons.receipt_long_outlined),
                  ),
                  ButtonSegment(
                    value: 'unit',
                    label: Text('Por unidad'),
                    icon: Icon(Icons.local_pizza_outlined),
                  ),
                ],
                selected: {_countMode},
                onSelectionChanged: (value) =>
                    setState(() => _countMode = value.first),
              ),
              const SizedBox(height: 6),
              Text(
                _countMode == 'visit'
                    ? 'Una marca por cada compra cobrada que lleve productos '
                          'de la tarjeta, lleve 1 o 3 (como se sella el '
                          'cartón). La compra en que solo se lleva la gratis '
                          'no marca.'
                    : 'Cada unidad cobrada suma una marca: 3 pizzas en una '
                          'compra = 3 marcas.',
                style: const TextStyle(fontSize: 12.5, color: _textSecondary),
              ),
              const SizedBox(height: 16),
              const Text(
                '¿Qué productos cuentan?',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'product', label: Text('Productos')),
                  ButtonSegment(
                    value: 'category',
                    label: Text('Categorías completas'),
                  ),
                ],
                selected: {_scope},
                onSelectionChanged: (value) => setState(() {
                  _scope = value.first;
                  _selected = {};
                  _searchCtrl.clear();
                }),
              ),
              const SizedBox(height: 8),
              Text(
                _scope == 'category'
                    ? 'Todo producto de la categoría suma, incluidos los que '
                          'se agreguen después.'
                    : 'El premio es una unidad gratis de cualquiera de estos '
                          'productos (la elige el cajero, con sus extras).',
                style: const TextStyle(fontSize: 12.5, color: _textSecondary),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _searchCtrl,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Buscar',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: filtered.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Sin resultados.'),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final option = filtered[index];
                          return CheckboxListTile(
                            dense: true,
                            value: _selected.contains(option.id),
                            title: Text(option.name),
                            onChanged: (checked) => setState(() {
                              if (checked == true) {
                                _selected.add(option.id);
                              } else {
                                _selected.remove(option.id);
                              }
                            }),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_selected.length} '
                '${_scope == 'category' ? 'categoría(s)' : 'producto(s)'} '
                'elegido(s)',
                style: const TextStyle(fontSize: 12, color: _textSecondary),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.event, size: 18, color: _textSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Cuenta compras desde ${dateFmt.format(_startsAt)}',
                      style: const TextStyle(fontSize: 13.5),
                    ),
                  ),
                  TextButton(
                    onPressed: _pickStart,
                    child: const Text('Cambiar'),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Activa'),
                value: _active,
                activeTrackColor: _green,
                onChanged: (value) => setState(() => _active = value),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Guardar'),
        ),
      ],
    );
  }
}
