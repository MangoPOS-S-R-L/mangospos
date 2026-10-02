class PaymentCompletionGate {
  PaymentCompletionGate(this._onReady);

  final void Function() _onReady;
  bool _confirmed = false;
  bool _closed = false;
  bool _finished = false;

  void confirm() {
    _confirmed = true;
    _finishIfReady();
  }

  void close({bool hasPaymentResult = false}) {
    _closed = true;
    if (hasPaymentResult) _confirmed = true;
    _finishIfReady();
  }

  void _finishIfReady() {
    if (_finished || !_confirmed || !_closed) return;
    _finished = true;
    _onReady();
  }
}
