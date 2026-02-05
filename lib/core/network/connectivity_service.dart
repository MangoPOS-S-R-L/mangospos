import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Servicio de monitoreo de conectividad
class ConnectivityService {
  static ConnectivityService? _instance;
  final Connectivity _connectivity = Connectivity();

  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  bool _isConnected = true;
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  ConnectivityService._();

  /// Singleton instance
  factory ConnectivityService() {
    _instance ??= ConnectivityService._();
    return _instance!;
  }

  /// Stream de cambios de conectividad
  Stream<bool> get connectionStream => _connectionController.stream;

  /// Estado actual de la conexión
  bool get isConnected => _isConnected;

  /// Inicializar monitoreo de conectividad
  Future<void> initialize() async {
    // Verificar estado inicial
    await _checkConnectivity();

    // Escuchar cambios
    _subscription = _connectivity.onConnectivityChanged.listen(
      _handleConnectivityChange,
      onError: (error) {
        debugPrint('Error en connectivity stream: $error');
      },
    );

    debugPrint('ConnectivityService initialized. Connected: $_isConnected');
  }

  /// Verificar conectividad actual
  Future<void> _checkConnectivity() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _updateConnectionStatus(result);
    } catch (e) {
      debugPrint('Error checking connectivity: $e');
      _updateConnectionStatus([ConnectivityResult.none]);
    }
  }

  /// Manejar cambios de conectividad
  void _handleConnectivityChange(List<ConnectivityResult> results) {
    _updateConnectionStatus(results);
  }

  /// Actualizar estado de conexión
  void _updateConnectionStatus(List<ConnectivityResult> results) {
    final wasConnected = _isConnected;

    // Si hay alguna conexión válida (wifi, mobile, ethernet)
    _isConnected = results.any(
      (result) =>
          result != ConnectivityResult.none &&
          result != ConnectivityResult.bluetooth,
    );

    // Notificar solo si cambió el estado
    if (wasConnected != _isConnected) {
      debugPrint('Connectivity changed: $_isConnected');
      _connectionController.add(_isConnected);
    }
  }

  /// Simular desconexión (para testing)
  void simulateDisconnect() {
    debugPrint('🔴 Simulating disconnect...');
    _isConnected = false;
    _connectionController.add(false);
  }

  /// Simular reconexión (para testing)
  void simulateReconnect() {
    debugPrint('🟢 Simulating reconnect...');
    _isConnected = true;
    _connectionController.add(true);
  }

  /// Limpiar recursos
  void dispose() {
    _subscription?.cancel();
    _connectionController.close();
  }
}
