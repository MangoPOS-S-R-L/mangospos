import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/dining_table.dart';
import '../../../data/models/reservation.dart';
import '../../../data/models/zone.dart';
import '../../../data/repositories/customers_repository.dart';
import '../../../data/repositories/zones_repository.dart';
import '../../../domain/repositories/i_reservations_repository.dart';
import '../viewmodel/reservations_viewmodel.dart';

/// Abre el formulario de crear/editar reserva. Devuelve `true` si se guardó.
Future<bool?> showReservationForm(
  BuildContext context, {
  required String businessId,
  DateTime? initialDay,
  Reservation? existing,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ReservationFormDialog(
      businessId: businessId,
      initialDay: initialDay,
      existing: existing,
    ),
  );
}

/// Opción de mesa (mesa + nombre de zona) para el selector.
class _TableOption {
  final DiningTable table;
  final String zoneName;
  const _TableOption(this.table, this.zoneName);

  String get label {
    final base = table.label?.isNotEmpty == true ? table.label! : table.code;
    return '$zoneName · $base (${table.capacity}p)';
  }
}

class _ReservationFormDialog extends ConsumerStatefulWidget {
  final String businessId;
  final DateTime? initialDay;
  final Reservation? existing;

  const _ReservationFormDialog({
    required this.businessId,
    this.initialDay,
    this.existing,
  });

  @override
  ConsumerState<_ReservationFormDialog> createState() =>
      _ReservationFormDialogState();
}

class _ReservationFormDialogState
    extends ConsumerState<_ReservationFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  late DateTime _date;
  late TimeOfDay _time;
  int _durationMinutes = 90;
  int _partySize = 2;
  String? _customerId;
  String? _tableId;

  List<_TableOption> _tables = const [];
  bool _loadingTables = true;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _nameCtrl.text = e.customerName;
      _phoneCtrl.text = e.customerPhone ?? '';
      _notesCtrl.text = e.notes ?? '';
      final local = e.reservedForLocal;
      _date = DateTime(local.year, local.month, local.day);
      _time = TimeOfDay(hour: local.hour, minute: local.minute);
      _durationMinutes = e.durationMinutes;
      _partySize = e.partySize;
      _customerId = e.customerId;
      _tableId = e.tableId;
    } else {
      final base = widget.initialDay ?? DateTime.now();
      _date = DateTime(base.year, base.month, base.day);
      _time = const TimeOfDay(hour: 19, minute: 0);
    }
    _loadTables();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTables() async {
    try {
      final repo = ZonesRepository(Supabase.instance.client);
      final zones = await repo.fetchZones(widget.businessId);
      final visibleZones = zones.where((z) {
        final n = z.name.toLowerCase();
        return n != 'ventas manuales' &&
            n != 'ventas rápidas' &&
            n != 'delivery';
      }).toList();

      final options = <_TableOption>[];
      for (final Zone z in visibleZones) {
        final tables = await repo.fetchTablesByZone(z.id);
        for (final t in tables) {
          options.add(_TableOption(t, z.name));
        }
      }
      if (!mounted) return;
      setState(() {
        _tables = options;
        _loadingTables = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingTables = false);
    }
  }

  DateTime get _reservedForLocal => DateTime(
        _date.year,
        _date.month,
        _date.day,
        _time.hour,
        _time.minute,
      );

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _searchCustomer() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CustomerSearchSheet(businessId: widget.businessId),
    );
    if (picked != null) {
      setState(() {
        _customerId = picked['id'] as String?;
        _nameCtrl.text = (picked['name'] as String?) ?? _nameCtrl.text;
        final phone = picked['phone'] as String?;
        if (phone != null && phone.isNotEmpty) _phoneCtrl.text = phone;
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_tableId == null) {
      _toast('Selecciona una mesa.');
      return;
    }
    setState(() => _saving = true);

    final input = ReservationInput(
      businessId: widget.businessId,
      tableId: _tableId!,
      customerName: _nameCtrl.text.trim(),
      partySize: _partySize,
      reservedForLocal: _reservedForLocal,
      durationMinutes: _durationMinutes,
      customerId: _customerId,
      customerPhone:
          _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
    );

    final vm = ref.read(reservationsVmProvider.notifier);
    final error = _isEdit
        ? await vm.update(widget.existing!.id, input)
        : await vm.create(input);

    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      _toast(error);
      return;
    }
    Navigator.of(context).pop(true);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = [
      'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.9;

    return Dialog(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 460, maxHeight: maxH),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(),
              const SizedBox(height: 14),
              const Divider(height: 1, color: AppColors.border),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Form(key: _formKey, child: _fields()),
                ),
              ),
              const SizedBox(height: 20),
              _footer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isEdit ? 'Detalles de la reserva' : 'Nueva reserva',
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                _isEdit
                    ? 'ID #${widget.existing!.id.substring(0, 8).toUpperCase()}'
                    : 'Completa los datos de la reserva',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.mutedForeground,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        _closeButton(),
      ],
    );
  }

  Widget _closeButton() {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: _saving ? null : () => Navigator.of(context).pop(false),
        customBorder: const CircleBorder(),
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: Icon(Icons.close, size: 22, color: AppColors.mutedForeground),
        ),
      ),
    );
  }

  Widget _fields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('Nombre del cliente'),
        TextFormField(
          controller: _nameCtrl,
          textCapitalization: TextCapitalization.words,
          decoration: _dec(
            hint: 'Ej. Roberto Fox',
            suffixIcon: IconButton(
              tooltip: 'Buscar cliente existente',
              icon: const Icon(Icons.person_search_outlined, size: 20),
              color: AppColors.mutedForeground,
              onPressed: _searchCustomer,
            ),
          ),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'Escribe el nombre' : null,
        ),
        const SizedBox(height: 16),
        _label('Teléfono (opcional)'),
        TextFormField(
          controller: _phoneCtrl,
          keyboardType: TextInputType.phone,
          decoration: _dec(hint: 'Ej. 809-555-1234'),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('Hora'),
                  _pickerField(
                    icon: Icons.schedule,
                    text: _time.format(context),
                    onTap: _pickTime,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('Fecha'),
                  _pickerField(
                    icon: Icons.calendar_today_outlined,
                    text: _formatDate(_date),
                    onTap: _pickDate,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _label('Personas'),
        _stepperField(),
        const SizedBox(height: 16),
        _label('Duración'),
        DropdownButtonFormField<int>(
          initialValue: _durationMinutes,
          decoration: _dec(),
          borderRadius: BorderRadius.circular(12),
          items: const [60, 90, 120, 150, 180]
              .map((m) => DropdownMenuItem(value: m, child: Text('$m min')))
              .toList(),
          onChanged: (v) => setState(() => _durationMinutes = v ?? 90),
        ),
        const SizedBox(height: 16),
        _label('Mesa'),
        _tableField(),
        const SizedBox(height: 16),
        _label('Notas (opcional)'),
        TextFormField(
          controller: _notesCtrl,
          maxLines: 2,
          decoration: _dec(hint: 'Cumpleaños, silla bebé, ventana…'),
        ),
      ],
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.mutedForeground,
        ),
      ),
    );
  }

  InputDecoration _dec({String? hint, Widget? suffixIcon}) {
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c, width: w),
        );
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.mutedForeground),
      filled: true,
      fillColor: AppColors.card,
      isDense: true,
      suffixIcon: suffixIcon,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: border(AppColors.border),
      border: border(AppColors.border),
      focusedBorder: border(AppColors.primary, 1.5),
      errorBorder: border(AppColors.destructive),
      focusedErrorBorder: border(AppColors.destructive, 1.5),
    );
  }

  Widget _pickerField({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.foreground,
                  ),
                ),
              ),
              Icon(icon, size: 19, color: AppColors.mutedForeground),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepperField() {
    final overCapacity = _tables
        .where((o) => o.table.id == _tableId)
        .any((o) => _partySize > o.table.capacity);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              _circleBtn(
                Icons.remove,
                _partySize > 1 ? () => setState(() => _partySize--) : null,
                primary: false,
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '$_partySize ${_partySize == 1 ? 'persona' : 'personas'}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
              ),
              _circleBtn(
                Icons.add,
                () => setState(() => _partySize++),
                primary: true,
              ),
            ],
          ),
        ),
        if (overCapacity)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Aviso: el grupo supera la capacidad de la mesa.',
              style: TextStyle(color: AppColors.warning, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback? onTap, {required bool primary}) {
    final enabled = onTap != null;
    final bg = primary
        ? (enabled ? AppColors.primary : AppColors.primary.withValues(alpha: 0.4))
        : AppColors.muted;
    final fg = primary
        ? Colors.white
        : (enabled ? AppColors.foreground : AppColors.mutedForeground);
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(icon, size: 20, color: fg),
        ),
      ),
    );
  }

  Widget _tableField() {
    if (_loadingTables) {
      return Container(
        height: 50,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Cargando mesas…',
                style: TextStyle(color: AppColors.mutedForeground)),
          ],
        ),
      );
    }
    if (_tables.isEmpty) {
      return const Text(
        'No hay mesas configuradas. Crea mesas en Ajustes → Zonas y Mesas.',
        style: TextStyle(color: AppColors.destructive, fontSize: 13),
      );
    }
    final values = _tables.map((o) => o.table.id).toSet();
    final selected = values.contains(_tableId) ? _tableId : null;
    return DropdownButtonFormField<String>(
      initialValue: selected,
      isExpanded: true,
      decoration: _dec(hint: 'Selecciona una mesa'),
      borderRadius: BorderRadius.circular(12),
      items: _tables
          .map((o) => DropdownMenuItem(
                value: o.table.id,
                child: Text(o.label, overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: (v) => setState(() => _tableId = v),
    );
  }

  Widget _footer() {
    return Row(
      children: [
        Expanded(child: _confirmButton()),
        const SizedBox(width: 12),
        Expanded(child: _cancelButton()),
      ],
    );
  }

  Widget _confirmButton() {
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: _saving ? null : _save,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 52,
          alignment: Alignment.center,
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(
                  _isEdit ? 'Guardar' : 'Confirmar',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _cancelButton() {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: _saving ? null : () => Navigator.of(context).pop(false),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: const Text(
            'Cancelar',
            style: TextStyle(
              color: AppColors.foreground,
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// Hoja de búsqueda de clientes existentes. Reutiliza CustomersRepository.
class _CustomerSearchSheet extends StatefulWidget {
  final String businessId;
  const _CustomerSearchSheet({required this.businessId});

  @override
  State<_CustomerSearchSheet> createState() => _CustomerSearchSheetState();
}

class _CustomerSearchSheetState extends State<_CustomerSearchSheet> {
  final _repo = CustomersRepository(Supabase.instance.client);
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    setState(() => _loading = true);
    try {
      final rows = await _repo.getCustomers(widget.businessId, query: q);
      if (!mounted) return;
      setState(() {
        _results = rows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Buscar cliente',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: AppColors.secondary,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.border),
              ),
            ),
            onChanged: _search,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 280,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? const Center(child: Text('Sin resultados'))
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (_, i) {
                          final c = _results[i];
                          return ListTile(
                            leading: const Icon(Icons.person_outline),
                            title: Text((c['name'] as String?) ?? '—'),
                            subtitle: Text((c['phone'] as String?) ?? ''),
                            onTap: () => Navigator.of(context).pop(c),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
