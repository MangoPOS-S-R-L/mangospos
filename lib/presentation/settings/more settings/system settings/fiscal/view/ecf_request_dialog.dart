import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/repositories/ecf_request_repository.dart';

/// Formulario con que el dueño pide la facturación electrónica. Al enviar, el
/// servidor guarda la solicitud y registra la empresa con el proveedor usando
/// el certificado. Devuelve el resultado, o null si se cerró sin enviar.
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

class _EcfRequestDialogState extends ConsumerState<_EcfRequestDialog> {
  late final EcfRequestData _d = widget.status.data;
  late final _rnc = TextEditingController(text: _d.rnc ?? '');
  late final _legal = TextEditingController(text: _d.legalName ?? '');
  late final _trade = TextEditingController(text: _d.tradeName ?? '');
  late final _address = TextEditingController(text: _d.fiscalAddress ?? '');
  late final _province = TextEditingController(text: _d.province ?? '');
  late final _municipality = TextEditingController(text: _d.municipality ?? '');
  late final _email = TextEditingController(text: _d.email ?? '');
  late final _contactName =
      TextEditingController(text: widget.status.contactName ?? '');
  late final _contactPhone =
      TextEditingController(text: widget.status.contactPhone ?? '');
  final _password = TextEditingController();

  late bool _alreadyAuthorized = widget.status.alreadyAuthorized ?? false;
  bool _accept = false;
  bool _obscure = true;
  bool _sending = false;
  String? _certName;
  Uint8List? _certBytes;
  String? _error;

  static const _maxCertBytes = 100 * 1024;

  @override
  void dispose() {
    for (final c in [
      _rnc, _legal, _trade, _address, _province, _municipality, _email,
      _contactName, _contactPhone, _password,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickCertificate() async {
    try {
      // FileType.any a propósito: filtrar por extensión .p12 falla en algunos
      // Android/iOS que no conocen ese tipo. Se valida después.
      final result = await FilePicker.pickFiles(type: FileType.any);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final ext = file.name.contains('.') ? file.name.split('.').last.toLowerCase() : '';
      String? error;
      Uint8List? bytes;
      if (ext != 'p12' && ext != 'pfx') {
        error = 'El certificado tiene que ser un archivo .p12 o .pfx.';
      } else if (file.size > _maxCertBytes) {
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

  String? _validate() {
    final rnc = _rnc.text.replaceAll(RegExp(r'\D'), '');
    if (rnc.length != 9 && rnc.length != 11) {
      return 'El RNC debe tener 9 dígitos (u 11 si es cédula).';
    }
    if (_legal.text.trim().isEmpty) return 'Falta la razón social.';
    if (_address.text.trim().isEmpty) return 'Falta la dirección fiscal.';
    if (_contactName.text.trim().isEmpty) return 'Falta la persona de contacto.';
    if (_contactPhone.text.replaceAll(RegExp(r'\D'), '').length < 10) {
      return 'El teléfono de contacto debe incluir el código de área.';
    }
    if (_certBytes == null) return 'Falta tu certificado de firma digital (.p12).';
    if (_password.text.isEmpty) return 'Falta la contraseña del certificado.';
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
              _field(_trade, 'Nombre comercial (opcional)'),
              _field(_address, 'Dirección fiscal (la registrada en la DGII)', maxLength: 100),
              Row(
                children: [
                  Expanded(child: _field(_province, 'Provincia')),
                  const SizedBox(width: 12),
                  Expanded(child: _field(_municipality, 'Municipio')),
                ],
              ),
              _field(_email, 'Correo', keyboard: TextInputType.emailAddress),
              const SizedBox(height: 8),
              const _Group('Contacto'),
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
              const SizedBox(height: 8),
              const _Group('Certificado de firma digital'),
              OutlinedButton.icon(
                onPressed: _sending ? null : _pickCertificate,
                icon: const Icon(Icons.upload_file, size: 18),
                label: Text(_certName ?? 'Elegir certificado (.p12)'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _password,
                obscureText: _obscure,
                enabled: !_sending,
                decoration: InputDecoration(
                  labelText: 'Contraseña del certificado',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off, size: 18),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Debe estar a nombre de tu empresa o de su representante legal. '
                'MangoPOS no guarda el certificado ni la contraseña: van directo al '
                'proveedor de facturación electrónica.',
                style: TextStyle(fontSize: 11.5, color: MangoColors.muted),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _accept,
                onChanged: _sending ? null : (v) => setState(() => _accept = v ?? false),
                activeColor: MangoColors.primaryOrange,
                title: const Text(
                  'Autorizo a MangoPOS a registrar mi empresa con su proveedor de '
                  'facturación electrónica usando este certificado.',
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
