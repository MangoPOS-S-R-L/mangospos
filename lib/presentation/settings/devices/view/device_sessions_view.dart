import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/core/utils/device_utils.dart';
import 'package:mangopos/data/models/device_session.dart';
import 'package:mangopos/data/repositories/device_sessions_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// Ajustes → Dispositivos conectados.
///
/// Equipos con una sesión abierta en el negocio activo (tabla
/// `device_sessions`, migración 20260918_0001). El dueño/admin puede
/// ponerle nombre a cada equipo y pedirle que cierre su sesión: el equipo
/// obedece en su próximo ping (≤5 min), ver `DeviceSessionReporter`.
class DeviceSessionsView extends ConsumerStatefulWidget {
  const DeviceSessionsView({super.key});

  @override
  ConsumerState<DeviceSessionsView> createState() => _DeviceSessionsViewState();
}

class _DeviceSessionsViewState extends ConsumerState<DeviceSessionsView> {
  /// Mientras la pantalla está abierta se relee sola, para que un cierre
  /// pedido pase de "pendiente" a desaparecer sin tocar nada.
  static const _autoRefresh = Duration(minutes: 1);

  List<DeviceSession> _sessions = const [];
  String? _thisDeviceId;
  bool _loading = true;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    _timer = Timer.periodic(_autoRefresh, (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<String?> _businessId() async {
    final fromSession = ref.read(sessionProvider).activeBusinessId;
    if (fromSession != null && fromSession.isNotEmpty) return fromSession;
    return resolveBusinessIdOrNull(Supabase.instance.client, 'auto');
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final businessId = await _businessId();
      if (businessId == null) {
        throw StateError('No se pudo identificar el negocio.');
      }
      final repo = ref.read(deviceSessionsRepositoryProvider);
      final results = await Future.wait([
        repo.list(businessId),
        DeviceUtils.getDeviceId(),
      ]);
      if (!mounted) return;
      setState(() {
        _sessions = results[0] as List<DeviceSession>;
        _thisDeviceId = results[1] as String;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // En el refresco automático no tapamos la lista por un fallo de red.
      if (silent && _sessions.isNotEmpty) return;
      setState(() {
        _loading = false;
        _error = e is StateError
            ? e.message
            : DeviceSessionsRepository.humanizeError(e);
      });
    }
  }

  Future<void> _revoke(DeviceSession s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('¿Cerrar la sesión de "${s.displayName}"?'),
        content: Text(
          'El equipo cerrará la sesión en su próximo contacto con el '
          'servidor: máximo 5 minutos, o apenas vuelvan a abrir la app. Si '
          'está sin internet, la cerrará al reconectarse.\n\n'
          'Si alguien está cobrando en ese equipo, se le interrumpe lo que '
          'esté haciendo. Las ventas pendientes de sincronizar no se '
          'pierden.\n\n'
          'Esto no bloquea la cuenta: la persona puede volver a iniciar '
          'sesión. Para impedirlo, cambia la contraseña de '
          '${s.userEmail ?? 'esa cuenta'}.',
          style: const TextStyle(height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.destructive,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Cerrar sesión'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref.read(deviceSessionsRepositoryProvider).revoke(s.id);
      if (!mounted) return;
      AppToast.success(
        context,
        'Listo. "${s.displayName}" cerrará la sesión en su próximo contacto.',
      );
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, DeviceSessionsRepository.humanizeError(e));
    }
  }

  Future<void> _rename(DeviceSession s) async {
    final controller = TextEditingController(text: s.label ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nombre del dispositivo'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Nombre',
            hintText: 'Ej. Tablet barra / Caja principal',
            helperText: 'Déjalo vacío para usar "${s.deviceName ?? 'Dispositivo'}".',
          ),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value == (s.label ?? '')) return;

    try {
      await ref.read(deviceSessionsRepositoryProvider).rename(s.id, value);
      if (!mounted) return;
      AppToast.success(context, 'Nombre guardado.');
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, DeviceSessionsRepository.humanizeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final businessName = ref.watch(
      sessionProvider.select((s) => s.activeBusinessName),
    );
    return Scaffold(
      backgroundColor: AppColors.background,
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
        title: const Text('Dispositivos conectados'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Actualizar',
          ),
        ],
      ),
      body: _buildBody(businessName),
    );
  }

  Widget _buildBody(String? businessName) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: MangoColors.primaryOrange),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.destructive),
              ),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _load, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }

    final online = _sessions.where((s) => s.isOnline).length;
    final idle = _sessions.length - online;

    return RefreshIndicator(
      onRefresh: _load,
      color: MangoColors.primaryOrange,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(16),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              _Summary(
                businessName: businessName,
                online: online,
                idle: idle,
              ),
              const SizedBox(height: 12),
              if (_sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Text(
                    'No hay dispositivos con sesión abierta.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.mutedForeground),
                  ),
                )
              else
                for (final s in _sessions) ...[
                  _DeviceSessionCard(
                    session: s,
                    isThisDevice: s.deviceId == _thisDeviceId,
                    onRevoke: () => _revoke(s),
                    onRename: () => _rename(s),
                  ),
                  const SizedBox(height: 12),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  final String? businessName;
  final int online;
  final int idle;

  const _Summary({
    required this.businessName,
    required this.online,
    required this.idle,
  });

  @override
  Widget build(BuildContext context) {
    final where = (businessName == null || businessName!.trim().isEmpty)
        ? 'este negocio'
        : businessName!.trim();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.infoSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.infoBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: AppColors.info, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Equipos con sesión abierta en $where: $online en línea'
              '${idle > 0 ? ', $idle sin actividad reciente' : ''}. '
              'Cada equipo reporta cada 5 minutos mientras la app está '
              'abierta.',
              style: const TextStyle(fontSize: 13, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceSessionCard extends StatelessWidget {
  final DeviceSession session;
  final bool isThisDevice;
  final VoidCallback onRevoke;
  final VoidCallback onRename;

  const _DeviceSessionCard({
    required this.session,
    required this.isThisDevice,
    required this.onRevoke,
    required this.onRename,
  });

  static final _dateFmt = DateFormat('dd/MM/yyyy h:mm a', 'es_DO');

  IconData get _platformIcon => switch (session.platform) {
        'android' => Icons.tablet_android_rounded,
        'ios' => Icons.tablet_mac_rounded,
        'windows' => Icons.desktop_windows_rounded,
        'macos' => Icons.laptop_mac_rounded,
        'linux' => Icons.computer_rounded,
        'web' => Icons.language_rounded,
        _ => Icons.devices_other_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final s = session;
    final details = <String>[
      if (s.signedInAt != null)
        'Sesión desde ${_dateFmt.format(s.signedInAt!.toLocal())}',
      if (s.appVersion != null) 'v${s.appVersion}',
      // Con etiqueta, el nombre técnico queda como referencia.
      if (s.label != null && s.deviceName != null)
        s.hostname != null ? '${s.deviceName} · ${s.hostname}' : s.deviceName!,
    ];
    final showEmail = s.userName != null && s.userEmail != null;
    final showEmployee =
        s.employeeName != null && s.employeeName != s.userName;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: s.isRevokePending
            ? Border.all(color: AppColors.warningBorder)
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _platformIcon,
                color: s.isOnline
                    ? MangoColors.primaryOrange
                    : AppColors.mutedForeground,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      s.displayName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (isThisDevice)
                      const _Pill(
                        text: 'Este dispositivo',
                        color: AppColors.success,
                      ),
                  ],
                ),
              ),
              _StatusPill(session: s),
              PopupMenuButton<String>(
                tooltip: 'Opciones',
                onSelected: (value) {
                  if (value == 'rename') onRename();
                  if (value == 'revoke') onRevoke();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'rename',
                    child: Text('Ponerle nombre'),
                  ),
                  // Para este equipo se usa el "Cerrar sesión" normal.
                  if (!isThisDevice)
                    PopupMenuItem(
                      value: 'revoke',
                      enabled: !s.isRevokePending,
                      child: Text(
                        s.isRevokePending
                            ? 'Cierre ya solicitado'
                            : 'Cerrar sesión',
                        style: TextStyle(
                          color: s.isRevokePending
                              ? null
                              : AppColors.destructive,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 36, right: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoLine(
                  icon: Icons.person_outline_rounded,
                  text: showEmail
                      ? '${s.accountLabel} · ${s.userEmail}'
                      : s.accountLabel,
                ),
                if (showEmployee)
                  _InfoLine(
                    icon: Icons.badge_outlined,
                    text: 'Empleado activo: ${s.employeeName}',
                  ),
                if (details.isNotEmpty)
                  _InfoLine(
                    icon: Icons.schedule_rounded,
                    text: details.join(' · '),
                    muted: true,
                  ),
                if (s.isRevokePending)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Cierre de sesión solicitado'
                      '${s.revokedByName != null ? ' por ${s.revokedByName}' : ''}'
                      '. Se aplicará cuando el equipo se conecte.',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.warning,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final DeviceSession session;

  const _StatusPill({required this.session});

  @override
  Widget build(BuildContext context) {
    if (session.isRevokePending) {
      return const _Pill(text: 'Cierre pendiente', color: AppColors.warning);
    }
    if (session.isOnline) {
      return const _Pill(text: 'En línea', color: AppColors.success, dot: true);
    }
    return _Pill(
      text: 'Activo ${formatIdle(session.idleSeconds)}',
      color: AppColors.mutedForeground,
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  final bool dot;

  const _Pill({required this.text, required this.color, this.dot = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool muted;

  const _InfoLine({required this.icon, required this.text, this.muted = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.mutedForeground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.3,
                color: muted ? AppColors.mutedForeground : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
