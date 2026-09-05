import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/fiscal/ncf_types.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import '../viewmodel/fiscal_viewmodel.dart';
import '../../../../../../data/models/fiscal_models.dart';
import '../../../../../../core/theme/app_colors.dart';

class FiscalReceiptsView extends ConsumerStatefulWidget {
  final String businessId;
  const FiscalReceiptsView({super.key, required this.businessId});

  @override
  ConsumerState<FiscalReceiptsView> createState() => _FiscalReceiptsViewState();
}

class _FiscalReceiptsViewState extends ConsumerState<FiscalReceiptsView> {
  final _rncController = TextEditingController();
  final _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(fiscalVmProvider.notifier).load(widget.businessId);
      final state = ref.read(fiscalVmProvider);
      _rncController.text = state.fiscalRnc;
      _nameController.text = state.fiscalName;
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(fiscalVmProvider);

    ref.listen(fiscalVmProvider.select((s) => s.error), (prev, next) {
      if (next != null && next.isNotEmpty) {
        AppToast.error(context, next);
      }
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Configuración Fiscal (DR)'),
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: .4,
        actions: [
          IconButton(
            onPressed: () =>
                ref.read(fiscalVmProvider.notifier).load(widget.businessId),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: vm.isLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: MangoColors.primaryOrange,
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader('Datos del Emisor'),
                  const SizedBox(height: 16),
                  _buildBusinessCard(vm),
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _sectionHeader('Secuencias NCF'),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: MangoColors.primaryOrange,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => _showFormDialog(),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Agregar Secuencia'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildNCFTable(vm.sequences),
                  const SizedBox(height: 48),
                ],
              ),
            ),
    );
  }

  Widget _buildBusinessCard(FiscalState vm) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildField(
                  label: 'RNC / Cédula',
                  controller: _rncController,
                  hint: 'Ej: 131904561',
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: _buildField(
                  label: 'Razón Social',
                  controller: _nameController,
                  hint: 'Ej: Mi Negocio SRL',
                ),
              ),
              const SizedBox(width: 20),
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: MangoColors.darkGray,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    ref
                        .read(fiscalVmProvider.notifier)
                        .updateFiscalInfo(
                          widget.businessId,
                          rnc: _rncController.text,
                          name: _nameController.text,
                        );
                    AppToast.success(context, 'Configuración guardada');
                  },
                  child: const Text('Guardar'),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Divider(height: 1),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: MangoColors.primaryOrange.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.flash_on_rounded,
                      color: MangoColors.primaryOrange,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Modalidad e-CF (Facturación Electrónica)',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        'Emitir comprobantes electrónicos (Serie E) de forma prioritaria.',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                    ],
                  ),
                ],
              ),
              Switch(
                value: vm.preferElectronicBilling,
                onChanged: (v) => ref
                    .read(fiscalVmProvider.notifier)
                    .toggleElectronicBilling(widget.businessId, v),
                activeThumbColor: MangoColors.primaryOrange,
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Divider(height: 1),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: MangoColors.primaryOrange.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.receipt_long_rounded,
                      color: MangoColors.primaryOrange,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Comprobante predefinido',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        'El que sale preseleccionado al cobrar; el cajero puede cambiarlo por venta.',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                    ],
                  ),
                ],
              ),
              _defaultNcfDropdown(vm),
            ],
          ),
        ],
      ),
    );
  }

  /// Selector del comprobante predefinido. Opciones = tipos con secuencia
  /// ACTIVA (solo esos pueden emitirse); si el guardado actual no tiene
  /// secuencia activa, se incluye igual para que el valor sea visible.
  Widget _defaultNcfDropdown(FiscalState vm) {
    final codes = <String>{};
    for (final s in vm.sequences) {
      if (!s.activo) continue;
      final code = '${s.serie}${s.tipo}'.toUpperCase();
      if (code.length >= 3) codes.add(code);
    }
    codes.add(vm.defaultNcfType.toUpperCase());
    final sorted = codes.toList()..sort();
    return SizedBox(
      width: 260,
      child: DropdownButtonFormField<String>(
        initialValue: sorted.contains(vm.defaultNcfType.toUpperCase())
            ? vm.defaultNcfType.toUpperCase()
            : null,
        isExpanded: true,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: MangoColors.sidebarBg.withValues(alpha: 0.3),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: MangoColors.cardBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: MangoColors.cardBorder),
          ),
        ),
        items: sorted
            .map(
              (code) => DropdownMenuItem(
                value: code,
                child: Text(
                  '$code — ${ncfTypeName(code)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(growable: false),
        onChanged: (code) async {
          if (code == null || code == vm.defaultNcfType) return;
          await ref
              .read(fiscalVmProvider.notifier)
              .setDefaultNcfType(widget.businessId, code);
          if (!mounted) return;
          if (ref.read(fiscalVmProvider).error == null) {
            AppToast.success(
              context,
              'Comprobante predefinido: $code — ${ncfTypeName(code)}',
            );
          }
        },
      ),
    );
  }

  Widget _buildField({
    required String label,
    required TextEditingController controller,
    String? hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: MangoColors.darkGray,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: MangoColors.sidebarBg.withOpacity(0.3),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: MangoColors.cardBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: MangoColors.cardBorder),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w900,
        color: MangoColors.darkGray,
      ),
    );
  }

  Widget _buildNCFTable(List<FiscalNcfSequence> sequences) {
    if (sequences.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(40),
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: MangoColors.cardBorder),
        ),
        child: Column(
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 48,
              color: MangoColors.muted.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            const Text(
              'No hay secuencias configuradas.',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: MangoColors.muted,
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        children: [
          _buildTableHeader(),
          const Divider(height: 1),
          ...sequences.map((s) => _buildTableRow(s)),
        ],
      ),
    );
  }

  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: MangoColors.sidebarBg.withOpacity(0.5),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: const Row(
        children: [
          Expanded(
            flex: 1,
            child: Text(
              'TIPO',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
                color: MangoColors.muted,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              'DESCRIPCIÓN',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
                color: MangoColors.muted,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              'SIGUIENTE NCF',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
                color: MangoColors.muted,
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              'RESTANTES',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
                color: MangoColors.muted,
              ),
            ),
          ),
          SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildTableRow(FiscalNcfSequence s) {
    final remaining = s.maximoSeq - s.ultimoSeq;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Expanded(
            flex: 1,
            child: Text(
              s.tipo,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: MangoColors.darkGray,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _getTipoNombre(s.tipo),
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                // Sin la fecha de la autorización, la DGII rechaza el e-CF con
                // el código 145 y el e-NCF queda quemado: se avisa AQUÍ, no
                // cuando el cliente ya está esperando su factura.
                if (s.needsExpirationDate)
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text(
                      'Falta el vencimiento de la DGII — no se puede emitir',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.red,
                      ),
                    ),
                  )
                else if (s.expirationDate != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Vence ${_formatDate(s.expirationDate!)}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: MangoColors.muted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              s.nextNcfFormatted,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: remaining < 100
                    ? Colors.red.withOpacity(0.1)
                    : Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$remaining',
                style: TextStyle(
                  color: remaining < 100 ? Colors.red : Colors.green,
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          IconButton(
            onPressed: () => _showFormDialog(editing: s),
            icon: const Icon(
              Icons.edit_rounded,
              color: MangoColors.primaryOrange,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _getTipoNombre(String tipo) {
    final map = {
      '01': 'Factura de Crédito Fiscal',
      '02': 'Factura de Consumo',
      '03': 'Nota de Débito',
      '04': 'Nota de Crédito',
      '14': 'Regímenes Especiales',
      '15': 'Gubernamental',
      '16': 'Exportación',
      '31': 'e-Crédito Fiscal',
      '32': 'e-Consumo',
      '33': 'e-Nota de Débito',
      '34': 'e-Nota de Crédito',
      '44': 'e-Regímenes Especiales',
      '45': 'e-Gubernamental',
    };
    return map[tipo] ?? 'Tipo $tipo';
  }

  Future<void> _showFormDialog({FiscalNcfSequence? editing}) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          _FiscalFormDialog(businessId: widget.businessId, editing: editing),
    );
    if (ok == true) {
      ref.read(fiscalVmProvider.notifier).load(widget.businessId);
    }
  }
}

class _FiscalFormDialog extends ConsumerStatefulWidget {
  final String businessId;
  final FiscalNcfSequence? editing;
  const _FiscalFormDialog({required this.businessId, this.editing});

  @override
  ConsumerState<_FiscalFormDialog> createState() => _FiscalFormDialogState();
}

class _FiscalFormDialogState extends ConsumerState<_FiscalFormDialog> {
  late String selectedSerie;
  late String selectedTipo;
  final _ultimoController = TextEditingController();
  final _maximoController = TextEditingController();
  bool _activo = true;
  DateTime? _expiration;
  String? _formError;

  /// e-CF distinto de E32: la DGII exige la fecha de vencimiento de la
  /// secuencia en el comprobante y la valida contra la autorización del rango.
  bool get _expirationRequired => selectedSerie == 'E' && selectedTipo != '32';

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e != null) {
      selectedSerie = e.serie;
      selectedTipo = e.tipo;
      _ultimoController.text = e.ultimoSeq.toString();
      _maximoController.text = e.maximoSeq.toString();
      _activo = e.activo;
      _expiration = e.expirationDate;
    } else {
      selectedSerie = 'B';
      selectedTipo = '01';
      _ultimoController.text = '0';
      _maximoController.text = '1000';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.editing != null;

    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isEdit ? 'Editar Secuencia' : 'Nueva Secuencia',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: MangoColors.darkGray,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Divider(height: 32),
            Row(
              children: [
                Expanded(
                  child: _buildLabelField(
                    'Serie',
                    DropdownButtonFormField<String>(
                      initialValue: selectedSerie,
                      decoration: _inputDeco(),
                      items: ['B', 'E']
                          .map(
                            (s) => DropdownMenuItem(
                              value: s,
                              child: Text(s == 'B' ? 'B (Legacy)' : 'E (e-CF)'),
                            ),
                          )
                          .toList(),
                      onChanged: isEdit
                          ? null
                          : (v) => setState(() {
                              selectedSerie = v!;
                              selectedTipo = selectedSerie == 'B' ? '01' : '31';
                            }),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildLabelField(
                    'Tipo',
                    DropdownButtonFormField<String>(
                      initialValue: selectedTipo,
                      decoration: _inputDeco(),
                      items:
                          (selectedSerie == 'B'
                                  ? {
                                      '01': '01 - Crédito Fiscal',
                                      '02': '02 - Consumo',
                                      // La nota de crédito es la que anula una
                                      // factura de papel ya entregada.
                                      '04': '04 - Nota de Crédito',
                                      '14': '14 - Reg. Especial',
                                      '15': '15 - Gubernamental',
                                      '16': '16 - Exportación',
                                    }
                                  : {
                                      '31': '31 - e-Crédito Fiscal',
                                      '32': '32 - e-Consumo',
                                      '33': '33 - e-Nota Débito',
                                      '34': '34 - e-Nota Crédito',
                                      '44': '44 - e-Reg. Especial',
                                      '45': '45 - e-Gubernamental',
                                    })
                              .entries
                              .map(
                                (e) => DropdownMenuItem(
                                  value: e.key,
                                  child: Text(e.value),
                                ),
                              )
                              .toList(),
                      onChanged: isEdit
                          ? null
                          : (v) => setState(() => selectedTipo = v!),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _buildLabelField(
                    'Último Secuencial',
                    TextField(
                      controller: _ultimoController,
                      keyboardType: TextInputType.number,
                      decoration: _inputDeco(hint: 'Ej: 0'),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildLabelField(
                    'Máximo Autorizado',
                    TextField(
                      controller: _maximoController,
                      keyboardType: TextInputType.number,
                      decoration: _inputDeco(hint: 'Ej: 1000'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildLabelField(
              _expirationRequired
                  ? 'Vencimiento de la secuencia (DGII) *'
                  : 'Vencimiento de la secuencia (DGII)',
              InkWell(
                onTap: _pickExpiration,
                borderRadius: BorderRadius.circular(12),
                child: InputDecorator(
                  decoration: _inputDeco().copyWith(
                    suffixIcon: _expiration == null
                        ? const Icon(Icons.calendar_today_rounded, size: 18)
                        : IconButton(
                            tooltip: 'Quitar fecha',
                            icon: const Icon(Icons.clear_rounded, size: 18),
                            onPressed: () => setState(() => _expiration = null),
                          ),
                    helperText: _expirationRequired
                        ? 'Tal como aparece en la autorización de la DGII. Sin '
                              'ella la DGII rechaza el e-CF (código 145).'
                        : 'Opcional. Déjala vacía si la autorización dice N/A.',
                    helperMaxLines: 3,
                  ),
                  child: Text(
                    _expiration == null
                        ? 'Sin fecha'
                        : '${_expiration!.day.toString().padLeft(2, '0')}/'
                              '${_expiration!.month.toString().padLeft(2, '0')}/'
                              '${_expiration!.year}',
                    style: TextStyle(
                      color: _expiration == null
                          ? MangoColors.muted
                          : MangoColors.darkGray,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            if (_formError != null) ...[
              const SizedBox(height: 12),
              Text(
                _formError!,
                style: const TextStyle(
                  color: Colors.red,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Estado de la secuencia',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: MangoColors.darkGray,
                  ),
                ),
                Switch(
                  value: _activo,
                  onChanged: (v) => setState(() => _activo = v),
                  activeThumbColor: MangoColors.primaryOrange,
                ),
              ],
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: const BorderSide(color: MangoColors.cardBorder),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      'Cancelar',
                      style: TextStyle(
                        color: MangoColors.darkGray,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: MangoColors.primaryOrange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _save,
                    child: Text(
                      isEdit ? 'Actualizar' : 'Crear Secuencia',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLabelField(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: MangoColors.muted,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  InputDecoration _inputDeco({String? hint}) {
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: MangoColors.sidebarBg.withOpacity(0.3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: MangoColors.cardBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: MangoColors.cardBorder),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: MangoColors.cardBorder.withOpacity(0.5)),
      ),
    );
  }

  Future<void> _pickExpiration() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiration ?? DateTime(now.year, 12, 31),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
      helpText: 'Vencimiento de la secuencia',
    );
    if (picked != null) setState(() => _expiration = picked);
  }

  Future<void> _save() async {
    final ultimo = int.tryParse(_ultimoController.text) ?? 0;
    final maximo = int.tryParse(_maximoController.text) ?? 1000;

    // Guardar un e-CF sin vencimiento es guardar una secuencia que no puede
    // emitir: la DGII la rechaza con el código 145.
    if (_expirationRequired && _expiration == null) {
      setState(() {
        _formError =
            'Los e-CF $selectedSerie$selectedTipo necesitan la fecha de '
            'vencimiento de la autorización de la DGII.';
      });
      return;
    }

    if (widget.editing != null) {
      await ref.read(fiscalVmProvider.notifier).saveSequence(
        widget.editing!.id!,
        {
          'current_number': ultimo,
          'range_end': maximo,
          'is_active': _activo,
          'expiration_date': _expiration?.toIso8601String().substring(0, 10),
        },
      );
    } else {
      await ref
          .read(fiscalVmProvider.notifier)
          .addSequence(
            widget.businessId,
            tipo: selectedTipo,
            serie: selectedSerie,
            ultimoSeq: ultimo,
            maximoSeq: maximo,
            expirationDate: _expiration,
          );
    }
    if (!mounted) return;
    Navigator.pop(context, true);
  }
}
