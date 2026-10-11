/// Por qué la cola de un negocio tiene trabajo nuevo y ya guardado.
enum OfflineQueueWorkReason {
  /// Una operación nueva quedó guardada en la cola.
  enqueued,

  /// Se guardó el id remoto de una venta local: sus acciones pueden avanzar.
  orderMapped,

  /// Se guardó el id remoto de un producto: una comanda retenida esperando
  /// ese id puede confirmarse.
  itemMapped,

  /// El cajero reactivó a mano operaciones que estaban en dead-letter.
  revived,

  /// Una comanda local terminó de imprimirse (o se resolvió su resultado
  /// incierto): su confirmación en cocina ya puede subir.
  kitchenRound,
}

/// Aviso de que la cola de [businessId] tiene trabajo nuevo DURABLE.
///
/// Se emite después del commit y con el candado de escritura suelto. Pide una
/// subida, no la espera: si nadie lo escucha (o un observador falla) la venta
/// ya guardada no se entera, y nada se pierde porque la cola es durable y el
/// uplink la revisa igual al arrancar, reanudar, reconectar y cada 5 s.
class OfflineQueueWork {
  const OfflineQueueWork({
    required this.businessId,
    required this.reason,
    required this.revision,
  });

  /// Negocio dueño de la operación (el de la acción, no el que esté abierto
  /// en pantalla cuando llega el aviso).
  final String businessId;
  final OfflineQueueWorkReason reason;

  /// Contador de trabajo aceptado de [businessId] en este proceso: crece con
  /// cada aviso. Una pasada que empezó con un valor menor no vio este trabajo.
  final int revision;

  @override
  String toString() =>
      'OfflineQueueWork($businessId, ${reason.name}, rev $revision)';
}
