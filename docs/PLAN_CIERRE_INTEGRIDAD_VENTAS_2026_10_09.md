# Plan de cierre y validación de integridad de ventas

Fecha: 9 de octubre de 2026. Estado: **pendiente de implementación y validación final**.
Negocio para contrastar el incidente: **El Encuentro Food Shop**.

Actualizado el 9 de octubre a las 22:50: se cruzó con la revisión adversarial
(fase 3) y los arreglos en curso (fase 4). Ver la sección 1b. Donde este plan
chocaba con una decisión ya tomada por el dueño, se ajustó y se indica.

Este documento define el trabajo necesario para cerrar la revisión de venta rápida,
venta manual, mesas por zona, delivery y sincronización offline. Crear este archivo
no implementa las correcciones ni autoriza ejecutar cambios en producción.

## 1. Qué sabemos y qué todavía no está demostrado

- Hay mejoras en apertura de ventas, separación de cuentas, respaldos, navegación,
  pagos pendientes, aislamiento de delivery y sincronización desde el shell.
- Esta revisión encontró cuatro riesgos concretos: liberación automática con
  información incompleta, descarte de cola offline, reintentos antiguos de
  cantidad y restauración completa de productos cuando falla una oferta. Tres se
  comprobaron en el código (T03, T04, T05) y no están en la fase 4. T02 coincide
  en parte con un hallazgo que la fase 4 ya corrige.
- Aparte, la revisión adversarial (fase 3) confirmó 20 hallazgos, 3 de ellos
  críticos, más uno mayor del crítico. Se corrigen en la fase 4 (sección 1b).
- Los demás puntos de este plan son requisitos de cierre que se deben contrastar
  con lo ya implementado. No implican que cada función existente esté defectuosa.
- No se obtuvo acceso autenticado a las órdenes reales del negocio ni se verificó
  qué funciones, permisos, índices, triggers y cron están instalados allí.
- El registro disponible de 733 pruebas aprobadas y una omitida es anterior a los
  últimos cambios. La fase 2 corrió la suite completa (1244 pruebas Flutter y la
  prueba SQL de continuidad), también antes de la fase 4. **Ninguna certifica el
  árbol de trabajo actual**; la corrida válida es la final de la fase 4 (F6) más
  la de la unidad F7.
- No está demostrada la causa del incidente concreto ni una pérdida de dinero.

Referencias: [auditoría previa](AUDITORIA_INTEGRIDAD_VENTAS_2026_10_09.md) y
[pendientes de mesas y offline](INTEGRIDAD_MESAS_PEDIDOS_OFFLINE.md). La sección
«Corrección (diseño final)» de la auditoría sustituye su descripción inicial de la
apertura rápida/manual: una apertura nueva toma un carril libre; la recuperación
de una venta propia usa su identidad explícita.

## 1b. Estado de los arreglos (fase 3 → fase 4) y trabajo agregado por este plan

Situación a las 22:45 del 9 de octubre. Los cambios de la fase 4 están en el árbol
de trabajo sin commit y mezclados con impresión, e-CF y el agente. Una unidad
«hecha» pasó sus propias pruebas; queda confirmada cuando F6 corre la suite
completa y verifica cada hallazgo.

| Unidad | Hallazgos (severidad) | Estado |
| --- | --- | --- |
| F1 SQL | 0004 reemplazaba sin aviso cuerpos vivos distintos (menor). Además: orden de despliegue documentado y sección de corrección en la auditoría | Hecha: 0004 aborta sin cambiar nada si un cuerpo vivo exige caja abierta u origen permitido; 135 comprobaciones |
| F2 abrir y retomar | Recarga atrasada de otra cuenta cae en Venta Rápida/Manual y se guarda en su respaldo (crítico). Venta Manual asignada a una mesa se retoma y cobra la mesa (crítico). Defensa basada en `Order.origin`, que siempre vale `table` (mayor, del crítico). Escaneo durante el cierre posterior al cobro se pierde (mayor). Cierre de la app durante la impresión retoma offline una venta ya cobrada (menor). Retomar libera la carga aunque ya la reemplazó otra (menor). Carrito retail cerrado salta al carrito de otro cliente (menor) | Hecha: 7 de 7, con pruebas que fallan sin el arreglo |
| F3 dinero y reintentos | Venta retail cobrada anulada por estado viejo o `void_order` en cola (crítico; dos hallazgos fusionados). App publicada antes de 0004: PGRST202 (mayor). Reintento de mesa offline rechazado por el empleado que abrió (menor). «Pagar» con espera sin límite (menor) | En curso |
| F4 recargas | Se adopta la anulación automática del barrido con pendientes locales (mayor). Un cierre adoptado queda fijo aunque el servidor reabra la orden (mayor). Doble lectura completa de la cola en cada recarga (menor) | Pendiente |
| F5 atribución y cocina | En producción, productos de mesa/delivery sin PIN quedan sin mesero y «Ventas por mesero» los pierde (mayor). Falta `fn_order_opener_employee_id` en producción (menor). Actor de quitar producto offline (menor). `excluded_by` nulo al quitar impuestos (menor). Cambio de cantidad durante la impresión local reimprime la línea (menor). Opcional: banner «Todo sincronizado» con operaciones muertas | Pendiente |
| F6 integración | Suite completa y verificación independiente de cada hallazgo | Pendiente |
| F7 (de este plan) | T03 limpiar cola; T04 parte cliente; T05 fallo de oferta; R5 delivery solo con un negocio; R6 anulación atómica frente a un cobro simultáneo (migración `20261009_0007`, SQL ya probado); R8 lo que agrega el cajero se le acredita aunque sea sin PIN, y la comanda lo muestra a él | Hecha el 10 de octubre: suite de Flutter 2526 ✓, SQL y agente en verde |
| Moncion | La comanda sale, pero los productos quedan «sin enviar» y hay que reenviar | Fuera del plan por decisión del usuario (9 de octubre, 23:45) |

Decisiones del dueño que este plan respeta:

- Venta Rápida/Manual «por equipo»: el siguiente cajero del mismo equipo retoma;
  dos cajas nunca comparten orden. Una app sin actualizar siempre abre venta nueva.
- Sin PIN y sin opener conocido, el producto se acredita al empleado del usuario
  conectado, como en HEAD. El «MESERO:» impreso nunca sale del usuario conectado:
  sale de quien abrió la orden. La auditoría registra siempre a quien hizo la acción.
- Sincronización automática con internet sin mensajes emergentes: solo indicador y
  banner con contadores. Solo «Sincronizar ahora» muestra su resultado.
- Primero la migración 0004 y después la app. Si delivery no encuentra el RPC de
  4 argumentos (PGRST202), llama al de 3 **solo si el usuario tiene un único
  negocio**. Con varias sucursales no crea el delivery y muestra «Falta actualizar
  el servidor», porque el servidor podría elegir otra sucursal. Es la decisión del
  dueño actualizada el 9 de octubre a las 23:20 (R5); antes caía siempre a la
  versión de 3 argumentos.
- Nunca borrar pendientes de la cola offline. Nunca tocar `is_service_fee`.

## 2. Reglas que debe cumplir el sistema

1. Una venta aceptada conserva sus productos, cobros e identidad después de
   navegación, reinicio, respuesta perdida y sincronización parcial.
2. Cada operación termina confirmada, pendiente o en conflicto visible. Un error
   no se presenta como éxito ni desaparece por limpieza automática.
3. Repetir una operación con la misma identidad produce un único efecto; reutilizar
   esa identidad con datos distintos se rechaza como conflicto.
4. Una respuesta o reintento antiguo no sobrescribe una edición posterior aceptada.
5. Una apertura o recarga no anula otra venta ni mezcla dos cuentas o sucursales.
6. Abonar o cerrar una subcuenta no libera una mesa con saldo o contenido pendiente.
7. Una orden pagada/anulada no revive silenciosamente; los pendientes tardíos se
   concilian por identidad y quedan recuperables si existe conflicto.
8. El backend valida identidad, negocio, permisos y transición de estado. Las
   restricciones de la pantalla no sustituyen las restricciones del servidor.
9. Pago, documento fiscal, caja e inventario pueden reconciliarse sin duplicaciones
   ni diferencias inexplicadas. Un fallo de impresión no vuelve a cobrar.
10. Ninguna purga elimina la única copia de una operación no confirmada.

La persistencia local debe sobrevivir un cierre abrupto del proceso una vez
confirmado su guardado. La pérdida física del dispositivo exige respaldo externo;
una terminal aislada no puede ofrecer consistencia inmediata con otra. En ese
caso se conservan las operaciones y se muestra incertidumbre, no se adivina.

## 3. Trabajo pendiente y criterios de aceptación

P0: riesgo de pérdida, duplicación o cierre incorrecto; bloquea la liberación final.
P1: recuperación, visibilidad y evidencia necesarias para cerrar la revisión.
Todas las casillas empiezan pendientes; requieren resultado y evidencia.

### T01 — P0: inventariar la base real y fijar la versión a validar

- [ ] Confirmar el UUID del negocio: los scripts referencian Food Shop y El
  Encuentro; el nombre comunicado no basta para escoger entre ellos.
- [ ] Ejecutar en modo lectura el diagnóstico
  `scripts/diagnostics/encuentro_food_shop_order_continuity.sql`, especialmente
  bloques 1, 6, 7, 8, 9 y 10. Guardar definiciones completas y ACL de las funciones,
  índices, triggers, overloads, cron y migraciones instaladas.
- [ ] Revisar también los RPC efectivos de pago, edición, anulación, traslado,
  división, liberación y sus políticas RLS. Comparar con el repositorio; identificar
  guardas de caja abierta, origen permitido y pertenencia al negocio.
- [ ] Fijar commit, diff de cambios sin commit, versión de app por terminal y hashes
  de migraciones/pruebas para que los resultados correspondan al mismo código.
- [ ] Preparar respaldo recuperable de la base y definiciones vivas. Validar su
  restauración en un entorno aislado antes de modificar producción.

**Aceptación:** negocio identificado sin ambigüedad, diferencias explicadas y
respaldo restaurable. No sustituir una función viva por la del repo sin revisar
su comportamiento adicional. El rollback del repo no prueba equivalencia con la
base instalada.

### T02 — P0: impedir liberaciones basadas en datos incompletos

Puntos de revisión: `fn_release_empty_table`, `fn_release_empty_tables`, cron,
`table_order_screen.dart`, `sales_by_zone_viewmodel.dart` y cierre proyectado del Hub.

**Alcance en esta entrega:** la parte mínima está en F4. El cliente no adopta la
anulación automática del barrido mientras haya pendientes locales, y un cierre
adoptado no queda fijo si el servidor reabre la orden. El protocolo de acuses por
terminal (casillas 1, 2 y 4) es un rediseño y pasa a la fase siguiente (sección 8).
La auditoría ya lo deja como limitación conocida.

- [ ] Definir un protocolo de confirmación por sesión/orden y terminal participante,
  con identidad, versión/secuencia y acuse durable. Registrar participación antes
  de admitir trabajo offline cuando sea necesario para conocer a los participantes.
- [ ] No liberar automáticamente mientras exista un participante aislado, un acuse
  faltante, una versión desconocida o una operación pendiente/en conflicto.
- [ ] Verificar vacío, saldo y versión dentro de la misma transacción que cierra,
  usando el lock compartido con apertura y replay. Un acuse anterior no autoriza
  cerrar una versión posterior.
- [ ] Aplicar la regla a todas las rutas de liberación, incluido cron. Retirar un
  equipo del registro requiere conciliación explícita; un timeout no prueba vacío.
- [ ] Probar llegada tardía de productos a una sesión cerrada/reutilizada y el error
  `MP402`: conservar los pendientes y no transferirlos a la cuenta nueva.

**Aceptación:** caja A ve vacío, equipo B tiene productos offline, transcurre el
periodo de gracia y corre el barrido: no se anula ni se libera la venta de B. Al
reconectar se recupera la misma identidad, o se expone un conflicto recuperable.
Para esta entrega se exige la segunda parte (B no pierde sus productos: misma
identidad o conflicto recuperable). Que el barrido no llegue a anular requiere el
protocolo de la fase siguiente.

### T03 — P0: proteger operaciones financieras frente a limpieza

Puntos de revisión: `main_shell.dart::_confirmAndClear`,
`OfflinePosService.clearPendingActions` y `OfflineQueueDao.deleteAllPending`.

**Comprobado en el código:** «Limpiar cola...», en el menú del indicador de
sincronización, borra todas las operaciones pendientes y muertas del negocio,
cobros incluidos. Solo pide confirmar en un diálogo. Ya estaba en HEAD; no lo
introdujo este trabajo. Va contra la regla del dueño de nunca borrar pendientes.
No está en la fase 4: entra en F7.

- [ ] Sustituir el descarte indiscriminado por cuarentena/conciliación que conserve
  payload, identidad, negocio, actor, error y estado de cada operación.
- [ ] Impedir borrar cobros y sus dependencias sin confirmación o resolución
  documentada. Una advertencia del diálogo no sustituye esta protección.
- [ ] Conservar journal de pagos, mappings, marcadores de idempotencia y acciones
  pendientes durante logout, cambio de negocio, limpieza de caché y actualización.
- [ ] Exportar y verificar un respaldo antes de cualquier purga autorizada; asegurar
  recuperación y aislamiento de esos datos entre usuarios/negocios.
- [ ] Evitar que una limpieza concurrente elimine acciones reclamadas por el
  sincronizador o que éste las reintroduzca con un estado incorrecto.

**Aceptación:** un cobro pendiente, failed o dead sigue recuperable después de
limpieza y reinicio; reintentarlo lo aplica una vez. No basta guardar un contador.

### T04 — P0: ordenar cantidades y demás ediciones concurrentes

Riesgo observado en `SalesViewModel.updateItemQuantity`: una petición antigua que
falla por transporte puede encolarse después de una edición posterior confirmada.
El replay aplica su cantidad absoluta sin comprobar esa versión.

**Comprobado en el código:** cuando falla la red, la rama que encola no compara
`_itemQuantityMutationVersions`. Ejemplo: se envía 2, luego 3; el 3 se confirma, el
2 vence y se encola, y al sincronizar la línea queda en 2. **En esta entrega (F7):**
no encolar una cantidad que una edición posterior del mismo equipo ya reemplazó.
El versionado en servidor y los conflictos entre terminales (casillas 1 y 4) pasan
a la fase siguiente.

- [ ] Incorporar identidad y orden causal/versionado a las mutaciones; el servidor
  debe rechazar o reconocer operaciones obsoletas de forma atómica.
- [ ] No encolar una intención ya sustituida por una edición posterior. Conservar
  la evidencia del intento incierto hasta reconciliar el resultado remoto.
- [ ] Revisar compactación, cola, replay y espejo del Hub: el orden de llegada de
  respuestas no determina cuál era la última intención del operador.
- [ ] Extender la revisión a notas, descuentos, modificadores, takeout y traslado
  de líneas. Para ediciones de distintas terminales, definir resolución explícita
  de conflictos; los contadores locales de dos equipos no son comparables solos.

**Aceptación:** enviar cantidad 2 y luego 3, confirmar 3 y provocar timeout de 2;
sincronizar/reiniciar no puede dejar cantidad 2 ni alterar sus totales. Cubrir
también respuestas inversas y replay repetido. La edición desde dos terminales
se valida con el versionado de la fase siguiente.

### T05 — P0: aislar el fallo de una oferta

Riesgo observado en `SalesViewModel.addOfferDeal`: el catch restaura `previousItems`
y `previousOrder`, pudiendo ocultar productos agregados mientras esperaba la oferta.

**Comprobado en el código.** F2 solo cubre la oferta que responde cuando ya se
eligió otra cuenta; este caso es dentro de la misma cuenta y entra en F7. La
auditoría dice «un rechazo revierte solo su línea»: para las ofertas todavía no es
cierto; esa frase de la auditoría se corrige al cerrar F7.

- [ ] Revertir únicamente la línea/operación de oferta rechazada y recalcular
  totales con los productos actuales, preservando las otras mutaciones.
- [ ] Usar la orden, negocio y selección capturados para pantalla y respaldo.
- [ ] Persistir una intención de oferta con ID estable antes de enviar cuando se
  admita offline; ante timeout reconciliar/reintentar el mismo ID. Si no se admite
  offline, rechazarla explícitamente sin informar que quedó guardada.
- [ ] Distinguir rechazo definitivo de resultado remoto desconocido: un timeout
  no demuestra que el servidor no creó la oferta.

**Aceptación:** iniciar oferta A, agregar producto B y rechazar A: B conserva
identidad, cantidades y precio en pantalla, respaldo y servidor. Si A se guardó
pero se perdió su respuesta, recuperarla no genera una segunda oferta.

### T06 — P0: durabilidad local y replay idempotente de extremo a extremo

Dependencia: la deduplicación en servidor de altas y ofertas depende de
`20260929_0001_add_item_idempotent` (sin aplicar). Sin ella la app recurre a los
RPC anteriores (PGRST202) y funciona, pero un reintento tras una respuesta perdida
puede duplicar la línea. No se puede aprobar T06 en producción sin aplicarla.

- [ ] Inventariar cada operación de venta y comprobar guardado durable de intención,
  contexto y dependencias antes de presentarla como aceptada.
- [ ] Resolver atómicamente cola, snapshot y mappings: transacción local cuando
  comparten almacenamiento, o journal recuperable cuando no. Cubrir web y nativo.
- [ ] Inyectar fallos de escritura, lectura, cifrado y espacio insuficiente: no
  interpretar un respaldo ilegible como una venta vacía ni crear otro pago.
- [ ] Recuperar acciones processing después de reinicio, con deduplicación durable
  del servidor ante una respuesta perdida después del commit.
- [ ] Mantener IDs de orden, sesión, producto, check, pago y operación a través de
  remaps. No resolver dependencias por nombre de producto ni reutilizar otra cuenta.
- [ ] Comprobar las aperturas offline por slot cuando la orden ya fue pagada/anulada
  y faltó guardar el mapping/acuse; no crear otra venta financiera por ese reintento.
- [ ] Separar errores transitorios, RPC no disponible y conflictos definitivos;
  failed/dead requieren recuperación visible, no eliminación ni falso éxito.

**Aceptación:** detener el proceso antes/después de cada escritura y commit remoto;
al reiniciar, cada operación aceptada conserva un único efecto o un conflicto
recuperable. Repetir el mismo ID diez veces; probar también ID igual/payload distinto.

### T07 — P0: cobros, subcuentas, caja, documentos e inventario

Dependencia: el candado de cobro entre cajas es `20260929_0002_payment_attempt_lock`
(sin aplicar; la app sigue sin él por PGRST202). Sin esa migración no se puede
aprobar «dos cajas no cobran dos veces». F3 cubre la venta retail cobrada que se
anulaba. Pasan a la fase siguiente: caja y fecha de origen del cobro offline
(se cruza con el proyecto de una caja o varias) y el estado durable de la emisión
fiscal externa.

- [ ] Verificar el journal existente de cobro dividido y su recuperación por orden,
  negocio y check. Un fallo de lectura no debe iniciar un nuevo cobro desde cero.
- [ ] Verificar bloqueo de intento, deduplicación de abonos y estabilidad de índices
  y métodos después de respuesta perdida/reinicio. Dos cajas no cobran dos veces.
- [ ] Confirmar en servidor la cobertura del saldo y la transición de cierre dentro
  de una transacción. Definir cómo se bloquean/versionan nuevas líneas durante pago.
- [ ] Verificar caja de origen y fecha del cobro offline; no trasladar dinero a otra
  jornada porque sincronizó después de medianoche o de cerrar caja.
- [ ] Reconciliar documento fiscal/nota de venta, numeración y pago. Si una emisión
  externa es asíncrona, usar un estado/outbox durable y recuperable; no suponer una
  transacción atómica entre PostgreSQL y un servicio externo.
- [ ] Probar consumo y reversión de inventario: replay, anulaciones y devolución no
  duplican movimientos. Definir redondeo y tolerancia monetaria explícitos.
- [ ] Impresión/reimpresión fallida no repite pago, documento ni consumo.

**Aceptación:** suma de abonos confirmados y saldo reconciliados con checks, orden,
caja, documentos y movimientos. Cobro parcial mantiene la venta abierta; cobro
completo la cierra una sola vez. Ninguna diferencia monetaria sin explicación.

### T08 — P0: anulación, eliminación, división y traslado auditables

**Alcance en esta entrega:** F3 cubre la anulación de una venta cobrada (cola,
op-log del Hub y cierre de pestaña retail), y F5 cubre el actor de quitar
productos e impuestos. El resto de T08 se cruza con trabajos propios que tienen
migraciones sin aplicar: borrar ítems con NCF, motivo de eliminación y merma
(`20260920_0002`), y aprobador de borrado por cajero con PIN (`20261005_0003`).
Pasa a la fase siguiente salvo regresiones causadas por este trabajo.

**R6 — P0, en F7: anulación encolada frente a un cobro simultáneo.** El replay de
`void_order` (cola y op-log del Hub) lee la orden y después llama a
`fn_close_order_and_table`, que no protege `paid`. Si otra caja cobra entre la
lectura y el cierre, se anula una venta cobrada. La ventana es corta, pero es
dinero.

- [ ] Migración nueva: anular solo si la orden sigue abierta, en una sola
  operación con bloqueo de la fila, y devolver si la omitió por estar cobrada o
  cerrada.
- [ ] Que el replay use esa función; si la omite, el replay se marca completado
  sin anular.
- [ ] La anulación explícita con motivo (`annulOrder`) no cambia.
- [ ] Prueba SQL con dos sesiones (cobro y anulación a la vez) y prueba Flutter del
  replay.

- [ ] Verificar cada transición en backend, con permisos, actor, motivo, operación
  e identidad de origen/destino; no depender únicamente del PIN o botón de la UI.
- [ ] Evitar borrado físico sin trazabilidad de productos enviados a cocina; conservar
  evento/tombstone y cantidades anteriores/nuevas. El fallo de auditoría no permite
  una eliminación silenciosa.
- [ ] Hacer división/traslado atómicos y protegerlos frente a replay y cobro concurrente.
  Una línea pertenece a una cuenta; no puede perderse entre origen y destino.
- [ ] Verificar borrado agrupado desde TODAS: mostrar alcance por líneas, unidades
  y checks; eliminar una unidad no elimina filas ajenas.
- [ ] Distinguir ausencia, falta de permisos y operación ya aplicada. Conservar
  historial e informar un conflicto cuando existan dos órdenes activas anómalas.

**Aceptación:** cada cambio se reconstruye por evento; los productos y totales
conservados entre origen y destino cuadran. Rechazar una mutación no revierte
otra confirmada ni modifica la cuenta seleccionada después.

### T09 — P1: sincronización automática y visibilidad de pendientes

Decisión del dueño: las pasadas automáticas no muestran mensajes emergentes (ni
éxito, ni espera, ni fallo, ni operaciones muertas). Las «alertas» de esta sección
son el indicador y el banner con contadores al día. Solo «Sincronizar ahora»
muestra su resultado.

- [ ] Validar el uploader desde el shell: inicio ya online, reconexión, backoff,
  cambio de negocio y ausencia de ejecuciones concurrentes, sin abrir Ventas.
- [ ] Probar tanto la cola del equipo como el op-log recibido por el Hub; un host
  con cola propia vacía debe subir operaciones de otras cajas.
- [ ] Medir tiempo hasta iniciar un reintento elegible: objetivo de una revisión
  de cinco segundos más la latencia del ciclo/red, con la app activa y backend sano.
- [ ] Verificar indicadores diferenciados: guardado local, enviado al Hub,
  confirmado por servidor, error y conflicto. «Entregado al Hub» no equivale a
  «registrado en servidor».
- [ ] Definir comportamiento al suspender/cerrar la app: si no hay proceso activo,
  los pendientes se conservan y se retoman al arrancar; no anunciar subida activa.
- [ ] Mantener alertas de cobros no confirmados, operaciones detenidas y antigüedad
  de la cola. Cada error recuperable tiene un camino de conciliación.

**Aceptación:** venta rápida offline se registra automáticamente al recuperar
conexión, sin botón manual y sin cambiar la venta que el operador está viendo.

### T10 — P1: validar aperturas y separación de contextos

- [ ] Dos cajas abren rápida/manual simultáneamente: cuentas nuevas independientes;
  reabrir una cuenta propia por ID conserva sus productos y abonos.
- [ ] Validar carriles ocupados, zonas homónimas, sesión sin orden viva, límite de
  50 carriles y respuesta perdida al abrir. No ocultar ventas anteriores.
- [ ] Dos deliveries conservan dirección, tipo, cargo y respaldo separados; creación
  simultánea y consecutivos mayores de 999 no colisionan.
- [ ] El negocio activo se envía y valida en servidor. R5 (decisión del dueño, en
  F7): si delivery no encuentra el RPC de 4 argumentos (PGRST202), llama al de 3
  solo cuando el usuario tiene un único negocio. Con varias sucursales no crea el
  delivery y muestra «Falta actualizar el servidor». Solo pasa si la app sale
  antes que 0004.
- [ ] Rechazar usuario suplantado, negocio ajeno y ejecución anónima; comprobar
  accesos legítimos de dueño y usuarios compartidos.
- [ ] Probar cambio de negocio/mesa mientras responden cargas, altas, ofertas,
  cobros, dirección, envío a cocina y anulaciones.

**Aceptación:** ninguna respuesta tardía mezcla contextos; una apertura no anula
otra cuenta. Identidad y totales coinciden entre pantalla, respaldo, Hub y servidor.

### T11 — P1: impresión ligada a la operación y recuperación

- [ ] Mantener outbox durable por ronda/comanda, ID estable, líneas y cantidades
  capturadas; productos agregados después pertenecen a la siguiente ronda.
- [ ] Distinguir encolado, envío, confirmación disponible y resultado incierto.
  Deduplicar reintentos y mostrar una reimpresión explícita cuando no pueda probarse
  la entrega física. No prometer impresión exactamente una vez sin acuse adecuado.
- [ ] Probar caída de agente/impresora, respuesta perdida, reinicio y recuperación
  sin volver a cobrar ni marcar líneas nuevas como enviadas.
- Caso Moncion (la comanda sale, pero los productos quedan «sin enviar»): fuera
  del plan por decisión del usuario. V26 no se exige en esta entrega.
- [ ] F5 cubre el cambio de cantidad de una línea mientras se imprime la comanda
  local: la siguiente ronda no reimprime la línea completa.

**Aceptación:** cada comanda queda trazable y recuperable; cualquier duplicación
o incertidumbre se ve, y ninguna línea se da por enviada por un trabajo ajeno.

### T12 — P1: investigar el incidente y preparar operación recuperable

- [ ] Obtener fecha aproximada, terminal y orden/mesa/ticket del incidente reportado.
  Conservar evidencias antes de reparar datos.
- [ ] Correlacionar orden, sesión, items, abonos, checks, documentos, anulaciones,
  journal offline/Hub, trabajos de impresión y reutilización posterior de la mesa.
- [ ] Documentar causa demostrada o límites de la investigación. No tomar una fila
  anulada como prueba automática de dinero perdido.
- [ ] Preparar procedimiento de recuperación para pending/failed/dead, MP402,
  mapping faltante, journal ilegible y cobro con resultado remoto desconocido.
- [ ] Añadir trazabilidad por negocio, terminal, actor, operation_id, order_id,
  session_id y versión; evitar secretos y datos personales innecesarios en logs.
- [ ] Probar exportación/restauración de journal y respaldo, incluidos cifrado y
  acceso controlado, antes de autorizar purgas.

**Aceptación:** un operador puede recuperar un pendiente sin duplicar dinero;
el incidente tiene conclusión documentada o una carencia de evidencia explícita.

## 4. Matriz obligatoria de pruebas

Ejecutar el ciclo de venta en rápida, manual, zona y delivery; incluir retail si
está habilitado. Usar dos terminales reales, al menos la combinación Windows/LAN
del negocio. Para dinero usar datos y medios de prueba en un entorno controlado.

| ID | Escenario | Resultado obligatorio |
| --- | --- | --- |
| V01 | Dos aperturas simultáneas rápida/manual | Órdenes separadas; ninguna anulación |
| V02 | Reinicio con carrito y abono pendientes | Misma identidad, contenido y saldo |
| V03 | Arrancar ya online sin entrar en Ventas | Subida automática de pendientes elegibles |
| V04 | Corte WAN con LAN/Hub disponible | Operaciones durables y subida posterior única |
| V05 | WAN y Hub inaccesibles | Persistencia por terminal; conflicto visible al conciliar |
| V06 | Equipo B aislado, A ejecuta barrido/cron | B no pierde la venta ni su sesión por vacío aparente |
| V07 | Cantidad 2 falla después de confirmar 3 | Pantalla, respaldo y servidor conservan 3 |
| V08 | Oferta falla mientras otro producto se agrega | Solo se revierte la oferta rechazada |
| V09 | Commit remoto con respuesta perdida | Reintento reconoce un único efecto |
| V10 | Cola guardada, snapshot/mapping fallan | Reinicio recupera sin pérdida ni duplicación |
| V11 | Limpiar/logout/cambiar negocio con cobro pendiente | Intención y dependencias recuperables |
| V12 | Cobro dividido: caída después del primer abono | Reanuda plan y saldo; no repite el abono |
| V13 | Dos cajas cobran o editan durante un pago | Un cierre coherente; conflicto rechazado/visible |
| V14 | Abono/cierre de un check con otro pendiente | Mesa y orden siguen abiertas |
| V15 | Replay de traslado/división/anulación | Un efecto auditado; totales conservados |
| V16 | Llegada tardía a sesión reutilizada, MP402 | No mezcla cuentas; pendiente recuperable |
| V17 | Navegación/cambio de negocio durante una respuesta | Respuesta afecta solo su contexto capturado |
| V18 | Dos deliveries, misma y distintas sucursales | Dirección/cargo/identidad aislados |
| V19 | Repetir ID diez veces y cambiar payload del mismo ID | Un efecto; payload distinto rechazado |
| V20 | Impresora/agente caen; nuevos items durante envío | Recuperación trazable; ronda correcta; no recobro |
| V21 | Sincronizar después de medianoche/cierre de caja | Fecha y caja conciliadas sin traslado silencioso |
| V22 | Sin permiso, negocio ajeno, usuario suplantado | Backend rechaza sin mutaciones parciales |
| V23 | Migración ausente/RPC incompatible | Pendientes conservados (PGRST202 no pasa a muertas). Delivery: con un negocio usa la firma de 3 argumentos; con varios no crea y avisa «Falta actualizar el servidor» |
| V24 | Host Hub sin pendientes propios y con op-log ajeno | Subida automática del op-log recibido |
| V25 | Disco lleno/journal ilegible/clave no disponible | Error explícito; no falso éxito ni nueva cuenta vacía |
| V26 | (Fuera del plan) Enviar a cocina con fallo o lentitud después de imprimir (Moncion) | Productos marcados enviados una vez; no hay que reenviar ni sale comanda doble |
| V27 | Recarga atrasada de la mesa A al entrar a Venta Rápida/Manual | No escribe en la pantalla ni en el respaldo de Venta Rápida/Manual |
| V28 | Venta Manual asignada a mesa; después abrir Venta Manual | Abre venta nueva; no muestra ni cobra la cuenta de la mesa |
| V29 | Cerrar pestaña retail cobrada con lectura fallida, o `void_order` en cola | Nunca anula una venta cobrada; la pestaña se retira o queda para resolver |
| V30 | Escanear durante el cierre posterior al cobro | El producto escaneado no se pierde ni cae en la venta cobrada |
| V31 | Producto sin PIN en mesa/delivery (producción sin `fn_order_opener_employee_id`) | Se acredita al usuario conectado; el MESERO impreso sigue siendo quien abrió |
| V32 | «Limpiar cola...» con un cobro pendiente o muerto | El cobro no se pierde: queda en cuarentena recuperable |
| V33 | Replay de una anulación mientras otra caja cobra la misma orden | La venta cobrada no se anula; el replay queda completado sin efecto |

Para alta, oferta, cantidad, borrado, traslado, división, pago y cierre, interrumpir
antes del guardado local, después del guardado, antes del commit remoto y después
del commit sin respuesta. Reiniciar en cada frontera relevante; una espera en un
mock no sustituye matar el proceso en un equipo real.

## 5. Validación automatizada y evidencia

Primero agregar regresiones específicas para T02–T05: las pruebas anteriores no
bastan para demostrar esos casos. Las de los hallazgos de la fase 3 las agrega cada
unidad de la fase 4, y F6 las verifica una por una. Usar payloads realistas del RPC, incluidos
`replayed` e `item_exists`, y efectos confirmados, rechazados y desconocidos.

Después ejecutar sobre la misma versión a liberar:

```bash
flutter analyze --no-pub
flutter test --no-pub
flutter test --no-pub test/core/offline test/sales --reporter expanded
bash supabase/tests/sales_order_continuity_local_test.sh
bash supabase/tests/add_item_idempotent_local_test.sh
bash supabase/tests/payment_attempt_lock_local_test.sh
bash supabase/tests/notification_events_local_test.sh
```

Estas ejecuciones son trabajo futuro, no resultados de este documento. Flutter
puede escribir cachés; los scripts SQL crean bases desechables y necesitan sus
dependencias locales. Revisar requisitos y destino de cada script antes de correrlo.
Añadir pruebas SQL/integración para versiones, liberación distribuida, permisos,
recuperación y conciliación que estas suites todavía no cubran.

Los fixtures locales no reproducen automáticamente la base viva. Validar también
en staging con estructura, funciones, ACL e índices equivalentes a producción,
datos protegidos y servicios externos configurados para prueba. Cubrir migración
repetida, concurrencia, rollback y clientes anteriores; un rollback no borra las
ventas creadas después de migrar.

Registrar por ejecución:

| Campo | Evidencia requerida |
| --- | --- |
| Versión | Commit + diff sin commit, hash de migraciones, app/terminal |
| Entorno | SO, PostgreSQL, red, modo cloud/Hub, negocio de prueba |
| Caso | Vxx/Txx, pasos, punto de fallo y resultado esperado |
| Identidades | Operación, orden, sesión, item, check, intento de pago |
| Estado inicial/final | Pantalla, cola/journal, Hub y consultas de servidor |
| Conciliación | Productos, saldo, pagos, caja, documentos e inventario |
| Resultado | Aprobado/fallido/bloqueado, logs y evidencia recuperable |
| Responsable | Persona que ejecutó y quien revisó el resultado |

Toda prueba fallida deja una incidencia abierta. Una prueba omitida relevante
no cuenta como aprobada. Explicar advertencias de análisis y eliminar las nuevas
relacionadas con estos cambios. Repetir las pruebas afectadas si cambia el código.

## 6. Orden de implementación y despliegue

0. **Terminar la fase 4 y F7:** F3, F4, F5 y F6 (sección 1b). Después F7 (T03,
   T04 parte cliente, T05, R5 y R6). Van en serie porque tocan
   `sales_viewmodel.dart`; nadie más debe editarlo mientras corren.
   Luego separar los commits: el árbol mezcla este trabajo con impresión, e-CF y
   el agente.
1. **Inventario y diagnóstico:** T01, versión fija, evidencia y respaldo recuperable.
2. **Correcciones de pérdida:** T02–T06 y regresiones que reproduzcan los fallos,
   con el alcance de esta entrega que indica cada tarea.
3. **Integridad financiera:** T07–T08, permisos y conciliación de estado/dinero,
   con el mismo criterio de alcance.
4. **Validación operativa:** T09–T12, suites, staging y matriz en dos terminales.
5. **Preparar liberación:** comparar todas las funciones vivas y preservar sus
   guardas. La migración `20261009_0004` detecta ciertas guardas y overloads, pero
   no todas las diferencias de cuerpo/ACL; no ignorar su aborto.
6. **Backend primero:** aplicar las migraciones revisadas antes de publicar la app
   que usa `fn_open_offline_sale` y delivery de cuatro argumentos. Comprobar schema
   de PostgREST, firmas, permisos y compatibilidad de clientes anteriores.
   Migraciones de este flujo:
   - `20261009_0004_sales_order_continuity`: obligatoria antes de la app.
   - `20260929_0001_add_item_idempotent` y `20260929_0002_payment_attempt_lock`:
     la app funciona sin ellas, porque recurre a los RPC anteriores con PGRST202.
     Sin ellas no hay deduplicación de altas ni candado de cobro entre cajas, y
     T06 y T07 no se pueden aprobar.
   - `20261009_0005_order_opener_name_alias`: ya está aplicada.
   - La migración nueva de R6 (anular solo si la orden sigue abierta): antes de la
     app que la usa.
   Antes de cada una, guardar las definiciones vivas y compararlas a mano (la base
   viva diverge del repo).
7. **Actualizar terminales:** inventariar versiones, conservar/exportar pendientes
   y verificar el arranque de los uploaders. Las nuevas garantías pueden requerir
   que todos los participantes usen el protocolo actualizado; cliente viejo
   compatible con una apertura no significa integridad distribuida validada.
8. **Piloto del negocio:** cubrir al menos una jornada completa, cierre de caja y
   recuperación de cortes controlados; conciliar al final sin operaciones perdidas.
9. **Seguimiento y recuperación:** revisar cola/errores/conflictos y diferencias.
   Ante incidente conservar evidencia y contener el flujo afectado. Antes de volver
   una app/función atrás, comprobar que podrá leer las nuevas operaciones; no
   ejecutar un rollback que restablezca anulaciones automáticas de ventas vivas.

Este orden requiere revisión y autorización del despliegue correspondiente; el
alcance actual es elaborar el plan. No reparar ni reabrir órdenes históricas en
masa como parte de instalar la migración.

## 7. Condiciones para declarar cerrada la revisión

- [ ] Hallazgos de la fase 3 corregidos y verificados uno por uno (F6); F7 aprobada.
- [ ] T01–T08 aprobados con evidencia, con el alcance de esta entrega; ningún
  riesgo P0 abierto. Lo que pasó a la fase siguiente (sección 8) tiene
  responsable y fecha.
- [ ] T09–T12 completos; cualquier excepción P1 tiene alcance, responsable,
  impacto documentado y decisión explícita. No se exceptúa un riesgo monetario.
- [ ] Suites ejecutadas sobre la versión final; regresiones nuevas aprobadas.
- [ ] V01–V33 (salvo V26, fuera del plan) ejecutados en los modos que usa el negocio, incluidos dos equipos
  reales y las fronteras de fallo relevantes; sin escenarios críticos omitidos.
- [ ] Migraciones y permisos verificados en la base instalada; app actualizada en
  todas las terminales participantes y compatible con pendientes anteriores.
- [ ] Incidente de El Encuentro Food Shop investigado, con conclusión o límites
  expresos; recuperaciones revisadas y trazables, sin inventar una causa.
- [ ] Piloto y cierre de caja conciliados con pagos, documentos e inventario.
- [ ] No hay operaciones no contabilizadas: cada pendiente/conflicto restante está
  identificado, conservado y asignado para resolución; no se oculta por un contador.
- [ ] Recuperación y respaldo probados; responsables operativos conocen el proceso.
- [ ] Informe final incluye versión validada, resultados, límites y aprobación.

**Cierre = implementación + pruebas actuales + despliegue verificado + conciliación
en el negocio.** La existencia de archivos, migraciones o pruebas históricas no
equivale a ese cierre, ni justifica una promesa absoluta de cero fallos.

## 8. Fase siguiente (fuera de esta entrega)

Son requisitos reales, pero exigen rediseño o se cruzan con otros proyectos que
tienen migraciones propias sin aplicar. No bloquean esta entrega salvo que una
prueba muestre una regresión causada por este trabajo.

- **T02:** protocolo de acuses por terminal antes de liberar una mesa (registro de
  participantes, versión y acuse durable, también en el cron).
- **T04:** versionado de mutaciones en servidor y resolución de conflictos de
  edición entre terminales.
- **T07:** caja y fecha de origen del cobro offline, y estado durable de la emisión
  fiscal externa.
- **T08:** historial completo de borrado, división y traslado. Se cruza con borrar
  ítems con NCF, motivo de eliminación (`20260920_0002`) y aprobador de borrado
  (`20261005_0003`).
