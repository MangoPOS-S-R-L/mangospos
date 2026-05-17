// lib/presentation/settings/business_profile/business_profile_screen.dart
//
// Pantalla "Datos del Negocio": edicion del perfil de la sucursal
// (nombre, RNC, direccion, telefono, email, eslogan, mensaje al pie),
// upload/delete de logo, y toggles de personalizacion del ticket
// (logo en factura, mostrar eslogan, mostrar nombre de sucursal).
//
// Source of truth para los headers/footers de la representacion impresa.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_colors.dart';
import '../../../core/business/business_resolver.dart';
import '../../../data/models/business_profile.dart';
import '../../../data/repositories/business_profile_repository.dart';

class BusinessProfileScreen extends ConsumerStatefulWidget {
  final String businessId;
  const BusinessProfileScreen({super.key, required this.businessId});

  @override
  ConsumerState<BusinessProfileScreen> createState() =>
      _BusinessProfileScreenState();
}

class _BusinessProfileScreenState extends ConsumerState<BusinessProfileScreen> {
  late final BusinessProfileRepository _repo;
  final _formKey = GlobalKey<FormState>();

  // Controllers
  final _businessNameCtrl = TextEditingController();
  final _branchNameCtrl = TextEditingController();
  final _fiscalNameCtrl = TextEditingController();
  final _fiscalRncCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _sloganCtrl = TextEditingController();
  final _footerCtrl = TextEditingController();

  // State
  BusinessProfile? _profile;
  // UUID real del business resuelto desde widget.businessId (que puede
  // venir como 'auto'). Necesario porque .eq('id', ...) requiere UUID
  // válido en Postgres y los uploads/policies usan business_id como
  // primer carpeta del path en Storage.
  String? _resolvedBusinessId;
  bool _loading = true;
  bool _saving = false;
  bool _uploadingLogo = false;
  String? _error;

  // Listas customizables del header y footer del ticket (commit 0003).
  // Mantienen orden + on/off por bloque. La UI muestra ReorderableListView
  // y persiste con _save().
  List<TicketBlock> _headerBlocks = List.from(TicketBlocks.defaultHeader);
  List<TicketBlock> _footerBlocks = List.from(TicketBlocks.defaultFooter);

  // Toggle legacy `printLogoOnInvoice` se sigue exponiendo para que el
  // boton "subir logo" pueda mostrar disabled hasta que el usuario active
  // el bloque "logo" en el header. Cuando deprecemos los toggles viejos
  // se reemplaza por chequear _headerBlocks.firstWhere(key=='logo').enabled.
  bool _printLogoOnInvoice = false;

  @override
  void initState() {
    super.initState();
    _repo = BusinessProfileRepository(Supabase.instance.client);
    _loadProfile();
  }

  @override
  void dispose() {
    _businessNameCtrl.dispose();
    _branchNameCtrl.dispose();
    _fiscalNameCtrl.dispose();
    _fiscalRncCtrl.dispose();
    _addressCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _sloganCtrl.dispose();
    _footerCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 'auto' viene del router. Resolvemos al UUID del business activo
      // (cache via BusinessResolver, fallback a SharedPreferences/DB).
      final resolved = await BusinessResolver.ensure(widget.businessId);
      _resolvedBusinessId = resolved;

      final profile = await _repo.getProfile(resolved);
      if (profile == null) {
        setState(() {
          _error = 'No se encontró el negocio.';
          _loading = false;
        });
        return;
      }
      _populateFromProfile(profile);
      setState(() {
        _profile = profile;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error cargando perfil: $e';
        _loading = false;
      });
    }
  }

  void _populateFromProfile(BusinessProfile p) {
    _businessNameCtrl.text = p.businessName ?? '';
    _branchNameCtrl.text = p.branchName ?? '';
    _fiscalNameCtrl.text = p.fiscalName ?? '';
    _fiscalRncCtrl.text = p.fiscalRnc ?? '';
    _addressCtrl.text = p.address ?? '';
    _phoneCtrl.text = p.phone ?? '';
    _emailCtrl.text = p.email ?? '';
    _sloganCtrl.text = p.slogan ?? '';
    _footerCtrl.text = p.ticketFooterMessage ?? '';
    // Listas reorderables. effectiveHeader/Footer ya cae a defaults
    // canonicos si la columna esta vacia (negocios viejos pre-0003).
    _headerBlocks = List.from(p.effectiveHeaderBlocks);
    _footerBlocks = List.from(p.effectiveFooterBlocks);
    // El "Logo" del header gobierna la habilitacion del boton subir logo.
    _printLogoOnInvoice = _headerBlocks
        .firstWhere(
          (b) => b.key == 'logo',
          orElse: () => const TicketBlock(key: 'logo', enabled: false),
        )
        .enabled;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final bid = _resolvedBusinessId;
    if (bid == null) return;
    setState(() => _saving = true);
    try {
      // Sync el toggle legacy `printLogoOnInvoice` con el bloque "logo"
      // del header — mientras los toggles viejos no se borran de DB
      // mantenemos coherencia. PrintTicketService ya solo lee las listas.
      final headerWithLogoSync = _headerBlocks
          .map(
            (b) => b.key == 'logo'
                ? b.copyWith(enabled: _printLogoOnInvoice)
                : b,
          )
          .toList();
      await _repo.updateProfile(
        businessId: bid,
        businessName: _businessNameCtrl.text,
        branchName: _branchNameCtrl.text,
        fiscalName: _fiscalNameCtrl.text,
        fiscalRnc: _fiscalRncCtrl.text,
        address: _addressCtrl.text,
        phone: _phoneCtrl.text,
        email: _emailCtrl.text,
        slogan: _sloganCtrl.text,
        ticketFooterMessage: _footerCtrl.text,
        printLogoOnInvoice: _printLogoOnInvoice,
        headerBlocks: headerWithLogoSync,
        footerBlocks: _footerBlocks,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Datos guardados'),
            backgroundColor: Color(0xFF22C55E),
          ),
        );
      }
      await _loadProfile();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error guardando: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _uploadLogo() async {
    final bid = _resolvedBusinessId;
    if (bid == null) return;
    setState(() => _uploadingLogo = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return; // usuario cancelo
      }
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) {
        throw Exception('No se pudo leer el archivo.');
      }
      // 2MB limit (mismo que el bucket).
      if (bytes.length > 2 * 1024 * 1024) {
        throw Exception('El archivo supera 2MB.');
      }
      final ext = (file.extension ?? 'png').toLowerCase();
      await _repo.uploadLogo(
        businessId: bid,
        bytes: bytes,
        extension: ext,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Logo actualizado'),
            backgroundColor: Color(0xFF22C55E),
          ),
        );
      }
      await _loadProfile();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error subiendo logo: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingLogo = false);
    }
  }

  Future<void> _deleteLogo() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar logo'),
        content: const Text(
          '¿Querés eliminar el logo? Las facturas dejarán de imprimirlo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final bid = _resolvedBusinessId;
    if (bid == null) return;
    setState(() => _uploadingLogo = true);
    try {
      await _repo.deleteLogo(bid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Logo eliminado')),
        );
      }
      await _loadProfile();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error eliminando logo: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingLogo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MangoColors.sidebarBg,
      appBar: AppBar(
        title: const Text('Datos del Negocio'),
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: .4,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Regresar',
          onPressed: () => Navigator.of(context).canPop()
              ? Navigator.of(context).pop()
              : context.go(AppRoutes.settings),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: MangoColors.primaryOrange),
            )
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : _buildForm(context),
      bottomNavigationBar: _loading || _error != null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: MangoColors.primaryOrange,
                    foregroundColor: MangoColors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save_rounded),
                  label: Text(_saving ? 'Guardando…' : 'Guardar cambios'),
                ),
              ),
            ),
    );
  }

  Widget _buildForm(BuildContext context) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _sectionCard(
            title: 'Identidad del negocio',
            children: [
              _textField(
                controller: _businessNameCtrl,
                label: 'Nombre comercial',
                hint: 'Ej: Restaurante La Esquina',
              ),
              const SizedBox(height: 12),
              _textField(
                controller: _branchNameCtrl,
                label: 'Nombre de la sucursal',
                hint: 'Ej: Sucursal Centro',
              ),
              const SizedBox(height: 12),
              _textField(
                controller: _addressCtrl,
                label: 'Dirección',
                hint: 'Calle, número, sector, ciudad',
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _textField(
                      controller: _phoneCtrl,
                      label: 'Teléfono',
                      hint: '809-555-1234',
                      keyboard: TextInputType.phone,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _textField(
                      controller: _emailCtrl,
                      label: 'Email',
                      hint: 'contacto@negocio.com',
                      keyboard: TextInputType.emailAddress,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          _sectionCard(
            title: 'Datos fiscales',
            children: [
              _textField(
                controller: _fiscalNameCtrl,
                label: 'Razón social',
                hint: 'Como aparece en DGII',
              ),
              const SizedBox(height: 12),
              _textField(
                controller: _fiscalRncCtrl,
                label: 'RNC',
                hint: '130860981',
                keyboard: TextInputType.number,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _logoSectionCard(),
          const SizedBox(height: 16),
          _sectionCard(
            title: 'Textos del ticket',
            children: [
              _textField(
                controller: _sloganCtrl,
                label: 'Eslogan (opcional)',
                hint: 'Ej: La mejor comida de la ciudad',
              ),
              const SizedBox(height: 12),
              _textField(
                controller: _footerCtrl,
                label: 'Mensaje al pie del ticket (opcional)',
                hint: 'Ej: Gracias por su visita',
                maxLines: 2,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _blocksReorderCard(
            title: 'Encabezado del ticket',
            subtitle:
                'Activá los bloques que querés imprimir y arrastralos para reordenar. Aplica a factura y pre-cuenta.',
            blocks: _headerBlocks,
            labelFor: _headerBlockLabel,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex -= 1;
                final item = _headerBlocks.removeAt(oldIndex);
                _headerBlocks.insert(newIndex, item);
              });
            },
            onToggle: (index, value) {
              setState(() {
                _headerBlocks[index] =
                    _headerBlocks[index].copyWith(enabled: value);
                // Mantener sync el toggle legacy del logo (gobierna el
                // boton "subir logo" en la seccion de arriba).
                if (_headerBlocks[index].key == 'logo') {
                  _printLogoOnInvoice = value;
                }
              });
            },
          ),
          const SizedBox(height: 16),
          _blocksReorderCard(
            title: 'Pie del ticket',
            subtitle:
                'Bloques al final del ticket. Aplica a factura y pre-cuenta.',
            blocks: _footerBlocks,
            labelFor: _footerBlockLabel,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex -= 1;
                final item = _footerBlocks.removeAt(oldIndex);
                _footerBlocks.insert(newIndex, item);
              });
            },
            onToggle: (index, value) {
              setState(() {
                _footerBlocks[index] =
                    _footerBlocks[index].copyWith(enabled: value);
              });
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  // Labels legibles para cada key de bloque
  // ───────────────────────────────────────────────────────────────────────

  String _headerBlockLabel(String key) {
    switch (key) {
      case 'logo':
        return 'Logo';
      case 'business_name':
        return 'Nombre comercial';
      case 'slogan':
        return 'Eslogan';
      case 'legal_name':
        return 'Razón social';
      case 'branch_name':
        return 'Sucursal';
      case 'address':
        return 'Dirección';
      case 'phone':
        return 'Teléfono';
      case 'email':
        return 'Email';
      case 'rnc':
        return 'RNC';
      default:
        return key;
    }
  }

  String _footerBlockLabel(String key) {
    switch (key) {
      case 'footer_message':
        return 'Mensaje custom (configurado arriba)';
      case 'thank_you':
        return 'Mensaje de despedida';
      default:
        return key;
    }
  }

  Widget _blocksReorderCard({
    required String title,
    required String subtitle,
    required List<TicketBlock> blocks,
    required String Function(String) labelFor,
    required void Function(int oldIndex, int newIndex) onReorder,
    required void Function(int index, bool value) onToggle,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 12),
          // shrinkWrap + buildDefaultDragHandles para que entre dentro del
          // ListView padre sin scroll anidado conflictivo.
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: blocks.length,
            onReorder: onReorder,
            itemBuilder: (context, index) {
              final block = blocks[index];
              return Padding(
                key: ValueKey('block-${block.key}'),
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    ReorderableDragStartListener(
                      index: index,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          Icons.drag_handle,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        labelFor(block.key),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: block.enabled
                              ? MangoColors.darkGray
                              : Colors.grey.shade500,
                        ),
                      ),
                    ),
                    Switch(
                      value: block.enabled,
                      activeThumbColor: MangoColors.successGreen,
                      onChanged: (v) => onToggle(index, v),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _logoSectionCard() {
    final logoUrl = _profile?.logoUrl;
    return _sectionCard(
      title: 'Logo del negocio',
      children: [
        Row(
          children: [
            Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: MangoColors.cardBorder),
              ),
              child: logoUrl != null && logoUrl.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        logoUrl,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image_outlined,
                          color: Colors.grey,
                          size: 40,
                        ),
                      ),
                    )
                  : const Icon(
                      Icons.image_outlined,
                      color: Colors.grey,
                      size: 40,
                    ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    logoUrl == null
                        ? 'Sin logo configurado'
                        : 'Logo activo',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Recomendado: PNG o JPG, max 2 MB. '
                    'Se recomienda alto ≤ 150 px para que entre bien en 80 mm.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: MangoColors.primaryOrange,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: _uploadingLogo ? null : _uploadLogo,
                        icon: _uploadingLogo
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.upload_rounded, size: 18),
                        label: Text(
                          _uploadingLogo
                              ? 'Subiendo…'
                              : (logoUrl == null
                                  ? 'Subir logo'
                                  : 'Cambiar logo'),
                        ),
                      ),
                      if (logoUrl != null)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red),
                          ),
                          onPressed: _uploadingLogo ? null : _deleteLogo,
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Eliminar'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  // Helpers UI
  // ───────────────────────────────────────────────────────────────────────

  Widget _sectionCard({required String title, required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    String? hint,
    int maxLines = 1,
    TextInputType? keyboard,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboard,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: MangoColors.cardBorder),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      validator: validator,
    );
  }

}
