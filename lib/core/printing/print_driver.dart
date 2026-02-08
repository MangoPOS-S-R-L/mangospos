import 'dart:async';
import 'print_job.dart';

/// Abstract class defining the capabilities of a Print Driver
abstract class PrintDriver {
  /// Unique identifier of the driver (e.g. 'agent', 'native')
  String get id;

  /// Check if the driver is available/ready
  Future<bool> isAvailable();

  /// Discover printers supported by this driver
  /// Returns a list of printer configuration/metadata
  Future<List<Map<String, dynamic>>> discoverPrinters();

  /// Send a print job
  /// Throws Exception on critical failure
  Future<void> print(PrintJob job);

  /// Check status of a specific printer
  Future<bool> checkPrinterStatus(String printerId);
}
