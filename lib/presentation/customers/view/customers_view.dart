import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/presentation/customers/viewmodel/customers_viewmodel.dart';
import 'package:mangopos/services/dgii_lookup_service.dart';
import 'package:mangopos/services/session/session_controller.dart';

class CustomersView extends ConsumerStatefulWidget {
  const CustomersView({super.key});

  @override
  ConsumerState<CustomersView> createState() => _CustomersViewState();
}

class _CustomersViewState extends ConsumerState<CustomersView> {
  final TextEditingController _searchController = TextEditingController();
  String? _lastBusinessId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(customersViewModelProvider).init();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearch(String val) {
    ref.read(customersViewModelProvider).search(val);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final vm = ref.watch(customersViewModelProvider);
    final customers = vm.customers;
    final isLoading = vm.isLoading;

    if (session.activeBusinessId != null &&
        session.activeBusinessId != _lastBusinessId) {
      _lastBusinessId = session.activeBusinessId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _searchController.clear();
          ref.read(customersViewModelProvider).init();
        }
      });
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            const Text(
              'Clientes',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),

            // Toolbar
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: _onSearch,
                    decoration: InputDecoration(
                      hintText:
                          'Buscar por nombre, correo o número de teléfono',
                      prefixIcon: const Icon(Icons.search, color: AppColors.mutedForeground),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 0,
                        horizontal: AppSpacing.lg,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.file_upload_outlined, size: 18),
                  label: const Text('Importar'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.foreground,
                    side: const BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.lg,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('Exportar'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.foreground,
                    side: const BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.lg,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                ElevatedButton(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => const _CustomerFormDialog(),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl,
                      vertical: AppSpacing.lg,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.button),
                    ),
                  ),
                  child: const Text(
                    'Agregar Cliente',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xxl),

            // Table Header
            Container(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md, horizontal: AppSpacing.lg),
              decoration: BoxDecoration(
                color: AppColors.secondary,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: const Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(
                      'NOMBRE DEL CLIENTE',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      'CORREO ELECTRÓNICO',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      'TELÉFONO',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      'TOTAL DE PEDIDOS',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      'ACCIÓN',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: AppColors.mutedForeground,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),

            // Table Body
            Expanded(
              child: isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
                  : customers.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.people_outline,
                              size: 48,
                              color: AppColors.mutedForeground.withValues(alpha: 0.5)),
                          const SizedBox(height: AppSpacing.md),
                          const Text(
                            'No hay clientes',
                            style: TextStyle(
                              color: AppColors.mutedForeground,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: customers.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1, color: AppColors.border),
                      itemBuilder: (context, index) {
                        final customer = customers[index];
                        final name = customer['name'] ?? 'Sin Nombre';
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.md,
                            horizontal: AppSpacing.lg,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: Text(
                                  name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.foreground,
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: 3,
                                child: Text(
                                  customer['email'] ?? '--',
                                  style: const TextStyle(color: AppColors.mutedForeground),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  customer['phone'] ?? '--',
                                  style: const TextStyle(color: AppColors.mutedForeground),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Row(
                                  children: [
                                    InkWell(
                                      onTap: () {
                                        // Can implement navigation to detail
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: AppSpacing.sm,
                                          vertical: AppSpacing.xs,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.accent,
                                          borderRadius: BorderRadius.circular(
                                            AppRadius.sm,
                                          ),
                                          border: Border.all(
                                            color: AppColors.border,
                                          ),
                                        ),
                                        child: const Text(
                                          '0 PEDIDOS',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.mutedForeground,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: () {
                                        showDialog(
                                          context: context,
                                          builder: (_) => _CustomerFormDialog(
                                            customer: customer,
                                          ),
                                        );
                                      },
                                      icon: const Icon(
                                        Icons.edit_outlined,
                                        size: 14,
                                      ),
                                      label: const Text('Actualizar'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: AppColors.foreground,
                                        side: const BorderSide(
                                          color: AppColors.border,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: AppSpacing.md,
                                          vertical: AppSpacing.sm,
                                        ),
                                        textStyle: const TextStyle(
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: AppSpacing.sm),
                                    InkWell(
                                      onTap: () async {
                                        final ok = await _confirmDelete(
                                          context,
                                          customer['name']?.toString() ??
                                              'este cliente',
                                        );
                                        if (ok != true) return;
                                        if (!context.mounted) return;
                                        try {
                                          await ref
                                              .read(customersViewModelProvider)
                                              .deleteCustomer(customer['id']);
                                          if (!context.mounted) return;
                                          AppToast.success(
                                            context,
                                            'Cliente eliminado',
                                          );
                                        } catch (e) {
                                          if (!context.mounted) return;
                                          AppToast.error(context, 'Error: $e');
                                        }
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.all(AppSpacing.sm),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: AppColors.destructive.withValues(alpha:0.5),
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            AppRadius.sm,
                                          ),
                                          color: AppColors.destructive.withValues(alpha:0.05),
                                        ),
                                        child: const Icon(
                                          Icons.delete_outline,
                                          size: 16,
                                          color: AppColors.destructive,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Confirma con el usuario antes de borrar un cliente. Devuelve `true`
/// si confirmó. Se mantiene fuera del state class para poder llamarse
/// desde el itemBuilder de la lista sin acoplar al viewmodel del row.
Future<bool?> _confirmDelete(BuildContext context, String name) {
  return showDialog<bool>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: const Text('Eliminar cliente'),
      content: Text(
        '¿Seguro que quieres eliminar a "$name"? Esta acción no se puede deshacer.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.destructive,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: const Text('Eliminar'),
        ),
      ],
    ),
  );
}

/// Form unificado para crear y editar cliente. Si `customer` es null va
/// en modo crear; si trae un mapa, modo editar (prefilea los campos y
/// llama updateCustomer en submit).
///
/// Incluye campo RNC con botón "Buscar en DGII" que consulta el registro
/// oficial vía [DgiiLookupService] y autocompleta el nombre / razón social.
class _CustomerFormDialog extends ConsumerStatefulWidget {
  const _CustomerFormDialog({this.customer});

  final Map<String, dynamic>? customer;

  @override
  ConsumerState<_CustomerFormDialog> createState() =>
      _CustomerFormDialogState();
}

class _CustomerFormDialogState extends ConsumerState<_CustomerFormDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _legalNameController;
  late final TextEditingController _emailController;
  late final TextEditingController _phoneController;
  late final TextEditingController _addressController;
  late final TextEditingController _rncController;

  bool _isLookingUpDgii = false;
  bool _isSaving = false;
  String? _dgiiNote; // mensaje informativo bajo el RNC (estado, errores)

  // Indicadores adicionales del padrón DGII tras un lookup. Solo se
  // muestran (no se guardan) — DGII puede cambiar el estado del
  // contribuyente, así que mantener una copia stale en DB confunde más
  // que ayuda. Re-query si el cajero quiere data fresca.
  String? _dgiiEstado;
  String? _dgiiActividad;
  bool? _dgiiFacturador;

  bool get _isEdit => widget.customer != null;

  @override
  void initState() {
    super.initState();
    final c = widget.customer;
    _nameController = TextEditingController(
      text: c?['name']?.toString() ?? '',
    );
    _legalNameController = TextEditingController(
      text: c?['legal_name']?.toString() ?? '',
    );
    _emailController = TextEditingController(
      text: c?['email']?.toString() ?? '',
    );
    _phoneController = TextEditingController(
      text: c?['phone']?.toString() ?? '',
    );
    _addressController = TextEditingController(
      text: c?['address']?.toString() ?? '',
    );
    _rncController = TextEditingController(
      text: c?['tax_id']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _legalNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _rncController.dispose();
    super.dispose();
  }

  Future<void> _lookupDgii() async {
    final raw = _rncController.text.trim();
    if (raw.isEmpty) {
      setState(() => _dgiiNote = 'Escribe el RNC primero.');
      return;
    }
    setState(() {
      _isLookingUpDgii = true;
      _dgiiNote = null;
      _dgiiEstado = null;
      _dgiiActividad = null;
      _dgiiFacturador = null;
    });
    try {
      final info = await DgiiLookupService().lookupByRnc(raw);
      if (!mounted) return;
      if (info == null) {
        setState(() {
          _dgiiNote = 'RNC no encontrado en el registro de DGII.';
        });
        return;
      }
      // Autocompletar nombre comercial (campo `name`) solo si está vacío
      // o estamos creando. En edit no pisamos sin permiso del usuario
      // (puede tener un alias custom).
      final fillName = info.displayName;
      if (fillName != null && fillName.isNotEmpty) {
        if (!_isEdit || _nameController.text.trim().isEmpty) {
          _nameController.text = fillName;
        }
      }
      // Razón social (legal_name): la sobreescribimos siempre que venga
      // del padrón DGII. Es data oficial que cambia poco, y el cajero
      // típicamente no la modifica manual. Si quieren un legal_name
      // custom pueden editarlo después.
      final legal = info.nombreRazonSocial;
      if (legal != null && legal.isNotEmpty) {
        _legalNameController.text = legal;
      }

      setState(() {
        _dgiiNote = null; // se reemplaza por badges + texto detallado abajo
        _dgiiEstado = info.estado;
        _dgiiActividad = info.actividadEconomica;
        _dgiiFacturador = info.esFacturadorElectronico;
      });
    } on InvalidRncException catch (e) {
      if (!mounted) return;
      setState(() => _dgiiNote = e.toString());
    } catch (e) {
      if (!mounted) return;
      setState(() => _dgiiNote = 'Error consultando DGII: $e');
    } finally {
      if (mounted) {
        setState(() => _isLookingUpDgii = false);
      }
    }
  }

  /// Renderiza badges informativos con los datos no-persistidos del
  /// padrón DGII. Solo aparece tras un lookup exitoso. Si no hay nada
  /// que mostrar (todos los _dgii* son null), devuelve SizedBox vacío.
  Widget _buildDgiiBadges() {
    final estado = _dgiiEstado;
    final actividad = _dgiiActividad;
    final facturador = _dgiiFacturador;
    if (estado == null && actividad == null && facturador == null) {
      return const SizedBox.shrink();
    }
    final children = <Widget>[];
    if (estado != null) {
      final isActivo = estado.trim().toUpperCase() == 'ACTIVO';
      children.add(_dgiiBadge(
        label: estado,
        color: isActivo ? const Color(0xFF22C55E) : AppColors.destructive,
      ));
    }
    if (facturador == true) {
      children.add(_dgiiBadge(
        label: 'Facturador Electrónico',
        color: const Color(0xFF3B82F6),
      ));
    }
    if (actividad != null) {
      children.add(_dgiiBadge(
        label: actividad,
        color: AppColors.mutedForeground,
      ));
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Wrap(spacing: 6, runSpacing: 6, children: children),
    );
  }

  Widget _dgiiBadge({required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      AppToast.info(context, 'El nombre es obligatorio.');
      return;
    }

    final data = <String, dynamic>{
      'name': name,
      'legal_name': _legalNameController.text.trim(),
      'email': _emailController.text.trim(),
      'phone': _phoneController.text.trim(),
      'address': _addressController.text.trim(),
      // Guardamos solo dígitos para evitar duplicados por separadores.
      'tax_id': _rncController.text.replaceAll(RegExp(r'[^0-9]'), ''),
    };
    // Sanea: campos vacíos van como null para no ensuciar la DB con
    // strings vacíos.
    data.updateAll((k, v) => (v is String && v.isEmpty) ? null : v);

    setState(() => _isSaving = true);
    try {
      final vm = ref.read(customersViewModelProvider);
      if (_isEdit) {
        await vm.updateCustomer(widget.customer!['id'] as String, data);
      } else {
        await vm.addCustomer(data);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        AppToast.error(
          context,
          _isEdit
              ? 'Error al actualizar cliente: $e'
              : 'Error al crear cliente: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isEdit ? 'Editar Cliente' : 'Agregar Cliente',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),

              // ─── RNC + lookup DGII ────────────────────────────────
              const Text(
                'RNC / Cédula',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _rncController,
                      keyboardType: TextInputType.number,
                      decoration: _inputDecoration(
                        '000000000 (9) o 00000000000 (11)',
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: _isLookingUpDgii ? null : _lookupDgii,
                      icon: _isLookingUpDgii
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.search, size: 16),
                      label: const Text('Buscar en DGII'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppRadius.button,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (_dgiiNote != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _dgiiNote!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
              _buildDgiiBadges(),

              const SizedBox(height: AppSpacing.lg),
              _buildField(
                'Nombre Comercial',
                'Ej. Banco Popular (cómo lo conoce el cliente)',
                _nameController,
              ),
              const SizedBox(height: AppSpacing.lg),
              _buildField(
                'Razón Social',
                'Ej. Banco Popular Dominicano S.A. — usado en facturación',
                _legalNameController,
              ),
              const SizedBox(height: AppSpacing.lg),
              _buildField(
                'Correo Electrónico',
                'Agregar Correo del Cliente',
                _emailController,
              ),
              const SizedBox(height: AppSpacing.lg),
              _buildField(
                'Teléfono',
                'Agregar Teléfono del Cliente',
                _phoneController,
              ),
              const SizedBox(height: AppSpacing.lg),
              _buildField(
                'Dirección',
                'Agregar Dirección del Cliente',
                _addressController,
              ),
              const SizedBox(height: AppSpacing.xxxl),
              Row(
                children: [
                  ElevatedButton(
                    onPressed: _isSaving ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xxl,
                        vertical: AppSpacing.lg,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                      ),
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            _isEdit ? 'Guardar cambios' : 'Guardar',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  OutlinedButton(
                    onPressed: _isSaving ? null : () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.foreground,
                      side: const BorderSide(color: AppColors.border),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xxl,
                        vertical: AppSpacing.lg,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                      ),
                    ),
                    child: const Text('Cancelar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(
    String label,
    String placeholder,
    TextEditingController controller,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: controller,
          decoration: _inputDecoration(placeholder),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.mutedForeground),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        borderSide: const BorderSide(color: AppColors.primary, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: 14,
      ),
    );
  }
}
