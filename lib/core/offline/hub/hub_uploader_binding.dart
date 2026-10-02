import 'hub_config.dart';

/// Keeps the uploader stable while its destination has not changed.
class HubUploaderBinding {
  ({String businessId, TerminalMode mode, String? url})? _current;

  bool shouldBind({
    required String businessId,
    required TerminalMode mode,
    String? url,
  }) {
    final next = (
      businessId: businessId,
      mode: mode,
      url: mode == TerminalMode.hubClient ? url : null,
    );
    if (_current == next) return false;
    _current = next;
    return true;
  }

  void reset() => _current = null;
}
