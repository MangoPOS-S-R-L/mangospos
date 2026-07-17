import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';

class CashCloseModeView extends ConsumerStatefulWidget {
  const CashCloseModeView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  ConsumerState<CashCloseModeView> createState() => _CashCloseModeViewState();
}

class _CashCloseModeViewState extends ConsumerState<CashCloseModeView> {
  String? _resolvedBusinessId;
  String? _selected;
  bool _allowRecount = false;
  bool _printSalesByArea = false;
  bool _printProductsByArea = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final id = await BusinessResolver.ensure(widget.businessId);
      final repo = ref.read(posSettingsRepositoryProvider);
      final mode = await repo.getCashCloseMode(id);
      final allowRecount = await repo.getAllowRecount(id);
      final printSalesByArea = await repo.getCashClosePrintSalesByArea(id);
      final printProductsByArea = await repo.getCashClosePrintProductsByArea(id);
      if (!mounted) return;
      setState(() {
        _resolvedBusinessId = id;
        _selected = mode;
        _allowRecount = allowRecount;
        _printSalesByArea = printSalesByArea;
        _printProductsByArea = printProductsByArea;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo cargar la preferencia: $e';
        _loading = false;
      });
    }
  }

  Future<void> _setAllowRecount(bool enabled) async {
    if (_saving || _resolvedBusinessId == null || enabled == _allowRecount) {
      return;
    }
    final previous = _allowRecount;
    setState(() {
      _allowRecount = enabled;
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(posSettingsRepositoryProvider)
          .setAllowRecount(businessId: _resolvedBusinessId!, enabled: enabled);
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.info(
        context,
        enabled
            ? 'Reconteo habilitado: el cajero verá el botón «Volver a contar».'
            : 'Reconteo deshabilitado.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _allowRecount = previous;
        _saving = false;
        _error = 'No se pudo guardar el cambio: $e';
      });
    }
  }

  Future<void> _setPrintSalesByArea(bool enabled) async {
    if (_saving ||
        _resolvedBusinessId == null ||
        enabled == _printSalesByArea) {
      return;
    }
    final previous = _printSalesByArea;
    setState(() {
      _printSalesByArea = enabled;
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(posSettingsRepositoryProvider)
          .setCashClosePrintSalesByArea(
            businessId: _resolvedBusinessId!,
            enabled: enabled,
          );
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.info(
        context,
        enabled
            ? 'El cierre de caja incluirá el desglose por área de producción.'
            : 'Desglose por área de producción desactivado en el cierre.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _printSalesByArea = previous;
        _saving = false;
        _error = 'No se pudo guardar el cambio: $e';
      });
    }
  }

  Future<void> _setPrintProductsByArea(bool enabled) async {
    if (_saving ||
        _resolvedBusinessId == null ||
        enabled == _printProductsByArea) {
      return;
    }
    final previous = _printProductsByArea;
    setState(() {
      _printProductsByArea = enabled;
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(posSettingsRepositoryProvider)
          .setCashClosePrintProductsByArea(
            businessId: _resolvedBusinessId!,
            enabled: enabled,
          );
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.info(
        context,
        enabled
            ? 'El cierre de caja incluirá el desglose de productos por área.'
            : 'Desglose de productos por área desactivado en el cierre.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _printProductsByArea = previous;
        _saving = false;
        _error = 'No se pudo guardar el cambio: $e';
      });
    }
  }

  Future<void> _select(String mode) async {
    if (_saving || _selected == mode || _resolvedBusinessId == null) return;
    final previous = _selected;
    setState(() {
      _selected = mode;
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(posSettingsRepositoryProvider)
          .setCashCloseMode(businessId: _resolvedBusinessId!, mode: mode);
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.info(
        context,
        mode == PosSettingsRepository.cashCloseDetailed
            ? 'Modo de cierre: detallado (3 pasos)'
            : 'Modo de cierre: compacto (1 paso)',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _selected = previous;
        _saving = false;
        _error = 'No se pudo guardar el cambio: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: const Text(
          'Modo de cierre de caja',
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
    final selected = _selected ?? PosSettingsRepository.cashCloseCompact;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _IntroCard(saving: _saving),
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _ErrorBanner(message: _error!),
          ),
        _ModeOption(
          value: PosSettingsRepository.cashCloseCompact,
          groupValue: selected,
          title: 'Compacto (1 paso)',
          description:
              'Un solo modal con efectivo, tarjeta y transferencia juntos. '
              'Cierre más rápido para cajeros experimentados. '
              '(Comportamiento actual del POS.)',
          onChanged: _saving ? null : _select,
        ),
        const SizedBox(height: 12),
        _ModeOption(
          value: PosSettingsRepository.cashCloseDetailed,
          groupValue: selected,
          title: 'Detallado (3 pasos)',
          description:
              'Wizard guiado: primero efectivo (con desglose por '
              'denominación), luego tarjeta y transferencia, y por último '
              'revisión. Más estructurado para cajeros nuevos o auditorías '
              'estrictas.',
          highlighted: true,
          onChanged: _saving ? null : _select,
        ),
        const SizedBox(height: 24),
        const _SectionLabel('Reconteo'),
        const SizedBox(height: 8),
        _RecountSwitch(
          value: _allowRecount,
          onChanged: _saving ? null : _setAllowRecount,
        ),
        const SizedBox(height: 24),
        const _SectionLabel('Reporte de cierre'),
        const SizedBox(height: 8),
        _SalesByAreaSwitch(
          value: _printSalesByArea,
          onChanged: _saving ? null : _setPrintSalesByArea,
        ),
        const SizedBox(height: 12),
        _ProductsByAreaSwitch(
          value: _printProductsByArea,
          onChanged: _saving ? null : _setPrintProductsByArea,
        ),
        const SizedBox(height: 24),
        const _SectionLabel('Plaza comercial'),
        const SizedBox(height: 8),
        const _MallExportLink(),
      ],
    );
  }
}

/// Acceso a la configuración del envío de ventas por SFTP a la plaza
/// comercial (ej. Ágora Santiago Center).
class _MallExportLink extends StatelessWidget {
  const _MallExportLink();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.go(AppRoutes.settingsMallSalesExport),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: MangoColors.cardBorder),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.cloud_upload_outlined,
                  color: MangoColors.muted,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Reporte a plaza comercial (SFTP)',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Configura el envío del acumulado de ventas por hora al '
                      'servidor de la plaza (ej. Ágora). Se sube al cerrar '
                      'caja o manualmente.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Colors.black38),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
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
}

class _RecountSwitch extends StatelessWidget {
  const _RecountSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
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
              color: value
                  ? const Color(0xFFFFEDD5)
                  : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.replay_rounded,
              color: value ? MangoColors.primaryOrange : MangoColors.muted,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Permitir recontar antes de firmar',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Si está activado, el cajero verá un botón «Volver a '
                  'contar» en el flujo de cierre que limpia los montos y '
                  'reinicia el conteo. Solo aplica antes de firmar; una '
                  'vez confirmado el cierre, no se puede revertir.',
                  style: TextStyle(
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

class _SalesByAreaSwitch extends StatelessWidget {
  const _SalesByAreaSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
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
              color: value
                  ? const Color(0xFFFFEDD5)
                  : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.pie_chart_outline_rounded,
              color: value ? MangoColors.primaryOrange : MangoColors.muted,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Incluir ventas por área de producción',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Si está activado, el papel del cierre de caja agrega un '
                  'desglose de ventas por área (cocina, bar, etc.) con monto, '
                  'unidades y órdenes, para el periodo de la sesión.',
                  style: TextStyle(
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

class _ProductsByAreaSwitch extends StatelessWidget {
  const _ProductsByAreaSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
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
              color: value
                  ? const Color(0xFFFFEDD5)
                  : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.format_list_bulleted_rounded,
              color: value ? MangoColors.primaryOrange : MangoColors.muted,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Incluir desglose de ventas por productos',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Si está activado, debajo del resumen por área el cierre '
                  'lista cada producto con su cantidad (unidades), agrupado '
                  'por área de producción (Bar, Cocina, etc.).',
                  style: TextStyle(
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

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.saving});

  final bool saving;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_outline, color: Colors.black54),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Elige la estructura del flujo de cierre. Ambos modos son '
              'a ciegas durante el conteo — el cajero nunca ve el monto '
              'esperado por el sistema antes de confirmar.',
              style: TextStyle(color: Colors.black87, fontSize: 14),
            ),
          ),
          if (saving) ...[
            const SizedBox(width: 12),
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.value,
    required this.groupValue,
    required this.title,
    required this.description,
    required this.onChanged,
    this.highlighted = false,
  });

  final String value;
  final String groupValue;
  final String title;
  final String description;
  final ValueChanged<String>? onChanged;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final isSelected = value == groupValue;
    final accent = highlighted
        ? MangoColors.successGreen
        : MangoColors.darkGray;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onChanged == null ? null : () => onChanged!(value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected ? accent : MangoColors.cardBorder,
              width: isSelected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: RadioListTile<String>(
            value: value,
            groupValue: groupValue,
            onChanged: onChanged == null
                ? null
                : (v) {
                    if (v != null) onChanged!(v);
                  },
            activeColor: accent,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: Colors.black87,
                ),
              ),
            ),
            subtitle: Text(
              description,
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFA32D2D)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFA32D2D)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFFA32D2D), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
