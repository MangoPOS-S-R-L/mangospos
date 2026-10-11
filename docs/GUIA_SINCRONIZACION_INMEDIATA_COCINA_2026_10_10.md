# Guía de cierre: sincronización inmediata y confirmación de cocina

Fecha: 10 de octubre de 2026. Base revisada: `92c13664`, más el estado de trabajo actual. El comportamiento del build `fec15ee9` también fue contrastado.

Esta guía define implementación, pruebas y publicación. No significa que los cambios estén implementados o instalados. Alcance: subida de la cola y consistencia del envío a cocina; no incluye cambios de precios, impuestos o descuentos.

## 1. Resultado que debemos obtener

Al guardar durablemente una operación, la app debe solicitar su subida inmediatamente, sin esperar al ciclo periódico. Si otra subida está en curso, debe conservar la solicitud y revisar el trabajo nuevo al terminar. Una dependencia que acaba de guardarse también debe despertar el sincronizador.

«Inmediato» significa empezar el intento sin una espera artificial de cinco segundos. La confirmación final depende de la red, del servidor y de las dependencias de la operación. Mientras falte esa confirmación, la app debe conservar los datos y mostrar su estado real.

El recorrido esperado es:

```text
Guardar operación y su identidad en almacenamiento durable
    → emitir solicitud de subida después del commit
    → seleccionar la autoridad de esa cuenta: nube o Hub
    → procesar sin solapar pasadas para el mismo negocio/destino
    → guardar el resultado o el motivo de espera
    → actualizar los equipos y conservar los reintentos necesarios
```

Para cocina se deben distinguir tres hechos: la ronda está guardada; se aceptó el envío a cocina; la impresión fue entregada, quedó pendiente o tiene resultado incierto. Un papel impreso y la confirmación del servidor son hechos diferentes.

## 2. Hallazgos que justifican el cambio

| Lugar | Comportamiento actual | Trabajo necesario |
| --- | --- | --- |
| `lib/core/offline/offline_pos_service.dart`, `enqueueAction` | Guarda antes de usar la red; despierta inmediatamente la entrega al Hub cuando hay uploader. No emite una solicitud equivalente hacia la nube. | Emitir una solicitud después de persistir, para la autoridad que corresponda. |
| `lib/core/offline/offline_sales_uplink.dart` | Se activa al arrancar, reconectar y cada cinco segundos. Ya agrupa solicitudes mientras está ocupado mediante `_triggerAgain`. | Conectar eventos de operaciones nuevas, dependencias resueltas y reanudación. |
| `lib/presentation/shell/offline_sales_uplink_provider.dart` | Solo sincroniza si `hasActionsReadyToSync` encuentra trabajo elegible. | Conservar los eventos que lleguen mientras haya otra pasada o una comprobación de elegibilidad en curso. |
| `SalesViewModel.syncPendingOfflineActions` | Una petición automática se descarta si `_syncInFlight` está activo. Solo las forzadas tienen una pasada posterior explícita. | Conservar la petición automática sin convertirla en `force`. |
| `OfflinePosService.syncPendingActions` | Una llamada concurrente devuelve la pasada activa. Esa pasada leyó una lista de operaciones al comenzar. | Revisar nuevas solicitudes cuando termine; devolver la pasada activa no demuestra que haya procesado una operación añadida después. |
| `SalesViewModel.confirmOrder` | Cualquier producto `tmp_` conduce al envío local, incluso si su alta online sigue terminando. | Esperar las altas de la ronda con un límite y luego elegir el camino correcto. |
| `PrintingService.sendLocalOrderToKitchen` | Imprime antes de encolar `confirm_local_order`. | Registrar la ronda antes del efecto externo y guardar sus resultados por área. |
| `SalesViewModel._runOrderDetailLoad` | Una operación pendiente puede conservar toda la copia local. | Conservar las ediciones pendientes incorporando las confirmaciones de cocina de los mismos productos/rondas. |
| `lib/presentation/sales/view/table_order_screen.dart` | «Pre-Cuenta» usa su bloqueo de acción; no verifica explícitamente frescura y envío pendiente antes de imprimir. | Verificación específica de la cuenta y aviso según el estado real de cocina. |
| `lib/presentation/shell/hub_host_uplink.dart` | El Hub sube su op-log cada cuatro segundos. | Si se exige inmediatez también con Hub, despertar la subida al confirmar un nuevo append durable. |

No usar `_bumpQueueRevision` como evento indiscriminado. Hoy algunas revisiones cambian en un `finally`, incluso si una escritura falló, y otras cambian durante el replay. Eso podría disparar subidas sin commit o producir ciclos de reintento continuos.

## 3. Fase 1: disparar la subida después de guardar

### 3.1 Contrato de eventos

Crear una señal interna con negocio, motivo y revisión/secuencia durable. Los nombres concretos pueden adaptarse al proyecto. Debe cubrir:

- Nueva operación aceptada en la cola.
- Mapeo local → remoto guardado, de orden o de producto, que puede desbloquear una operación.
- Dependencia de una ronda completada.
- Arranque, reanudación de la app, reconexión y cambio de negocio autorizado.
- Append confirmado en el op-log del Hub, cuando corresponda.

Emitir después de que la transacción termine correctamente y después de liberar el bloqueo de escritura. La señal solicita trabajo; no espera la red y no debe hacer fallar una venta ya guardada si un observador falla. El almacenamiento durable permite recuperar una señal perdida al reiniciar.

No disparar una nueva pasada por cada actualización interna de `processing`, `completed`, contadores o errores. Una operación retenida sin una dependencia nueva no debe generar un ciclo sin fin.

### 3.2 Conectar el coordinador

El coordinador debe vivir mientras la sesión de la app esté activa, independientemente de que Ventas esté abierta. Verificar su inicialización en los recorridos de escritorio, tablet y móvil; no asumir que todos pasan por el mismo shell.

Suscribirse a la señal, filtrar el negocio correcto y solicitar `trigger()`. Mantener el ciclo de cinco segundos como recuperación para señales perdidas y reintentos cuyo plazo vence. Agregar el disparo al volver la app al primer plano.

No prometer ejecución de timers cuando el sistema operativo suspenda el proceso. Al reanudar debe revisar la cola durable inmediatamente.

### 3.3 Evitar perder solicitudes durante otra pasada

Conservar una revisión solicitada y la revisión de trabajo observada al iniciar cada pasada. Después de soltar los bloqueos, si llegó trabajo nuevo, volver a comprobar elegibilidad y ejecutar otra pasada. Agrupar múltiples solicitudes en esa comprobación; no lanzar una pasada paralela por cada evento.

Resolver los tres niveles que hoy pueden ocultar una solicitud: `_busy` del uplink, `_syncInFlight` del VM y `_queueSyncInFlight` del servicio. En particular, si `hasActionsReadyToSync` responde falso porque el servicio está ocupado, la solicitud debe esperar al fin de esa pasada, no desaparecer.

La repetición automática debe usar `force: false`. No ignorar backoff, no reactivar dead-letter automáticamente y no pasar una operación propiedad del Hub a la nube. Reutilizar las reglas de `_replayGate` y sus excepciones para comandas retenidas; respetar las dependencias de cada cuenta y permitir avanzar cuentas independientes.

### 3.4 Despertar al resolver dependencias

Conectar los commits de `_saveItemMapping`, `_saveOrderMapping` y las altas de producto/oferta con operaciones retenidas que dependan de ellos. El evento debe llevar el negocio capturado en la operación original, no el que esté abierto después en pantalla.

Si el motivo de retención era exclusivamente un ID todavía inexistente y ahora se resolvió, habilitar ese reintento sin esperar un backoff causado por esa dependencia. Conservar las esperas de errores de transporte, límites del servidor o migraciones faltantes. No borrar motivos distintos a la dependencia resuelta.

## 4. Fase 2: pulsar «Enviar» mientras un producto se guarda

1. Capturar negocio, cuenta, selección, productos, cantidades y ronda al pulsar «Enviar».
2. Registrar futures de las altas de esa ronda, incluyendo ofertas y modificadores con efecto en su contenido. Un conjunto de IDs temporales por sí solo no permite esperar el resultado del guardado.
3. Esperar esas altas con un presupuesto limitado y configurable. No esperar auditorías o consultas auxiliares que no condicionen el contenido de cocina.
4. Resolver los IDs finales conservando la identidad original de la operación. Un timeout no demuestra que el servidor no guardó el producto: repetir con el mismo `client_op_id` y conciliar.
5. Si la ronda está completa en su autoridad disponible, enviar únicamente sus IDs. Evaluar el camino `onlyItemIds`, que ya existe, para evitar que una nueva línea agregada durante la espera se incluya en la ronda capturada.
6. Si una alta quedó en la cola o hay un corte de conexión, continuar por el camino local durable. Una caída temporal no debe borrar ni omitir esos productos.
7. Al finalizar un alta tardía, guardar el mapeo y solicitar inmediatamente la confirmación pendiente de esa misma ronda.

Mantener el bloqueo de edición de las líneas capturadas durante su envío. No incluir productos agregados después en una ronda anterior. Con Hub configurado como autoridad, usarlo con internet y sin internet; este cambio no autoriza a saltarlo mediante una escritura directa a la nube.

Esperar el guardado reduce el uso innecesario del camino local. No reemplaza el arreglo del disparo inmediato ni la recuperación de operaciones atascadas.

## 5. Fase 3: conservar la ronda y su confirmación de cocina

### 5.1 Registro durable anterior a la impresión

Guardar antes de imprimir: ID de ronda estable, negocio, cuenta, identidades de los productos, cantidades y áreas. No publicar una operación incompleta como «lista para imprimir» al replay mientras el envío local sigue reclamado.

Diseñar una reclamación durable con recuperación por vencimiento/reinicio, compartida entre envío local y replay. Ambos deben reutilizar la identidad de la ronda y las claves de deduplicación por área. Tras cada área, guardar si fue entregada, aceptada en una cola de impresión, quedó pendiente o tiene resultado incierto.

Una impresora térmica común no ofrece una transacción atómica con SQLite o PostgreSQL. Si la app muere después de sacar papel y antes de guardar el resultado, no se puede garantizar «exactamente una impresión» solo moviendo el orden del código. Ese intervalo debe quedar como resultado incierto, con recuperación visible y sin reimprimir automáticamente a ciegas.

Si el papel ya salió y solo falta la confirmación del servidor, el replay debe confirmar los IDs de esa ronda sin generar otra impresión. Revisar la migración `20261010_0002_confirm_order_items_to_kitchen.sql` y su definición viva antes de publicar; una migración en el repositorio no acredita que esté instalada.

### 5.2 Reconciliar estado sin revertir confirmaciones

Conservar los cambios locales por campo/producto y el registro de rondas, en lugar de bloquear toda actualización del servidor por una nota pendiente.

- Misma línea y ronda confirmada en servidor: incorporar esa confirmación aunque quede una edición local pendiente.
- Misma ronda enviada localmente con confirmación pendiente: una respuesta antigua `draft` no borra la evidencia local; mostrar «Enviado localmente · pendiente de sincronizar».
- Incremento posterior: es contenido nuevo pendiente, no queda confirmado por la ronda anterior.
- Producto realmente nuevo: sigue sin enviar hasta que tenga su propia ronda.
- Cuenta cobrada o anulada por el servidor: aplicar las reglas de cierre existentes; no revivirla solo porque tenga una marca local de cocina.

Evitar comparar únicamente nombres o `product_id`: dos rondas pueden contener el mismo producto. Usar IDs de línea, su mapeo, cantidades y la identidad de ronda. Si hace falta ampliar el backend, versionar el contrato y preparar compatibilidad antes del rollout.

En equipos que todavía no reciben el dato por nube o Hub, no inventar una confirmación. Mostrar que la información está pendiente de actualizar.

## 6. Fase 4: precuenta y diagnóstico visible

Deshabilitar «Pre-Cuenta» durante la verificación inicial de la cuenta mediante un estado específico, no mediante cualquier `loading` que pueda quedar pegado. La verificación debe tener límite y resultado explícito: datos verificados, copia local disponible o error de actualización.

Después de la recarga, clasificar por ronda antes de ofrecer acciones:

- Sin enviar: lista de productos y «Enviar a cocina / Imprimir igual / Cancelar», según la propuesta del usuario.
- Enviado localmente, falta confirmación: informar la sincronización pendiente y permitir precuenta; no ofrecer un segundo envío de la misma ronda.
- Impresión pendiente o incierta: mostrar el área y su motivo; recuperar/reimprimir con una acción específica de esa ronda.

Capturar cuenta y selección para que cambiar de mesa durante la espera no imprima otra cuenta. Después de cualquier acción del aviso, volver a comprobar el estado de esa misma cuenta antes de imprimir.

En la sincronización automática, usar barra fija y visor de cola, sin mensajes emergentes por cada pasada. Mostrar pendiente más antiguo, última pasada, último avance real, intentos y motivo: esperando producto, sin conexión, reintento programado, error del servidor o revisión necesaria. No usar «Todo sincronizado» si todavía quedan comandas sin confirmar o en cuarentena.

Registrar negocio, dispositivo, cuenta, ronda, operación y marcas de tiempo de guardado, solicitud, inicio, resultado y confirmación. No incluir tokens ni credenciales. Esto debe permitir explicar una retención de 72 minutos, no solo mostrar un contador.

## 7. Pruebas automáticas obligatorias

Los nuevos tests deben fallar con el código anterior y pasar con la implementación. Usar reloj controlado, HTTP simulado, SQLite temporal y dos instancias independientes. Para los efectos backend, usar PostgreSQL real desechable. No usar un piloto físico como sustituto de estas pruebas.

| ID | Escenario | Resultado exigido |
| --- | --- | --- |
| S01 | App online e inactiva; se encola una operación | Empieza el intento sin avanzar el reloj hasta el timer de cinco segundos. |
| S02 | La escritura durable falla | No se emite aceptación ni se sube una operación no guardada. |
| S03 | Nueva operación después de que una pasada leyó su cola | Segunda revisión inmediata al terminar; ningún evento perdido ni solapamiento. |
| S04 | Otra entrada, VM o servicio ya está sincronizando | Se conserva la solicitud hasta que libera el bloqueo. |
| S05 | Muchos eventos durante una pasada | Se agrupan; concurrencia máxima por destino = 1; sin bucle de pasadas vacías. |
| S06 | Sin red, arranque, reanudación y reconexión | Datos retenidos; intento inmediato al recuperar condiciones; no depende de abrir Ventas. |
| S07 | Backoff, dead-letter y fallo de otra cuenta | Respeta retenciones y procesa trabajo independiente sin usar `force`. |
| S08 | «Enviar» durante un alta de producto/oferta/modificadores | Cocina recibe una vez exactamente la ronda capturada. |
| S09 | Alta tarda o pierde la respuesta después del commit | Misma identidad al conciliar; un producto y una confirmación, sin inserción duplicada. |
| S10 | Comanda retenida por mapeo que se guarda después | Se desbloquea inmediatamente y confirma solo sus productos. |
| S11 | Se agrega una ronda nueva durante el envío anterior | No se confirma ni imprime como parte de la anterior. |
| S12 | Comanda local impresa; vuelve internet | Confirma sin reimprimir áreas ya entregadas. |
| S13 | Reinicio antes de imprimir, después de imprimir y antes del ACK | Recuperación durable; el resultado incierto se identifica y no se reimprime a ciegas. |
| S14 | Servidor confirmado y caja con una nota pendiente | Caja incorpora la confirmación y conserva la nota. Reproducir el fallo local encontrado en A26. |
| S15 | Enviado localmente y lectura antigua del servidor | No vuelve a «sin enviar»; conserva la ronda y su aviso de sincronización. |
| S16 | Precuenta durante hidratación, fallo de recarga y cambio de mesa | No imprime otra cuenta; distingue sin enviar de confirmación pendiente. |
| S17 | Dos equipos, Hub con WAN disponible y luego cortada | Autoridad consistente, dato compartido por LAN y subida al volver WAN sin replay doble. |
| S18 | Cambiar negocio mientras una dependencia termina | El evento conserva el negocio original; no altera la cuenta del negocio nuevo. |
| S19 | Falta RPC o permiso backend | Operación conservada con motivo visible; no se marca completada ni se repite papel. |
| S20 | Cantidad adicional del mismo producto y cierre concurrente | Confirmación solo de la ronda original; incremento pendiente; no resucita cuenta cerrada. |

Ampliar como mínimo:

- `test/core/offline/offline_sales_uplink_test.dart`.
- `test/core/offline/queue_sync_readiness_test.dart`.
- `test/core/offline/confirm_local_order_items_replay_test.dart`.
- `test/sales/kitchen_local_print_edit_guard_test.dart`.
- `test/sales/open_resume_integrity_test.dart`.
- `test/sales/offline_sync_silent_test.dart`.
- `test/core/offline/pending_kitchen_prints_test.dart`.
- `test/core/offline/hub_kitchen_quarantine_test.dart`.
- `supabase/tests/confirm_order_items_to_kitchen_local_test.sh`.

Agregar pruebas de integración para la señal post-commit real y el coordinador real; probar `trigger()` directamente no demuestra que `enqueueAction` lo invoque.

## 8. Publicación y recuperación de pendientes existentes

1. Implementar en cambios separados: eventos/serialización; espera de altas; persistencia de rondas; reconciliación de estado; precuenta/diagnóstico.
2. Ejecutar los tests del flujo modificado, análisis estático y las regresiones de cola, cocina, pagos y cierre pertinentes. Guardar comando, resultado y commit exacto. Una prueba que reproduce el fallo no cuenta como prueba de que ya se arregló.
3. Si cambia el backend o el formato durable, aplicar contratos compatibles antes de activar la app nueva. Las rondas antiguas sin IDs no pueden transformarse en «confirmar toda la orden»; conservar su revisión manual.
4. Publicar un build identificable y registrar versión por equipo: caja, meseros y Hub. La publicación por sí sola no acredita instalación. No activar contratos que excluyan equipos viejos hasta completar el inventario.
5. Conservar cola, snapshots, mapas e identidades durante actualización y rollback. La desactivación del disparo inmediato no debe borrar pendientes ni invalidar rondas ya registradas. Separar este rollout de T02 y otros cambios que requieran actualización coordinada de todos los equipos.
6. Para A26 y otros pendientes existentes, inspeccionar el equipo que envió: cuenta, IDs de productos, ronda, áreas impresas, acción `confirm_local_order`, mapeos y último error. Contrastar con SQL. Confirmar solo la ronda acreditada sin reimprimir; no marcar todos los borradores enviados ni vaciar la cola para quitar el aviso.
7. Si falta evidencia de la ronda o el resultado de impresión es incierto, conservarla para resolución explícita. La ausencia de una marca SQL no demuestra que el papel no salió.

## 9. Criterios para declarar cerrado este problema

- [ ] La señal se emite después del commit durable y alcanza el coordinador sin esperar un timer.
- [ ] Ninguna solicitud nueva se pierde durante una pasada o comprobación en curso.
- [ ] Resolver una dependencia activa el trabajo correspondiente sin alterar otras retenciones.
- [ ] La subida opera desde la sesión de la app, con arranque y reanudación cubiertos en los recorridos soportados.
- [ ] Las comandas tienen registro durable previo al efecto externo, recuperación e identidad estable por ronda/área.
- [ ] Una confirmación local o del servidor no retrocede por una copia anterior; los productos añadidos después siguen pendientes.
- [ ] S01–S20 pasan, con evidencia en SQLite y PostgreSQL para los casos que lo requieren.
- [ ] No se genera otra comanda cuando solo falta confirmar una impresión ya entregada.
- [ ] Los estados pendientes e inciertos son visibles y tienen causa trazable.
- [ ] Backend compatible e inventario de instalaciones completados; pendientes anteriores conciliados o retenidos explícitamente.

No declarar «solucionado definitivamente» solo porque el timer pasó de tres minutos a cinco segundos o porque una ejecución no mostró pendientes. El cierre exige demostrar el disparo inmediato, la recuperación, la consistencia entre equipos y la ausencia de duplicación en los casos descritos.
