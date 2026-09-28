import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:mangopos/core/auth/offline_auth_service.dart';
import 'package:mangopos/core/offline/offline_readiness_provider.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

/// PIN synchronization status, with optional legacy terminal registration.
class DeviceBindingView extends ConsumerStatefulWidget {
  const DeviceBindingView({super.key, this.service});

  final OfflineAuthService? service;

  @override
  ConsumerState<DeviceBindingView> createState() => _DeviceBindingViewState();
}

class _DeviceBindingViewState extends ConsumerState<DeviceBindingView> {
  OfflineAuthService get _service => widget.service ?? OfflineAuthService();
  final _deviceNameCtrl = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  bool _bound = false;
  String? _boundBusinessId;
  DateTime? _lastSyncAt;
  int _rosterCount = 0;
  String? _errorMessage;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _deviceNameCtrl.text = _suggestDeviceName();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _deviceNameCtrl.dispose();
    super.dispose();
  }

  String _suggestDeviceName() {
    if (kIsWeb) return 'Terminal Web';
    if (Platform.isAndroid) return 'Terminal Android';
    if (Platform.isIOS) return 'Terminal iOS';
    if (Platform.isMacOS) return 'Terminal Mac';
    if (Platform.isWindows) return 'Terminal Windows';
    if (Platform.isLinux) return 'Terminal Linux';
    return 'Terminal POS';
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final bound = await _service.isDeviceBound();
      final boundBusiness = await _service.currentBoundBusinessId();
      final businessId = ref.read(sessionProvider).activeBusinessId;
      DateTime? syncedAt;
      int rosterCount = 0;
      if (businessId != null && businessId.isNotEmpty) {
        syncedAt = await _service.rosterSyncedAt(businessId);
        final roster = await _service.cachedRoster(businessId);
        rosterCount = roster.length;
      }
      if (!mounted) return;
      setState(() {
        _bound = bound && boundBusiness == businessId;
        _boundBusinessId = businessId;
        _lastSyncAt = syncedAt;
        _rosterCount = rosterCount;
        _loading = false;
      });
      ref.invalidate(offlineReadinessProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = FriendlyError.humanize('Error consultando estado: $e');
      });
    }
  }

  Future<void> _bind() async {
    final session = ref.read(sessionProvider);
    final businessId = session.activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      setState(() {
        _errorMessage = 'No hay un negocio activo seleccionado.';
      });
      return;
    }
    final deviceName = _deviceNameCtrl.text.trim();
    if (deviceName.isEmpty) {
      setState(() {
        _errorMessage = 'Ingresa un nombre para este dispositivo.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
      _statusMessage = null;
    });

    try {
      await _service.bindDevice(businessId: businessId, deviceName: deviceName);
      // Sync inicial inmediato. Si falla, el bind igual queda hecho —
      // el usuario puede reintentar manualmente.
      try {
        await _service.syncRoster(businessId: businessId);
      } catch (e) {
        if (mounted) {
          setState(() {
            _errorMessage = _syncFailureMessage(e);
          });
        }
      }
      await _refresh();
      if (mounted && _errorMessage == null) {
        setState(() {
          _statusMessage =
              'Dispositivo vinculado y roster sincronizado correctamente.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _errorMessage = FriendlyError.humanize('No se pudo vincular: $e'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _errorMessage = null;
      _statusMessage = null;
    });
    try {
      final users = await _service.syncRoster(
        businessId: ref.read(sessionProvider).activeBusinessId,
      );
      await _refresh();
      if (mounted) {
        setState(() {
          _statusMessage =
              'PIN actualizados: ${users.length} usuario(s) guardados en este equipo.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = _syncFailureMessage(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _syncFailureMessage(Object error) {
    debugPrint('DeviceBindingView: descarga de usuarios falló: $error');
    if (error is PostgrestException &&
        error.code == '42883' &&
        error.message.toLowerCase().contains('crypt')) {
      return 'El equipo está vinculado, pero falta una actualización del servidor '
          'para descargar los usuarios. El acceso con PIN sin internet aún no está listo. '
          'No necesitas vincularlo de nuevo.';
    }
    return 'No se pudieron descargar los usuarios. ${FriendlyError.from(error)}';
  }

  Future<void> _unbind() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Desvincular dispositivo'),
        content: const Text(
          'Se eliminará el registro manual de este equipo. La sincronización '
          'automática de PIN seguirá disponible con la sesión del negocio. ¿Continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Desvincular'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _busy = true;
      _errorMessage = null;
      _statusMessage = null;
    });
    try {
      await _service.clearDeviceBinding();
      final businessId = ref.read(sessionProvider).activeBusinessId;
      if (businessId != null) await _service.startBackgroundSync(businessId);
      await _refresh();
      if (mounted) {
        setState(() => _statusMessage = 'Dispositivo desvinculado.');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _errorMessage = FriendlyError.humanize('Error desvinculando: $e'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PIN sin internet')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildIntroCard(),
                    const SizedBox(height: 16),
                    _buildBoundCard(),
                    if (!_bound) _buildBindForm(),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
                      _MessageBanner(
                        text: _errorMessage!,
                        color: const Color(0xFFFEE2E2),
                        textColor: const Color(0xFFB91C1C),
                      ),
                    ],
                    if (_statusMessage != null) ...[
                      const SizedBox(height: 12),
                      _MessageBanner(
                        text: _statusMessage!,
                        color: const Color(0xFFDCFCE7),
                        textColor: const Color(0xFF166534),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildIntroCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Sincronización automática de PIN',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            SizedBox(height: 8),
            Text(
              'Los PIN y permisos se descargan al entrar al negocio, sin vincular '
              'este equipo. Se actualizan desde la caja principal por intranet '
              'o desde internet y se guardan cifrados. La caja principal debe '
              'seguir encendida y conectada a la red local.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBindForm() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Registro manual opcional (compatibilidad)',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _deviceNameCtrl,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Nombre del dispositivo',
                hintText: 'Ej: Caja Principal, Tablet Mesera 1',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.link),
              label: Text(_busy ? 'Vinculando...' : 'Vincular dispositivo'),
              onPressed: _busy ? null : _bind,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBoundCard() {
    final synced = _lastSyncAt != null
        ? DateFormat('dd MMM yyyy HH:mm').format(_lastSyncAt!.toLocal())
        : 'Nunca';
    final stale =
        _lastSyncAt == null ||
        DateTime.now().toUtc().difference(_lastSyncAt!.toUtc()) >
            OfflineAuthService.rosterTtl;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: Color(0xFF16A34A)),
                const SizedBox(width: 8),
                Text(
                  _bound
                      ? 'Dispositivo vinculado'
                      : 'Acceso con PIN automático',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(label: 'Negocio', value: _boundBusinessId ?? '—'),
            _InfoRow(label: 'Usuarios en caché', value: '$_rosterCount'),
            _InfoRow(
              label: 'Última sincronización',
              value: synced,
              valueColor: stale ? const Color(0xFFB91C1C) : null,
            ),
            if (stale)
              Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  _lastSyncAt == null
                      ? 'Aún no se han descargado los usuarios. Sincroniza para preparar el acceso con PIN sin internet.'
                      : 'Los permisos guardados vencieron. Sincroniza para poder entrar con PIN sin internet.',
                  style: TextStyle(color: Color(0xFFB91C1C), fontSize: 12),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.sync),
                    label: Text(
                      _busy ? 'Sincronizando...' : 'Sincronizar ahora',
                    ),
                    onPressed: _busy ? null : _syncNow,
                  ),
                ),
                if (_bound) const SizedBox(width: 12),
                if (_bound)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.link_off),
                    label: const Text('Desvincular'),
                    onPressed: _busy ? null : _unbind,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFEF4444),
                      side: const BorderSide(color: Color(0xFFEF4444)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 180,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? const Color(0xFF111827),
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({
    required this.text,
    required this.color,
    required this.textColor,
  });

  final String text;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: textColor)),
    );
  }
}
