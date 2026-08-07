// Ajustes → Gestión de Impresión → Modo sin impresora.
//
// Enciende/apaga el modo en dos niveles: el interruptor del NEGOCIO (que
// viaja a `business_settings.printerless_mode` y aplica a todas las cajas)
// y el override de ESTE DISPOSITIVO (SharedPreferences, para la caja que sí
// tiene impresora dentro de un negocio sin ellas, o al revés).
//
// La lógica de resolución vive en core/printing/printerless_mode.dart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/printing/printerless_mode.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/services/session/session_controller.dart';

class PrinterlessModeView extends ConsumerStatefulWidget {
  const PrinterlessModeView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  ConsumerState<PrinterlessModeView> createState() =>
      _PrinterlessModeViewState();
}

class _PrinterlessModeViewState extends ConsumerState<PrinterlessModeView> {
  bool _loading = true;
  bool _saving = false;
  bool _businessEnabled = false;
  PrinterlessDeviceOverride _override = PrinterlessDeviceOverride.inherit;

  String get _businessId {
    if (widget.businessId != 'auto' && widget.businessId.isNotEmpty) {
      return widget.businessId;
    }
    return ref.read(sessionProvider).activeBusinessId ?? '';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final businessId = _businessId;
    final override = await PrinterlessMode.deviceOverride();
    var enabled = false;
    if (businessId.isNotEmpty) {
      try {
        enabled = await ref
            .read(posSettingsRepositoryProvider)
            .getPrinterlessMode(businessId);
      } catch (_) {
        // Sin red o sin la migración aplicada: se muestra apagado, que es
        // el comportamiento efectivo.
      }
    }
    if (!mounted) return;
    setState(() {
      _businessEnabled = enabled;
      _override = override;
      _loading = false;
    });
  }

  Future<void> _saveBusiness(bool value) async {
    final businessId = _businessId;
    if (businessId.isEmpty) {
      AppToast.error(context, 'No se pudo resolver el negocio activo.');
      return;
    }
    setState(() {
      _saving = true;
      _businessEnabled = value;
    });
    try {
      await ref
          .read(posSettingsRepositoryProvider)
          .setPrinterlessMode(businessId: businessId, enabled: value);
      // Que el cambio se sienta en el siguiente cobro, sin esperar el TTL.
      PrinterlessMode.invalidate();
      await ref
          .read(posSettingsRepositoryProvider)
          .refreshBusinessSettings(businessId);
      if (!mounted) return;
      AppToast.success(
        context,
        value
            ? 'Modo sin impresora activado para el negocio.'
            : 'El negocio vuelve a imprimir en papel.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _businessEnabled = !value);
      AppToast.error(context, 'No se pudo guardar: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveOverride(PrinterlessDeviceOverride value) async {
    setState(() {
      _saving = true;
      _override = value;
    });
    await PrinterlessMode.setDeviceOverride(value);
    PrinterlessMode.invalidate();
    if (!mounted) return;
    setState(() => _saving = false);
    AppToast.success(context, 'Preferencia de este dispositivo guardada.');
  }

  /// Lo que efectivamente va a pasar en ESTA caja con la combinación actual.
  bool get _effective {
    switch (_override) {
      case PrinterlessDeviceOverride.alwaysPrint:
        return false;
      case PrinterlessDeviceOverride.neverPrint:
        return true;
      case PrinterlessDeviceOverride.inherit:
        return _businessEnabled;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF7F7F7),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: MangoColors.darkGray,
                padding: EdgeInsets.zero,
              ),
              onPressed: () => context.go(AppRoutes.printingBase),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Regresar'),
            ),
            const SizedBox(height: 12),
            const Text(
              'Modo sin impresora',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Con este modo encendido el sistema deja de necesitar '
              'impresoras. Facturas, pre-cuentas, reimpresiones, cierres de '
              'caja y recibos de movimiento se muestran en pantalla, con la '
              'opción de compartirlos en PDF o mandarlos a una impresora '
              'normal del sistema operativo.',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 20),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  backgroundColor: MangoColors.bgLight,
                  color: MangoColors.primaryOrange,
                ),
              )
            else ...[
              _statusBanner(),
              const SizedBox(height: 18),
              _businessCard(),
              const SizedBox(height: 16),
              _deviceCard(),
              const SizedBox(height: 16),
              _notesCard(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusBanner() {
    final on = _effective;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: on ? const Color(0xFFEFF6FF) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: on ? const Color(0xFFBFDBFE) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          Icon(
            on ? Icons.desktop_windows_rounded : Icons.print_rounded,
            color: on ? const Color(0xFF2563EB) : MangoColors.darkGray,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              on
                  ? 'En esta caja los documentos salen POR PANTALLA. No se '
                        'necesita ninguna impresora conectada.'
                  : 'En esta caja los documentos salen POR PAPEL, como '
                        'siempre.',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: MangoColors.darkGray,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _businessCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _businessEnabled,
            onChanged: _saving ? null : _saveBusiness,
            title: const Text(
              'Operar sin impresoras en todo el negocio',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: MangoColors.darkGray,
              ),
            ),
            subtitle: const Text(
              'Aplica a todas las cajas del negocio. Las comandas de cocina '
              'también dejan de imprimirse: los pedidos llegan al KDS.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }

  Widget _deviceCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Solo este dispositivo',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Sirve cuando la caja principal tiene impresora y las tablets de '
            'los meseros no (o al revés). Se guarda solo en este equipo.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 8),
          for (final option in PrinterlessDeviceOverride.values)
            RadioListTile<PrinterlessDeviceOverride>(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: option,
              // ignore: deprecated_member_use
              groupValue: _override,
              // ignore: deprecated_member_use
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) _saveOverride(value);
                    },
              title: Text(
                option.label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: MangoColors.darkGray,
                ),
              ),
              subtitle: Text(
                option.description,
                style: const TextStyle(fontSize: 11.5, color: Colors.black54),
              ),
            ),
        ],
      ),
    );
  }

  Widget _notesCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            'Qué cambia exactamente',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: MangoColors.darkGray,
            ),
          ),
          SizedBox(height: 10),
          _Bullet(
            'Factura, pre-cuenta y reimpresión abren un ticket en pantalla '
            'con el mismo formato del papel, y se pueden compartir en PDF.',
          ),
          _Bullet(
            'El cierre de caja y los recibos de ingresos/gastos hacen lo '
            'mismo. El cierre se guarda igual que siempre.',
          ),
          _Bullet(
            'Las comandas NO abren ventana en cada envío: la cocina las ve '
            'en el KDS. Solo dejan de exigir impresora asignada.',
          ),
          _Bullet(
            'El NCF, los impuestos y los totales no cambian: es el mismo '
            'documento, solo que en pantalla.',
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: child,
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 5, right: 8),
            child: Icon(Icons.circle, size: 6, color: Color(0xFF94A3B8)),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12.5, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }
}
