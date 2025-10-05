import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:uuid/uuid.dart';

class PrinterService {
  WebSocketChannel? _channel;
  final String serverUrl;
  final String clientId;

  PrinterService({required this.serverUrl}) : clientId = Uuid().v4();

  void connect() {
    _channel = WebSocketChannel.connect(
      Uri.parse('$serverUrl?client=$clientId'),
    );

    _channel!.stream.listen(
      (message) {
        final response = jsonDecode(message);
        print('📨 Respuesta: $response');

        if (response['success'] == true) {
          print('✅ ${response['message']}');
        } else {
          print('❌ Error: ${response['error']}');
        }
      },
      onError: (error) => print('Error: $error'),
      onDone: () {
        print('Conexión cerrada, reconectando...');
        Future.delayed(Duration(seconds: 3), () => connect());
      },
    );
  }

  Future<List<Map<String, dynamic>>> getAvailableAgents() async {
    try {
      final response = await http.get(
        Uri.parse('${serverUrl.replaceAll('ws://', 'http://')}/agents'),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(data['agents']);
      }
    } catch (e) {
      print('Error obteniendo agentes: $e');
    }
    return [];
  }

  void printToAgent({
    required String agentId,
    required String printerIp,
    required String content,
    int port = 9100,
  }) {
    if (_channel == null) connect();

    final message = jsonEncode({
      'action': 'print',
      'agentId': agentId,
      'ip': printerIp,
      'port': port,
      'content': content,
    });

    _channel?.sink.add(message);
  }

  void dispose() {
    _channel?.sink.close();
  }
}

// Widget de ejemplo
class PrinterWidget extends StatefulWidget {
  @override
  _PrinterWidgetState createState() => _PrinterWidgetState();
}

class _PrinterWidgetState extends State<PrinterWidget> {
  late PrinterService printerService;
  List<Map<String, dynamic>> agents = [];
  String? selectedAgent;

  @override
  void initState() {
    super.initState();
    printerService = PrinterService(
      serverUrl: 'ws://tu-vps.com:3000', // Cambia por tu VPS
    );
    printerService.connect();
    _loadAgents();
  }

  Future<void> _loadAgents() async {
    final agentList = await printerService.getAvailableAgents();
    setState(() {
      agents = agentList;
      if (agents.isNotEmpty) {
        selectedAgent = agents.first['id'];
      }
    });
  }

  void _print() {
    if (selectedAgent == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('No hay agentes disponibles')));
      return;
    }

    printerService.printToAgent(
      agentId: selectedAgent!,
      printerIp: '192.168.0.172',
      content: 'Hola desde Flutter Web!\n\n',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        DropdownButton<String>(
          value: selectedAgent,
          hint: Text('Seleccionar agente'),
          items: agents.map((agent) {
            return DropdownMenuItem<String>(
              value: agent['id'] as String,
              child: Text(agent['id'] as String),
            );
          }).toList(),
          onChanged: (value) {
            setState(() => selectedAgent = value);
          },
        ),
        ElevatedButton(onPressed: _print, child: Text('Imprimir')),
        ElevatedButton(
          onPressed: _loadAgents,
          child: Text('Actualizar agentes'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    printerService.dispose();
    super.dispose();
  }
}
