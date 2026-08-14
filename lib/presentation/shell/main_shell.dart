import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http; // ✅ check internet
import 'package:google_fonts/google_fonts.dart';

import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/offline_queue_status_provider.dart';
import 'package:mangopos/core/agent/hub_server_controller.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/presentation/shell/hub_host_uplink.dart';
import 'package:mangopos/core/offline/offline_refreshers.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/presentation/shell/offline_logout_guard.dart';
import 'package:mangopos/core/printing/printer_heartbeat_provider.dart';
import 'package:mangopos/core/printing/ble_printer_connection_provider.dart';
import 'package:mangopos/core/services/fullscreen/fullscreen_service.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/utils/responsive_utils.dart';
import 'package:mangopos/services/session/session_controller.dart';

import '../../app/theme/mango_colors.dart';
import '../../app/router/routes.dart';
import '../billing/widgets/billing_guard.dart';
import '../onboarding/pending_approval_guard.dart';
import '../inventory/viewmodel/expiring_lots_badge_provider.dart';
import '../../core/business/business_features_provider.dart';
import '../../core/business/business_modules_provider.dart';
import '../inventory/viewmodel/low_stock_badge_provider.dart';
import '../sales/viewmodel/sales_viewmodel.dart';
import 'mobile_shell.dart';
import 'shell_destinations.dart';
import 'update_available_banner.dart';
import '../../core/theme/app_colors.dart';

class MainShell extends ConsumerStatefulWidget {
  /// El shell de navegación con estado del `StatefulShellRoute.indexedStack`.
  /// Es un `Widget` que renderiza el `IndexedStack` de las ramas (cada sección
  /// se mantiene viva) y expone `goBranch(index)` para cambiar de sección
  /// conservando el estado de las demás.
  final StatefulNavigationShell navigationShell;
  const MainShell({super.key, required this.navigationShell});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  OfflineQueueSyncResult? _lastNotifiedResult;

  @override
  Widget build(BuildContext context) {
    // Mantiene vivo el HubModeController desde el arranque del shell: al ser un
    // provider no-autoDispose, basta con instanciarlo una vez para que empiece
    // a observar conectividad y, cuando se active kHubModeEnabled, drene su
    // op-log al reconectar. Usamos read (no watch) para no re-construir el shell
    // en cada cambio de modo; con la flag apagada el controller queda inerte.
    ref.read(hubModeProvider);

    // Paridad Windows del Hub: mantiene vivo el HubServerController, que en
    // Windows/Linux levanta el servidor Dart dedicado de /hub/* cuando este
    // equipo es el Hub (modo hubHost). Inerte en web/Mac/tablet/móvil y cuando
    // el equipo no es Hub.
    ref.read(hubServerProvider);

    // Drenaje rápido del op-log del Hub host (cada 4s) para que las ediciones
    // de las cajas lleguen al servidor sin esperar el sync de 3 min → el cobro
    // del cashier en la caja principal queda exacto. Inerte salvo en hubHost.
    ref.read(hubHostUplinkProvider);

    // F6: mantiene vivo el coordinador de bajada desde el arranque del shell
    // (read, no watch). Refresca catálogo/zonas/inventario del negocio activo
    // al reconectar y periódicamente, para operar offline con datos al día.
    ref.read(offlineSyncCoordinatorProvider);

    // Wrap del child con dos guards en orden de prioridad:
    //   1. PendingApprovalGuard: si la cuenta está pendiente de aprobación
    //      (status='pending'), bloquea con pantalla "en revisión".
    //   2. BillingGuard: si la cuenta está suspendida o en trial sin tarjeta
    //      verificada, el guard sustituye el contenido por un overlay
    //      bloqueante.
    // Pending tiene prioridad sobre billing — si la cuenta ni siquiera
    // está aprobada, no tiene sentido empujarle el flujo de tarjeta.
    // Rutas exentas (registro, onboarding, login, billing) las maneja
    // cada guard internamente.
    final child = PendingApprovalGuard(
      child: BillingGuard(child: widget.navigationShell),
    );

    // Escuchamos el resultado del último sync para notificar al cajero
    // qué se sincronizó. El controller es singleton; usamos referencia
    // por identidad de OfflineQueueSyncResult para evitar duplicar la
    // notificación entre rebuilds de otras pantallas.
    ref.listen<OfflineQueueStatus>(offlineQueueStatusProvider,
        (previous, next) {
      final result = next.lastResult;
      if (result == null) return;
      if (identical(result, _lastNotifiedResult)) return;
      if (!result.didWork && result.pending == 0) {
        _lastNotifiedResult = result;
        return;
      }
      _lastNotifiedResult = result;
      _showSyncSnackBar(context, result);
    });

    // En anchos compactos (<600dp) usamos el shell móvil con bottom nav +
    // drawer. El topbar horizontal solo tiene sentido en tablet/desktop.
    if (ResponsiveHelper.useCompactShell(context)) {
      return MobileShell(navigationShell: widget.navigationShell);
    }

    const topBarHeight = 64.0;
    const horizontalPadding = 16.0;
    const navGap = 16.0;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // ======= APP BAR =======
            Container(
              height: topBarHeight,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: horizontalPadding,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x0F000000), // Shadow soft
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  const _Logo(),
                  const SizedBox(width: 32),

                  // Menú principal (Centro) - scroll horizontal cuando no cabe.
                  // Filtramos destinos por:
                  //   1) Permiso del rol (oculta lo bloqueado en vez de
                  //      mostrar el candado gris).
                  //   2) Config del business (`header_destinations_disabled`)
                  //      — el owner puede ocultar destinos a todos los
                  //      empleados sin tocar permisos por rol.
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Builder(builder: (context) {
                        final session = ref.watch(sessionProvider);
                        final sessionCtrl =
                            ref.read(sessionProvider.notifier);
                        final businessId = session.activeBusinessId ?? '';
                        final disabledAsync = ref.watch(
                          headerDestinationsDisabledProvider(businessId),
                        );
                        // Mientras carga la config, usamos `[]` —
                        // muestra todos los destinos permitidos por rol,
                        // que es el comportamiento histórico.
                        final disabledRoutes = disabledAsync.value ??
                            const <String>[];
                        final features = ref.watchBusinessFeatures();
                        final modules = ref.watchEnabledModules();
                        final visible = kPrimaryDestinations.where((d) {
                          final code = d.permissionCode;
                          final hasPerm =
                              code == null || sessionCtrl.hasPermission(code);
                          final hidden = disabledRoutes.contains(d.route);
                          final featureOk =
                              isDestinationFeatureEnabled(d, features);
                          final moduleOk =
                              isDestinationModuleEnabled(d, modules);
                          return hasPerm && !hidden && featureOk && moduleOk;
                        }).toList(growable: false);
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < visible.length; i++) ...[
                              if (i > 0) const SizedBox(width: navGap),
                              _TopNavItem(
                                destination: visible[i],
                                navigationShell: widget.navigationShell,
                              ),
                            ],
                          ],
                        );
                      }),
                    ),
                  ),

                  // Sección derecha (Acciones)
                  Row(
                    children: [
                      // Pantalla completa
                      const _FullscreenButton(),

                      const SizedBox(width: 12),

                      // Badge de operaciones offline pendientes
                      const _OfflineQueueBadge(),

                      const SizedBox(width: 8),

                      // Badge de estado de impresoras (heartbeat 30s).
                      // Verde = todas OK, amarillo = ≥1 offline, gris
                      // = aún sondeando o sin impresoras configuradas.
                      const _PrinterHeartbeatBadge(),

                      // Badge de conexión BLE persistente (impresora BT). Solo
                      // aparece cuando hay impresoras BT: azul=conectada,
                      // amarillo=reconectando.
                      const _BlePrinterBadge(),

                      // Vencimientos y stock bajo se movieron al menú del
                      // usuario (avatar) para aligerar el header.

                      const SizedBox(width: 16),

                      // Divider
                      Container(height: 32, width: 1, color: Colors.grey[300]),

                      const SizedBox(width: 16),

                      // User Info
                      const _UserInfo(),
                    ],
                  ),
                ],
              ),
            ),

            // ======= BANNER ACTUALIZACIÓN (solo web, solo si hay deploy nuevo)
            const UpdateAvailableBanner(),

            // ======= CONTENIDO =======
            Expanded(child: child),
          ],
        ),
      ),
    );
  }

  /// SnackBar contextual al final de un sync. Mensaje varía según haya
  /// completados, fallidos, o solo pendientes (caso "no había red real
  /// todavía"). Se dispara via ref.listen del provider central — no se
  /// lanza desde el viewmodel para evitar acoplar al BuildContext del
  /// shell con la lógica de sync.
  void _showSyncSnackBar(BuildContext context, OfflineQueueSyncResult r) {
    // Nota de dead-letter: acciones que agotaron reintentos y requieren
    // intervención manual. Se anexa a cualquier mensaje para que el cajero
    // sepa que hay operaciones atascadas que no reintentan solas.
    final deadNote =
        r.dead > 0 ? ' ${r.dead} sin resolver (requieren revisión).' : '';
    final Color bg;
    final String message;
    if (r.hasFailures) {
      bg = const Color(0xFFEF4444);
      message =
          'Sync parcial: ${r.completed} OK, ${r.failed} con error. Pendientes: ${r.pending}.$deadNote';
    } else if (r.hasConflicts) {
      // Sync completo pero con conflictos cross-device (ej: items
      // borrados por otro terminal, modificadores stale). Mostramos en
      // ambar para que destaque y ofrecemos acción "Ver detalle".
      bg = const Color(0xFFF59E0B);
      message =
          '${r.completed} sincronizada(s) — ${r.conflicts.length} con conflicto entre terminales.$deadNote';
    } else if (r.completed > 0) {
      bg = r.dead > 0 ? const Color(0xFFF59E0B) : const Color(0xFF22C55E);
      message = r.pending > 0
          ? '${r.completed} operación(es) sincronizada(s). Quedan ${r.pending} pendientes.$deadNote'
          : '${r.completed} operación(es) sincronizada(s). Cola al día.$deadNote';
    } else if (r.pending > 0) {
      // Sin trabajo hecho pero quedaron operaciones — típicamente sin red.
      bg = const Color(0xFFF59E0B);
      message = '${r.pending} operación(es) en espera de conexión.$deadNote';
    } else if (r.dead > 0) {
      // Solo dead-letter: nada que sincronizar pero hay atascadas.
      bg = const Color(0xFFEF4444);
      message =
          '${r.dead} operación(es) sin resolver. Revísalas desde el ícono de la cola.';
    } else {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: r.hasConflicts ? 8 : 4),
        content: Text(message),
        // Con fallos o dead-letter el detalle útil es la cola misma (tipo
        // de operación + last_error); con solo conflictos, el resumen de
        // conflictos cross-device.
        action: r.hasFailures || r.dead > 0
            ? SnackBarAction(
                label: 'Ver detalle',
                textColor: Colors.white,
                onPressed: () =>
                    unawaited(showOfflineQueueDetailDialog(context, ref)),
              )
            : r.hasConflicts
                ? SnackBarAction(
                    label: 'Ver detalle',
                    textColor: Colors.white,
                    onPressed: () => _showConflictsDialog(context, r.conflicts),
                  )
                : null,
      ),
    );
  }

  void _showConflictsDialog(
    BuildContext context,
    List<OfflineSyncConflict> conflicts,
  ) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B)),
            SizedBox(width: 8),
            Expanded(child: Text('Conflictos al sincronizar')),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Otro terminal modifico estos recursos mientras estabas '
                'offline. Las operaciones se completaron sin reintentar; '
                'revisa los totales y ajusta si hace falta.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: conflicts.length,
                  separatorBuilder: (_, _) => const Divider(height: 12),
                  itemBuilder: (_, i) {
                    final c = conflicts[i];
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.info_outline,
                            size: 16,
                            color: Color(0xFFF59E0B),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            c.reason,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }
}

class _OfflineQueueBadge extends ConsumerWidget {
  const _OfflineQueueBadge();

  Future<void> _showMenu(BuildContext context, WidgetRef ref) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;

    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    final hasDead = ref.read(offlineQueueStatusProvider).dead > 0;

    final action = await showMenu<String>(
      context: context,
      position: position,
      items: [
        // Visor de la cola: qué operaciones hay, en qué estado y con qué
        // error real — para diagnosticar antes de decidir limpiar.
        const PopupMenuItem(
          value: 'view',
          child: Row(
            children: [
              Icon(Icons.receipt_long_rounded,
                  size: 18, color: Color(0xFF111827)),
              SizedBox(width: 8),
              Text('Ver operaciones...'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'sync',
          child: Row(
            children: [
              Icon(Icons.sync_rounded, size: 18, color: Color(0xFF111827)),
              SizedBox(width: 8),
              Text('Sincronizar ahora'),
            ],
          ),
        ),
        // Solo si hay dead-letter: reintentar las que agotaron sus
        // reintentos (útil cuando el cajero corrigió la causa raíz).
        if (hasDead)
          const PopupMenuItem(
            value: 'retry_dead',
            child: Row(
              children: [
                Icon(Icons.replay_rounded, size: 18, color: Color(0xFFB45309)),
                SizedBox(width: 8),
                Text('Reintentar sin resolver',
                    style: TextStyle(color: Color(0xFFB45309))),
              ],
            ),
          ),
        const PopupMenuItem(
          value: 'clear',
          child: Row(
            children: [
              Icon(Icons.delete_outline,
                  size: 18, color: Color(0xFFEF4444)),
              SizedBox(width: 8),
              Text('Limpiar cola...',
                  style: TextStyle(color: Color(0xFFEF4444))),
            ],
          ),
        ),
      ],
    );

    if (!context.mounted) return;

    if (action == 'view') {
      await showOfflineQueueDetailDialog(context, ref);
    } else if (action == 'sync') {
      await ref
          .read(currentOrderProvider.notifier)
          .syncPendingOfflineActions(force: true);
    } else if (action == 'retry_dead') {
      await _retryDead(context, ref);
    } else if (action == 'clear') {
      await _confirmAndClear(context, ref);
    }
  }

  /// Resucita las acciones en dead-letter (vuelven a pending, intentos 0)
  /// y dispara un sync inmediato. Pensado para cuando el cajero corrigió
  /// la causa del atasco y quiere que reintenten.
  Future<void> _retryDead(BuildContext context, WidgetRef ref) async {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;

    final revived = await OfflinePosService().retryDeadActions(businessId);
    if (!context.mounted) return;
    if (revived == 0) {
      await ref.read(offlineQueueStatusProvider.notifier).refreshNow();
      return;
    }
    // Reactivadas → intentar sincronizar de inmediato.
    await ref
        .read(currentOrderProvider.notifier)
        .syncPendingOfflineActions(force: true);
    await ref.read(offlineQueueStatusProvider.notifier).refreshNow();
    if (!context.mounted) return;
    AppToast.info(
      context,
      '$revived operación(es) reencoladas para reintento.',
    );
  }

  Future<void> _confirmAndClear(
    BuildContext context,
    WidgetRef ref,
  ) async {
    // clearPendingActions borra todas las no-completadas (pendientes +
    // dead-letter); el conteo del aviso debe reflejar ambas para no
    // subestimar lo que se va a descartar.
    final status = ref.read(offlineQueueStatusProvider);
    final pending = status.pending + status.dead;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444)),
            SizedBox(width: 8),
            Expanded(child: Text('Limpiar cola offline')),
          ],
        ),
        content: Text(
          'Vas a descartar $pending operacion(es) pendiente(s) sin sincronizar al server. '
          'Solo usalo si estan bloqueadas por errores irresolubles (ej: referencias a recursos '
          'borrados). Las operaciones YA aplicadas en server NO se ven afectadas.\n\n'
          'Esta accion no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFEF4444)),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Limpiar'),
          ),
        ],
      ),
    );

    if (ok != true || !context.mounted) return;

    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;

    final deleted = await OfflinePosService().clearPendingActions(businessId);
    await ref.read(offlineQueueStatusProvider.notifier).refreshNow();
    if (!context.mounted) return;
    AppToast.success(
      context,
      'Cola limpiada: $deleted operacion(es) descartada(s).',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(offlineQueueStatusProvider);
    final count = status.pending;
    final dead = status.dead;
    final hasPending = count > 0;
    final hasDead = dead > 0;
    // El indicador se enciende con pendientes O con dead-letter: si todo
    // lo pendiente murió, `pending` sería 0 pero el cajero igual debe ver
    // que hay operaciones atascadas (en rojo, no en ámbar).
    final active = hasPending || hasDead;
    final total = count + dead;
    final badgeText = total > 99 ? '99+' : '$total';
    // Rojo = hay dead-letter (requiere acción). Ámbar = solo pendientes
    // (esperan conexión). Gris = todo al día.
    final accent = hasDead
        ? const Color(0xFFB91C1C)
        : const Color(0xFFB45309);

    return Tooltip(
      message: hasDead
          ? '$dead sin resolver (requieren revisión)'
              '${hasPending ? ' · $count pendiente(s)' : ''} — click para gestionar'
          : hasPending
              ? '$count operación(es) offline pendiente(s) — click para sync o limpiar'
              : 'Todo sincronizado',
      child: MouseRegion(
        cursor: active
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: active ? () => _showMenu(context, ref) : null,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: hasDead
                      ? const Color(0xFFFEE2E2)
                      : hasPending
                          ? const Color(0xFFFFF3CD)
                          : Colors.grey[100],
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  hasDead
                      ? Icons.error_outline_rounded
                      : hasPending
                          ? Icons.cloud_off_rounded
                          : Icons.cloud_done_rounded,
                  color: active ? accent : Colors.grey[500],
                ),
              ),
              if (active)
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    constraints: const BoxConstraints(
                      minWidth: 18,
                      minHeight: 18,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      badgeText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        height: 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Visor de la cola offline: lista cada operación no sincronizada con su
/// estado, intentos y el último error real (`last_error`). Antes este
/// detalle no era visible en ninguna vista, así que un atasco solo tenía
/// una salida: "Limpiar cola" a ciegas (perdiendo las operaciones). Desde
/// aquí el cajero diagnostica y puede forzar un sync que también reintenta
/// las dead-letter.
Future<void> showOfflineQueueDetailDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final businessId = ref.read(sessionProvider).activeBusinessId;
  if (businessId == null || businessId.isEmpty) return;

  final actions = await OfflinePosService().unsettledActions(businessId);
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.receipt_long_rounded, color: Color(0xFF111827)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              actions.isEmpty
                  ? 'Operaciones offline'
                  : 'Operaciones offline (${actions.length})',
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: actions.isEmpty
            ? const Text('No hay operaciones pendientes. Cola al día.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Estas operaciones aún no llegan al servidor. Las '
                    'marcadas "Sin resolver" agotaron sus reintentos '
                    'automáticos; "Sincronizar ahora" las reintenta todas.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 380),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: actions.length,
                        separatorBuilder: (_, _) => const Divider(height: 16),
                        itemBuilder: (_, i) =>
                            _OfflineQueueActionRow(action: actions[i]),
                      ),
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cerrar'),
        ),
        if (actions.isNotEmpty)
          FilledButton.icon(
            icon: const Icon(Icons.sync_rounded, size: 18),
            label: const Text('Sincronizar ahora'),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              unawaited(ref
                  .read(currentOrderProvider.notifier)
                  .syncPendingOfflineActions(force: true));
            },
          ),
      ],
    ),
  );
}

/// Fila del visor: tipo legible + contexto (producto/monto), estado,
/// intentos y último error de la operación encolada.
class _OfflineQueueActionRow extends StatelessWidget {
  const _OfflineQueueActionRow({required this.action});

  final Map<String, dynamic> action;

  static String _label(String? type) {
    switch (type) {
      case 'add_item':
        return 'Agregar producto';
      case 'delete_item':
        return 'Eliminar producto';
      case 'update_item_quantity':
        return 'Cambiar cantidad';
      case 'update_item_notes':
        return 'Editar notas';
      case 'toggle_item_takeout':
        return 'Producto para llevar';
      case 'move_item_to_check':
        return 'Mover a otra cuenta';
      case 'mark_order_takeout':
        return 'Orden para llevar';
      case 'process_payment':
        return 'Cobro';
      case 'void_order':
        return 'Anular orden';
      case 'send_to_kitchen':
        return 'Enviar a cocina';
      case 'confirm_local_order':
        return 'Crear orden';
      case 'open_table':
        return 'Abrir mesa';
      case 'open_cash_session':
        return 'Apertura de caja';
      case 'close_cash_session':
        return 'Cierre de caja';
      case 'cash_transaction':
        return 'Movimiento de caja';
      case 'inventory_adjust':
        return 'Ajuste de inventario';
      case 'inventory_movement':
        return 'Movimiento de inventario';
      case 'kds_item_status':
        return 'Estado de cocina (KDS)';
      case 'set_delivery_fee':
        return 'Fee de delivery';
      case 'add_item_modifier':
        return 'Modificadores de producto';
      default:
        return type == null || type.isEmpty ? 'Operación' : type;
    }
  }

  /// Contexto corto según el tipo: producto ×cantidad para acciones de
  /// items, monto para cobros/movimientos de caja.
  static String? _detail(Map<String, dynamic> a) {
    final product = a['product_name']?.toString().trim();
    if (product != null && product.isNotEmpty) {
      final qty = (a['qty'] ?? a['quantity']) as num?;
      if (qty != null && qty > 0) {
        final q = qty == qty.truncateToDouble()
            ? qty.toInt().toString()
            : qty.toString();
        return '$product ×$q';
      }
      return product;
    }
    final amount = (a['amount'] as num?)?.toDouble();
    if (amount != null && amount > 0) {
      return 'Monto: ${amount.toStringAsFixed(2)}';
    }
    return null;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final status = action['status']?.toString() ?? 'pending';
    final isDead = status == 'dead';
    final attempts = (action['attempts'] as num?)?.toInt() ?? 0;
    final lastError = action['last_error']?.toString().trim();
    final queuedAt =
        DateTime.tryParse(action['queued_at']?.toString() ?? '')?.toLocal();

    final String chipLabel;
    final Color chipColor;
    if (isDead) {
      chipLabel = 'Sin resolver';
      chipColor = const Color(0xFFB91C1C);
    } else if (status == 'failed') {
      chipLabel = 'Con error';
      chipColor = const Color(0xFFB45309);
    } else if (status == 'processing') {
      chipLabel = 'En proceso';
      chipColor = const Color(0xFF2563EB);
    } else {
      chipLabel = 'Pendiente';
      chipColor = const Color(0xFF6B7280);
    }

    final detail = _detail(action);
    final meta = [
      if (queuedAt != null)
        'Encolada ${_two(queuedAt.day)}/${_two(queuedAt.month)} '
            '${_two(queuedAt.hour)}:${_two(queuedAt.minute)}',
      if (attempts > 0) '$attempts intento(s)',
    ].join(' · ');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            isDead ? Icons.error_outline_rounded : Icons.schedule_rounded,
            size: 18,
            color: chipColor,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _label(action['type']?.toString()),
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: chipColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      chipLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: chipColor,
                      ),
                    ),
                  ),
                ],
              ),
              if (detail != null)
                Text(
                  detail,
                  style: TextStyle(fontSize: 12.5, color: Colors.grey[700]),
                ),
              if (meta.isNotEmpty)
                Text(
                  meta,
                  style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
                ),
              if (lastError != null && lastError.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    lastError,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFFB91C1C),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ===== ITEM DEL MENÚ (PILL SHAPE) =====
class _TopNavItem extends ConsumerStatefulWidget {
  final ShellDestination destination;
  final StatefulNavigationShell navigationShell;
  const _TopNavItem({
    required this.destination,
    required this.navigationShell,
  });

  @override
  ConsumerState<_TopNavItem> createState() => _TopNavItemState();
}

class _TopNavItemState extends ConsumerState<_TopNavItem> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    ref.watch(sessionProvider);
    final d = widget.destination;
    final hasAccess = d.permissionCode == null ||
        ref
            .read(sessionProvider.notifier)
            .hasPermission(d.permissionCode!);
    final loc = GoRouterState.of(context).uri.toString();
    final active = isDestinationActive(d, loc);

    // Tres tiers de densidad para el top nav:
    //   - < 900px (teléfono / tablet en portrait apretado): solo icono +
    //     tooltip. La barra cabe sin overflow y el cajero ve todos los destinos.
    //   - 900-1279px (tablets en landscape, monitores 1024×768): icono +
    //     label en modo compacto (font 13, padding 12). Los 7 destinos +
    //     logo + chip de rol caben sin recortar.
    //   - ≥ 1280px (desktop): icono + label en modo cómodo (font 15, padding 16).
    final width = MediaQuery.of(context).size.width;
    final showLabel = width >= 900;
    final labelCompact = width < 1280;
    final iconColor = hasAccess
        ? (active ? Colors.white : Colors.grey[600]!)
        : Colors.grey[500]!;
    final labelColor = hasAccess
        ? (active ? Colors.white : Colors.grey[700]!)
        : Colors.grey[500]!;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      cursor: hasAccess
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden,
      child: Tooltip(
        // En modo compact (sin labels) el tooltip da accesibilidad —
        // muestra "Dashboard", "Ventas", etc. al hover/long-press.
        // Cuando hay label visible, el tooltip queda como reinforcement.
        message: d.label,
        waitDuration: const Duration(milliseconds: 400),
        child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: hasAccess
            ? () => goToShellDestination(
                  context,
                  widget.navigationShell,
                  d.route,
                )
            : null,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: showLabel ? (labelCompact ? 12 : 16) : 10,
            vertical: 8,
          ),
          decoration: BoxDecoration(
            color: hasAccess
                ? (active
                      ? MangoColors.primaryOrange
                      : (_isHovering
                            ? const Color(0xFFF7F7F9)
                            : Colors.transparent))
                : const Color(0xFFF7F7F9),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (d.svgAsset != null)
                SvgPicture.asset(
                  d.svgAsset!,
                  width: 22,
                  height: 22,
                  colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
                )
              else
                Icon(d.materialIcon, size: 22, color: iconColor),
              if (showLabel) ...[
                SizedBox(width: labelCompact ? 6 : 8),
                Text(
                  d.label,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: labelCompact ? 13 : 15,
                    fontWeight: active && hasAccess
                        ? FontWeight.bold
                        : FontWeight.w600,
                    color: labelColor,
                  ),
                ),
              ],
              if (!hasAccess) ...[
                const SizedBox(width: 6),
                const Icon(Icons.lock_outline, size: 14, color: Colors.grey),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }
}

// ===== FULLSCREEN BUTTON =====
class _FullscreenButton extends StatefulWidget {
  const _FullscreenButton();

  @override
  State<_FullscreenButton> createState() => _FullscreenButtonState();
}

class _FullscreenButtonState extends State<_FullscreenButton> {
  final FullscreenService _service = createFullscreenService();
  bool _supported = false;
  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final supported = await _service.isSupported();
    final fullscreen = supported ? await _service.isFullscreen() : false;
    if (!mounted) return;
    setState(() {
      _supported = supported;
      _fullscreen = fullscreen;
    });
  }

  Future<void> _toggle() async {
    if (!_supported) return;
    await _service.toggleFullscreen();
    await _loadState();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) {
      return const SizedBox.shrink();
    }

    return Tooltip(
      message: _fullscreen ? 'Salir de pantalla completa' : 'Pantalla completa',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _toggle,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.grey[100],
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              _fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
              color: Colors.grey[700],
            ),
          ),
        ),
      ),
    );
  }
}

// ===== Caja cuadrada para el icono =====
class _SquareIconBox extends StatelessWidget {
  final Widget child;
  final double size;
  const _SquareIconBox({required this.child, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final resolvedSize = context.iconSizeOf(size);
    return Container(
      width: resolvedSize,
      height: resolvedSize,
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F9),
        border: Border.all(color: const Color(0xFFEAEAEA)),
        borderRadius: BorderRadius.circular(15),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}

// ===== Indicador de conexión (solo icono) =====
class _ConnectionIndicator extends StatefulWidget {
  const _ConnectionIndicator();

  @override
  State<_ConnectionIndicator> createState() => _ConnectionIndicatorState();
}

class _ConnectionIndicatorState extends State<_ConnectionIndicator> {
  bool _online = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _checkNow();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _checkNow());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _checkNow() async {
    final ok = await _hasInternet();
    if (mounted && ok != _online) setState(() => _online = ok);
  }

  Future<bool> _hasInternet() async {
    try {
      final res = await http
          .head(Uri.parse('https://www.gstatic.com/generate_204'))
          .timeout(const Duration(seconds: 2));
      return res.statusCode == 204 || res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _online ? MangoColors.successGreen : Colors.redAccent;
    final iconSize = context.iconSizeOf(26);

    return _SquareIconBox(
      size: 44,
      child: SvgPicture.asset(
        'assets/icons/conexion.svg',
        width: iconSize,
        height: iconSize,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      ),
    );
  }
}

// ===== LOGO =====
class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    // final logoHeight = context.hp(context.isMobile ? 6 : 5);
    return Image.asset(
      'assets/images/Logo Completo.png',
      height: 32, // Más compacto y elegante para el Dashboard
      fit: BoxFit.contain,
    );
  }
}

// ===== USER INFO =====
class _UserInfo extends ConsumerWidget {
  const _UserInfo();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final ctrl = ref.read(sessionProvider.notifier);
    final role = session.activeRole;
    final roleLabel = role?.label ?? 'Sin rol';
    final businessName = session.activeBusinessName?.trim().isNotEmpty == true
        ? session.activeBusinessName!.trim()
        : 'Negocio';

    // Alertas de inventario (antes badges del header): se muestran dentro del
    // menú del usuario. El avatar lleva un punto rojo si hay alguna activa.
    final lowStockCount = ref
        .watch(lowStockBadgeCountProvider)
        .maybeWhen(data: (v) => v, orElse: () => 0);
    final expiringLotsCount = ref
        .watch(expiringLotsBadgeCountProvider)
        .maybeWhen(data: (v) => v, orElse: () => 0);
    final hasInventoryAlerts = lowStockCount > 0 || expiringLotsCount > 0;

    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Hola, ${session.userName ?? 'Usuario'}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 4),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                InkWell(
                  onTap: session.availableRoles.length > 1
                      ? () async {
                          final selected = await showMenu<PosRole>(
                            context: context,
                            position: const RelativeRect.fromLTRB(0, 64, 24, 0),
                            items: session.availableRoles
                                .map(
                                  (r) => PopupMenuItem<PosRole>(
                                    value: r,
                                    child: Row(
                                      children: [
                                        if (r == role)
                                          const Padding(
                                            padding: EdgeInsets.only(right: 8),
                                            child: Icon(Icons.check, size: 14),
                                          ),
                                        Text(r.label),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                          );
                          if (selected != null) {
                            ctrl.switchRole(selected);
                          }
                        }
                      : null,
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      roleLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF475569),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(width: 8),
        PopupMenuButton<_UserMenuAction>(
          tooltip: 'Menu de usuario',
          color: Colors.white,
          surfaceTintColor: Colors.white,
          shadowColor: const Color(0x14000000),
          elevation: 10,
          constraints: const BoxConstraints(minWidth: 300, maxWidth: 300),
          menuPadding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFFE5E7EB)),
          ),
          style: const ButtonStyle(
            overlayColor: WidgetStatePropertyAll(Colors.transparent),
            splashFactory: NoSplash.splashFactory,
          ),
          offset: const Offset(0, 12),
          onSelected: (value) async {
            switch (value) {
              case _UserMenuAction.switchBranch:
                final selected = await _showBranchPicker(context, session, ctrl);
                if (selected != null && context.mounted) {
                  context.go(AppRoutes.dashboard);
                }
                break;
              case _UserMenuAction.manageBranches:
                context.go(AppRoutes.settingsBranches);
                break;
              case _UserMenuAction.plan:
                context.go(AppRoutes.settingsPlan);
                break;
              case _UserMenuAction.settings:
                context.go(AppRoutes.settings);
                break;
              case _UserMenuAction.lowStock:
                context.go(AppRoutes.inventoryLowStock);
                break;
              case _UserMenuAction.expiringLots:
                context.go(AppRoutes.inventoryLots);
                break;
              case _UserMenuAction.logout:
                final proceed = await confirmLogoutDiscardingOffline(
                    context, session.activeBusinessId);
                if (!proceed || !context.mounted) break;
                await ctrl.signOut();
                if (!context.mounted) return;
                context.go(AppRoutes.login);
                break;
            }
          },
          itemBuilder: (_) {
            // Gates por rol/permiso para el menú de usuario. La idea es
            // que un cajero/mesero/cocina NO vea opciones de admin
            // (Gestionar sucursales, Mejorar plan, Ajustes) — quedan
            // ocultas, no solo deshabilitadas. La home del rol siempre
            // está disponible vía la navegación principal del shell.
            final isAdminLevel =
                session.activeRole == PosRole.administrador;
            final canOpenSettings =
                ctrl.hasPermission('settings.usuarios.acceso');
            final canSwitchBranch = session.availableBusinesses.length > 1;
            return [
              PopupMenuItem<_UserMenuAction>(
                enabled: false,
                padding: EdgeInsets.zero,
                height: 88,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF0E7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.storefront_rounded,
                          color: MangoColors.primaryOrange,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              businessName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                                color: Color(0xFF1F2937),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Sesion activa como $roleLabel',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF6B7280),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem<_UserMenuAction>(
                value: _UserMenuAction.lowStock,
                padding: EdgeInsets.zero,
                height: 56,
                child: _UserMenuTile(
                  icon: lowStockCount > 0
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_none,
                  label: 'Alertas de stock bajo',
                  accent: const Color(0xFFFFE9E0),
                  iconColor: const Color(0xFFDC2626),
                  badgeCount: lowStockCount,
                  badgeColor: const Color(0xFFDC2626),
                ),
              ),
              PopupMenuItem<_UserMenuAction>(
                value: _UserMenuAction.expiringLots,
                padding: EdgeInsets.zero,
                height: 56,
                child: _UserMenuTile(
                  icon: expiringLotsCount > 0
                      ? Icons.event_busy_rounded
                      : Icons.event_note_outlined,
                  label: 'Lotes por vencer',
                  accent: const Color(0xFFFFEAD9),
                  iconColor: const Color(0xFFC2410C),
                  badgeCount: expiringLotsCount,
                  badgeColor: const Color(0xFFC2410C),
                ),
              ),
              const PopupMenuDivider(height: 1),
              if (canSwitchBranch)
                PopupMenuItem<_UserMenuAction>(
                  value: _UserMenuAction.switchBranch,
                  padding: EdgeInsets.zero,
                  height: 56,
                  child: const _UserMenuTile(
                    icon: Icons.swap_horiz_rounded,
                    label: 'Cambiar sucursal',
                    accent: Color(0xFFEAFBF3),
                    iconColor: Color(0xFF059669),
                  ),
                ),
              if (isAdminLevel)
                const PopupMenuItem<_UserMenuAction>(
                  value: _UserMenuAction.manageBranches,
                  padding: EdgeInsets.zero,
                  height: 56,
                  child: _UserMenuTile(
                    icon: Icons.apartment_rounded,
                    label: 'Gestionar sucursales',
                    accent: Color(0xFFFFF0D9),
                    iconColor: MangoColors.primaryOrange,
                  ),
                ),
              if (isAdminLevel)
                const PopupMenuItem<_UserMenuAction>(
                  value: _UserMenuAction.plan,
                  padding: EdgeInsets.zero,
                  height: 56,
                  child: _UserMenuTile(
                    icon: Icons.rocket_launch_rounded,
                    label: 'Mejorar plan',
                    accent: Color(0xFFFFF0D9),
                    iconColor: MangoColors.primaryOrange,
                  ),
                ),
              if (canOpenSettings)
                const PopupMenuItem<_UserMenuAction>(
                  value: _UserMenuAction.settings,
                  padding: EdgeInsets.zero,
                  height: 56,
                  child: _UserMenuTile(
                    icon: Icons.settings_rounded,
                    label: 'Ajustes del sistema',
                    accent: Color(0xFFEAF0FF),
                    iconColor: Color(0xFF2563EB),
                  ),
                ),
              const PopupMenuDivider(height: 1),
              const PopupMenuItem<_UserMenuAction>(
                value: _UserMenuAction.logout,
                padding: EdgeInsets.zero,
                height: 56,
                child: _UserMenuTile(
                  icon: Icons.logout_rounded,
                  label: 'Cerrar sesion',
                  accent: Color(0xFFFFE7E7),
                  iconColor: Color(0xFFDC2626),
                  textColor: Color(0xFFDC2626),
                ),
              ),
              const PopupMenuDivider(height: 1),
              const PopupMenuItem<_UserMenuAction>(
                enabled: false,
                padding: EdgeInsets.zero,
                height: 40,
                child: ColoredBox(
                  color: Color(0xFFF8FAFC),
                  child: Center(
                    child: Text(
                      'version ${String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0')}',
                      style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                    ),
                  ),
                ),
              ),
            ];
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFFF97316), Color(0xFFFFB74D)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1FF97316),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(Icons.person, color: Colors.white, size: 20),
              ),
              // Punto rojo: hay alertas de inventario (stock bajo o
              // vencimientos) sin revisar; el detalle vive en el menú.
              if (hasInventoryAlerts)
                Positioned(
                  top: -1,
                  right: -1,
                  child: Container(
                    width: 13,
                    height: 13,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<SessionBusiness?> _showBranchPicker(
  BuildContext context,
  SessionState session,
  SessionController ctrl,
) async {
  return showModalBottomSheet<SessionBusiness>(
    context: context,
    backgroundColor: Colors.white,
    showDragHandle: true,
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFF97316), Color(0xFFFBAA16)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cambiar sucursal',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Cada sucursal trabaja con sus propios datos. Cambiar aquí cambia el negocio activo del panel.',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              for (final branch in session.availableBusinesses)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: branch.id == session.activeBusinessId
                          ? const Color(0xFFFED7AA)
                          : const Color(0xFFE5E7EB),
                    ),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    leading: CircleAvatar(
                      backgroundColor: branch.id == session.activeBusinessId
                          ? const Color(0xFFFFE8D6)
                          : const Color(0xFFF3F4F6),
                      child: Icon(
                        branch.id == session.activeBusinessId
                            ? Icons.check_rounded
                            : Icons.storefront_rounded,
                        color: branch.id == session.activeBusinessId
                            ? MangoColors.primaryOrange
                            : const Color(0xFF6B7280),
                      ),
                    ),
                    title: Text(
                      branch.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(branch.companyName ?? branch.roleLabel),
                    trailing: branch.id == session.activeBusinessId
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFECFDF5),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              'Actual',
                              style: TextStyle(
                                color: Color(0xFF059669),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      await ctrl.switchBusiness(branch.id);
                      if (!context.mounted) return;
                      Navigator.of(context).pop(branch);
                    },
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

enum _UserMenuAction {
  switchBranch,
  manageBranches,
  plan,
  settings,
  lowStock,
  expiringLots,
  logout,
}

class _UserMenuTile extends StatelessWidget {
  const _UserMenuTile({
    required this.icon,
    required this.label,
    required this.accent,
    required this.iconColor,
    this.textColor,
    this.badgeCount,
    this.badgeColor,
  });

  final IconData icon;
  final String label;
  final Color accent;
  final Color iconColor;
  final Color? textColor;
  final int? badgeCount;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: textColor ?? const Color(0xFF374151),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if ((badgeCount ?? 0) > 0) ...[
            Container(
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: badgeColor ?? const Color(0xFFDC2626),
                borderRadius: BorderRadius.circular(999),
              ),
              alignment: Alignment.center,
              child: Text(
                badgeCount! > 99 ? '99+' : '$badgeCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: (textColor ?? const Color(0xFF9CA3AF)).withValues(
              alpha: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

/// Badge del estado de la conexión BLE persistente con impresoras Bluetooth
/// (PRD BT — observabilidad). Se oculta cuando no hay impresoras BT
/// persistentes (idle); azul = conectada, amarillo = reconectando.
class _BlePrinterBadge extends ConsumerWidget {
  const _BlePrinterBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overall = ref.watch(blePrinterOverallProvider);
    if (overall == BlePrinterOverall.idle) return const SizedBox.shrink();

    final bool connected = overall == BlePrinterOverall.connected;
    final Color bg =
        connected ? const Color(0xFFDBEAFE) : const Color(0xFFFEF3C7);
    final Color fg =
        connected ? const Color(0xFF1E40AF) : const Color(0xFFB45309);
    final IconData icon =
        connected ? Icons.bluetooth_connected : Icons.bluetooth_searching;
    final String tooltip = connected
        ? 'Impresora Bluetooth conectada'
        : 'Reconectando impresora Bluetooth…';

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: fg),
        ),
      ),
    );
  }
}

/// Badge de salud de impresoras en tiempo real. Se actualiza cada 30s
/// vía `printerHeartbeatProvider`. Estados visuales:
///   - 🟢 verde:    todas las impresoras de red OK.
///   - 🟡 amarillo: al menos una offline (click muestra cuáles).
///   - ⚪ gris:     aún sondeando o ninguna impresora configurada.
///
/// El badge solo cuenta impresoras de red. USB/Bluetooth viven en el
/// agent local y tienen su propio path de error visible al imprimir.
class _PrinterHeartbeatBadge extends ConsumerWidget {
  const _PrinterHeartbeatBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final businessId = session.activeBusinessId ?? '';
    if (businessId.isEmpty) return const SizedBox.shrink();

    final heartbeatAsync = ref.watch(printerHeartbeatProvider(businessId));
    final snapshot = heartbeatAsync.value;

    final Color bg;
    final Color fg;
    final IconData icon;
    String tooltip;
    int offlineCount = 0;

    if (snapshot == null || !snapshot.hasPrinters) {
      bg = const Color(0xFFF1F5F9);
      fg = const Color(0xFF6B7280);
      icon = Icons.print_outlined;
      tooltip = snapshot == null
          ? 'Sondeando impresoras...'
          : 'No hay impresoras de red configuradas';
    } else if (snapshot.allOnline) {
      bg = const Color(0xFFD1FAE5);
      fg = const Color(0xFF065F46);
      icon = Icons.print_outlined;
      tooltip = 'Todas las impresoras responden '
          '(${snapshot.statuses.length})';
    } else {
      offlineCount = snapshot.offline.length;
      bg = const Color(0xFFFEF3C7);
      fg = const Color(0xFFB45309);
      icon = Icons.print_disabled_outlined;
      final names = snapshot.offline
          .map((s) => s.name)
          .where((n) => n.trim().isNotEmpty)
          .join(', ');
      tooltip = '$offlineCount impresora(s) sin conexión'
          '${names.isEmpty ? '' : ': $names'}';
    }

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: snapshot != null && snapshot.hasPrinters
            ? () => _showDetail(context, snapshot)
            : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: fg),
              if (offlineCount > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '$offlineCount',
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showDetail(BuildContext context, PrinterHeartbeatSnapshot snap) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final ordered = snap.statuses.values.toList()
          ..sort((a, b) {
            if (a.online == b.online) return a.name.compareTo(b.name);
            return a.online ? 1 : -1; // offline arriba
          });
        return AlertDialog(
          title: const Text('Estado de impresoras'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final s in ordered) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      s.online ? Icons.check_circle : Icons.error_outline,
                      color: s.online
                          ? const Color(0xFF10B981)
                          : const Color(0xFFEF4444),
                    ),
                    title: Text(
                      s.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      s.online
                          ? 'Conectada · ${s.ipAddress ?? '-'}'
                          : 'Sin respuesta · ${s.ipAddress ?? '-'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Última revisión: '
                    '${snap.lastUpdated.toLocal().toString().substring(11, 19)}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cerrar'),
            ),
          ],
        );
      },
    );
  }
}
