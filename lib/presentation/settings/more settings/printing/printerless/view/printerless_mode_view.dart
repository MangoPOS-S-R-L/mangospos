// Ajustes → Gestión de Impresión → Modo sin impresora.
//
// Tres controles, porque el caso comun no es todo-o-nada:
//   1. Documentos de CAJA por negocio (`business_settings.printerless_mode`).
//   2. COMANDAS por negocio (`business_settings.printerless_kitchen`) — para
//      el restaurante con impresora en caja y cocina solo con KDS.
//   3. Override de ESTE DISPOSITIVO (SharedPreferences), que solo pisa el
//      punto 1: la impresora de cocina es compartida.
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
  bool _kitchenEnabled = false;
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
    var kitchen = false;
    if (businessId.isNotEmpty) {
      final repo = ref.read(posSettingsRepositoryProvider);
      try {
        enabled = await repo.getPrinterlessMode(businessId);
        kitchen = await repo.getPrinterlessKitchen(businessId);
      } catch (_) {
        // Sin red o sin la migración aplicada: se muestra apagado, que es
        // el comportamiento efectivo.
      }
    }
    if (!mounted) return;
    setState(() {
      _businessEnabled = enabled;
      _kitchenEnabled = kitchen;
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

  Future<void> _saveKitchen(bool value) async {
    final businessId = _businessId;
    if (businessId.isEmpty) {
      AppToast.error(context, 'No se pudo resolver el negocio activo.');
      return;
    }
    setState(() {
      _saving = true;
      _kitchenEnabled = value;
    });
    try {
      await ref
          .read(posSettingsRepositoryProvider)
          .setPrinterlessKitchen(businessId: businessId, enabled: value);
      PrinterlessMode.invalidate();
      await ref
          .read(posSettingsRepositoryProvider)
          .refreshBusinessSettings(businessId);
      if (!mounted) return;
      AppToast.success(
        context,
        value
            ? 'Las comandas dejan de imprimirse: van solo al KDS.'
            : 'Las comandas vuelven a imprimirse en cocina.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _kitchenEnabled = !value);
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
              'Con este modo el sistema deja de necesitar impresoras: los '
              'documentos se muestran en pantalla, con opción de compartirlos '
              'en PDF o mandarlos a una impresora normal del sistema '
              'operativo. Caja y cocina se controlan por separado, así puedes '
              'seguir imprimiendo facturas y apagar solo las comandas.',
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
              _kitchenCard(),
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
    final kitchenLine = _kitchenEnabled
        ? 'Las comandas no se imprimen: la cocina las ve en el KDS.'
        : 'Las comandas siguen saliendo por la impresora de cocina.';
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  on
                      ? 'En esta caja los documentos salen POR PANTALLA. No '
                            'se necesita impresora conectada.'
                      : 'En esta caja los documentos salen POR PAPEL, como '
                            'siempre.',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: MangoColors.darkGray,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  kitchenLine,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _businessCard() {
    return _card(
      child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        value: _businessEnabled,
        onChanged: _saving ? null : _saveBusiness,
        secondary: _cardIcon(
          Icons.receipt_long_rounded,
          const Color(0xFFEAF0FF),
          const Color(0xFF2563EB),
        ),
        title: const Text(
          'Facturas y pre-cuentas sin impresora',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: MangoColors.darkGray,
          ),
        ),
        subtitle: const Text(
          'Aplica a todas las cajas del negocio. Cubre factura, pre-cuenta, '
          'reimpresión, cierre de caja y recibos de ingresos/gastos: salen '
          'en pantalla con opción de compartir PDF. No toca las comandas.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ),
    );
  }

  Widget _kitchenCard() {
    return _card(
      child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        value: _kitchenEnabled,
        onChanged: _saving ? null : _saveKitchen,
        secondary: _cardIcon(
          Icons.soup_kitchen_outlined,
          const Color(0xFFFFF0D9),
          const Color(0xFFF97316),
        ),
        title: const Text(
          'Comandas sin impresora (solo KDS)',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: MangoColors.darkGray,
          ),
        ),
        subtitle: const Text(
          'Los envíos a cocina dejan de imprimir papel y de exigir impresora '
          'por área: el pedido llega al KDS. No abre ventana en cada envío. '
          'Es un ajuste del negocio — la impresora de cocina es compartida, '
          'así que el override de abajo no lo cambia.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ),
    );
  }

  Widget _cardIcon(IconData icon, Color background, Color foreground) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 20, color: foreground),
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
            'los meseros no (o al revés). Se guarda solo en este equipo y '
            'afecta únicamente facturas, pre-cuentas, cierres y recibos — '
            'nunca las comandas.',
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
            'Caja y cocina son independientes: puedes imprimir facturas en '
            'papel y mandar solo las comandas al KDS, o al revés.',
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
