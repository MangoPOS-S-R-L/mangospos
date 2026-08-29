// Guard del bloqueo por falta de pago.
//
// Envuelve el shell autenticado y aplica el modelo escalonado:
//   ok      → pasa derecho
//   warning → banner ámbar arriba del POS (descartable por sesión)
//   grace   → banner rojo con regresiva (no descartable)
//   locked  → sustituye TODO por AccountLockedView
//
// Relación con BillingGuard: este guard es el dueño del bloqueo. BillingGuard
// sigue apagado (`_kEnabled=false`) y solo cubre el caso de onboarding "trial
// sin tarjeta"; el camino de suspensión lo maneja este. No encender los dos a
// la vez para el mismo caso o el usuario ve dos overlays peleándose.
//
// Rutas exentas: aquellas donde el dueño está justamente resolviendo el pago.
// Si bloqueáramos esas, el bloqueo no tendría salida.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/models/account_access_state.dart';
import '../../../services/session/session_controller.dart';
import '../providers/access_providers.dart';
import 'access_banner.dart';
import 'account_locked_view.dart';

class AccessGuard extends ConsumerStatefulWidget {
  const AccessGuard({super.key, required this.child});

  final Widget child;

  static const exemptPathPrefixes = <String>[
    '/register',
    '/onboarding',
    '/settings/billing',
    '/login',
  ];

  @override
  ConsumerState<AccessGuard> createState() => _AccessGuardState();
}

class _AccessGuardState extends ConsumerState<AccessGuard>
    with WidgetsBindingObserver {
  /// Descartar el banner ámbar dura lo que dure la app abierta. A propósito no
  /// se persiste: cada arranque el dueño vuelve a verlo.
  bool _bannerDismissed = false;

  /// Refresca la regresiva del banner sin depender de que llegue un evento.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al volver del background revalidamos: es el momento en que más probable
    // es que el estado haya cambiado (el dueño pagó desde el navegador, o el
    // operador desbloqueó desde el panel).
    if (state == AppLifecycleState.resumed) {
      final businessId = ref.read(sessionProvider).activeBusinessId;
      if (businessId != null) {
        ref.read(refreshAccountAccessProvider)(businessId);
      }
    }
  }

  void _ensureTicker(bool needed) {
    if (needed && _ticker == null) {
      _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!needed && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final businessId = ref.watch(sessionProvider).activeBusinessId;
    if (businessId == null) {
      _ensureTicker(false);
      return widget.child;
    }

    final async = ref.watch(accountAccessProvider(businessId));

    // Mientras carga o si falla, dejamos pasar. El repo ya cae al snapshot
    // local ante un fallo de red; si igual explota, preferimos dejar operar
    // antes que varar a un cajero por un problema nuestro.
    final state = async.value;
    if (state == null) {
      _ensureTicker(false);
      return widget.child;
    }

    final currentPath = GoRouterState.of(context).uri.path;
    final exempt = AccessGuard.exemptPathPrefixes.any(currentPath.startsWith);

    if (state.blocksApp) {
      _ensureTicker(false);
      // En las rutas de pago dejamos ver la pantalla real para que el dueño
      // pueda registrar la tarjeta; el resto del POS queda detrás del bloqueo.
      if (exempt) return widget.child;
      return AccountLockedView(state: state);
    }

    if (state.showsBanner && !exempt) {
      final isGrace = state.level == AccessLevel.grace;
      _ensureTicker(true);
      if (isGrace || !_bannerDismissed) {
        return Column(
          children: [
            AccessBanner(
              state: state,
              onDismiss: isGrace
                  ? null
                  : () => setState(() => _bannerDismissed = true),
            ),
            Expanded(child: widget.child),
          ],
        );
      }
    }

    _ensureTicker(false);
    return widget.child;
  }
}
