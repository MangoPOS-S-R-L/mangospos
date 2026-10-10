# Pendientes — 9 de octubre de 2026, 23:25

Alcance: integridad de ventas, impresión, e-CF (revisión de Codex) y despliegue.
**Nada de esto tiene commit.** Las migraciones nuevas de ventas e impresión no
están aplicadas, salvo `20261009_0005`; el estado de las de e-CF hay que
confirmarlo. El plan de validación detallado está en
[PLAN_CIERRE_INTEGRIDAD_VENTAS_2026_10_09.md](PLAN_CIERRE_INTEGRIDAD_VENTAS_2026_10_09.md).

---

## 0. Decisiones que necesito de ti

- [x] **Moncion: fuera del plan** por decisión del usuario (9 de octubre, 23:45).
- [x] **Decidido (10 de octubre): la comanda dice quien agregó los platos**, también el cajero.
  Reemplaza la decisión de las 23:50 («sin PIN, quien abrió»): R7 queda eliminado y la
  impresión no cambia (`print_ticket_service.dart:293`: autor de los platos y, si no hay,
  quien abrió).
- [x] **Decidido (10 de octubre): lo que agrega el cajero se acredita al cajero, aunque sea
  sin PIN.** Aplica a todo equipo cuyo rol no pide PIN (administrador, supervisor, cajero).
  Va en F7 como R8.
- [x] **Aceptado (23:25).** **F4 relajó una regla tuya.** Una Venta Rápida/Manual cerrada por el barrido
  automático se retoma si este equipo todavía tiene productos sin subir para esa
  orden. Sin esto, esos productos quedaban en una orden fantasma o como operaciones
  muertas. Las cobradas y las de otro origen se siguen rechazando. ¿Lo aceptas?
- [x] **Aceptado (23:25).** **F2: retomar cuando el servidor da un error que no es de red.** En ese caso
  decide la carga de confirmación de siempre, así que la venta puede retomarse sin
  que se haya confirmado su origen. Rechazarla abriría una venta nueva cada vez y
  dejaría la anterior viva sin cobrar, lo que traba el cierre de caja. ¿Lo aceptas?
- [x] **Aceptado (23:25).** **F3: MESERO impreso tras quitar a un mesero inactivo.** Si el servidor rechaza
  al mesero que abrió la mesa (`EMPLOYEE_NOT_IN_BUSINESS`), la mesa se reabre sin él
  para no bloquear la venta. Ya con internet, el «MESERO:» impreso sale de la
  cuenta que sincronizó. Eso toca tu regla de que el mesero impreso nunca sale del
  usuario conectado. ¿Lo aceptas o prefieres otra salida?

## 1. Integridad de ventas

### 1.1 Fase 4, en curso en otra sesión
- [x] F1 SQL: 0004 aborta si la base viva exige caja abierta (135 comprobaciones).
- [x] F2 abrir y retomar: 7 hallazgos, incluidos los dos críticos de cuentas cruzadas.
- [x] F3 dinero y reintentos: venta retail cobrada nunca se anula; PGRST202 no pasa
  a muertas; mesero inactivo; «Pagar» con espera acotada.
- [x] F4 recargas: no adopta la anulación del barrido si hay pendientes; un cierre
  adoptado no queda fijo; una sola lectura de la cola por recarga.
- [ ] F5 atribución y cocina (corriendo): productos sin PIN se acreditan al usuario
  conectado, como HEAD, sin cambiar el MESERO impreso; `excluded_by`; actor al quitar
  offline; cambio de cantidad durante la impresión local.
- [ ] F6: suite completa y verificación independiente de cada hallazgo.

### 1.2 F7 — HECHA (10 de octubre, 00:55; sin commit)
- [x] **T03 «Limpiar cola...»:** hoy borra pendientes y muertas, cobros incluidos.
  Pasar a cuarentena recuperable; nunca descartar un cobro sin conciliar. Respaldo cifrado sin
  tope: cada limpieza en su propia clave (`offline_queue_discarded_<negocio>_<instante>`).
- [x] **T04 cantidades:** no encolar una cantidad que una edición posterior ya
  reemplazó.
- [x] **T05 ofertas:** si falla, revertir solo la oferta, no toda la lista.
- [x] **R5 delivery sin 0004:** usar la firma de 3 argumentos solo si el usuario
  tiene un único negocio. Con varias sucursales, no crear y avisar «Falta
  actualizar el servidor».
- [x] **R8 cajero acreditado:** en `_resolveItemEmployeeId`, si el rol del equipo no es
  mesero, el producto se acredita al empleado del usuario conectado, también en mesas
  abiertas con PIN de otro mesero. Si sin internet no se conoce su empleado, queda sin autor
  (nunca a nombre de otro). Los equipos de mesero sin PIN siguen usando a quien abrió la mesa.
  Con esto, la comanda de lo que agrega el cajero dice el cajero.
- [x] **R6 anulación frente a un cobro simultáneo:** migración nueva que anule solo
  si la orden sigue abierta y sin cobros, en un solo paso con bloqueo de fila. El
  replay de `void_order` la usa. Debe cubrir también las ventas con **cobro
  parcial**: F3 confirmó que una retail parcialmente cobrada todavía se puede anular
  al cerrar su pestaña o por la cola. `annulOrder` no cambia.

- Validación de F7: suite completa de Flutter 2526 ✓ (1 omitida previa), analizador sin
  avisos nuevos, SQL `void_order_if_unpaid` 15 ok, `sales_order_continuity` 135 ok,
  `printer_delivery_uncertain` 19 ok, `ecf_test_set_replace` 14 ok, agente 27/27, Deno 242/242.
  Las pruebas nuevas de T04 y T05 fallan sin su arreglo (comprobado).
  Registro completo de la corrida final (2527 ✓, 1 omitida, 0 fallos, con el respaldo sin tope):
  `~/.claude/projects/-Users-cristiangomez-dev-mangospos/sales_integrity_2026_10_09/f7_full_suite_20261010_0054.txt`.
  La primera corrida tuvo 1 fallo (un fake de `sales_cancel_navigation_integrity_test` sin la anulación protegida);
  se corrigió el fake y se repitió la suite completa.

### 1.3 Moncion (fuera del plan)
- Fuera del plan por decisión del usuario (23:45). La investigación de la causa
  quedó guardada en la sesión de la fase 4; no forma parte de esta entrega.

### 1.4 Riesgos residuales que dejaron F2–F4 (revisar)
Verificación de la fase 4: 16 hallazgos arreglados, 2 con regresión menor y 2 parciales. Los
hace la sesión mangospos-53 después de F7:
- [x] `reloadOrderNow()` (Pre-Cuenta, Cobrar, cargo de delivery, quitar impuestos) puede leer
  el respaldo pintado con «cargando» si el reintento al retomar reemplazó su carga.
  **Arreglado (10 de octubre, revisión de Codex + 2 /code-review):** la carga anota cuándo
  escribió datos del servidor. Si ni la suya ni una posterior lo hizo, `reloadOrderNow` sigue
  la carga vigente de la misma cuenta o, si la reemplazó algo que no era una carga (la marca de
  comanda enviada), repite la suya. Hasta 3 vueltas y 10 s. Si la suya ya escribió, no espera.
  Pruebas nuevas en `open_resume_integrity_test` (fallan sin el arreglo).
- [ ] `orderQueueStatus` cuenta como «van a revivir la orden» altas bloqueadas detrás de una
  acción muerta o de `hub_delivery_started`; solo deben contar las que el replay reproduciría.
- [x] El bloqueo de edición durante la impresión local debe empezar desde que `confirmOrder`
  captura la ronda (cubre la caída de en línea a local).
  **Arreglado (10 de octubre, revisión de Codex + 2 /code-review):** el bloqueo se toma al
  capturar la ronda y dura también el intento por la nube (tiene tope: `ResilientHttpClient`
  corta cada petición a los 30 s y, detectada la caída, las demás fallan al instante); si cae
  a la LAN, se imprime lo capturado. Mensaje: «Espera a que termine de enviarse la comanda…».
  Una línea temporal cuya alta en línea termina durante el envío sigue bloqueada con su id real
  y queda enviada (antes se reimprimía). Pruebas nuevas en `kitchen_local_print_edit_guard_test`.
  Se probó y descartó volver a tomar la ronda al caer a la LAN: perdía líneas recién pasadas a
  su id real.
- [ ] Actor de los retiros sin red en cajas Hub (parcial, menor); revisar contra R8.
- [x] La marca local de «pagada» se escribe después de la espera del e-CF (hasta
  ~8 s). Si la app muere ahí, con Realtime caído y reinicio sin internet, se podría
  retomar una venta cobrada. Arreglo más fuerte: marcarla en el VM de pago.
  **Arreglado (10 de octubre, revisión de Codex + 2 /code-review):** la pantalla define la marca
  una vez (`markPaidLocally` en `_openPaymentModal`, con orden, origen y sub-cuenta del cobro y el
  notifier ya leído) y se la pasa a los dos modales como `onServerConfirmed`. El cobro dividido
  la pide al confirmarse el último abono, después del diario (en un `finally`: también si el
  diario falla) y antes del e-CF; el de crédito, al confirmarse el pago. `handleConfirmed` la
  repite de respaldo sin escribir dos veces. Pruebas en `open_resume_integrity_test`,
  `payment_split_retry_test` (conexión del diálogo) y `payment_modal_server_confirmed_test`
  (VM; el paso del modal no tiene prueba de widget).
- [ ] Una acción cuyo RPC nunca llega a desplegarse reintenta cada 30 s para
  siempre: el error PGRST202 se reconoce de forma genérica, y además por el texto
  «Falta aplicar la migración», que puede cambiar.
- [ ] `table_order_screen.dart`: `openOnPayButton` corre antes de revisar
  `isPromotingLocalOrder`. Falta también una marca local de cerrada para cobros
  retail en línea.
- [ ] MP402 después de un barrido (otra sesión tomó la mesa o el carril): la copia
  local queda en pantalla para recuperarla a mano.
- [ ] Ya existía antes: reabrir con `openTable` una mesa barrida crea una orden
  nueva, y los productos en cola de la orden vieja no pasan a la nueva.
- [x] Ya existía antes: el replay de `confirm_local_order` llamaba `sendToKitchen(orderId)`, que
  confirma en el servidor TODAS las líneas en borrador de la orden, también las agregadas
  después de imprimir la comanda local (quedaban «enviadas» sin haber salido).
  **Arreglado (10 de octubre); `20261010_0002` ya está en producción** (verificado con la
  definición viva: idéntica al repo; la viva de `fn_confirm_order_to_kitchen` tampoco genera
  `print_jobs`, y los disparadores de `orders`/`order_items` no imprimen).
  **Rehecho tras la segunda revisión de Codex (10 de octubre, tarde):** el replay confirma SOLO
  los ids de la ronda impresa, también cuando reimprime áreas que no salieron
  (`sendOrderToKitchen(onlyItemIds:)`). Ya no hay respaldo de «orden entera»: si falta el mapeo
  de una línea temporal, la acción se conserva (espera sin gastar intentos si su alta sigue en
  la cola; si no, 8 intentos y dead-letter); sin la RPC, se conserva con el aviso «Falta
  actualizar el servidor»; una acción de una versión anterior sin ids va a dead-letter para
  recuperarla a mano. Ninguna de esas retenciones bloquea las demás acciones de su orden
  (`kitchen_hold`): el alta que trae el mapeo y los cobros siguen. El mapeo `tmp_`→id real se
  guarda (esperado, con el negocio de la operación) al terminar cada alta en línea y cada oferta
  cuya línea está en una comanda local, aunque la impresión ya haya terminado. Pruebas:
  `confirm_local_order_items_replay_test` (7) y la regresión de punta a punta en
  `kitchen_local_print_edit_guard_test`. Límite: el Hub sigue marcando la orden entera como
  enviada en su vista local.
  **Hub (tercera revisión de Codex):** una comanda del op-log sin ids ya no se da por completada.
  Pasa a una cuarentena durable: dead-letter en la cola del equipo Hub con el mismo id (visible
  en el visor como «Comanda · Mesa N · retenida del Hub» y en el aviso de operaciones sin
  resolver), sin marcarse subida; el op-log y su réplica conservan su orden aunque se cierre.
  Nunca se reproduce por la cola local (ni forzada ni con «Reintentar»: podría crear la orden de
  una caja cliente); solo «Limpiar cola» la resuelve, con respaldo cifrado. Además, la
  reproducción calcula los ids de la ronda antes de resolver la orden: lo retenido no toca el
  servidor. Prueba: `hub_kitchen_quarantine_test`.
- [x] **Marca de venta cobrada con el contexto del cobro (segunda revisión de Codex):** el negocio
  y el modo se fijan al tocar «Pagar»; `markVirtualSalePaidLocally` ya no lee el negocio ni el
  modo activos, y `markPaidOrderLocally` recibe el negocio del cobro (con otra sucursal ya en
  pantalla solo escribe la marca). Regresiones en `open_resume_integrity_test`.
- [x] `promoteLocalOrderForPayment` usa la misma espera que `reloadOrderNow` (`_settleOrderLoad`):
  si otra carga reemplaza la suya, la venta ya no se cobra por la cola con precuenta.
- [ ] Opcional: no imprimir la precuenta si la orden recargada cambió.
- [ ] El guard de Realtime y el unsubscribe de la apertura de venta virtual no
  tienen prueba unitaria.

### 1.5 Fase siguiente (fuera de esta entrega)
- [x] T02: cada equipo confirma antes de liberar una mesa (registro de
  participantes, versión y acuse, también en el cron).
  **Hecho (10 de octubre, sin aplicar):** migración `20261010_0030_table_release_acks` (+ROLLBACK;
  antes se llamaba `0003`: se renumeró para ir DESPUÉS de la contención aplicada, que reemplaza la
  misma función. Conserva el mínimo de 6 h de salón y su reversa restaura el cuerpo contenido vivo):
  versión de sesión por disparadores (`table_session_versions`), participantes, pedidos y
  confirmaciones; `fn_release_empty_tables` y `fn_release_empty_table` (mismas firmas) solo
  liberan con todas las confirmaciones sin pendientes de la versión vigente, en la transacción
  con el candado de la mesa; `fn_release_empty_table_v2` para la app nueva. Sin participantes
  registrados (versión anterior de la app) no se libera sola; un equipo revocado no retiene.
  App: registro al cargar una cuenta, `SessionReleaseResponder` en el ciclo de subida (cada
  30 s), salida de mesa vacía con equipo y cola. Pruebas: `table_release_acks_local_test.sh`
  (27 ok, con la terminal aislada y la carrera), `session_release_responder_test` (4) y registro
  en `open_resume_integrity_test`. Antes de aplicar: comparar con la definición viva.
- [x] **Fase 1 del plan del 10-oct (pedido perdido en Food Shop MESA4): contener el barrido.**
  Migración `20261010_0004_contain_auto_releases` (+ROLLBACK), **APLICADA el 10-oct** (md5 verificado): el barrido
  (cron y salón) no toca mesas de salón con menos de 6 h; ventas rápidas y delivery siguen igual
  (sus carriles vacíos bloquearían cada cierre de caja con OPEN_TABLES_EXIST). Salir de una mesa
  sin productos la sigue liberando al instante (decisión del dueño). Prueba:
  `contain_auto_releases_local_test.sh` (16 ok, con línea base y reversa). Antes de aplicar:
  `md5(prosrc)` de `fn_release_empty_tables` viva debe ser `0f4f14c5307f8dd8f1060bf5a20c7a42`;
  después, `f681b45052c86bb3ad2b586cf8ef93a2`. Si T02 se corrige después, conservar el mínimo de 6 h.
- [ ] **Fase 2: la cuenta de un equipo que vuelve a conectarse no puede desaparecer.** Huecos:
  (a) productos que llegan a una cuenta liberada cuya mesa ya tomó otra cuenta → hoy MP402 y quedan
  atascados; (b) la cuenta local se sube con `openTable(mesa)` y se mezcla con la cuenta abierta
  actual; (c) reenviar la salida de una cuenta local nunca subida puede liberar la cuenta de otro.
  El salón solo muestra la última sesión abierta por mesa (`v_zone_table_status`).
  **Plan rector desde el 10-oct: [PLAN_IMPLEMENTACION_HUB_FOOD_SHOP_2026_10_10.md](PLAN_IMPLEMENTACION_HUB_FOOD_SHOP_2026_10_10.md)**
  (decisión del dueño: «es con lo que seguiremos»; es para TODOS los negocios, no solo Food Shop, y va
  DESPUÉS de terminar esta fase 2). Estos huecos son su F1 (identidad de cuenta y apertura recuperable). Decisión de presentación (dueño, opción A): la cuenta en conflicto se ve en
  la MISMA mesa con «2 cuentas · revisar», se elige al tocarla y no se cobra hasta resolverla.
  Definiciones vivas guardadas (F0): `supabase/tests/fixtures/live_table_open_release_20261010.sql`
  (`fn_open_table_and_load` solo delega en `fn_open_table`; `fn_close_order_and_table` libera la mesa
  solo sin órdenes vivas en la sesión; existe `uniq_open_session_per_table`).
  **Servidor APLICADO por el dueño el 10-oct** (antes de la app y del ajuste de transferir/unir mesa; ver «Falta»): `20261010_0020_order_review_accounts` (+ROLLBACK). La cuenta
  recuperada es una 2ª orden de la sesión con `orders.review_reason`; `orders.client_order_id` (único) es
  la identidad de la cuenta local. `fn_open_local_table_order` (misma identidad → misma cuenta; mesa libre →
  normal; vacía del mismo usuario → la adopta; si no → en revisión), candado de ítems que preserva en vez de
  rechazar (MP402 → la cuenta vuelve en revisión; MP401 → los productos van a una cuenta en revisión, la
  cobrada no se toca), `fn_open_table` y el total del salón ignoran las de revisión (`review_orders_count`,
  `review_total` al final de la vista), `fn_resolve_review_order` (unir / anular con motivo). Prueba:
  `order_review_accounts_local_test.sh` (48 ok, con línea base MP402 y reversa). OJO: `CREATE OR REPLACE
  VIEW` borra las opciones de la vista; la migración y la reversa las copian y reaplican.
  Verificado en producción el 10-oct (columnas, 4 funciones, `fn_open_table`, candado, disparador `O`,
  columnas de la vista, permisos intactos, 0 cuentas en revisión).
  **Hallazgo aparte (previo, no lo causó 0020):** `v_zone_table_status` no tiene `security_invoker` y
  `anon` tiene SELECT: con la clave anónima que trae la app se leen mesas, meseros, clientes y totales de
  TODOS los negocios (la vista corre como su dueño y salta RLS). Propuesta: `revoke select … from anon`
  tras confirmar que ninguna pantalla sin sesión la lee. Decisión del dueño pendiente.
  **Visto el 10-oct (negocio de prueba «cristian», web):** MESA71 ocupada en el servidor (sesión, 1 orden,
  RD$640) se veía «Disponible» y la zona «0 ocupadas»; al recargar la página salió bien. La pantalla
  estaba vieja: `ByZoneViewModel.load` descarta en silencio el fallo de `fetchStatusByBusiness`
  (`catchError((_) => null)`) y `_loadZoneStatus` conserva lo último pintado (solo `developer.log`); o
  se cortó el tiempo real. Falta (plan F3): marca fija «Salón sin actualizar desde HH:MM» cuando falle
  la carga o el tiempo real esté caído, y recarga periódica mientras dure. Sin snackbars.
  **Mesa vacía disponible sola (dueño, 10-oct: «hay que hacer alguna forma de que se ponga disponible
  automáticamente»):** (a) app: sin `fn_release_empty_table_v2` (T02 sin aplicar) la salida de una mesa
  vacía ya no la deja naranja: usa `fn_release_empty_table` al instante si el equipo no tiene trabajo
  pendiente de esa cuenta (`sales_repository.releaseEmptyTableIfNeeded`, prueba
  `empty_table_release_immediate_test`, 4 ok); (b) `20261010_0021_sweep_dine_in_30min` (+ROLLBACK,
  APLICADA por el dueño el 10-oct, verificada: huella `03248ee6…`; 0005–0010 NO aplicadas): el barrido libera mesas de salón vacías a los 30 min (0004 esperaba 6 h). Seguro por 0020.
  Prueba `sweep_dine_in_30min_local_test.sh` (15 ok). Huella antes `f681b450…`, después `03248ee6…`.
  **Carrera de la salida y órdenes huérfanas (pendiente 8, 10-oct):** `20261010_0023_release_lock_and_orphan_heal` (+ROLLBACK, APLICADA y verificada el 10-oct; `fn_reattach_orphan_order` `4a5cd739…`): `fn_release_empty_table` toma también el candado por mesa de `fn_open_table` (el FOR UPDATE solo no la excluía → orden viva en sesión cerrada); el candado de ítems cura la orden viva colgada de una sesión cerrada (`fn_reattach_orphan_order`: mesa libre → reabre su sesión; tomada → cuenta en revisión). Huellas: salida `5dc47a35…`→`fc268e83…`, candado de ítems `81f185d0…`→`64a6e390…`. Prueba `release_lock_and_orphan_heal_local_test.sh` (16 ok, con dblink: dos conexiones reales). OJO: el ROLLBACK de 0030 (T02) restaura la salida sin este candado; si se aplica 0030, partir de 0023.
  **«Mover a otra mesa» + quién la tomó (pedidos del dueño al probar la hoja, 10-oct):** `20261010_0024_move_review_order` (+ROLLBACK, APLICADA y verificada el 10-oct, las 6 huellas): `fn_move_review_order` (mesa libre → su cuenta, a nombre del mesero que la tomó; ocupada → suma; origen se libera si queda vacío; nunca con cobros; permiso `ventas.mesas.mover_unir` o PIN de Supervisor); columnas `orders.taken_by_employee_id/taken_by_user_id/taken_at_table_id` llenadas en todos los caminos de cuentas en revisión (+ completado desde la bitácora); `fn_review_accounts` para la hoja («Tomada por Claudia · MESA71»). Redefine `fn_open_local_table_order`, `fn_move_closed_order_to_review`, `fn_late_items_review_order` (0020) y `fn_reattach_orphan_order` (0023). Huellas después: `fn_late_items_review_order` `7c463ebf…`, `fn_move_closed_order_to_review` `3450d855…`, `fn_move_review_order` `d24616a8…`, `fn_open_local_table_order` `83596396…`, `fn_reattach_orphan_order` `32aff8d2…`, `fn_review_accounts` `125d3c05…`. Pruebas: `move_review_order_local_test.sh` (22 ok), `review_move_targets_test` (3), `review_account_origin_test` (3). **Probado por el dueño en la app (negocio «cristian», MESA71, 10-oct): marca «2 cuentas · revisar», «Tomada por Admin · MESA71», Unir/Anular/Mover a mesa libre, todo bien** (tras arreglar `_reload` con setState que devolvía un Future; prueba `review_accounts_sheet_test`).
  **10-oct, tarde: la 0030 (T02) se aplicó por error después de la 0023 y se REVIRTIÓ** con su ROLLBACK (con la app instalada nunca hay confirmaciones: ninguna mesa vacía se liberaba y los carriles quick vacíos bloqueaban el cierre). Verificado: salida `fc268e83…`, barrido `03248ee6…`, sin `fn_release_empty_table_v2`.
  **OJO T02 (0005) tal como está escrito contradice la regla del dueño:** la salida espera confirmación de
  los otros equipos y el barrido no libera sesiones sin participantes (app anterior) → mesas naranjas.
  Al corregirlo (F4): salida de mesa SIN productos = inmediata; barrido con el mínimo de 0021.
  **Falta (urgente: la migración ya corre):** (1) `fn_transfer_table_session` viva (transferir/unir con una cuenta en
  revisión puede dejar la otra huérfana); (2) comparar huellas vivas; (3) **aplicar junto con la app que
  muestra las cuentas en revisión**: con la app anterior los productos tardíos quedarían en una cuenta que
  el salón no muestra. **App HECHA (10-oct, sin commit):** la cola sube la cuenta local con su identidad (`SalesRepository.openLocalTableOrder` → `fn_open_local_table_order`, cae a `openTable` sin la migración); el salón lee `review_orders_count`/`review_total`, marca roja «2 cuentas · revisar» / «Cuenta por revisar» en tarjeta y plano (`widgets/review_accounts_badge.dart`); al tocar la mesa se abre la hoja `widgets/review_accounts_sheet.dart` (productos, total, motivo, hora; «Unir a la cuenta actual» y «Anular (era duplicado)» con dueño o PIN de Supervisor + motivo; la cuenta en revisión no se cobra ni se edita); `ZonesRepository.transferTableSession` bloquea transferir/unir con una cuenta en revisión (guarda de app hasta ajustar `fn_transfer_table_session`). Pruebas nuevas: `review_accounts_badge_test` (9), `local_table_order_identity_test` (2); suites `test/core/offline` + `test/sales` 965 ok; analyze sin errores. Guarda en el servidor: `20261010_0022_transfer_respects_review` (+ROLLBACK, APLICADA y verificada el 10-oct, huella `30d20ed1…`): candado por mesa (origen y destino, orden fijo), origen con cuenta en revisión → MP412, origen y destino eligen solo la cuenta principal. Cuerpo vivo guardado en `supabase/tests/fixtures/live_transfer_table_session_20261010.sql` (md5 `4eed56f3…`); después `30d20ed1…`. Prueba `transfer_respects_review_local_test.sh` (13 ok, con línea base que reproduce la huérfana). Falta: probar en la app.
- [ ] **T02 — hueco encontrado por la revisión del plan Hub (F4, H12/H13), por corregir antes de activar:** un
  equipo confirma «vacío» y justo después (o aislado) agrega algo local; el servidor cierra con esa confirmación
  vieja. La versión del servidor no ve lo que aún está solo en el equipo. Falta: fase de cierre en el equipo
  (tras confirmar, ninguna mutación sobre esa cuenta sin revocar la confirmación; sin red, bloquear o abrir una
  cuenta provisional) y confirmación tomada en exclusión con las mutaciones. T02 igual es más seguro que lo que
  corre hoy (que libera sin preguntar a nadie).
- [x] T04: versionado de cambios en el servidor y conflictos entre terminales.
  **Hecho (10 de octubre, sin aplicar):** `20261010_0006_versioned_order_edits` (+ROLLBACK) y
  `20261010_0007_close_direct_order_edits` (+ROLLBACK). Versión en `order_items` y `orders` (disparadores);
  `fn_apply_order_edit` única entrada: candado de la orden (el del cobro), reintentos por `op_id`, rechazo de
  versiones viejas (o de valores, en líneas creadas sin red), `p_force` solo por decisión del operador. Unir
  líneas de subcuenta (`consolidate_check`) se calcula en el servidor con lo vigente. La nota de la sesión solo
  recibe líneas de auditoría atómicas (`fn_append_session_note`); ya no se reescribe entera. La 0007 cierra las
  funciones de edición directa para `authenticated` — **aplicarla solo cuando TODOS los equipos tengan la app
  nueva** (incluido el build de la App Store); se detiene sola si una función INVOKER depende de ellas.
  App: toda edición (cantidad, nota, detalle, descuentos, cortesía, promociones, para llevar, extras, mover,
  borrar, delivery, impuestos, cliente de cuenta y de subcuenta, división) manda id único + versión vista; en
  fila por línea (dos toques no chocan consigo); sin respaldo de escritura directa (`deleteCheck` ya no borra
  productos). Conflicto: diálogo «Quedarme con lo de ahora / Aplicar mi cambio» (mesa y división). Cola
  offline: base en cada acción, compactación conserva la base más vieja, rebase de cambios propios, conflicto
  = dead visible con «Reintentar» (forzado); en el Hub, cuarentena que el Hub reaplica forzada.
  Pruebas: SQL 33 ok (con dos terminales cobrando/editando, 0007 y reversas); Dart nuevas
  `versioned_order_edits_vm_test` (5) y `versioned_edit_replay_test` (6); suite completa 2565 ok.
  Pendiente conocido: RLS todavía permite UPDATE directo de `order_items`/`orders` por PostgREST (la app
  nueva no lo usa para editar; cerrarlo por columna requiere revisar cocina, alta de ofertas y anulación).
  Ediciones de cuenta hechas en una caja cliente del Hub viajan sin versión de la cuenta (el Hub no la
  proyecta): se aplican sobre la vigente.
- [x] T07: conciliación financiera (cobros sin red, emisión fiscal, inventario).
  **Hecho (10 de octubre, sin aplicar, sin commit):**
  - `20261010_0008_offline_payment_reconciliation` (+ROLLBACK): recibo durable por cobro sin red
    (`offline_payment_receipts`, clave estable = id de la acción). `fn_replay_offline_payment` sube con la v3
    VIVA en su caja y con su fecha; si no puede (caja cerrada/desconocida/sin caja, fecha adelantada >1 h,
    cuenta ya cobrada, mismo método+secuencia ocupado por otro cobro, cuenta que creció) NO aplica ni mueve:
    queda «por decidir». `fn_resolve_offline_payment` (dueño/admin/gerente): registrar en la caja abierta
    (fecha original + nota de la caja cerrada en `cash_transactions`), abono parcial, aplicar con su fecha o
    dejar constancia. `fn_order_money_state` (saldo, sobrepago, subcuenta cerrada sin cobrar, comprobante
    faltante) se guarda en cada recibo; `fn_offline_payment_issues` lista lo pendiente. El cierre de caja NO
    se toca (decisión del dueño): un cobro que llega con su caja cerrada se decide aparte.
  - App: la cola sube cobros por esa entrada (sin la migración, la v3 de siempre); «por decidir» = dead
    visible que frena su cuenta; visor con botón «Resolver» (`offline_payment_resolution_dialog.dart`); en
    el Hub, cuarentena resuelta en el servidor; «Limpiar dead» nunca borra dinero; la caja abierta sin red
    que se adopta al sincronizar queda anotada en el recibo.
  - `20261010_0009_ecf_emission_uncertain_state` (+ROLLBACK) + `emit-document` + `alanube-webhook`: estado
    `uncertain` (outbox y `ecf_status`); `send_started_at` antes del POST; tiempo agotado/red/5xx/409/
    «ya existe»/2xx sin guardar → incierto, NUNCA se reenvía solo ni se marca rechazado; reclamos vencidos
    → pending (sin envío) o uncertain (con envío); el webhook lo concilia por e-NCF (si coincide uno solo);
    `fn_resolve_uncertain_emission` (found_in_alanube / not_in_alanube con el MISMO e-NCF); un e-CF incierto
    no se anula hasta resolverlo (MP440). **Publicar las funciones DESPUÉS de la migración.**
  - `20261010_0010_consume_inventory_order_lock` (+ROLLBACK): renombra la viva a `_unlocked` (sin copiar su
    cuerpo) y pone delante un envoltorio con candado consultivo por orden. Reintentar impresión, cocina,
    emisión o cobro ya no descontaba dos veces (concilia por diferencia); dos conciliaciones SIMULTÁNEAS sí
    (reproducido en la prueba) y ya no.
  - Pruebas: SQL `offline_payment_reconciliation` 30 ok (respuesta perdida, reinicio, dos subidas a la vez,
    caja cerrada, cambio de jornada, cobro parcial, falla fiscal, candado de otro equipo, permisos, reversa),
    `ecf_emission_uncertain` 17 ok, `consume_inventory_order_lock` 7 ok; Dart `offline_payment_replay_test`
    (6); Deno `emission-outcome_test` (5), `_shared` 247 ok (`deno test --no-check --allow-env`).
  - Pendiente conocido: el cobro dividido EN LÍNEA reintenta una vez con la caja abierta ante
    CASH_SESSION_NOT_OPEN (cobro de ahora; con un intento retomado del diario mezclaría fecha vieja y caja
    nueva); `fn_book_removal_waste` (20260920_0002, sin aplicar) puede anotar merma dos veces en carrera;
    `admin_mark_ecf_for_retry` del panel admin no conoce `uncertain`; el `ecf_status` de Alanube no se
    consulta por e-NCF (falta confirmar con Alanube un endpoint de búsqueda).
- [ ] T08: historial completo de borrado, división y traslado. Se cruza con borrar
  ítems con NCF, motivo de eliminación (`20260920_0002`) y aprobador de borrado
  (`20261005_0003`).

## 2. Impresión y e-CF (revisión de Codex)

- [x] **P1 comandas que vencían a los 60 s:** arreglado con renovación de claims
  cada 20 s. Pruebas: 26/26 del agente y 19 comprobaciones SQL. **Despliegue:
  primero el agente en todos los equipos, después `20261009_0001`.**
- [x] **Aprobaciones comerciales** (arreglado 23:50): la migración nueva
  `20261009_0006` agrega `issuer_rnc`. La unicidad de las aprobaciones pasa a ser
  emisor + e-NCF; los sets de e-CF y de simulación conservan la suya. Cargar un set
  ahora borra y guarda en una sola transacción: si falla, queda el anterior.
- [x] **Simulación e-CF** (arreglado): `fn_ecf_replace_simulation_set` bloquea la
  fila del alta y comprueba que las secuencias no cambiaron. Si otra simulación
  ganó, aborta (`simulation_conflict`, «Vuelve a tocar Generar») sin reusar
  números. Probado con dos sesiones a la vez.
- [x] **Consulta de trackId** (arreglado): se revisa el presupuesto de 30 s antes
  de cada consulta, también en `check_test_set`. Lo que falta queda «en proceso»
  para el siguiente lote.
- [x] **Respuesta de la DGII** (arreglado): el tiempo límite cubre también la
  lectura del cuerpo.
- [x] **Búsqueda de impresoras** (arreglado): cada prueba espera 800 ms, se revisan
  64 direcciones a la vez, la red tiene un tope de 7 s y devuelve lo ya encontrado,
  y el USB corre en paralelo. La lista mantiene el orden de antes.
- Pruebas: 27/27 del agente, 94 Deno de `_shared` (con chequeo de tipos de
  `ecf-onboarding`) y 14 comprobaciones SQL en
  `supabase/tests/ecf_test_set_replace_local_test.sh`. Cada prueba nueva falla sin
  su arreglo. El cambio en `refreshTrackIds` no tiene prueba propia, porque
  `index.ts` corre `Deno.serve` al importarse; solo pasó el chequeo de tipos.

## 3. Lo que tienes que correr tú en producción

- [ ] Confirmar el UUID del negocio del incidente: los scripts tienen Food Shop y
  El Encuentro.
- [ ] Correr los bloques 1, 6, 7, 8, 9 y 10 de
  `scripts/diagnostics/encuentro_food_shop_order_continuity.sql`, uno por uno (el
  editor muestra solo el último resultado). Guardar la salida: el bloque 1 es la
  única vuelta atrás real de 0004.
- [ ] Antes de cada migración, guardar las definiciones vivas con
  `pg_get_functiondef`: la base viva difiere del repo. Sobre todo
  `fn_close_order_and_table` (R6), `fn_complete_print_job` y
  `fn_reclaim_stale_print_jobs` (0001), y las funciones de `20260929_0001` y `0002`.
- [ ] Datos del incidente de El Encuentro: fecha aproximada, equipo y
  orden/mesa/ticket.

## 4. Despliegue, en orden

**Encontrado el 10 de octubre — el cajero no podía agregar productos a una mesa:** en TODOS los negocios el rol
`cashier` de la base no tenía `ventas.orden.agregar_item`, `editar_item` ni `enviar_cocina`. La app los valida y la
pantalla de la mesa no mostraba el error (el toque «no hacía nada»). Arreglo, decidido por el dueño (flujo de mesa +
operación, sin anular, descuentos, reabrir, créditos ni movimientos de caja):
- [x] **Aplicada el 10 de octubre** (el dueño confirma que la app sigue normal; falta pegar la consulta de
  verificación). Era requisito antes de publicar la app nueva (la publicada no valida el permiso; la nueva sí):
  `20261010_0001_cashier_default_permissions.sql`: 17 permisos al rol cajero de cada negocio solo donde
  falten, y un disparador para que los negocios nuevos nazcan con ellos. Prueba local: 12 ok. Después, los cajeros
  cierran sesión y vuelven a entrar.
- [x] La pantalla de la mesa avisa «No tienes permiso para agregar productos…» en vez de no hacer nada (sin commit).

**Aplicado en producción (10 de octubre, verificado con consultas):** `20261009_0004`, `0005`, `0006`, `0007` y la
versión nueva de `20261009_0001` (con renovación de claims). La versión vieja de la 0001 ya estaba aplicada antes por
otra tarea; no hubo comandas dadas por inciertas (0 en 7 días). Falta: instalar el agente nuevo en los equipos (ya no
hay orden obligatorio con la 0001), publicar `ecf-onboarding` y la app, y revisar los permisos de `fn_sales_*` y los
estados de `print_jobs` (962 trabajos en 7 días, solo 160 impresos).

1. [x] F5, F6 y F7 terminadas; los 5 de Codex también. Quedan los 4 pendientes menores de la
   fase 4 que hará la sesión mangospos-53 (ver sección 1.4).
2. [ ] Correr todas las suites sobre el árbol final:
   - `flutter analyze --no-pub`
   - `flutter test --no-pub`
   - `node --test agent/test/printer_recovery.test.js`
   - pruebas Deno de `supabase/functions/_shared/*_test.ts`
   - SQL: `sales_order_continuity`, `add_item_idempotent`, `payment_attempt_lock`,
     `notification_events`, `printer_delivery_uncertain`, `sales_note_cash_cycle`,
     `order_opener_name_alias`, `ecf_test_set_replace` y la prueba nueva de R6.
3. [ ] Commits separados por tema: ventas; impresión y agente; e-CF; y lo que haya
   de otras sesiones (por ejemplo `azul-charge-subscription`).
4a0. **10-oct, tarde: el dueño aplicó `20261010_0006`, `0008`, `0010` y `0009`** (en ese orden), tras revisar que no afectan a la app instalada (0006/0008 solo agregan; 0010 envuelve la función viva con candado por orden; el guard de 0009 solo actúa con ecf_status 'uncertain'). Huellas esperadas: `fn_apply_order_edit` `da095ade…`, `fn_replay_offline_payment` `4976e9a0…`, `fn_resolve_uncertain_emission` `c775df5e…`, `consume_inventory_from_order` `42bad147…` (+ `_unlocked` `5448d7fa…`, el cuerpo vivo de siempre renombrado). **Verificadas por el dueño el 10-oct: las 5 huellas coinciden.** Salud en producción tras aplicarlas: 97 pedidos y 212 productos en 30 min, 15 líneas editadas (versión > 1), 180 movimientos de inventario y 119 cobros en 1 h, 0 esperas de candado, e-CF sin `uncertain` (done=1, failed=2, pending=1 en 24 h, a revisar aparte), cron del barrido OK. Suites locales: 15 SQL (~270 comprobaciones) y Flutter 2593 ok sobre 3a9e2e4b. Siguen SIN aplicar: 0007 (solo con la app nueva en TODOS los equipos) y 0030 (T02, decisión del dueño). Falta publicar `emit-document` y `alanube-webhook` nuevas (van con 0009).
4a1. [ ] **Lo que sigue tras 4a0 (en este orden):**
   1. Funciones (las corre el dueño; pide la clave SSH): primero
      `CHECK=1 ./scripts/deploy_edge_functions.sh emit-document alanube-webhook`. Lo esperado es que difieran solo
      `_shared/emission-outcome.ts` (nuevo), `emit-document/index.ts` y `alanube-webhook/index.ts`. Si sale otro
      archivo de `_shared`, publicar con `SKIP_SHARED` para que no viaje; emit-document solo necesita
      `alanube-client`, `dgii-rounding`, `ecf-payload`, `ecf-tax-lines` y `emission-outcome`. OJO:
      `ecf-onboarding.ts` cambió el 10-oct y su función no se publica aquí. Después, la misma línea sin `CHECK=1`. Nunca llamar
      emit-document para probar: mirar el log en la próxima venta electrónica. Lo nuevo: un envío con respuesta
      dudosa (caída, 5xx, 409, «ya existe») queda `uncertain` y no se reenvía. El webhook lo adopta solo si
      Alanube lo tiene. Si no, se resuelve con `fn_resolve_uncertain_emission`; el panel admin aún no lo conoce.
   2. App (commit 3a9e2e4b en adelante): subir la versión (`pubspec` dice 2.0.20+20020 desde 77b5b036, que no
      traía T04) para poder distinguir los equipos actualizados en `device_sessions.app_version`. Actualizar
      cada equipo con su cola en 0. Las ediciones que la app vieja dejó en cola sin subir quedan «por revisar»
      («Cambio hecho con una versión anterior de la app»), no se aplican solas. Los cobros en cola no se afectan.
   3. 0007: solo cuando `device_sessions` no muestre equipos activos con una versión anterior.
4a. [ ] **Migraciones del 10-oct (integridad, todas SIN aplicar), en este orden:**
   - `20261010_0006_versioned_order_edits` (T04) ANTES de publicar la app nueva (sin ella la app nueva no
     edita cuentas; la vieja sigue igual).
   - `20261010_0008_offline_payment_reconciliation`, `20261010_0010_consume_inventory_order_lock`: cuando sea
     (consulta previa del 10-oct: consumo vivo = UNIFICADA y sin `_unlocked`; CHECKs como espera 0009; 0
     emisiones trabadas). 0008 reconoce las cuentas en revisión de `0020` (cobro sin red de una cuenta ya
     cobrada o anulada: «aplicar a la cuenta en revisión», solo por decisión).
   - `20261010_0009_ecf_emission_uncertain_state` y DESPUÉS publicar `emit-document` y `alanube-webhook`.
   - `20261010_0030_table_release_acks` (T02; antes 0005, renumerada para ir después de `0021`, cuyo mínimo
     de 30 min conserva): **NO aplicar hasta que el dueño decida.** Choca con su regla posterior («salir de una
     mesa sin productos la libera al instante»; mesas disponibles solas) y tiene el hueco H12/H13. Con `0020`
     aplicada, lo tardío ya no se pierde (vuelve como cuenta en revisión).
   - `20261010_0007_close_direct_order_edits`: solo cuando TODOS los equipos (incl. App Store) tengan la app
     nueva.
   - De la sesión de cuentas en revisión (no mía, independiente de las anteriores): `20261010_0022_transfer_respects_review`
     (transferir/unir mesa con candado y sin tocar cuentas en revisión) y `20261010_0023_release_lock_and_orphan_heal`
     (candado consultivo en la salida de mesa vacía y cura de órdenes vivas en sesión cerrada) y
     `20261010_0024_move_review_order` (mover una cuenta en revisión a otra mesa; quién la tomó y en qué mesa;
     redefine funciones de 0020/0023); sin aplicar. 0008 solo lee `review_source_order_id`: no le afecta. Si algún día
     se aplica T02 (0030), va DESPUÉS de 0023: su reversa ya restaura la salida de 0023.
4. [ ] Migraciones de ventas, antes de publicar la app:
   - `20261009_0004`: obligatoria. Si aborta por guardas vivas, decidir antes de
     reintentar.
   - `20260929_0001` (alta sin duplicar) y `20260929_0002` (candado de cobro).
   - La migración nueva de R6.
   - `20261009_0005` ya está aplicada.
5. [ ] Agente: va dentro del instalador del sistema (`installer/windows/build_inno.ps1` lo compila desde `agent/`).
   **No usar `-SkipAgentBuild`**: tomaría `agent/dist/mangopos-agent.exe` del 29 de agosto, sin la renovación ni los
   arreglos de impresión. La `20261009_0001` nueva ya está aplicada.
5b. [x] `20261010_0002_confirm_order_items_to_kitchen`: aplicada (10 de octubre). Comparada con la
   definición viva: `fn_confirm_order_to_kitchen` es igual al repo (sin `print_jobs`);
   `consume_inventory_from_order` cuenta todas las líneas no anuladas, así que confirmar menos
   líneas no cambia el inventario.
6. [ ] e-CF y nota de venta: confirmar el estado y aplicar `20261008_0001`
   (requiere `ECF_CREDENTIALS_KEY`), `20261008_0002`, `20261008_0003`,
   `20261009_0002`, `20261009_0003` y `20261009_0006`. **La 0006 va antes de
   publicar la nueva `ecf-onboarding`:** sin ella, cargar sets y generar la
   simulación fallan con «Falta aplicar la migración 20261009_0006».
7. [ ] Publicar la app en todos los equipos y comprobar que la cola sube sola al
   arrancar.
8. [ ] Piloto en El Encuentro: un día completo con dos equipos, cortes de internet
   controlados y cierre de caja conciliado. Correr la matriz V01–V33 del plan.
9. [ ] Informe de cierre: versión validada, resultados, límites y aprobación.
