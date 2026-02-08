enum PrintJobStatus { queued, printing, completed, failed, retrying }

class PrintJob {
  final String id;
  final String printerId;
  final String content; // Text or Raw Base64
  final bool isRaw;
  final DateTime createdAt;
  PrintJobStatus status;

  PrintJob({
    required this.id,
    required this.printerId,
    required this.content,
    this.isRaw = false,
    required this.createdAt,
    this.status = PrintJobStatus.queued,
  });

  Map<String, dynamic> toJson() {
    return {
      'printerId': printerId,
      'type': isRaw ? 'raw' : 'text',
      'content': content,
      // Metadata handled by agent
    };
  }
}
