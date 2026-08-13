/// Estado del cromo global, resuelto **por excepción**.
///
/// La barra superior mantenía tres badges permanentes — nube, impresora y
/// Bluetooth — que responden todos a la misma pregunta: *¿la comanda va a
/// salir?*. El 95 % del turno los tres dicen que no pasa nada, así que reservan
/// altura fija para una excepción. Aquí se colapsan en un único estado con
/// prioridad definida, que en reposo no ocupa nada.
///
/// `resolve` es una función pura: se prueba sin `WidgetTester` ni providers.
library;

enum ChromeStatus {
  /// Todo en orden. No se dibuja banner; solo el punto del encabezado.
  ok,

  /// Hay comandas en cola sin imprimir. Prioridad 2.
  printQueue,

  /// Sin conexión al servidor: se está guardando local. Prioridad 1.
  offline,
}

extension ChromeStatusX on ChromeStatus {
  bool get isOk => this == ChromeStatus.ok;

  /// El banner solo existe fuera de [ChromeStatus.ok].
  bool get needsBanner => this != ChromeStatus.ok;
}

/// Resuelve el estado con la prioridad del PRD §7.1.
///
/// Sin conexión gana sobre la cola de impresión: si no hay servidor, la cola
/// no es el problema que el mesero puede resolver.
ChromeStatus resolveChromeStatus({
  required bool serverReachable,
  required int printQueue,
}) {
  if (!serverReachable) return ChromeStatus.offline; // prioridad 1
  if (printQueue > 0) return ChromeStatus.printQueue; // prioridad 2
  return ChromeStatus.ok;
}
