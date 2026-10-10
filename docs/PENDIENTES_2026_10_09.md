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
- [ ] T02: cada equipo confirma antes de liberar una mesa (registro de
  participantes, versión y acuse, también en el cron).
- [ ] T04: versionado de cambios en el servidor y conflictos entre terminales.
- [ ] T07: caja y fecha de origen del cobro offline; estado durable de la emisión
  fiscal externa.
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
