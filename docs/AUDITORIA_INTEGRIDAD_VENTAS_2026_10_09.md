# Integridad de ventas — 9 de octubre de 2026

Se revisaron los caminos de apertura, respaldo, recuperación, cambio de
cuenta y sincronización de venta rápida, manual, mesas por zona y delivery.
El negocio indicado para contrastar un incidente real es **El Encuentro
Food Shop**. No se obtuvo acceso autenticado a su servidor: estos hallazgos
se comprobaron en código, pruebas Flutter y PostgreSQL desechable, no con
sus órdenes de producción. No se han cambiado datos reales.

Correcciones implementadas:

- **Anulación al entrar a una pantalla.** `fn_open_manual_or_quick` cerraba
  ventas anteriores con estado `void`. Ahora retoma la orden viva y deja la
  anulación a la acción explícita del operador. Se conservan órdenes con
  productos y abonos. Las aperturas simultáneas comparten un lock por negocio
  antes de crear zona/mesa virtual. La creación redundante desde el cliente
  se elimina para que la base sea la única autoridad.
- **Sincronización dependiente de Ventas.** El shell inicia un uploader al
  arrancar, al recuperar conexión y al cambiar negocio. Revisa pendientes
  cada cinco segundos mientras está conectado; respeta el backoff de la cola
  y evita ejecuciones simultáneas. También cubre reiniciar la app ya online,
  sin esperar un evento nuevo de reconexión.
- **La subida de otra venta cambiaba la cuenta activa.** La recarga usa el
  mapping de la orden seleccionada, no el último mapping generado por toda
  la cola. Una subida parcial o una operación en error conserva el contenido
  local. Una respuesta antigua de apertura/carga/dirección no puede sustituir
  una selección más reciente ni guardar sus productos en la mesa anterior.
- **Respaldo sobreescrito por lecturas/remaps.** Las mutaciones de cada
  snapshot se serializan. Leer/reconciliar no vuelve a escribir ni borra el
  slot: una lectura antigua podía reemplazar productos nuevos. El índice de
  carritos exige una clave de cifrado durable y un guardado confirmado.
- **Ventas offline sin identidad/contexto propio.** Cada venta rápida o
  manual local se reproduce con un slot estable dedicado, incluso si ya se
  cobró y su snapshot fue retirado. La cola conserva origen, mesa y slot;
  delivery usa su mesa al recrear la orden. Los mappings solo se consideran
  guardados cuando la persistencia local se confirma.
- **Cerrar una pestaña inactiva dejaba una orden huérfana.** Se carga y anula
  la cuenta destino antes de retirar el carrito. Si el cierre falla, se
  conserva. Los pagos pendientes, incluso failed/dead, protegen la misma
  venta tanto con ID local como con UUID remoto. Los markers de cierre
  también reconocen ambos IDs para impedir revivir una cuenta cobrada.
- **Operaciones tardías y rollback completo.** Altas, eliminaciones y cambios
  de cantidad conservan la identidad de su orden. Un rechazo revierte solo
  su línea, sin borrar otros productos agregados mientras esperaba. El
  cierre y su nota se aplican a la cuenta capturada; su respuesta no vacía
  una cuenta elegida después. El envío a cocina captura la ronda antes de
  esperar la red o la impresora, y marca únicamente sus productos enviados;
  productos nuevos quedan pendientes de otra ronda.
- **Un cierre remoto ocultaba contenido todavía pendiente en el Hub.** Antes
  de retirar la proyección o publicar un cierre sintético se revisa la cola
  y el op-log por identidad local/remota. Con pendientes, errores de lectura
  o falta de prueba de confirmación, se conserva y señala el conflicto.
  Una anulación explícita sigue teniendo efecto. El cliente Hub conserva una
  proyección con contenido cuando el host no provee prueba de subida; el
  host puede retirar una cuenta pagada sin operaciones pendientes.
- **Delivery compartía respaldo y podía caer en otra sucursal.** Cada
  delivery persiste bajo su mesa, incluyendo dirección y tipo. La creación
  recibe el negocio activo y valida pertenencia. La lista descarta respuestas
  obsoletas al cambiar negocio. La base serializa consecutivos y conserva
  números mayores de 999 sin truncarlos. La firma antigua del RPC sigue
  disponible para clientes anteriores; esos clientes requieren actualización
  para enviar la sucursal correcta.

La migración `supabase/migrations/20261009_0004_sales_order_continuity.sql`
solo redefine aperturas; no recupera ni modifica órdenes históricas.
El nuevo RPC de venta offline limita ejecución a los roles autenticado y
servicio y valida la identidad del usuario autenticado.

Validación automatizada: ejecutar `flutter test --no-pub test/core/offline
test/sales --reporter expanded` y
`bash supabase/tests/sales_order_continuity_local_test.sh`. Las regresiones
cubren reinicio online, reconexión, reintentos, pagos pendientes remapeados,
ventas separadas sin snapshot, recarga parcial, navegación concurrente,
aislamiento de delivery, reaperturas con abonos y aperturas SQL simultáneas.
El SQL se aplica dos veces en una base temporal para comprobar reejecución;
las pruebas no conectan a producción. El resultado exacto de la última
ejecución se registra al cerrar esta revisión.

El diagnóstico `scripts/diagnostics/encuentro_food_shop_order_continuity.sql`
contiene solo consultas. Primero identifica los dos negocios referenciados
en el script de acceso del proyecto (Food Shop y El Encuentro); después
revisa definiciones instaladas, estados por día, órdenes anuladas con
contenido/pagos, sesiones cerradas con órdenes pendientes y zonas duplicadas.
Una fila candidata no prueba dinero perdido ni autoriza reabrirla: necesita
contraste con fecha, cuenta, pago y motivo de anulación.

Para activar los cambios se necesita aplicar esta migración antes de publicar
la aplicación actualizada en los equipos. No se ha ejecutado ese despliegue.
En producción falta confirmar las migraciones anteriores de idempotencia y
protección de órdenes huérfanas, revisar el incidente concreto y probar el
ciclo completo en dos terminales con cortes de internet, reinicio y cobro.
El protocolo entre terminales aisladas descrito en
`docs/INTEGRIDAD_MESAS_PEDIDOS_OFFLINE.md` sigue requiriendo validación: una
base remota no conoce operaciones que aún viven únicamente en otro equipo.
Las pruebas locales no justifican prometer ausencia absoluta de pérdidas en
un entorno que todavía no se ha actualizado ni observado.
Si el barrido cerró una orden y otra sesión reutilizó su mesa, el servidor
puede devolver `MP402`: los pendientes se conservan para recuperación
explícita. No se transfieren silenciosamente a la sesión nueva. La
conciliación corregida mantiene visible el conflicto; confirmar que una
mesa está vacía entre terminales aisladas sigue requiriendo un protocolo
de confirmaciones de todos esos equipos.

## Corrección (diseño final)

Esta sección reemplaza lo que arriba diga en contra; en particular, ya no
aplica que `fn_open_manual_or_quick` «retoma la orden viva».

- **Carriles solo-nuevos.** `fn_open_manual_or_quick` (app nueva y vieja)
  siempre abre una venta NUEVA en el primer carril libre del negocio:
  `quick`, `quick#2`, `quick#3`… (`manual`, `manual#2`…), con etiquetas
  «Venta rapida», «Venta rapida 2»… Nunca entrega la cuenta de otra caja
  ni anula órdenes. Si el carril tiene una sesión abierta sin órdenes vivas,
  la cierra (no hay dinero) y abre otra, sin 23505. Límite: 50 carriles,
  con un error claro. El carrito retail y la venta offline siguen
  retomando por su slot exacto (replays idempotentes).
- **«Por equipo» se resuelve en el cliente.** Cada instalación guarda en
  su respaldo local (slot `quick`/`manual` por negocio) el id de su venta y
  la retoma por id solo si el servidor confirma que la sesión de esa orden
  (`table_sessions.origin`) es del mismo origen que la pantalla y sigue
  abierta. Si no lo confirma, la suelta y abre una venta nueva. No se usa
  `Order.origin`: `orders` no tiene esa columna y siempre llega como
  `table`. Los borradores locales `local-order-…` se retoman como antes, y
  «Asignar a mesa» desde Venta Manual suelta el slot `manual`.
- **Orden de despliegue obligatorio: primero la migración, después la
  app.** La app nueva llama a `fn_open_offline_sale` y a
  `fn_open_delivery_order` de 4 argumentos, que solo existen tras
  `20261009_0004`. Si la app llega antes, crear delivery falla (PGRST202) y
  las ventas manuales hechas sin internet no suben. Las defensas previstas
  en la app (PGRST202 sin pasar a dead; delivery que recurre a la firma de
  3 argumentos, donde el servidor elige la sucursal más antigua del
  usuario) solo son respaldo y no sustituyen este orden. Si ocurre, se
  aplica la migración y se toca «Sincronizar ahora» en cada equipo
  afectado. La app anterior funciona con la migración ya aplicada.
- **Antes de aplicar la migración.** Correr los bloques 1, 6, 7, 8, 9 y 10
  de `scripts/diagnostics/encuentro_food_shop_order_continuity.sql` y
  guardar su salida (el bloque 1 es el rollback real). La migración NO
  detecta que un cuerpo o un ACL vivo difiera del repo: `CREATE OR
  REPLACE` lo reemplaza sin error. Por eso hay que comparar a mano las
  definiciones del bloque 1 con los cuerpos del repo. Solo aborta, sin
  cambiar nada, en dos casos: si algún overload vivo de
  `fn_open_manual_or_quick`, `fn_open_retail_cart` o
  `fn_open_delivery_order` contiene `fn_require_open_cash_session` u
  `ORIGIN_NOT_ALLOWED` (se revisa antes de borrar el overload legacy de 3
  argumentos), o si quedan overloads inesperados. Si aborta por esas
  guardas, hay que decidir de forma explícita si se conservan o se
  eliminan antes de volver a aplicarla. No hay comparación automática de
  huellas md5. `bash supabase/tests/sales_order_continuity_local_test.sh`
  cubre ese aborto y comprueba que no cambia nada.
