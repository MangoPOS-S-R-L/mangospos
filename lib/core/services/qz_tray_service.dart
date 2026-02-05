import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';

class QzTrayService {
  static const String _urlSecure = 'wss://localhost:8182';
  static const String _urlInsecure = 'ws://localhost:8181';
  WebSocketChannel? _channel;

  // Requests pending response [uid -> Completer]
  final Map<String, Completer<dynamic>> _pendingRequests = {};

  final _connectedController = StreamController<bool>.broadcast();
  Stream<bool> get connected => _connectedController.stream;
  bool _isConnected = false;

  bool get isConnected => _isConnected;

  Future<void> connect() async {
    if (_isConnected) return;
    try {
      await _connectTo(_urlSecure);
    } catch (e) {
      print('QZ Secure Connection failed ($e). Retrying insecure...');
      try {
        await _connectTo(_urlInsecure);
      } catch (e2) {
        _cleanup();
        throw Exception(
          'Failed to connect to QZ Tray. Make sure it is installed and running.\nSecure: $e\nInsecure: $e2',
        );
      }
    }
  }

  Future<void> _connectTo(String url) async {
    final channel = WebSocketChannel.connect(Uri.parse(url));

    // Wait for connection to be ready
    await channel.ready;
    print('QZ: Connected successfully to $url');

    _channel = channel;
    _channel!.stream.listen(
      (message) {
        _handleMessage(message);
      },
      onError: (e) {
        _cleanup();
        print('QZ WebSocket Error: $e');
      },
      onDone: () {
        _cleanup();
        print('QZ WebSocket Closed');
      },
    );

    _isConnected = true;
    _connectedController.add(true);
  }

  void _cleanup() {
    _isConnected = false;
    _connectedController.add(false);
    _pendingRequests.forEach((key, value) {
      if (!value.isCompleted) value.completeError('Connection closed');
    });
    _pendingRequests.clear();
  }

  void _handleMessage(dynamic message) {
    if (message is String) {
      try {
        final Map<String, dynamic> data = jsonDecode(message);
        final String? uid = data['uid'];

        if (uid != null && _pendingRequests.containsKey(uid)) {
          final completer = _pendingRequests.remove(uid)!;
          if (data.containsKey('error') && data['error'] != null) {
            completer.completeError(data['error']);
          } else {
            completer.complete(data['result']);
          }
        }
      } catch (e) {
        print('QZ Parse Error: $e');
      }
    }
  }

  void disconnect() {
    _channel?.sink.close();
    _cleanup();
  }

  Future<dynamic> _call(String method, dynamic params) async {
    if (!_isConnected) await connect();

    final uid = _generateUid();
    final completer = Completer<dynamic>();
    _pendingRequests[uid] = completer;

    final payload = jsonEncode({
      "call": method,
      "params": params,
      "timestamp": DateTime.now().millisecondsSinceEpoch,
      "uid": uid,
    });

    _channel!.sink.add(payload);

    // Timeout logic
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pendingRequests.remove(uid);
        throw TimeoutException("QZ Tray request timed out");
      },
    );
  }

  String _generateUid() {
    return '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(10000)}';
  }

  // --- Public Methods ---

  Future<List<String>> findPrinters() async {
    final res = await _call("printers.find", null);
    if (res is List) {
      return res.map((e) => e.toString()).toList();
    }
    return [];
  }

  Future<void> printESCPOS(String printerName, List<int> data) async {
    // data: base64 encoded string from bytes
    final base64Data = base64Encode(data);
    await _call("print", {
      "printer": printerName,
      "options": null,
      "data": [
        {
          "type": "raw",
          "format": "command",
          "flavor": "plain",
          "data": base64Data,
        },
      ],
    });
  }
}
