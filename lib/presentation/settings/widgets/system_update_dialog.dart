import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:io' show Platform;
import 'package:auto_updater/auto_updater.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

class SystemUpdateDialog extends StatefulWidget {
  const SystemUpdateDialog({super.key});

  @override
  State<SystemUpdateDialog> createState() => _SystemUpdateDialogState();
}

class _SystemUpdateDialogState extends State<SystemUpdateDialog> {
  bool _isChecking = true;
  bool _hasError = false;
  String _errorMessage = '';

  static const _currentVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.0',
  );

  @override
  void initState() {
    super.initState();
    _checkForUpdates();
  }

  Future<void> _checkForUpdates() async {
    if (kIsWeb || !(Platform.isMacOS || Platform.isWindows)) {
      if (mounted) {
        setState(() {
          _isChecking = false;
          _hasError = true;
          _errorMessage = 'Actualización no soportada en esta plataforma.';
        });
      }
      return;
    }

    try {
      await autoUpdater.setFeedURL('https://mangopos.com/appcast.xml');
      await autoUpdater.checkForUpdates(inBackground: true);

      // auto_updater maneja la UI de actualización internamente.
      // Si llegamos aquí sin excepción, el check fue exitoso.
      if (mounted) {
        setState(() {
          _isChecking = false;
          _hasError = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isChecking = false;
          _hasError = true;
          _errorMessage = FriendlyError.humanize('No se pudo verificar actualizaciones: $e');
        });
      }
    }
  }

  Future<void> _startUpdate() async {
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows)) {
      try {
        await autoUpdater.checkForUpdates();
      } catch (e) {
        if (mounted) {
          AppToast.error(context, 'No se pudo iniciar la actualización: $e');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: Colors.white,
      child: Container(
        padding: const EdgeInsets.all(32),
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F1F1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.system_update_alt_rounded,
                size: 48,
                color: Color(0xFF1C1917),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Actualización del Sistema',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1C1917),
              ),
            ),
            const SizedBox(height: 8),
            if (_isChecking)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Buscando actualizaciones disponibles...',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 32),
                  const CircularProgressIndicator(color: Color(0xFF1C1917)),
                ],
              )
            else if (_hasError)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, color: Colors.red[400], size: 32),
                  const SizedBox(height: 12),
                  Text(
                    _errorMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.red[600]),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Versión actual: $_currentVersion',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                ],
              )
            else
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline, color: Colors.green[600], size: 32),
                  const SizedBox(height: 12),
                  Text(
                    'Tu sistema está actualizado.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.green[700]),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Versión: $_currentVersion',
                    style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                  ),
                ],
              ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: Colors.grey[300]!),
                      ),
                    ),
                    child: Text(
                      _isChecking ? 'Cancelar' : 'Cerrar',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1C1917),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _isChecking ? null : _startUpdate,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFF97316),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'Buscar actualizaciones',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
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
