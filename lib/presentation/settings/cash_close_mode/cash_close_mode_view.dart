import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
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
      if (!mounted) return;
      setState(() {
        _resolvedBusinessId = id;
        _selected = mode;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            mode == PosSettingsRepository.cashCloseDetailed
                ? 'Modo de cierre: detallado (3 pasos)'
                : 'Modo de cierre: compacto (1 paso)',
          ),
          duration: const Duration(seconds: 2),
        ),
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
      ],
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
