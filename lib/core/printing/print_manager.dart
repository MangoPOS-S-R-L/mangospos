import 'package:flutter/foundation.dart';
import '../../core/printing/print_driver.dart';
import '../../core/printing/print_job.dart';
import '../../core/printing/agent_driver.dart';
import '../../core/printing/network_driver.dart';

/// Unified Print Manager
///
/// Handles Platform Logic:
/// - Web: Always use Agent
/// - Desktop: Use Agent OR Direct Network
/// - Mobile: Use Agent OR Direct Network
class PrintManager {
  static final PrintManager _instance = PrintManager._internal();
  factory PrintManager() => _instance;
  PrintManager._internal();

  /// Default Agent configuration
  String? _agentUrl;
  String? _agentToken;
  bool _preferDirect = false;

  /// Configure the global print manager
  void configure({
    String? agentUrl,
    String? agentToken,
    bool preferDirect = false,
  }) {
    _agentUrl = agentUrl;
    _agentToken = agentToken;
    _preferDirect = preferDirect;
  }

  Future<void> print(PrintJob job) async {
    final driver = await _selectDriver(job.printerId);
    if (driver == null) {
      throw Exception('No suitable print driver found for platform.');
    }

    await driver.print(job);
  }

  /// Platform Logic: Select best driver
  Future<PrintDriver?> _selectDriver(String printerId) async {
    // 1. Web
    if (kIsWeb) {
      return AgentPrintDriver(
        agentUrl: _agentUrl ?? 'http://localhost:9100',
        apiToken: _agentToken,
      );
    }

    // 2. Desktop/Mobile (Check preference)
    if (_preferDirect) {
      // If direct is preferred, try direct first for network printers
      // Check if printerId looks like an IP (x.x.x.x)
      final direct = NetworkPrintDriver();
      if (await direct.isAvailable()) {
        return direct;
      }
    }

    // 3. Fallback to Agent (even on Desktop)
    // Desktop apps might run the agent locally as a service.
    // Or connect to a remote agent.
    return AgentPrintDriver(
      agentUrl: _agentUrl ?? 'http://localhost:9100',
      apiToken: _agentToken,
    );
  }
}
