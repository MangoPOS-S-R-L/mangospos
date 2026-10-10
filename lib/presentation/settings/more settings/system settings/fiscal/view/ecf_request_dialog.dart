import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/repositories/ecf_request_repository.dart';

/// Formulario con que el dueño pide la facturación electrónica. Al enviar, el
/// servidor guarda la solicitud y registra la empresa con el proveedor usando
/// el certificado. Devuelve el resultado, o null si se cerró sin enviar.
///
/// Pide los requisitos del alta e-CF: datos de la empresa (RNC, razón social,
/// nombre comercial, dirección fiscal, teléfono, correo, representante legal),
/// sucursales, tipos de comprobantes, acceso a la Oficina Virtual de la DGII y
/// el certificado digital con su contraseña.
Future<EcfRequestResult?> showEcfRequestDialog(
  BuildContext context, {
  required String businessId,
  required EcfRequestStatus status,
}) {
  return showDialog<EcfRequestResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _EcfRequestDialog(businessId: businessId, status: status),
  );
}

class _EcfRequestDialog extends ConsumerStatefulWidget {
  const _EcfRequestDialog({required this.businessId, required this.status});

  final String businessId;
  final EcfRequestStatus status;

  @override
  ConsumerState<_EcfRequestDialog> createState() => _EcfRequestDialogState();
}

class _BranchFields {
  _BranchFields({String? name, String? address})
      : name = TextEditingController(text: name ?? ''),
        address = TextEditingController(text: address ?? '');

  final TextEditingController name;
  final TextEditingController address;

  bool get isEmpty => name.text.trim().isEmpty && address.text.trim().isEmpty;

  void dispose() {
    name.dispose();
    address.dispose();
  }
}

class _EcfRequestDialogState extends ConsumerState<_EcfRequestDialog> {
  late final EcfRequestData _d = widget.status.data;
  late final EcfRequestDetails _x = widget.status.details;
  late final _rnc = TextEditingController(text: _d.rnc ?? '');
  late final _legal = TextEditingController(text: _d.legalName ?? '');
  late final _trade = TextEditingController(text: _d.tradeName ?? '');
  late final _address = TextEditingController(text: _d.fiscalAddress ?? '');
  late final _province = TextEditingController(text: _d.province ?? '');
  late final _municipality = TextEditingController(text: _d.municipality ?? '');
  late final _phone = TextEditingController(text: _x.phone ?? '');
  late final _email = TextEditingController(text: _d.email ?? '');
  late final _legalRep = TextEditingController(text: _x.legalRepName ?? '');
  // El usuario de la Oficina Virtual casi siempre es el RNC o la cédula.
  late final _ofvUser = TextEditingController(text: _x.ofvUser ?? _d.rnc ?? '');
  final _ofvPassword = TextEditingController();
  late final _contactName =
      TextEditingController(text: widget.status.contactName ?? '');
  late final _contactPhone =
      TextEditingController(text: widget.status.contactPhone ?? '');
  final _password = TextEditingController();

  late final List<_BranchFields> _branches = [
    for (final b in _x.branches) _BranchFields(name: b.name, address: b.address),
  ];
  late final Set<String> _types = {..._x.ecfTypes};

  late bool _alreadyAuthorized = widget.status.alreadyAuthorized ?? false;
  bool _accept = false;
  bool _obscure = true;
  bool _obscureOfv = true;
  bool _sending = false;
  String? _certName;
  Uint8List? _certBytes;
  String? _error;

  static const _maxCertBytes = 100 * 1024;
  static final _emailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  @override
  void dispose() {
    for (final c in [
      _rnc, _legal, _trade, _address, _province, _municipality, _phone, _email,
      _legalRep, _ofvUser, _ofvPassword, _contactName, _contactPhone, _password,
    ]) {
      c.dispose();
    }
    for (final b in _branches) {
      b.dispose();
    }
    super.dispose();
  }

  Future<void> _pickCertificate() async {
    try {
      // FileType.any a propósito: filtrar por extensión .p12 falla en algunos
      // Android/iOS que no conocen ese tipo. Se valida después.
      final file = await FilePicker.pickFile(type: FileType.any);
      if (file == null) return;
      final ext = file.name.contains('.') ? file.name.split('.').last.toLowerCase() : '';
      String? error;
      Uint8List? bytes;
      if (ext != 'p12' && ext != 'pfx') {
        error = 'El certificado tiene que ser un archivo .p12 o .pfx.';
      } else if (await file.length() > _maxCertBytes) {
        error = 'Ese archivo es demasiado grande para ser un certificado de firma.';
      } else {
        bytes = await file.readAsBytes();
        if (bytes.isEmpty) error = 'No se pudo leer el archivo. Intenta elegirlo de nuevo.';
      }
      if (!mounted) return;
      setState(() {
        _error = error;
        if (error == null) {
          _certName = file.name;
          _certBytes = bytes;
        }
      });
    } catch (_) {
      setState(() => _error = 'No se pudo abrir el selector de archivos.');
    }
  }

  static int _digits(TextEditingController c) =>
      c.text.replaceAll(RegExp(r'\D'), '').length;

  // Mismo orden que el formulario: el primer error es el primero que se ve.
  String? _validate() {
    final rnc = _digits(_rnc);
    if (rnc != 9 && rnc != 11) {
      return 'El RNC debe tener 9 dígitos (u 11 si es cédula).';
    }
    if (_legal.text.trim().isEmpty) return 'Falta la razón social.';
    if (_address.text.trim().isEmpty) return 'Falta la dirección fiscal.';
    if (_province.text.trim().isEmpty) return 'Falta la provincia.';
    if (_municipality.text.trim().isEmpty) return 'Falta el municipio.';
    if (_digits(_phone) < 10) {
      return 'El teléfono de la empresa debe incluir el código de área.';
    }
    if (!_emailRe.hasMatch(_email.text.trim())) {
      return 'Escribe un correo válido.';
    }
    if (_legalRep.text.trim().isEmpty) {
      return 'Falta el nombre completo del representante legal.';
    }
    for (final b in _branches) {
      if (!b.isEmpty && b.address.text.trim().isEmpty) {
        final name = b.name.text.trim();
        return 'Falta la dirección de la sucursal $name.';
      }
    }
    if (_types.isEmpty) return 'Elige al menos un tipo de comprobante.';
    if (_ofvUser.text.trim().isEmpty) {
      return 'Falta el usuario de la Oficina Virtual de la DGII.';
    }
    if (_ofvPassword.text.trim().isEmpty && !_x.ofvPasswordSaved) {
      return 'Falta la clave de la Oficina Virtual de la DGII.';
    }
    if (_certBytes == null) return 'Falta tu certificado digital (.p12 o .pfx).';
    if (_password.text.isEmpty) return 'Falta la contraseña del certificado.';
    if (_contactName.text.trim().isEmpty) return 'Falta la persona de contacto.';
    if (_digits(_contactPhone) < 10) {
      return 'El teléfono de contacto debe incluir el código de área.';
    }
    if (!_accept) return 'Debes autorizar a MangoPOS para continuar.';
    return null;
  }

  Future<void> _submit() async {
    final error = _validate();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    String? clean(TextEditingController c) {
      final t = c.text.trim();
      return t.isEmpty ? null : t;
    }

    try {
      final result = await ref.read(ecfRequestRepositoryProvider).submit(
            widget.businessId,
            EcfRequestSubmission(
              data: EcfRequestData(
                rnc: _rnc.text.replaceAll(RegExp(r'\D'), ''),
                legalName: clean(_legal),
                tradeName: clean(_trade),
                fiscalAddress: clean(_address),
                province: clean(_province),
                municipality: clean(_municipality),
                email: clean(_email),
              ),
              details: EcfRequestDetails(
                phone: clean(_phone),
                legalRepName: clean(_legalRep),
                branches: [
                  for (final b in _branches)
                    if (!b.isEmpty)
                      EcfBranch(name: clean(b.name), address: b.address.text.trim()),
                ],
                ecfTypes: [
                  for (final t in ecfTypeCatalog.keys)
                    if (_types.contains(t)) t,
                ],
                ofvUser: clean(_ofvUser),
              ),
              // Vacía con una ya guardada: el servidor conserva la anterior.
              ofvPassword: _ofvPassword.text.trim().isEmpty ? null : _ofvPassword.text,
              contactName: _contactName.text.trim(),
              contactPhone: _contactPhone.text.trim(),
              alreadyAuthorized: _alreadyAuthorized,
              certificateFilename: _certName!,
              certificateBytes: _certBytes!,
              certificatePassword: _password.text,
            ),
          );
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e is EcfRequestException
            ? e.message
            : 'No se pudo enviar la solicitud. Revisa tu conexión e intenta de nuevo.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      title: const Text('Solicitar facturación electrónica'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Hint(
                'Escribe los datos tal como aparecen en la DGII. MangoPOS registra tu '
                'empresa con su proveedor de facturación electrónica y te acompaña '
                'en la certificación.',
              ),
              const SizedBox(height: 16),
              const _Group('Datos de tu empresa'),
              _field(_rnc, 'RNC o cédula', keyboard: TextInputType.number),
              _field(_legal, 'Razón social'),
              _field(_trade, 'Nombre comercial (si tiene)'),
              _field(_address, 'Dirección fiscal completa (la registrada en la DGII)', maxLength: 100),
              Row(
                children: [
                  Expanded(child: _field(_province, 'Provincia')),
                  const SizedBox(width: 12),
                  Expanded(child: _field(_municipality, 'Municipio')),
                ],
              ),
              Row(
                children: [
                  Expanded(child: _field(_phone, 'Teléfono', keyboard: TextInputType.phone)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(_email, 'Correo electrónico', keyboard: TextInputType.emailAddress),
                  ),
                ],
              ),
              _field(_legalRep, 'Nombre completo del representante legal'),
              const SizedBox(height: 8),
              const _Group('Sucursales (si aplica)'),
              const _Note('Si tienes más de un local, agrega cada uno con su dirección.'),
              const SizedBox(height: 6),
              for (var i = 0; i < _branches.length; i++) _branchRow(i),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _sending ? null : () => setState(() => _branches.add(_BranchFields())),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Agregar sucursal'),
                ),
              ),
              const SizedBox(height: 8),
              const _Group('Comprobantes que utilizas'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in ecfTypeCatalog.entries)
                    FilterChip(
                      label: Text('${e.key} · ${e.value}'),
                      selected: _types.contains(e.key),
                      selectedColor: MangoColors.primaryOrange.withValues(alpha: 0.15),
                      checkmarkColor: MangoColors.primaryOrange,
                      onSelected: _sending
                          ? null
                          : (v) => setState(() => v ? _types.add(e.key) : _types.remove(e.key)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              const _Note('La nota de crédito (E34) la usa MangoPOS para anular facturas.'),
              const SizedBox(height: 16),
              const _Group('Oficina Virtual de la DGII'),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _field(_ofvUser, 'Usuario')),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _secretField(
                      _ofvPassword,
                      _x.ofvPasswordSaved ? 'Clave (ya guardada)' : 'Clave',
                      obscure: _obscureOfv,
                      onToggle: () => setState(() => _obscureOfv = !_obscureOfv),
                    ),
                  ),
                ],
              ),
              _Note(
                '${_x.ofvPasswordSaved ? 'Déjala vacía para conservar la que ya enviaste. ' : ''}'
                'MangoPOS la guarda cifrada y solo la usa para tu postulación y las '
                'pruebas de certificación en la Oficina Virtual.',
              ),
              const SizedBox(height: 16),
              const _Group('Certificado digital'),
              OutlinedButton.icon(
                onPressed: _sending ? null : _pickCertificate,
                icon: const Icon(Icons.upload_file, size: 18),
                label: Text(_certName ?? 'Elegir certificado (.p12 o .pfx)'),
              ),
              const SizedBox(height: 8),
              _secretField(
                _password,
                'Contraseña del certificado',
                obscure: _obscure,
                onToggle: () => setState(() => _obscure = !_obscure),
              ),
              const _Note(
                'Emitido por una entidad autorizada por INDOTEL, a nombre de tu empresa '
                'o de su representante legal. MangoPOS no guarda el certificado ni su '
                'contraseña: van directo al proveedor de facturación electrónica.',
              ),
              const SizedBox(height: 16),
              const _Group('Persona de contacto'),
              Row(
                children: [
                  Expanded(child: _field(_contactName, 'Nombre')),
                  const SizedBox(width: 12),
                  Expanded(child: _field(_contactPhone, 'Teléfono', keyboard: TextInputType.phone)),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _alreadyAuthorized,
                onChanged: _sending ? null : (v) => setState(() => _alreadyAuthorized = v),
                title: const Text(
                  'Ya soy emisor electrónico autorizado por la DGII',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Si no lo eres, MangoPOS te guía en la certificación.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _accept,
                onChanged: _sending ? null : (v) => setState(() => _accept = v ?? false),
                activeColor: MangoColors.primaryOrange,
                title: const Text(
                  'Autorizo a MangoPOS a registrar mi empresa con su proveedor de '
                  'facturación electrónica usando este certificado, y a entrar a mi '
                  'Oficina Virtual de la DGII para la certificación.',
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.25)),
                  ),
                  child: Text(_error!, style: const TextStyle(fontSize: 12.5, color: Colors.red)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: MangoColors.primaryOrange,
            foregroundColor: Colors.white,
          ),
          onPressed: _sending ? null : _submit,
          child: _sending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Enviar solicitud'),
        ),
      ],
    );
  }

  void _removeBranch(_BranchFields b) {
    setState(() => _branches.remove(b));
    // Sus TextField siguen montados hasta el próximo frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => b.dispose());
  }

  Widget _branchRow(int i) {
    final b = _branches[i];
    return Row(
      key: ObjectKey(b),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 2, child: _field(b.name, 'Nombre')),
        const SizedBox(width: 12),
        Expanded(flex: 3, child: _field(b.address, 'Dirección', maxLength: 150)),
        IconButton(
          tooltip: 'Quitar sucursal',
          onPressed: _sending ? null : () => _removeBranch(b),
          icon: const Icon(Icons.close, size: 18),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    TextInputType? keyboard,
    int? maxLength,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        enabled: !_sending,
        keyboardType: keyboard,
        maxLength: maxLength,
        inputFormatters: keyboard == TextInputType.number
            ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9-]'))]
            : null,
        decoration: InputDecoration(labelText: label, counterText: ''),
      ),
    );
  }

  Widget _secretField(
    TextEditingController c,
    String label, {
    required bool obscure,
    required VoidCallback onToggle,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        obscureText: obscure,
        enabled: !_sending,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: IconButton(
            onPressed: onToggle,
            icon: Icon(obscure ? Icons.visibility : Icons.visibility_off, size: 18),
          ),
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(fontSize: 11.5, color: MangoColors.muted),
      );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: MangoColors.bgLight,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.35)),
      );
}
