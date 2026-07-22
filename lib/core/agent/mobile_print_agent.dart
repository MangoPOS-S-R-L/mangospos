/// MangoPOS Mobile Print Agent
///
/// Lightweight HTTP server that runs on Android/iOS and acts as a LAN print
/// relay — the same role as the Node.js agent on Windows.
///
/// Other devices on the network POST print jobs here, and this agent routes
/// them to USB (OTG), Bluetooth, or network printers connected to this device.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
// flutter_blue_plus_windows: wrapper cross-platform. Re-exporta APIs de
// flutter_blue_plus en no-Windows y usa win_ble_plus en Windows.
import 'package:flutter_blue_plus_windows/flutter_blue_plus_windows.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_usb_printer/flutter_usb_printer.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../printing/android_usb_raw_printer.dart';
import '../offline/hub/hub_config.dart';
import '../offline/hub/hub_op_log.dart';
import '../offline/hub/hub_order_projector.dart';
import '../offline/offline_pos_service.dart';
import '../../data/repositories/sales_repository.dart';
import '../offline/ncf_offline_allocator.dart';
import '../storage/storage_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Agent configuration
// ─────────────────────────────────────────────────────────────────────────────

const int _defaultPort = 4000;
const String _apiToken = 'MANGOPOS_SECURE_TOKEN_123';
const Duration _btScanTimeout = Duration(seconds: 4);
const Duration _btWriteTimeout = Duration(seconds: 8);

// ─────────────────────────────────────────────────────────────────────────────
// Main agent class
// ─────────────────────────────────────────────────────────────────────────────

class MobilePrintAgent {
  HttpServer? _server;
  int _port = _defaultPort;
  final List<Map<String, dynamic>> _jobHistory = [];

  /// Op-log del Hub Local (F3b). Solo se usa cuando este dispositivo actúa
  /// como Hub; los endpoints /hub/ops y /hub/state lo alimentan/leen.
  final HubOpLog _hubOpLog = HubOpLog();

  /// Asignador de NCF del Hub (F4). Cuando este dispositivo es el Hub, es el
  /// ÚNICO que asigna NCF offline → numeración secuencial sin huecos. El
  /// allocator serializa por serie, así que es seguro ante varias cajas
  /// pidiendo a la vez.
  final NcfOfflineAllocator _ncfAllocator = NcfOfflineAllocator();

  /// Suscriptores WebSocket del feed del Hub (F3c), por negocio. Cada op
  /// aplicada en /hub/ops se difunde a los sockets de ese negocio (el KDS y
  /// los demás terminales). Se llena cuando un cliente se conecta a
  /// /hub/events y envía `{"subscribe": "<business_id>"}`.
  final Map<String, Set<WebSocketChannel>> _hubSubscribers = {};
  final FlutterUsbPrinter _usbPrinter = FlutterUsbPrinter();

  bool get isRunning => _server != null;
  int get port => _port;
  String? get url {
    if (_server == null) return null;
    return 'http://${_server!.address.address}:$_port';
  }

  /// Start the HTTP server on [port]. Binds to all interfaces (0.0.0.0)
  /// so other devices on the LAN can reach it.
  Future<String?> start({int port = _defaultPort}) async {
    if (_server != null) {
      debugPrint('[MobileAgent] Already running on port $_port');
      return url;
    }

    _port = port;
    final router = _buildRouter();
    final handler = const shelf.Pipeline()
        .addMiddleware(_corsMiddleware())
        .addMiddleware(_authMiddleware())
        .addMiddleware(shelf.logRequests(
          logger: (msg, isError) =>
              debugPrint('[MobileAgent] ${isError ? "ERR " : ""}$msg'),
        ))
        .addHandler(router.call);

    try {
      _server = await shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        _port,
        shared: true,
      );
      debugPrint('[MobileAgent] Listening on port $_port');
      // H4: registra el difusor del Hub para que las ops que el HOST agrega a
      // su op-log local (sus propias mesas) se difundan por WS a las cajas
      // cliente, igual que las que llegan por POST /hub/ops.
      OfflinePosService().setHubBroadcaster(
        (biz, op) => _broadcastOp(biz, op),
      );
      return url;
    } catch (e) {
      debugPrint('[MobileAgent] Failed to start: $e');
      _server = null;
      return null;
    }
  }

  /// Stop the server.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    debugPrint('[MobileAgent] Stopped');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Router
  // ─────────────────────────────────────────────────────────────────────────

  Router _buildRouter() {
    final router = Router();

    // Health / status
    router.get('/health', _handleHealth);
    router.get('/status', _handleStatus);

    // Hub Local (F3): health/handshake. Sin auth (igual que /health).
    router.get('/hub/health', _handleHubHealth);
    // Hub Local (F3b): recibir una operación (POST) y servir el delta del
    // op-log (GET). Con auth (igual que el resto de endpoints).
    router.post('/hub/ops', _handleHubOps);
    router.get('/hub/state', _handleHubState);

    // H3: estado del salón + detalle de orden reconstruidos del op-log.
    router.get('/hub/salon', _handleHubSalon);
    router.get('/hub/order', _handleHubOrder);

    // Paso 2 (proxy real-time): el Hub ejecuta operaciones contra Supabase con
    // SU internet y devuelve el resultado real a las cajas cliente.
    router.post('/hub/proxy/open-table', _handleHubProxyOpenTable);
    router.post('/hub/proxy/add-item', _handleHubProxyAddItem);
    // Hub Local (F4): asigna el próximo NCF de una serie (asignador único en
    // LAN → numeración secuencial sin huecos).
    router.post('/hub/ncf/next', _handleHubNcfNext);
    // Feed en vivo (F3c): WebSocket. El cliente envía
    // {"subscribe":"<business_id>"} al conectar y recibe cada op aplicada.
    router.get('/hub/events', _hubEventsHandler());

    // Printer discovery
    router.get('/printers', _handleListPrinters);
    router.get('/api/printers/discover', _handleListPrinters);

    // Print job
    router.post('/print', _handlePrint);
    router.post('/api/printers/raw', _handleRawPrint);

    // Test print
    router.post('/test-print', _handleTestPrint);
    router.post('/api/printers/test', _handleTestPrint);

    // Job history
    router.get('/api/jobs', _handleJobHistory);

    return router;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Middleware
  // ─────────────────────────────────────────────────────────────────────────

  shelf.Middleware _corsMiddleware() {
    return (shelf.Handler innerHandler) {
      return (shelf.Request request) async {
        if (request.method == 'OPTIONS') {
          return shelf.Response.ok('', headers: _corsHeaders);
        }
        final response = await innerHandler(request);
        return response.change(headers: _corsHeaders);
      };
    };
  }

  static const _corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  };

  shelf.Middleware _authMiddleware() {
    return (shelf.Handler innerHandler) {
      return (shelf.Request request) async {
        final path = request.url.path;
        // Skip auth for health/status y el handshake del Hub.
        if (path == 'health' || path == 'status' || path == 'hub/health') {
          return innerHandler(request);
        }
        final authHeader = request.headers['authorization'] ?? '';
        if (authHeader.isNotEmpty && !authHeader.contains(_apiToken)) {
          return shelf.Response.forbidden(
            jsonEncode({'error': 'Unauthorized'}),
            headers: {'Content-Type': 'application/json'},
          );
        }
        return innerHandler(request);
      };
    };
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Handlers
  // ─────────────────────────────────────────────────────────────────────────

  shelf.Response _handleHealth(shelf.Request request) {
    return _jsonOk({'status': 'ok'});
  }

  /// Handshake del Hub Local (F3). `seq` es el último número de operación
  /// aplicado por el Hub; en F3a aún no hay op-log, así que es 0. El cliente
  /// (HubClient) usa esto para confirmar que el endpoint es un Hub alcanzable.
  Future<shelf.Response> _handleHubHealth(shelf.Request request) async {
    // Reporta el rol REAL de ESTE dispositivo (el designado en
    // `hub_device_role_<negocio>`), no 'hub' a ciegas. Antes cada caja corría
    // el agente de impresión y respondía 'hub', así que una caja cliente podía
    // engancharse a OTRA caja (o a sí misma) en vez de al Hub verdadero → leía
    // un op-log vacío y la mesa salía vacía. Ahora solo el equipo configurado
    // como Hub responde 'hub'. Best-effort: ante cualquier fallo cae a 'pos'
    // (no-hub), que es el lado seguro (el cliente NO lo tomará como Hub).
    var role = 'pos';
    try {
      final storage = await StorageService.getInstance();
      final businessId =
          await storage.read(StorageKeys.activeBusinessId) ?? '';
      if (businessId.isNotEmpty) {
        role = hubDeviceRoleToString(
          await HubConfigService().getDeviceRole(businessId),
        );
      }
    } catch (_) {
      // best-effort → 'pos'
    }
    return _jsonOk({
      'status': 'ok',
      'role': role,
      'hub_protocol': 1,
      'seq': 0,
    });
  }

  /// F3b: recibe una operación de un terminal, la agrega al op-log (seq +
  /// idempotente por op_id) y devuelve el seq asignado. El body es la acción
  /// (mismo shape que `enqueueAction`) e incluye `business_id`.
  Future<shelf.Response> _handleHubOps(shelf.Request request) async {
    final body = await _readJson(request);
    if (body == null) return _jsonError('Invalid JSON body', 400);
    final businessId = body['business_id']?.toString() ?? '';
    if (businessId.isEmpty) return _jsonError('Missing business_id', 400);
    final seq = await _hubOpLog.append(businessId, body);
    // Difundir la op aplicada (con su seq) a los suscriptores del feed.
    _broadcastOp(businessId, {...body, 'seq': seq});
    return _jsonOk({'seq': seq, 'op_id': body['op_id'] ?? body['id']});
  }

  /// Handler del WebSocket del feed del Hub (F3c). El cliente, al conectar,
  /// envía `{"subscribe":"<business_id>"}`; a partir de ahí recibe cada op.
  shelf.Handler _hubEventsHandler() {
    return webSocketHandler((WebSocketChannel channel, String? _) {
      String? subscribedBiz;
      channel.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message as String);
            if (data is Map && data['subscribe'] != null) {
              subscribedBiz = data['subscribe'].toString();
              _hubSubscribers
                  .putIfAbsent(subscribedBiz!, () => <WebSocketChannel>{})
                  .add(channel);
            }
          } catch (_) {
            // Mensaje no-JSON / desconocido: ignorar.
          }
        },
        onDone: () {
          if (subscribedBiz != null) {
            _hubSubscribers[subscribedBiz]?.remove(channel);
          }
        },
        onError: (_) {
          if (subscribedBiz != null) {
            _hubSubscribers[subscribedBiz]?.remove(channel);
          }
        },
      );
    });
  }

  /// Difunde una op a los suscriptores WebSocket del negocio. Limpia sockets
  /// muertos al vuelo.
  void _broadcastOp(String businessId, Map<String, dynamic> op) {
    final subs = _hubSubscribers[businessId];
    if (subs == null || subs.isEmpty) return;
    final msg = jsonEncode(op);
    for (final ch in subs.toList()) {
      try {
        ch.sink.add(msg);
      } catch (_) {
        subs.remove(ch);
      }
    }
  }

  /// F3b: sirve el delta del op-log desde `since` (query param) para que un
  /// terminal/KDS se ponga al día. Devuelve `{seq, ops}`.
  Future<shelf.Response> _handleHubState(shelf.Request request) async {
    final q = request.url.queryParameters;
    final businessId = q['business_id'] ?? '';
    if (businessId.isEmpty) return _jsonError('Missing business_id', 400);
    final since = int.tryParse(q['since'] ?? '0') ?? 0;
    final ops = await _hubOpLog.since(businessId, seq: since);
    final seq = await _hubOpLog.currentSeq(businessId);
    return _jsonOk({'seq': seq, 'ops': ops});
  }

  /// H3: sirve el estado del SALÓN (mesas ocupadas) reconstruido desde el
  /// op-log con [HubOrderProjector]. Equivalente LAN de `v_zone_table_status`
  /// para que el grid de las cajas lea del Hub. Devuelve `{tables: [...]}`.
  Future<shelf.Response> _handleHubSalon(shelf.Request request) async {
    final businessId = request.url.queryParameters['business_id'] ?? '';
    if (businessId.isEmpty) return _jsonError('Missing business_id', 400);
    final ops = await _hubOpLog.since(businessId, seq: 0);
    final tables = HubOrderProjector.projectSalon(ops)
        .map((t) => t.toJson())
        .toList(growable: false);
    return _jsonOk({'tables': tables});
  }

  /// H3: sirve el detalle de una orden por `table_id` u `order_id`,
  /// reconstruido desde el op-log. Equivalente LAN de `fn_get_order_bundle`
  /// para abrir una mesa ajena sin nube. 404 si no hay orden abierta.
  Future<shelf.Response> _handleHubOrder(shelf.Request request) async {
    final q = request.url.queryParameters;
    final businessId = q['business_id'] ?? '';
    if (businessId.isEmpty) return _jsonError('Missing business_id', 400);
    final tableId = q['table_id'];
    final orderId = q['order_id'];
    if ((tableId == null || tableId.isEmpty) &&
        (orderId == null || orderId.isEmpty)) {
      return _jsonError('Missing table_id or order_id', 400);
    }
    final ops = await _hubOpLog.since(businessId, seq: 0);
    final order = HubOrderProjector.projectOrder(
      ops,
      tableId: (tableId != null && tableId.isNotEmpty) ? tableId : null,
      orderId: (orderId != null && orderId.isNotEmpty) ? orderId : null,
    );
    if (order == null) return _jsonError('Order not found', 404);
    return _jsonOk(order.toJson());
  }

  /// Paso 2: el Hub abre/reanuda una mesa REAL contra Supabase (con su
  /// internet) y devuelve el JSON crudo de `fn_open_table_and_load`. La caja
  /// cliente lo parsea igual que el camino directo, así obtiene la orden real
  /// (con items, modifiers, tax_lines) sin depender de su propio WAN.
  Future<shelf.Response> _handleHubProxyOpenTable(shelf.Request request) async {
    final body = await _readJson(request);
    if (body == null) return _jsonError('Invalid JSON body', 400);
    final tableId = body['table_id']?.toString() ?? '';
    if (tableId.isEmpty) return _jsonError('Missing table_id', 400);
    try {
      final resp = await Supabase.instance.client.rpc(
        'fn_open_table_and_load',
        params: {
          'p_table_id': tableId,
          'p_user_id': body['user_id'],
          'p_people_count': (body['people_count'] as num?)?.toInt() ?? 1,
          'p_opened_by_employee_id': body['opened_by_employee_id'],
        },
      );
      if (resp is! Map) return _jsonError('open-table failed', 502);
      return _jsonOk(Map<String, dynamic>.from(resp));
    } catch (e) {
      return _jsonError('Hub open-table error: $e', 502);
    }
  }

  /// Paso 2: el Hub agrega un ítem REAL a la orden contra Supabase (con su
  /// internet) — ítem + modifiers + autor — y devuelve el id real. La caja
  /// cliente lo adopta (tmp→real) sin refetch. Así el ítem queda en el servidor
  /// al instante y el cobro sale correcto.
  Future<shelf.Response> _handleHubProxyAddItem(shelf.Request request) async {
    final body = await _readJson(request);
    if (body == null) return _jsonError('Invalid JSON body', 400);
    final orderId = body['order_id']?.toString() ?? '';
    final menuItemId = body['menu_item_id']?.toString() ?? '';
    if (orderId.isEmpty || menuItemId.isEmpty) {
      return _jsonError('Missing order_id or menu_item_id', 400);
    }
    try {
      final repo = SalesRepository(Supabase.instance.client);
      final itemId = await repo.addItemFromMenu(
        orderId: orderId,
        menuItemId: menuItemId,
        quantity: (body['quantity'] as num?)?.toDouble() ?? 1,
        checkPosition: (body['check_position'] as num?)?.toInt() ?? 1,
        isTakeout: body['is_takeout'] == true,
        notes: body['notes']?.toString(),
      );
      if (itemId.isEmpty) return _jsonError('add-item failed', 502);
      final mods = body['modifiers'];
      if (mods is List && mods.isNotEmpty) {
        await repo.addOrderItemModifiers(
          itemId: itemId,
          modifiers: mods
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList(growable: false),
        );
      }
      final empId = body['employee_id']?.toString();
      if (empId != null && empId.isNotEmpty) {
        try {
          await Supabase.instance.client
              .from('order_items')
              .update({'created_by_employee_id': empId})
              .eq('id', itemId);
        } catch (_) {}
      }
      return _jsonOk({'item_id': itemId});
    } catch (e) {
      return _jsonError('Hub add-item error: $e', 502);
    }
  }

  /// F4: asigna el próximo NCF de una serie. El allocator serializa por serie,
  /// así que varias cajas pidiendo a la vez obtienen números únicos. Devuelve
  /// `{ncf, number}` o `{exhausted: true}` si el rango se agotó (el caller
  /// emite recibo provisional). Body: business_id, ncf_type, serie, prefix,
  /// range_start, range_end, seed_current?.
  Future<shelf.Response> _handleHubNcfNext(shelf.Request request) async {
    final body = await _readJson(request);
    if (body == null) return _jsonError('Invalid JSON body', 400);
    final businessId = body['business_id']?.toString() ?? '';
    final ncfType = body['ncf_type']?.toString() ?? '';
    final serie = body['serie']?.toString() ?? '';
    final prefix = body['prefix']?.toString() ?? '';
    final rangeStart = (body['range_start'] as num?)?.toInt();
    final rangeEnd = (body['range_end'] as num?)?.toInt();
    if (businessId.isEmpty ||
        ncfType.isEmpty ||
        serie.isEmpty ||
        prefix.isEmpty ||
        rangeStart == null ||
        rangeEnd == null) {
      return _jsonError('Missing NCF range fields', 400);
    }
    final assignment = await _ncfAllocator.allocate(
      businessId: businessId,
      range: NcfRange(
        ncfType: ncfType,
        serie: serie,
        prefix: prefix,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        seedCurrent: (body['seed_current'] as num?)?.toInt(),
      ),
    );
    if (assignment == null) {
      return _jsonOk({'exhausted': true});
    }
    return _jsonOk({
      'ncf': assignment.ncf,
      'number': assignment.number,
      'ncf_type': assignment.ncfType,
      'serie': assignment.serie,
    });
  }

  shelf.Response _handleStatus(shelf.Request request) {
    return _jsonOk({
      'status': 'online',
      'agent': 'mangopos-mobile',
      'version': '1.0.0',
      'platform': Platform.isAndroid ? 'android' : 'ios',
      'port': _port,
      'jobs_processed': _jobHistory.length,
    });
  }

  Future<shelf.Response> _handleListPrinters(shelf.Request request) async {
    final printers = <Map<String, dynamic>>[];

    // USB printers (Android only)
    if (Platform.isAndroid) {
      try {
        final usbDevices = await FlutterUsbPrinter.getUSBDeviceList();
        for (final d in usbDevices) {
          printers.add({
            'type': 'usb',
            'name': d['manufacturer'] ?? d['productName'] ?? 'USB Printer',
            'vendorId': d['vendorId']?.toString() ?? '',
            'productId': d['productId']?.toString() ?? '',
            'deviceId': d['deviceId']?.toString() ?? '',
            'address': '${d['vendorId']}:${d['productId']}',
          });
        }
      } catch (e) {
        debugPrint('[MobileAgent] USB scan error: $e');
      }
    }

    // Bluetooth printers
    try {
      if (await FlutterBluePlus.isSupported) {
        final isOn = await FlutterBluePlus.adapterState.first ==
            BluetoothAdapterState.on;
        if (isOn) {
          // lastScanResults no existe en el wrapper Windows. Recolectamos
          // los results via stream durante el scan.
          final List<ScanResult> results = [];
          final sub = FlutterBluePlus.scanResults.listen((rs) {
            results
              ..clear()
              ..addAll(rs);
          });
          await FlutterBluePlus.startScan(timeout: _btScanTimeout);
          await Future.delayed(_btScanTimeout + const Duration(seconds: 1));
          await sub.cancel();
          for (final r in results) {
            final name = r.device.platformName;
            if (name.isEmpty) continue;
            printers.add({
              'type': 'bluetooth',
              'name': name,
              'address': r.device.remoteId.str,
              'mac': r.device.remoteId.str,
              'rssi': r.rssi,
            });
          }
        }
      }
    } catch (e) {
      debugPrint('[MobileAgent] BT scan error: $e');
    }

    return _jsonOk({'printers': printers, 'count': printers.length});
  }

  Future<shelf.Response> _handlePrint(shelf.Request request) async {
    final body = await _readJson(request);
    if (body == null) {
      return _jsonError('Invalid JSON body', 400);
    }

    final jobId = body['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString();
    final printer = body['printer'] as Map<String, dynamic>? ?? {};
    final content = body['content'] as Map<String, dynamic>? ?? {};
    final printerType = printer['type']?.toString() ?? 'network';

    // Aislamiento por negocio: si es una impresora de red, validar que la
    // IP+puerto correspondan a un printer registrado para algún business
    // al que el usuario tenga acceso (RLS hace el filtro automáticamente).
    if (printerType == 'network') {
      final ip = printer['ip']?.toString() ??
          printer['ip_address']?.toString() ??
          '';
      final port = (printer['port'] as num?)?.toInt() ?? 9100;
      if (!await _isNetworkPrinterAuthorized(ip, port)) {
        _addJobHistory(
          jobId,
          printerType,
          'rejected',
          error: 'Printer $ip:$port no pertenece a tu negocio',
        );
        return _jsonError(
          'Printer no autorizado para tu negocio (IP $ip:$port)',
          403,
        );
      }
    }

    try {
      final Uint8List bytes;
      final contentType = content['type']?.toString() ?? 'raw_base64';

      if (contentType == 'raw_base64') {
        final dataBase64 = content['dataBase64']?.toString() ??
            content['data_base64']?.toString() ??
            '';
        if (dataBase64.isEmpty) {
          return _jsonError('Missing dataBase64 in content', 400);
        }
        bytes = base64Decode(dataBase64);
      } else {
        return _jsonError('Unsupported content type: $contentType', 400);
      }

      switch (printerType) {
        case 'usb':
          await _printUsb(printer, bytes);
        case 'bluetooth':
          await _printBluetooth(printer, bytes);
        case 'network':
          await _printNetwork(printer, bytes);
        default:
          return _jsonError('Unknown printer type: $printerType', 400);
      }

      _addJobHistory(jobId, printerType, 'success');
      return _jsonOk({'success': true, 'jobId': jobId});
    } catch (e) {
      _addJobHistory(jobId, printerType, 'error', error: e.toString());
      return _jsonError('Print failed: $e', 500);
    }
  }

  Future<shelf.Response> _handleRawPrint(shelf.Request request) async {
    final body = await _readJson(request);
    if (body == null) return _jsonError('Invalid JSON', 400);

    final ip = body['ip']?.toString() ?? '';
    final port = (body['port'] as num?)?.toInt() ?? 9100;
    final dataBase64 = body['data']?.toString() ?? '';

    if (ip.isEmpty || dataBase64.isEmpty) {
      return _jsonError('Missing ip or data', 400);
    }

    // Aislamiento por negocio (igual que _handlePrint).
    if (!await _isNetworkPrinterAuthorized(ip, port)) {
      return _jsonError(
        'Printer no autorizado para tu negocio (IP $ip:$port)',
        403,
      );
    }

    try {
      final bytes = base64Decode(dataBase64);
      await _printNetwork({'ip': ip, 'port': port}, bytes);
      return _jsonOk({'success': true});
    } catch (e) {
      return _jsonError('Raw print failed: $e', 500);
    }
  }

  /// Verifica que la IP exista como printer activo en algún business al
  /// que el usuario autenticado tenga acceso. Las policies RLS de
  /// `printers` filtran automáticamente por `current_user_business_ids`,
  /// así que esta consulta solo devuelve filas de los negocios del user.
  ///
  /// Nota sobre el puerto: muchos registros legacy tienen `port=NULL` en
  /// la DB. Validamos PRIMARIAMENTE por IP — si la IP coincide con un
  /// printer del negocio del user, autoriza. El puerto es informativo.
  /// Si DOS businesses tienen la misma IP registrada (caso edge), RLS le
  /// devuelve al user el suyo y todo bien; si por error el otro también
  /// fuera visible, igual está autorizado en términos del modelo actual.
  ///
  /// Si no hay sesión Supabase activa (agente standalone), permite el
  /// print — caso edge de agente puro sin acceso a DB.
  Future<bool> _isNetworkPrinterAuthorized(String ip, int port) async {
    if (ip.isEmpty) return false;
    try {
      final client = Supabase.instance.client;
      if (client.auth.currentSession == null) {
        return true;
      }
      // Match solo por IP. Port se tolera porque hay registros legacy con
      // port=NULL. Si en el futuro se fuerza port no-null, agregar un
      // OR igualdad.
      final rows = await client
          .from('printers')
          .select('id, business_id, port')
          .eq('ip_address', ip)
          .eq('is_active', true)
          .limit(5);
      return (rows as List).isNotEmpty;
    } catch (e) {
      debugPrint(
        '[MobileAgent] _isNetworkPrinterAuthorized error: $e — '
        'permitiendo print para no romper en caso de outage temporal de DB',
      );
      return true;
    }
  }

  Future<shelf.Response> _handleTestPrint(shelf.Request request) async {
    final body = await _readJson(request);
    if (body == null) return _jsonError('Invalid JSON', 400);

    final printer = body['printer'] as Map<String, dynamic>? ?? body;
    final printerType = printer['type']?.toString() ?? 'network';

    // Simple test: ESC/POS init + text + cut
    final testBytes = Uint8List.fromList([
      0x1B, 0x40, // Initialize
      ...utf8.encode('*** MangoPOS Test ***\n'),
      ...utf8.encode('Agente Movil OK\n'),
      ...utf8.encode('${DateTime.now()}\n'),
      0x0A, 0x0A, 0x0A, // Feed
      0x1D, 0x56, 0x00, // Full cut
    ]);

    try {
      switch (printerType) {
        case 'usb':
          await _printUsb(printer, testBytes);
        case 'bluetooth':
          await _printBluetooth(printer, testBytes);
        case 'network':
          await _printNetwork(printer, testBytes);
        default:
          return _jsonError('Unknown type: $printerType', 400);
      }
      return _jsonOk({'success': true, 'message': 'Test print sent'});
    } catch (e) {
      return _jsonError('Test print failed: $e', 500);
    }
  }

  shelf.Response _handleJobHistory(shelf.Request request) {
    return _jsonOk({'jobs': _jobHistory, 'count': _jobHistory.length});
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Print drivers
  // ─────────────────────────────────────────────────────────────────────────

  /// Print to USB OTG printer (Android only).
  Future<void> _printUsb(Map<String, dynamic> printer, Uint8List data) async {
    if (!Platform.isAndroid) {
      throw Exception('USB OTG printing only supported on Android');
    }

    final vendorId = int.tryParse(printer['vendorId']?.toString() ?? '');
    final productId = int.tryParse(printer['productId']?.toString() ?? '');

    // Camino principal: canal nativo propio con bulkTransfer troceado y
    // verificado (arregla tickets a la mitad). Fallback por vid/pid ausente
    // o build sin el canal → plugin legado abajo.
    if (vendorId != null && productId != null) {
      try {
        await AndroidUsbRawPrinter.write(
          vendorId: vendorId,
          productId: productId,
          data: data,
        );
        return;
      } on MissingPluginException {
        debugPrint('[MobileAgent] usb_raw_printer ausente, usando legado');
      } on PlatformException catch (e) {
        if (e.code == 'usb_device_not_found') {
          // vid/pid guardado ya no coincide: probar la primera conectada.
          final devices = await AndroidUsbRawPrinter.listDevices();
          if (devices.isNotEmpty) {
            final vid =
                int.tryParse(devices.first['vendorId']?.toString() ?? '');
            final pid =
                int.tryParse(devices.first['productId']?.toString() ?? '');
            if (vid != null && pid != null) {
              await AndroidUsbRawPrinter.write(
                  vendorId: vid, productId: pid, data: data);
              return;
            }
          }
          throw Exception('No USB printers found');
        }
        throw Exception('USB print failed: ${e.message ?? e.code}');
      }
    }

    // Camino legado (flutter_usb_printer). Su write() nativo es
    // fire-and-forget: espaciamos bloques y damos margen antes de close()
    // para no cortar la transferencia en curso.
    bool connected = false;
    if (vendorId != null && productId != null) {
      connected = await _usbPrinter.connect(vendorId, productId) ?? false;
    }

    // Fallback: try connecting to the first available USB printer
    if (!connected) {
      final devices = await FlutterUsbPrinter.getUSBDeviceList();
      if (devices.isEmpty) {
        throw Exception('No USB printers found');
      }
      final d = devices.first;
      final vid = int.tryParse(d['vendorId']?.toString() ?? '');
      final pid = int.tryParse(d['productId']?.toString() ?? '');
      if (vid == null || pid == null) {
        throw Exception('Invalid USB device identifiers');
      }
      connected = await _usbPrinter.connect(vid, pid) ?? false;
    }

    if (!connected) {
      throw Exception('Could not connect to USB printer');
    }

    try {
      const chunk = 4 * 1024;
      for (var i = 0; i < data.length; i += chunk) {
        final end = (i + chunk < data.length) ? i + chunk : data.length;
        await _usbPrinter.write(Uint8List.sublistView(data, i, end));
        await Future.delayed(const Duration(milliseconds: 120));
      }
      await Future.delayed(const Duration(milliseconds: 700));
    } finally {
      await _usbPrinter.close();
    }
  }

  /// Print to Bluetooth printer via GATT write.
  Future<void> _printBluetooth(
      Map<String, dynamic> printer, Uint8List data) async {
    final address = printer['address']?.toString() ??
        printer['mac']?.toString() ??
        '';
    if (address.isEmpty) {
      throw Exception('Missing Bluetooth address/mac');
    }

    final device = BluetoothDevice.fromId(address);
    try {
      // flutter_blue_plus 1.x no acepta `license` (parametro 2.x-only).
      await device.connect(
        autoConnect: false,
        timeout: _btWriteTimeout,
      );
      
      // Try to request a larger MTU for faster printing on supported devices
      try {
        if (Platform.isAndroid) {
          await device.requestMtu(512);
        }
      } catch (e) {
        debugPrint('[MobileAgent] MTU request failed (ignoring): $e');
      }

      await Future.delayed(const Duration(milliseconds: 500));

      final services = await device.discoverServices();
      BluetoothCharacteristic? writableChar;

      for (final service in services) {
        for (final char in service.characteristics) {
          if (char.properties.write || char.properties.writeWithoutResponse) {
            writableChar = char;
            break;
          }
        }
        if (writableChar != null) break;
      }

      if (writableChar == null) {
        throw Exception('No writable characteristic found on Bluetooth device');
      }

      // Send data in chunks. 
      // Default BLE MTU is 23 bytes (20 bytes for data). 
      // We use a safe chunk size of 20 to ensure compatibility with all printers.
      const int safeChunkSize = 20;
      
      for (var i = 0; i < data.length; i += safeChunkSize) {
        final end = (i + safeChunkSize > data.length) ? data.length : i + safeChunkSize;
        final chunk = data.sublist(i, end);
        
        await writableChar.write(
          chunk.toList(),
          withoutResponse: writableChar.properties.writeWithoutResponse,
        );
        
        // Very small delay to allow the printer's buffer to catch up
        await Future.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  /// Print to network printer via direct TCP socket.
  Future<void> _printNetwork(
      Map<String, dynamic> printer, Uint8List data) async {
    final ip = printer['ip']?.toString() ?? '';
    final port = (printer['port'] as num?)?.toInt() ?? 9100;

    if (ip.isEmpty) {
      throw Exception('Missing network printer IP');
    }

    final socket = await Socket.connect(ip, port,
        timeout: const Duration(seconds: 5));
    try {
      socket.add(data);
      await socket.flush();
    } finally {
      await socket.close();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _readJson(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  shelf.Response _jsonOk(Map<String, dynamic> body) {
    return shelf.Response.ok(
      jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );
  }

  shelf.Response _jsonError(String message, int statusCode) {
    return shelf.Response(
      statusCode,
      body: jsonEncode({'error': message}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  void _addJobHistory(String id, String type, String status, {String? error}) {
    _jobHistory.insert(0, {
      'id': id,
      'type': type,
      'status': status,
      if (error != null) 'error': error,
      'timestamp': DateTime.now().toIso8601String(),
    });
    // Keep last 50 jobs
    if (_jobHistory.length > 50) {
      _jobHistory.removeRange(50, _jobHistory.length);
    }
  }
}
