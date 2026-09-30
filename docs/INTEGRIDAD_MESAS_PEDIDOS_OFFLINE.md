# Integridad de mesas y pedidos offline

Estado: 2026-09-30. Objetivo: ninguna comanda, producto, mesa o cobro debe
desaparecer silenciosamente por una recarga, un borrado fallido, una particion
de red o una sincronizacion parcial. "100%" solo se puede afirmar tras pasar
las pruebas de aceptacion en equipos reales y verificar las migraciones en el
negocio. Si dos equipos quedan aislados entre si, no existe forma de prometer
consistencia inmediata entre ambos; cada uno debe conservar sus operaciones y
mostrar el conflicto al reconectar, nunca sobrescribirlas silenciosamente.

## Implementado en esta revision

- El salon del Hub conserva visible una orden abierta aun con cero items
  proyectados. Solo `void_order` o un cierre/cobro total la retiran.
- Buscar una mesa ya no devuelve `null` por encontrar primero una orden vieja
  anulada. Si hay dos ordenes abiertas, una vacia no tapa otra con productos.
- Un `DELETE` de `order_items` que afecta cero filas ya no se informa como
  exitoso: se verifica la fila y se usa el RPC para distinguir ausencia o
  permisos. El replay offline mantiene la ausencia como operacion idempotente.
- El ViewModel rechaza borrar un ID que no esta en la orden actual. Si no puede
  persistir la accion offline en la cola, restaura el producto y muestra error.
  Si la cola se guardo pero falla el snapshot, avisa que no se cierre el equipo
  hasta sincronizar; esta condicion sigue siendo un riesgo a resolver.
- Un fallo al cerrar automaticamente una subcuenta vacia despues del DELETE ya
  no restaura en pantalla el producto que el servidor realmente elimino ni
  encola una segunda eliminacion.
- Pruebas unitarias cubren las reglas del Hub, borrado sin filas y borradores
  locales pendientes. No sustituyen una prueba de integracion Windows/LAN.
- Al salir de una mesa vacia, la liberacion confirmada por el servidor se
  refleja en el Hub y refresca el salon; `dispose()` ya no pierde ese callback.
  Una orden local que llego al Hub no se descarta silenciosamente: encola
  `release_empty_order`, que solo cierra si el Hub y el RPC la ven vacia.
  Una orden local aun no entregada se descarta junto con su snapshot. La salida
  por rutas distintas de Atrás aplica la misma limpieza una sola vez.
- Si una mesa con ID de servidor se abre en un cliente Hub o pierde internet
  durante la salida, la liberacion se guarda primero en la cola local y se
  reenvia al Hub/servidor. No depende de una llamada WAN en ese instante.

## Pendiente critico (P0)

1. **Conservar la liberacion automatica, pero no basarla en una lectura incompleta.**
   `table_order_screen.dart` programa `fn_release_empty_table` al salir si el
   estado local esta vacio. `sales_by_zone_viewmodel.dart` ejecuta
   `fn_release_empty_tables` con 15 minutos de gracia, y tambien puede existir
   un cron en PostgreSQL. El servidor no puede ver una comanda que sigue en la
   cola de otro Windows; por eso `COUNT(order_items)=0` no es prueba suficiente
   para anular orden y cerrar sesion. La preferencia operativa es que la mesa
   se libere sola: el protocolo pendiente debe esperar la confirmacion de las
   operaciones de todos los equipos conocidos, o mantenerla ocupada mientras
   alguno este aislado. La funcion actual sigue siendo automatica, pero no
   cumple esa garantia; no afirmar que las mesas no desaparecen.

2. **No borrar fisicamente productos enviados a cocina.** Reemplazar
   `DELETE` por tombstone/estado `void` con `operation_id`, razon, PIN/actor,
   terminal y timestamp. El trigger `order_item_removals` actual no registra
   borradores y captura errores sin bloquear el borrado; no es un historial
   completo. Las reducciones de cantidad tambien requieren evento inmutable.

3. **Confirmacion durable antes de cambiar la pantalla.** El borrado,
   anulacion, traslado y cobro deben escribirse de forma atomica en una cola
   local transaccional junto con el snapshot/version. Si falla esa escritura,
   conservar el estado anterior. La cola y el Hub deben confirmar con
   `operation_id` y secuencia monotona por orden; reintentar no puede duplicar
   ni perder operaciones. Resolver especialmente el caso "cola guardada,
   snapshot fallido".

4. **Reconciliacion de mesa por identidad, nunca por nombre de producto.**
   Cada `item_id`, `order_id`, `session_id` y `table_id` local debe mapearse a
   su ID remoto. Una dependencia sin mapping bloquea la operacion y alerta;
   no se adivina por nombre/cantidad. Detectar dos ordenes activas para una
   misma mesa como conflicto y mostrar ambas para revision, en vez de escoger
   una y ocultar la otra. La preferencia conservadora actual solo evita que
   una orden vacia tape otra con contenido.

5. **Borrado agrupado explicito.** Desde la vista TODAS, el dialogo actual
   puede eliminar varias filas del mismo producto en distintos checks. Debe
   mostrar exactamente cuantas lineas/unidades y de que subcuentas, pedir
   confirmacion del operador para cada alcance, y probar que eliminar una
   unidad no borra otras filas ni cierra la mesa. Exigir razon/PIN para algo
   ya impreso y mostrar el comprobante de anulacion al area correspondiente.

6. **Cobro y cierre de subcuentas.** Mantener un intento de pago durable e
   idempotente, confirmar pago/NCF/cierre de orden en una transaccion de
   servidor, y no liberar mesa por un abono o cierre parcial. La vista no debe
   mostrar "pagado" antes de la confirmacion durable local o remota. Probar
   caida de red y cierre de app en cada fase del pago.

## Pendiente alto (P1)

- Baseline del Hub: capturar de forma consistente las ordenes e items vivos
  antes de pasar a LAN; verificar version/frescura y advertir si falta la foto.
  No interpretar "sin datos" como "mesa libre".
- Si el Hub/caja no responde, cada Windows conserva sus operaciones y muestra
  estado "sin sincronizar". Al reconectar, resolver conflictos por eventos y
  secuencias, no por ultimo snapshot que llegue.
- Impresion: outbox local durable por comanda, intento con identificador unico,
  acuse de impresora cuando sea posible, reintentos con deduplicacion y estado
  visible "impreso / pendiente / error". Nunca dar por impresa una comanda
  solo porque se creo un trabajo; tampoco reimprimirla silenciosamente.
- Telemetria y auditoria: poder reconstruir por orden, producto, mesa, equipo
  y operador todos los eventos, impresiones, anulaciones, reintentos y cambios
  de sesion. Retenerlos tras pago y tras reinicio de la app.
- Respaldo y recuperacion: exportar el journal/outbox antes de purgarlo;
  prohibir poda mientras existan eventos no confirmados o conflictos.

## Caso B16 del 26/09/2026

La foto de la comanda muestra `ORDEN #707A0B98`, mesa B16, producto
"Pina Colada Virgen" y hora de impresion 19:23:21. La captura de pantalla
posterior muestra B16 con seis productos distintos, pero no el ID de la
orden. No prueba si es la misma orden, una reapertura o una eliminacion.

Investigar en produccion, solo lectura y con autorizacion del negocio:

1. Resolver el UUID completo cuyo prefijo es `707a0b98`, acotado al negocio y
   al 26/09/2026; comparar su `session_id`, `closed_at`, `status_ext` y mesa.
2. Comparar items vigentes, `order_item_removals`, `audit_logs`, checks,
   pagos, documentos fiscales y sesiones posteriores de B16.
3. Revisar journal offline/Hub y trabajos de impresion de ambos equipos,
   incluyendo IDs de operacion, orden y resultado de cada replay.
4. Si no hay evento de anulacion ni cobro pero la orden o el item desaparecio,
   tratarlo como incidente de integridad, preservar backups/logs y reproducir
   antes de cualquier reparacion de datos.

## Pruebas de aceptacion obligatorias

- Dos Windows (caja Hub y mesero), misma LAN sin internet; abrir B16, agregar
  un item, imprimir comanda, reiniciar ambos, y comprobar identidad/conteo.
- Cortar internet antes, durante y despues de alta, borrado, traslado,
  division de cuenta, pago e impresion. Repetir con LAN disponible y con Hub
  inaccesible. Ningun item impreso debe perderse sin evento auditable.
- Borrar una sola unidad, una linea entre varias del mismo producto y el
  ultimo item. La mesa sigue visible salvo cierre/anulacion explicitos.
- Abrir/cerrar/reabrir la pantalla mientras llega un snapshot viejo; no se
  puede cerrar una sesion con acciones locales o remotas pendientes.
- Dos ordenes activas anomalas en una mesa: ambas quedan recuperables y se
  muestra conflicto, no se descarta ninguna.
- Repetir el mismo `operation_id` diez veces y cortar el proceso tras cada
  escritura; resultado final unico, sin cobro duplicado ni impresion omitida.
- Reconciliar contra PostgreSQL y el Hub al recuperar internet; todo item,
  pago y trabajo de impresion queda confirmado o como conflicto visible.
- Ejecutar suite Flutter, pruebas SQL en PostgreSQL desechable y jornada piloto
  real. Guardar evidencia por escenario antes de declarar el modulo cerrado.

## Criterio de cierre

No se puede certificar "100% offline" mientras exista liberacion automatica
sin conocer pendientes de todos los equipos, borrado fisico sin auditoria
completa, o impresion sin confirmacion durable. Cerrar este documento solo
cuando cada P0 este implementado, desplegado y probado en dos Windows con
caidas de red reproducibles, mas una investigacion concluyente del caso B16.
