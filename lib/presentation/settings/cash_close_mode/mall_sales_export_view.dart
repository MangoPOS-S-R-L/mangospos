import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/core/services/mall_sales_export_service.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/mall_sales_export_repository.dart';
import '../../../core/theme/app_colors.dart';

/// Configuración del envío de ventas por hora al servidor SFTP de la plaza
/// comercial (ej. Ágora Santiago Center). Accesible desde Configuración →
/// Modo de cierre de caja → "Reporte a plaza comercial".
class MallSalesExportView extends ConsumerStatefulWidget {
  const MallSalesExportView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  ConsumerState<MallSalesExportView> createState() =>
      _MallSalesExportViewState();
}

class _MallSalesExportViewState extends ConsumerState<MallSalesExportView> {
  String? _resolvedBusinessId;
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  bool _sending = false;
  String? _error;

  bool _enabled = false;
  bool _sendOnCashClose = true;
  DateTime? _lastSentAt;
  String? _lastError;
  bool _obscurePassword = true;

  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '22');
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _dirCtrl = TextEditingController(text: '/');
  final _clientCodeCtrl = TextEditingController();
  final _prefixCtrl = TextEditingController(text: 'Ventas');
  final _rateCtrl = TextEditingController(text: '1');

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _dirCtrl.dispose();
    _clientCodeCtrl.dispose();
    _prefixCtrl.dispose();
    _rateCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final id = await BusinessResolver.ensure(widget.businessId);
      final config =
          await ref.read(mallSalesExportRepositoryProvider).getConfig(id);
      if (!mounted) return;
      setState(() {
        _resolvedBusinessId = id;
        if (config != null) {
          _enabled = config.enabled;
          _sendOnCashClose = config.sendOnCashClose;
          _hostCtrl.text = config.host;
          _portCtrl.text = config.port.toString();
          _userCtrl.text = config.username;
          _passCtrl.text = config.password;
          _dirCtrl.text = config.remoteDir;
          _clientCodeCtrl.text = config.clientCode;
          _prefixCtrl.text = config.filePrefix;
          _rateCtrl.text =
              config.exchangeRate == config.exchangeRate.roundToDouble()
                  ? config.exchangeRate.toStringAsFixed(0)
                  : config.exchangeRate.toString();
          _lastSentAt = config.lastSentAt;
          _lastError = config.lastError;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo cargar la configuración: $e';
        _loading = false;
      });
    }
  }

  MallSalesExportConfig _buildConfig() {
    return MallSalesExportConfig(
      businessId: _resolvedBusinessId!,
      enabled: _enabled,
      sendOnCashClose: _sendOnCashClose,
      host: _hostCtrl.text.trim(),
      port: int.tryParse(_portCtrl.text.trim()) ?? 22,
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
      remoteDir: _dirCtrl.text.trim(),
      clientCode: _clientCodeCtrl.text.trim(),
      filePrefix: _prefixCtrl.text.trim(),
      exchangeRate:
          double.tryParse(_rateCtrl.text.trim().replaceAll(',', '.')) ?? 1.0,
    );
  }

  Future<bool> _save({bool silent = false}) async {
    if (_resolvedBusinessId == null) return false;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(mallSalesExportRepositoryProvider)
          .saveConfig(_buildConfig());
      if (!mounted) return true;
      setState(() => _saving = false);
      if (!silent) {
        AppToast.success(context, 'Configuración guardada');
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _saving = false;
        _error = 'No se pudo guardar: $e';
      });
      return false;
    }
  }

  Future<void> _testConnection() async {
    if (_testing || _resolvedBusinessId == null) return;
    // Guarda primero para que la prueba use exactamente lo configurado.
    if (!await _save(silent: true)) return;
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      await MallSalesExportService().testConnection(_buildConfig());
      if (!mounted) return;
      AppToast.success(
        context,
        'Conexión exitosa: servidor y directorio accesibles.',
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Falló la conexión: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _sendToday() => _send(DateTime.now());

  /// Reenvío manual de un día pasado. Sirve para validar el formato con la
  /// plaza sin esperar al cierre de caja: el archivo del día se regenera
  /// completo y sobrescribe el remoto, así que reenviar no duplica nada.
  Future<void> _pickDateAndSend() async {
    if (_sending || _resolvedBusinessId == null) return;
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: today.subtract(const Duration(days: 1)),
      firstDate: today.subtract(const Duration(days: 90)),
      lastDate: today,
      helpText: 'Día de ventas a enviar',
    );
    if (picked == null) return;
    await _send(picked);
  }

  Future<void> _send(DateTime date) async {
    if (_sending || _resolvedBusinessId == null) return;
    if (!await _save(silent: true)) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final fileName = await MallSalesExportService().sendForDate(
        businessId: _resolvedBusinessId!,
        date: date,
        config: _buildConfig(),
      );
      if (!mounted) return;
      setState(() {
        _lastSentAt = DateTime.now();
        _lastError = null;
      });
      AppToast.success(context, 'Archivo $fileName subido correctamente.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastError = e.toString());
      AppToast.error(context, 'No se pudo enviar: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => context.go(AppRoutes.settingsCashCloseMode),
        ),
        title: const Text(
          'Reporte a plaza comercial',
          style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final busy = _saving || _testing || _sending;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _card(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.cloud_upload_outlined, color: Colors.black54),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Sube automáticamente el acumulado de ventas por hora (todas '
                  'las cajas) al servidor SFTP de la plaza comercial, en el '
                  'formato que exige su administración (ej. Ágora). El archivo '
                  'del día se regenera completo en cada envío.',
                  style: TextStyle(color: Colors.black87, fontSize: 14),
                ),
              ),
              if (busy) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _banner(_error!, isError: true),
          ),
        _switchTile(
          title: 'Enviar ventas a la plaza comercial',
          subtitle: 'Activa la exportación por SFTP para este negocio.',
          icon: Icons.storefront_outlined,
          value: _enabled,
          onChanged: busy ? null : (v) => setState(() => _enabled = v),
        ),
        const SizedBox(height: 12),
        _switchTile(
          title: 'Enviar automáticamente al cerrar caja',
          subtitle:
              'Además del envío manual, sube el archivo del día cada vez que '
              'se cierra una caja. La última caja en cerrar sube el '
              'consolidado final.',
          icon: Icons.point_of_sale_outlined,
          value: _sendOnCashClose,
          onChanged: busy ? null : (v) => setState(() => _sendOnCashClose = v),
        ),
        const SizedBox(height: 24),
        _sectionLabel('Servidor SFTP'),
        const SizedBox(height: 8),
        _card(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: _field(
                      controller: _hostCtrl,
                      label: 'Servidor (host)',
                      hint: 'ej. agorasantiagocenter.serveftp.net',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      controller: _portCtrl,
                      label: 'Puerto',
                      hint: '22',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      controller: _userCtrl,
                      label: 'Usuario',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      controller: _passCtrl,
                      label: 'Contraseña',
                      obscure: _obscurePassword,
                      suffix: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 20,
                        ),
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _field(
                controller: _dirCtrl,
                label: 'Directorio remoto',
                hint: '/ (raíz) o /ventas',
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _sectionLabel('Formato del archivo'),
        const SizedBox(height: 8),
        _card(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _field(
                      controller: _clientCodeCtrl,
                      label: 'Código de cliente (NUMSERIE)',
                      hint: 'Lo asigna la plaza, ej. 341',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      controller: _rateCtrl,
                      label: 'Tasa (TASA)',
                      hint: '1',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _field(
                controller: _prefixCtrl,
                label: 'Prefijo del archivo',
                hint: 'ej. Ventas_4_8 → Ventas_4_8_16072026.txt',
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _sectionLabel('Estado'),
        const SizedBox(height: 8),
        if (_lastSentAt != null)
          _banner(
            'Último envío exitoso: '
            '${DateFormat('dd/MM/yyyy hh:mm a').format(_lastSentAt!)}',
          ),
        if (_lastError != null) ...[
          if (_lastSentAt != null) const SizedBox(height: 8),
          _banner('Último error: $_lastError', isError: true),
        ],
        if (_lastSentAt == null && _lastError == null)
          _banner('Aún no se ha realizado ningún envío.'),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : _testConnection,
                icon: const Icon(Icons.wifi_tethering),
                label: Text(_testing ? 'Probando...' : 'Probar conexión'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : _sendToday,
                icon: const Icon(Icons.send_outlined),
                label: Text(_sending ? 'Enviando...' : 'Enviar ventas de hoy'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: busy ? null : _pickDateAndSend,
            icon: const Icon(Icons.event_repeat_outlined),
            label: const Text('Reenviar otro día...'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Guardando...' : 'Guardar cambios'),
            style: FilledButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: Colors.black54,
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: child,
    );
  }

  Widget _banner(String message, {bool isError = false}) {
    final color = isError ? const Color(0xFFA32D2D) : const Color(0xFF166534);
    final bg = isError ? const Color(0xFFFFEBEE) : const Color(0xFFECFDF5);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.info_outline,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: suffix,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _switchTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: value ? MangoColors.primaryOrange : MangoColors.cardBorder,
          width: value ? 1.5 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: value ? const Color(0xFFFFEDD5) : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              color: value ? MangoColors.primaryOrange : MangoColors.muted,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.black54,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            value: value,
            activeTrackColor: MangoColors.primaryOrange,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
