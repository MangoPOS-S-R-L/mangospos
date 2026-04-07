import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:io' show Platform;
import 'package:auto_updater/auto_updater.dart';

class SystemUpdateDialog extends StatefulWidget {
  const SystemUpdateDialog({Key? key}) : super(key: key);

  @override
  State<SystemUpdateDialog> createState() => _SystemUpdateDialogState();
}

class _SystemUpdateDialogState extends State<SystemUpdateDialog> {
  bool _isChecking = true;
  bool _updateAvailable = false;
  String _currentVersion = "1.0.0+1";
  String _latestVersion = "1.1.0+3";

  @override
  void initState() {
    super.initState();
    _checkForUpdates();
  }

  Future<void> _checkForUpdates() async {
    // Simula la llamada al backend o servidor de actualizaciones
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      setState(() {
        _isChecking = false;
        // Por motivos de demostración, establecemos que sí hay una actualización
        _updateAvailable = true; 
      });
    }
  }

  Future<void> _startUpdate() async {
    Navigator.of(context).pop();
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows)) {
      try {
        await autoUpdater.checkForUpdates();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No se pudo iniciar la actualización: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Actualización no soportada en esta plataforma.'),
          backgroundColor: Colors.orange,
        ),
      );
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
            else if (_updateAvailable)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '¡Nueva versión encontrada!',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.green[700]),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey[50],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey[200]!),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                         Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Versión actual', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                            Text(_currentVersion, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const Icon(Icons.arrow_forward_rounded, color: Colors.grey, size: 20),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('Versión nueva', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                            Text(_latestVersion, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFFF97316))),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              )
            else
              Text(
                'Tu sistema ya cuenta con la versión más reciente.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey[600]),
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
                if (!_isChecking && _updateAvailable) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _startUpdate,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFF97316),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        'Actualizar ahora',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
