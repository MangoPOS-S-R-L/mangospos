// Botón + flujo de registro de tarjeta vía la Payment Page de Azul (form
// HOSPEDADO por Azul). Reutilizable: onboarding Step 4 y Settings → Método de
// pago. Azul captura la tarjeta y, con 3DS habilitado en el MID, corre la
// autenticación 3D Secure en su propia página (Verified by Visa / Mastercard ID
// Check). MangoPOS nunca toca el PAN → PCI SAQ A.
//
// Flujo:
//   1. createTokenizationSession (Edge Fn) → payment_page_url.
//   2. launchUrl(payment_page_url) en el navegador del sistema.
//   3. El backend (azul-callback) inserta la tarjeta al aprobar → el stream
//      Realtime de azul_payment_methods re-emite y detectamos la tarjeta nueva
//      (cambio de id respecto a la previa) → onSuccess.
//   4. Al volver del navegador (resume) re-leemos por si Realtime se perdió.

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme/mango_colors.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/repositories/billing_repository.dart';
import '../providers/billing_providers.dart';

class AzulPaymentPageLauncher extends ConsumerStatefulWidget {
  final String businessId;
  final String idleLabel;
  final IconData icon;

  /// Llamado cuando aparece la tarjeta nueva (registro exitoso).
  final VoidCallback? onSuccess;

  /// Si true, muestra un toast de éxito al detectar la tarjeta. Desactívalo si
  /// el caller maneja su propio mensaje en [onSuccess].
  final bool showSuccessToast;

  const AzulPaymentPageLauncher({
    super.key,
    required this.businessId,
    this.idleLabel = 'Agregar tarjeta',
    this.icon = Icons.lock_rounded,
    this.onSuccess,
    this.showSuccessToast = true,
  });

  @override
  ConsumerState<AzulPaymentPageLauncher> createState() =>
      _AzulPaymentPageLauncherState();
}

class _AzulPaymentPageLauncherState
    extends ConsumerState<AzulPaymentPageLauncher> with WidgetsBindingObserver {
  bool _isLoading = false;
  bool _isWaiting = false;
  String? _lastError;
  String? _beforeCardId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isWaiting) {
      // Volvió del navegador. Re-leemos la tarjeta; si en unos segundos no
      // apareció una nueva, dejamos de esperar (probablemente canceló/declinó —
      // no podemos leer el estado de la sesión por RLS). El éxito lo cierra
      // antes la detección por ref.watch en build.
      ref.invalidate(defaultPaymentMethodProvider(widget.businessId));
      Future.delayed(const Duration(seconds: 4), () {
        if (!mounted || !_isWaiting) return;
        final pm = ref
            .read(defaultPaymentMethodProvider(widget.businessId))
            .value;
        if (pm == null || pm.id == _beforeCardId) {
          setState(() => _isWaiting = false);
          AppToast.info(
            context,
            'No se registró una tarjeta nueva. Si cancelaste, intenta de nuevo.',
          );
        }
      });
    }
  }

  /// En móvil abrimos un navegador IN-APP (Custom Tabs en Android /
  /// SafariViewController en iOS): se siente dentro de la app, comparte sesión y
  /// vuelve solo al cerrarse. En web/desktop no hay navegador embebido confiable
  /// (Windows no soporta WebView, y Azul bloquea el iframe) → navegador del
  /// sistema, manteniendo viva la app para detectar la tarjeta por Realtime.
  LaunchMode _launchMode() {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      return LaunchMode.inAppBrowserView;
    }
    return LaunchMode.externalApplication;
  }

  Future<void> _launch() async {
    final repo = ref.read(billingRepositoryProvider);
    setState(() {
      _isLoading = true;
      _lastError = null;
    });
    try {
      _beforeCardId = ref
          .read(defaultPaymentMethodProvider(widget.businessId))
          .value
          ?.id;
      final session =
          await repo.createTokenizationSession(businessId: widget.businessId);
      final ok = await launchUrl(
        Uri.parse(session.paymentPageUrl),
        mode: _launchMode(),
      );
      if (!ok) {
        throw BillingRepositoryException(
          'No se pudo abrir el navegador para registrar la tarjeta.',
        );
      }
      if (!mounted) return;
      setState(() => _isWaiting = true);
    } on BillingRepositoryException catch (e) {
      if (mounted) setState(() => _lastError = e.message);
    } catch (e) {
      if (mounted) {
        setState(() => _lastError = 'No se pudo iniciar el registro: $e');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Cierra el estado "esperando" tras detectar la tarjeta nueva (éxito).
  void _onSuccess() {
    if (!_isWaiting) return;
    setState(() => _isWaiting = false);
    if (widget.showSuccessToast) {
      AppToast.success(context, 'Tarjeta registrada correctamente.');
    }
    widget.onSuccess?.call();
  }

  @override
  Widget build(BuildContext context) {
    // Detección robusta del éxito: observamos la tarjeta default con ref.watch
    // (SÍ reconstruye este widget ante el cambio; el ref.listen anterior a veces
    // no disparaba cuando el padre reconstruía en el mismo ciclo). Si mientras
    // esperábamos apareció una tarjeta distinta a la previa → registro exitoso.
    final current =
        ref.watch(defaultPaymentMethodProvider(widget.businessId)).value;
    if (_isWaiting && current != null && current.id != _beforeCardId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onSuccess());
    }

    final disabled = _isLoading || _isWaiting;
    final label = _isLoading
        ? 'Preparando pasarela…'
        : _isWaiting
            ? 'Esperando confirmación…'
            : widget.idleLabel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_lastError != null) ...[
          _ErrorBanner(message: _lastError!),
          const SizedBox(height: 12),
        ],
        if (_isWaiting) ...[
          _WaitingPanel(onCancel: () => setState(() => _isWaiting = false)),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          onPressed: disabled ? null : _launch,
          style: FilledButton.styleFrom(
            backgroundColor: MangoColors.primaryOrange,
            foregroundColor: MangoColors.white,
            disabledBackgroundColor: MangoColors.cardBorder,
            disabledForegroundColor: MangoColors.muted,
            minimumSize: const Size.fromHeight(48),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          icon: _isLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : Icon(widget.icon, size: 18),
          label: Text(label,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFB91C1C), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                  fontSize: 13, color: Color(0xFFB91C1C), height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _WaitingPanel extends StatelessWidget {
  final VoidCallback onCancel;
  const _WaitingPanel({required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4EC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFD3B0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: MangoColors.primaryOrange),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Completa el registro en tu navegador',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Ingresa y autentica tu tarjeta en la página segura de Azul que se '
            'abrió. Cuando termines, vuelve a la app: tu tarjeta aparecerá aquí.',
            style: TextStyle(
              fontSize: 12,
              color: MangoColors.darkGray.withValues(alpha: 0.7),
              height: 1.4,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onCancel,
              child: const Text('Cancelar'),
            ),
          ),
        ],
      ),
    );
  }
}
