import 'package:flutter/material.dart';
import '../core/cache/cache_manager.dart';
import '../core/cache/cache_config.dart';
import '../core/cache/models/sync_status.dart';
import '../core/network/connectivity_service.dart';

/// Página de prueba del CacheManager - DÍA 1
///
/// Esta página demuestra:
/// - ✅ Inicialización del cache
/// - ✅ Guardado y lectura de datos simples
/// - ✅ Cache-first vs Network-first
/// - ✅ Indicador de estado en tiempo real
/// - ✅ Simulación de modo offline
class CacheTestPage extends StatefulWidget {
  const CacheTestPage({super.key});

  @override
  State<CacheTestPage> createState() => _CacheTestPageState();
}

class _CacheTestPageState extends State<CacheTestPage> {
  final _cacheManager = CacheManager();
  final _connectivity = ConnectivityService();

  String _testResult = '';
  bool _isLoading = false;
  int _apiCallCount = 0;

  @override
  void initState() {
    super.initState();
    _initializeCache();
  }

  Future<void> _initializeCache() async {
    setState(() => _isLoading = true);

    try {
      await CacheManager.initialize(
        priorityOrder: [CachePriority.critical],
        onProgress: (module, progress) {
          debugPrint('Loading $module: $progress%');
        },
      );

      _addResult('✅ Cache initialized successfully');
    } catch (e) {
      _addResult('❌ Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _addResult(String message) {
    setState(() {
      _testResult += '$message\n';
    });
    debugPrint(message);
  }

  // ==================== TESTS ====================

  /// TEST 1: Guardar y leer datos simples
  Future<void> _testBasicCacheReadWrite() async {
    _addResult('\n📝 TEST 1: Basic Read/Write');
    setState(() => _isLoading = true);

    try {
      // Guardar
      await _cacheManager.set(
        key: 'cache_test_message',
        data: {
          'message': 'Hello from cache!',
          'timestamp': DateTime.now().toIso8601String(),
        },
        updateLocalCache: true,
      );
      _addResult('  ✓ Data saved to cache');

      // Leer
      final cached = await _cacheManager.get<Map<String, dynamic>>(
        key: 'cache_test_message',
        fromJson: (json) => json as Map<String, dynamic>,
        fetchFromApi: () async => {'error': 'Should not call API'},
        strategy: CacheStrategy.cacheOnly,
      );

      if (cached != null && cached['message'] == 'Hello from cache!') {
        _addResult('  ✓ Data read from cache correctly');
        _addResult('  Message: ${cached['message']}');
      } else {
        _addResult('  ✗ Failed to read from cache');
      }
    } catch (e) {
      _addResult('  ✗ Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// TEST 2: Cache-first con API fallback
  Future<void> _testCacheFirstStrategy() async {
    _addResult('\n🔄 TEST 2: Cache-First Strategy');
    setState(() => _isLoading = true);
    _apiCallCount = 0;

    try {
      // Primera llamada: No hay cache, debe llamar API
      final result1 = await _cacheManager.get<Map<String, dynamic>>(
        key: 'cache_test_products',
        fromJson: (json) => json as Map<String, dynamic>,
        fetchFromApi: _simulatedApiCall,
        strategy: CacheStrategy.cacheFirst,
        ttl: Duration(minutes: 5),
      );

      _addResult(
        '  1st call: ${result1?['source']} (API calls: $_apiCallCount)',
      );

      // Segunda llamada: Ya hay cache, NO debe llamar API
      await Future.delayed(Duration(seconds: 1));

      final result2 = await _cacheManager.get<Map<String, dynamic>>(
        key: 'cache_test_products',
        fromJson: (json) => json as Map<String, dynamic>,
        fetchFromApi: _simulatedApiCall,
        strategy: CacheStrategy.cacheFirst,
        ttl: Duration(minutes: 5),
      );

      _addResult(
        '  2nd call: ${result2?['source']} (API calls: $_apiCallCount)',
      );

      if (_apiCallCount == 1) {
        _addResult('  ✓ Cache-first working correctly!');
      } else {
        _addResult('  ✗ Expected 1 API call, got $_apiCallCount');
      }
    } catch (e) {
      _addResult('  ✗ Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// TEST 3: Modo offline
  Future<void> _testOfflineMode() async {
    _addResult('\n📴 TEST 3: Offline Mode');
    setState(() => _isLoading = true);

    try {
      // 1. Guardar datos mientras estamos online
      _addResult('  Setting up cache...');
      await _cacheManager.set(
        key: 'cache_test_offline',
        data: {'message': 'Cached data for offline'},
        updateLocalCache: true,
      );

      // 2. Simular pérdida de conexión
      _addResult('  🔴 Simulating disconnect...');
      _connectivity.simulateDisconnect();
      await Future.delayed(Duration(seconds: 1));

      // 3. Intentar leer (debe usar cache)
      final offline = await _cacheManager.get<Map<String, dynamic>>(
        key: 'cache_test_offline',
        fromJson: (json) => json as Map<String, dynamic>,
        fetchFromApi: () async => throw Exception('No internet!'),
        strategy: CacheStrategy.cacheFirst,
        useStaleCacheOnError: true,
      );

      if (offline != null) {
        _addResult('  ✓ Data available offline: ${offline['message']}');
      } else {
        _addResult('  ✗ Failed to get data offline');
      }

      // 4. Reconectar
      _addResult('  🟢 Reconnecting...');
      _connectivity.simulateReconnect();
      await Future.delayed(Duration(seconds: 1));

      _addResult('  ✓ Back online!');
    } catch (e) {
      _addResult('  ✗ Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// Simular llamada a API
  Future<Map<String, dynamic>> _simulatedApiCall() async {
    _apiCallCount++;
    _addResult('    → API call #$_apiCallCount');

    // Simular latencia
    await Future.delayed(Duration(milliseconds: 500));

    return {
      'source': 'API',
      'products': ['Product 1', 'Product 2', 'Product 3'],
      'timestamp': DateTime.now().toIso8601String(),
      'callNumber': _apiCallCount,
    };
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cache Test - DÍA 1'),
        actions: [_buildCacheStatusIndicator()],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Indicador de estado
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Estos tests prueban el CacheManager básico con diferentes estrategias.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Botones de prueba
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _testBasicCacheReadWrite,
              icon: const Icon(Icons.edit_note),
              label: const Text('Test 1: Basic Read/Write'),
            ),
            const SizedBox(height: 8),

            ElevatedButton.icon(
              onPressed: _isLoading ? null : _testCacheFirstStrategy,
              icon: const Icon(Icons.cached),
              label: const Text('Test 2: Cache-First Strategy'),
            ),
            const SizedBox(height: 8),

            ElevatedButton.icon(
              onPressed: _isLoading ? null : _testOfflineMode,
              icon: const Icon(Icons.wifi_off),
              label: const Text('Test 3: Offline Mode'),
            ),
            const SizedBox(height: 8),

            OutlinedButton.icon(
              onPressed: () {
                setState(() => _testResult = '');
              },
              icon: const Icon(Icons.clear),
              label: const Text('Clear Results'),
            ),

            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),

            // Resultados
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _testResult.isEmpty
                        ? 'Run a test to see results...'
                        : _testResult,
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),

            if (_isLoading)
              Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCacheStatusIndicator() {
    return StreamBuilder<CacheState>(
      stream: _cacheManager.stateStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        final state = snapshot.data!;

        IconData icon;
        Color color;

        switch (state.status) {
          case CacheStatus.synced:
            icon = Icons.cloud_done;
            color = Colors.green;
            break;
          case CacheStatus.syncing:
            icon = Icons.sync;
            color = Colors.blue;
            break;
          case CacheStatus.cached:
            icon = Icons.storage;
            color = Colors.orange;
            break;
          case CacheStatus.offline:
            icon = Icons.cloud_off;
            color = Colors.red;
            break;
          case CacheStatus.error:
            icon = Icons.error;
            color = Colors.red;
            break;
          default:
            icon = Icons.cloud;
            color = Colors.grey;
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Tooltip(
            message: state.status.name,
            child: Icon(icon, color: color),
          ),
        );
      },
    );
  }
}
