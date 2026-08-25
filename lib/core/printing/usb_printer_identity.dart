/// Identidad de una impresora USB tal como se guarda en `device_path` / `mac`.
///
/// `vendorId:productId` alcanzaba mientras hubiera UNA sola térmica por OTG,
/// pero dos impresoras del mismo modelo comparten esos números: el ticket
/// salía en cualquiera de las dos. Por eso la identidad guarda también el
/// dispositivo concreto:
///
///   - [deviceName]: ruta del bus (`/dev/bus/usb/001/003`). Identifica el
///     puerto físico; cambia si se recablea.
///   - [serialNumber]: sobrevive al cambio de puerto, pero muchas térmicas
///     genéricas no lo exponen (y en Android 10+ leerlo exige permiso).
///
/// Formato de almacenamiento: `"4611:8215?dev=%2Fdev%2Fbus%2Fusb%2F001%2F003&sn=XYZ"`.
/// La cola va como query y no como segmentos de ruta porque el `deviceName`
/// de Android ES una ruta y se comería el separador.
class UsbPrinterIdentity {
  final int vendorId;
  final int productId;
  final String? deviceName;
  final String? serialNumber;

  const UsbPrinterIdentity({
    required this.vendorId,
    required this.productId,
    this.deviceName,
    this.serialNumber,
  });

  /// Cadena para guardar en `device_path` / `mac`.
  String get storageValue {
    final buffer = StringBuffer('$vendorId:$productId');
    final params = <String>[
      if (deviceName != null && deviceName!.isNotEmpty)
        'dev=${Uri.encodeComponent(deviceName!)}',
      if (serialNumber != null && serialNumber!.isNotEmpty)
        'sn=${Uri.encodeComponent(serialNumber!)}',
    ];
    if (params.isNotEmpty) {
      buffer.write('?${params.join('&')}');
    }
    return buffer.toString();
  }

  /// Clave para deduplicar dispositivos en el descubrimiento. Dos impresoras
  /// iguales solo se distinguen por serie o puerto, así que la clave los
  /// prefiere antes que caer a `vid:pid`.
  String get discoveryKey {
    if (serialNumber != null && serialNumber!.isNotEmpty) {
      return 'usb-sn:$serialNumber';
    }
    if (deviceName != null && deviceName!.isNotEmpty) {
      return 'usb-dev:$deviceName';
    }
    return 'usb:$vendorId:$productId';
  }

  /// Construye la identidad desde un mapa de `AndroidUsbRawPrinter.listDevices()`
  /// (o del listado del agente). Devuelve `null` si falta vendor/product.
  static UsbPrinterIdentity? fromDeviceMap(Map<dynamic, dynamic> device) {
    final vendorId = int.tryParse(device['vendorId']?.toString() ?? '');
    final productId = int.tryParse(device['productId']?.toString() ?? '');
    if (vendorId == null || productId == null) return null;
    final deviceName = device['deviceName']?.toString().trim();
    final serial = device['serialNumber']?.toString().trim();
    return UsbPrinterIdentity(
      vendorId: vendorId,
      productId: productId,
      deviceName: (deviceName?.isEmpty ?? true) ? null : deviceName,
      serialNumber: (serial?.isEmpty ?? true) ? null : serial,
    );
  }

  /// Parsea una identidad guardada. Soporta los formatos históricos para que
  /// las impresoras ya configuradas sigan imprimiendo sin reconfigurarse:
  ///   - `"4611:8215"`                                  (legado Android, decimal)
  ///   - `"usb://1a2b:3c4d"`                            (legado desktop, hex)
  ///   - `"usb://1a2b:3c4d/serie"`                      (legado con serie)
  ///   - `"4611:8215?dev=/dev/bus/usb/001/003&sn=XYZ"`  (actual)
  static UsbPrinterIdentity? parse(String? raw) {
    final s = raw?.trim();
    if (s == null || s.isEmpty) return null;

    var body = s;
    if (body.contains('://')) body = body.split('://').last;

    String? deviceName;
    String? serialNumber;

    final qIndex = body.indexOf('?');
    if (qIndex >= 0) {
      final query = body.substring(qIndex + 1);
      body = body.substring(0, qIndex);
      for (final pair in query.split('&')) {
        final eq = pair.indexOf('=');
        if (eq <= 0) continue;
        final key = pair.substring(0, eq);
        final String value;
        try {
          value = Uri.decodeComponent(pair.substring(eq + 1)).trim();
        } catch (_) {
          continue; // valor mal codificado: se ignora, no rompe la impresión
        }
        if (value.isEmpty) continue;
        if (key == 'dev') deviceName = value;
        if (key == 'sn') serialNumber = value;
      }
    }

    // Formato legado `usb://1a2b:3c4d/serie`: lo que va tras la primera '/'
    // era la serie. Se conserva como tal en vez de descartarlo.
    if (body.contains('/')) {
      final slash = body.indexOf('/');
      final tail = body.substring(slash + 1).trim();
      body = body.substring(0, slash);
      if (tail.isNotEmpty) serialNumber ??= tail;
    }

    final parts = body.split(':');
    if (parts.length < 2) return null;

    // Android guarda decimal; desktop guarda hex. Intentamos decimal y si el
    // token trae dígitos hex (a-f) caemos a base 16.
    int? parseId(String t) {
      final tk = t.trim();
      if (tk.isEmpty) return null;
      return int.tryParse(tk) ?? int.tryParse(tk, radix: 16);
    }

    final vid = parseId(parts[0]);
    final pid = parseId(parts[1]);
    if (vid == null || pid == null) return null;

    return UsbPrinterIdentity(
      vendorId: vid,
      productId: pid,
      deviceName: deviceName,
      serialNumber: serialNumber,
    );
  }

  @override
  String toString() => storageValue;
}
