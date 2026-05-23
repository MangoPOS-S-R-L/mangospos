import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/core/auth/offline_auth_service.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// Pantalla "Vincular dispositivo" — Fase 2.5 del rollout offline.
///
/// Permite al owner/admin vincular este terminal físico a su negocio.
/// Una vez vinculado, el cliente puede sincronizar el roster de usuarios
/// y validar PINs sin conexión a internet.
class DeviceBindingView extends ConsumerStatefulWidget {
  const DeviceBindingView({super.key});

  @override
  ConsumerState<DeviceBindingView> createState() => _DeviceBindingViewState();
}

class _DeviceBindingViewState extends ConsumerState<DeviceBindingView> {
  final _service = OfflineAuthService();
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
      final businessId = await _service.currentBoundBusinessId();
      DateTime? syncedAt;
      int rosterCount = 0;
      if (businessId != null && businessId.isNotEmpty) {
        syncedAt = await _service.rosterSyncedAt(businessId);
        final roster = await _service.cachedRoster(businessId);
        rosterCount = roster.length;
      }
      if (!mounted) return;
      setState(() {
        _bound = bound;
        _boundBusinessId = businessId;
        _lastSyncAt = syncedAt;
        _rosterCount = rosterCount;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = 'Error consultando estado: $e';
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
      await _service.bindDevice(
        businessId: businessId,
        deviceName: deviceName,
      );
      // Sync inicial inmediato. Si falla, el bind igual queda hecho —
      // el usuario puede reintentar manualmente.
      try {
        await _service.syncRoster();
      } catch (e) {
        if (mounted) {
          setState(() {
            _statusMessage =
                'Dispositivo vinculado, pero la sincronización inicial falló: $e';
          });
        }
      }
      await _refresh();
      if (mounted && _statusMessage == null) {
        setState(() {
          _statusMessage =
              'Dispositivo vinculado y roster sincronizado correctamente.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'No se pudo vincular: $e');
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
      final users = await _service.syncRoster();
      await _refresh();
      if (mounted) {
        setState(() {
          _statusMessage =
              'Roster sincronizado: ${users.length} usuario(s) en caché offline.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Error sincronizando: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unbind() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Desvincular dispositivo'),
        content: const Text(
          'Después de desvincular, este dispositivo no podrá validar PINs '
          'offline hasta vincularlo de nuevo. ¿Continuar?',
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
      await _refresh();
      if (mounted) {
        setState(() => _statusMessage = 'Dispositivo desvinculado.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Error desvinculando: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vincular dispositivo')),
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
                    if (_bound) _buildBoundCard() else _buildBindForm(),
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
              '¿Qué hace vincular el dispositivo?',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            SizedBox(height: 8),
            Text(
              'Permite que este terminal valide PINs de empleados y opere '
              'completamente sin conexión a internet. El roster de usuarios '
              'autorizados se guarda encriptado localmente y se sincroniza '
              'cuando hay red. Solo el propietario o administradores del '
              'negocio pueden vincular o desvincular terminales.',
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
              'Vincular este dispositivo',
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
    final stale = _lastSyncAt == null ||
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
                const Icon(
                  Icons.check_circle,
                  color: Color(0xFF16A34A),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Dispositivo vinculado',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(
              label: 'Negocio',
              value: _boundBusinessId ?? '—',
            ),
            _InfoRow(
              label: 'Usuarios en caché',
              value: '$_rosterCount',
            ),
            _InfoRow(
              label: 'Última sincronización',
              value: synced,
              valueColor: stale ? const Color(0xFFB91C1C) : null,
            ),
            if (stale)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'El roster está vencido. Algunos flujos críticos pueden '
                  'bloquearse hasta sincronizar.',
                  style: TextStyle(
                    color: Color(0xFFB91C1C),
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.sync),
                    label: Text(_busy ? 'Sincronizando...' : 'Sincronizar ahora'),
                    onPressed: _busy ? null : _syncNow,
                  ),
                ),
                const SizedBox(width: 12),
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
  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

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
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontSize: 13,
              ),
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
