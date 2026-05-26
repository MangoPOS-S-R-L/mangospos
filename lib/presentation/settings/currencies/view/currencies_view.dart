import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';

import '../widgets/usd_display_settings_card.dart';

class CurrenciesView extends ConsumerStatefulWidget {
  const CurrenciesView({super.key});

  @override
  ConsumerState<CurrenciesView> createState() => _CurrenciesViewState();
}

class _CurrenciesViewState extends ConsumerState<CurrenciesView> {
  String? _businessId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _resolveBusinessId();
  }

  Future<void> _resolveBusinessId() async {
    try {
      final id = await BusinessResolver.ensure('auto');
      if (!mounted) return;
      setState(() {
        _businessId = id;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'No se pudo resolver el negocio: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Regresar',
          onPressed: () => Navigator.of(context).canPop()
              ? Navigator.of(context).pop()
              : context.go(AppRoutes.settings),
        ),
        title: const Text('Monedas'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_businessId == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // PRD 6 — Sub-sección "Moneda Secundaria (USD Display)".
          UsdDisplaySettingsCard(businessId: _businessId!),
          const SizedBox(height: 16),
          // Espacio reservado para futuras monedas (EUR, multi-tasa, etc.)
        ],
      ),
    );
  }
}
