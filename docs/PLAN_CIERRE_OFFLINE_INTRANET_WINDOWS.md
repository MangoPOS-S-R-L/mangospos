# Plan de cierre: operacion offline e intranet Windows

Estado: pendiente de implementacion y certificacion. Revision: 2026-09-30.

## 1. Objetivo y limite fisico

Objetivo: un negocio ya instalado sigue operando cuando pierde internet, sin
configurar IP, rol del Hub, vinculacion de PIN ni rutas de red en el momento de
la caida. La caja Windows actua como autoridad local; dos o mas meseros Windows
y cocina leen/escriben por la LAN. Al regresar internet, todos los hechos se
concilian una sola vez. El alcance incluye ventas, cobros, fiscal, cocina,
impresion, caja, inventario, compras, usuarios, configuracion y reportes.

"100%" significa **100% de los flujos soportados pasan los criterios de
aceptacion**, no disponibilidad absoluta frente a fallos de energia, disco,
router, caja, impresora o papel. No se debe anunciar una venta como cobrada o un
ticket como impreso solo porque un servidor acepto la solicitud.

Escenarios distintos:

| Escenario | Comportamiento exigido |
|---|---|
| WAN caida, LAN activa | Operacion compartida en el Hub; impresoras LAN y USB accesibles segun su host. |
| WAN y LAN caidas | Operacion local limitada y durable por equipo; no prometer mesas compartidas, PIN nuevo ni impresoras de otra PC. Reconciliar al restaurar LAN. |
| Hub/caja cerrada o apagada | No hay autoridad compartida. Modo local seguro o failover **solo** con replica, lease/fencing y pruebas contra doble Hub. |
| Equipo nuevo sin preparacion previa | No tiene negocio, credenciales, catalogo ni rangos fiscales. Requiere aprovisionamiento seguro previo o paquete de activacion local; no puede funcionar magicamente. |

## 2. Baseline y bloqueos conocidos

### Revision de migraciones del 2026-09-29

- `20260929_0001_add_item_idempotent.sql`: revisada y probada en PostgreSQL
  desechable con `supabase/tests/add_item_idempotent_local_test.sh`. El alta
  verifica pertenencia al negocio, deduplica `client_op_id` en la misma
  transaccion y rechaza reutilizarlo con otro contenido. La app nueva bloquea
  el alta si falta la funcion; no vuelve a la RPC sin idempotencia. La ruta de
  aumento de unidades tambien usa ahora el flujo `addItem` con outbox.
- `20260929_0002_payment_attempt_lock.sql`: revisada y probada en PostgreSQL
  desechable con `supabase/tests/payment_attempt_lock_local_test.sh`. Acquire,
  release y pago validan pertenencia al negocio; la subcuenta debe pertenecer
  a la orden; cada abono exige lease vigente y el NCF offline llega al RPC
  original. La app nueva bloquea el cobro online si falta el candado.
- Ambos scripts de rollback pasaron en la base desechable. La prueba usa un
  esquema minimo y una funcion de pago **stub**: no valida los triggers ni
  las firmas de la base viva. Antes de aplicar en produccion, comprobar en un
  clon reciente el esquema real, permisos, `auth.role()`,
  `is_member_of_business`, reglas fiscales, concurrencia y rollback.
- El cobro dividido guarda el diario antes del primer envio y se detiene si
  falla el almacenamiento. Los intentos incompletos ya no se borran por edad;
  requieren conciliacion. Esto no convierte el pago offline en una transaccion
  unica del Hub ni sustituye las pruebas con dos PC.
- Orden de despliegue: respaldo y prueba de restauracion; aplicar y verificar
  `0001` y `0002` en clon; aplicar en produccion con ventana y monitoreo;
  comprobar RPCs con una cuenta de prueba; **despues** instalar la app nueva en
  caja y meseros. Si la migracion falta, la app bloquea esos flujos por
  seguridad. No desplegar una app nueva antes de las funciones requeridas.
- Ninguna de estas migraciones se aplico a produccion desde este entorno. La
  migracion de compras `20260929_0050` es un cambio independiente y no forma
  parte de esta revision de dos migraciones.

El codigo ya tiene cola local, Hub LAN, descubrimiento, snapshots de lectura,
PIN cacheado, proyecciones de pedidos/cocina y varios transportes de impresion.
No partir de cero ni usar los porcentajes estimados como certificacion. Los
detalles actuales estan en [Intranet Windows](INTRANET_WINDOWS_Y_ADMINISTRACION.md)
y [revision de cobros](COBROS_INTRANET_REVISION_20260928.md). Los PRD de mayo y
el smoke test de junio son antecedentes, **no** estado actual: contienen
afirmaciones que ya cambiaron.

Bloqueos de liberacion actuales:

- La migracion `20260928_0002_session_offline_roster.sql` se probo en PostgreSQL
  desechable, no se aplico a produccion; validar tambien leases y token LAN.
- La version reciente no se compilo, instalo ni probo en caja + dos meseros
  Windows reales. Los tests Flutter/loopback no prueban firewall, impresoras ni
  concurrencia fisica.
- PIN y permisos caducan 24 horas despues de la ultima descarga cloud; copiarlos
  desde el Hub no reinicia ese plazo. No hay altas/bajas/permisos locales.
- Cobro dividido carece de diario durable del intento completo y transaccion
  unica en el Hub. Persisten rutas directas a Supabase y falta bloqueo por
  cuenta entre PC.
- Crear un item no tiene idempotencia transaccional de extremo a extremo en
  servidor si se pierde el acuse despues del INSERT. Hay casos sin cubrir de
  subcuentas, abonos, ajustes de orden y alias de ID local/remoto.
- Inventario administrativo, compras, usuarios y configuracion son mayormente
  dependientes de nube. El cache de lectura no equivale a escritura local.
- La impresion puede confirmar trabajo **encolado**, no papel entregado. El
  fallback de algunas rutas llega a `print_jobs` cloud, inutil si no hay WAN.
- El proceso Hub vive dentro de MangoPOS de la caja: cerrar la app lo detiene.

## 3. Trabajo pendiente por prioridad

Cada casilla requiere implementacion, test automatizado y evidencia en Windows.
P0 impide certificar venta segura; P1 completa la operacion diaria; P2 cierra
administracion, resiliencia y soporte.

### P0. Preparacion y conectividad automatica

- [ ] Definir un estado unico `listo para corte`: negocio y sesion inicial,
  token privado LAN, lease de Hub, cache de catalogo/impuestos/modificadores,
  mesas, PIN/roles, NCF, impresoras/rutas y espacio de disco. No declarar listo
  por presencia de archivos solamente: validar version, integridad y vigencia.
- [ ] Preparar automaticamente al entrar al negocio y refrescar en segundo
  plano; alertar antes del corte si algo critico falta, con causa y accion.
  Ninguna configuracion manual debe ser necesaria cuando ya se perdio WAN.
- [ ] Compilar ambos instaladores Windows, verificar migraciones en entorno de
  prueba y actualizar todos los terminales a la misma version. Probar reglas
  de firewall para `4100` (Hub) y `4000` (agente) en subred local, perfiles
  privado/dominio, sin desactivar el firewall.
- [ ] Confirmar que discovery valida `/hub/health`, `business_id`, rol, token y
  version; no confundir agente de impresion u otra web con el Hub. Reintentar
  al cambiar IP, reiniciar router/cliente y recuperar WAN, sin vincular PIN ni
  escribir IP. Mostrar estado y diagnostico util cuando Windows deniegue la
  regla de firewall.
- [ ] Definir una sola autoridad por negocio mientras existe Hub: lease,
  fencing y epoch consistentes en cloud/Hub/clientes. Nunca elegir otro Hub a
  ciegas solo porque el titular no responde; evitar split-brain.
- [ ] Decidir e implementar aprovisionamiento seguro para un equipo nuevo que
  nunca inicio sesion. Si se exige alta sin WAN, usar paquete firmado o flujo
  local equivalente, con expiracion y revocacion posterior. Documentar que esto
  no es lo mismo que preparacion automatica de equipos ya instalados.

### P0. Ventas, items, cobros y fiscal

- [ ] Convertir cada mutacion de pedido en comando durable con `operation_id`
  estable, aplicado transaccionalmente en Hub y deduplicado en Supabase. Incluir
  alta de item y reemplazo de modificadores; respuesta perdida + reintento no
  puede duplicar items, impuestos ni descuentos.
  - Avance 2026-09-29, **alta de item**: `client_op_id` por toque en el intento
    online, el proxy del Hub, la accion encolada y el replay (cola y op-log).
    El servidor deduplica en `fn_add_item_from_menu_idempotent` + bitacora
    `order_item_client_ops` (migracion `20260929_0001`, **sin aplicar**;
    `supabase/tests/add_item_idempotent_local_test.sh` 43/43, incluida
    concurrencia). Los modificadores de un reintento se reemplazan, no se
    insertan. Sin la migracion la app cae a la RPC vieja (sin garantia).
  - Avance 2026-09-29, **oferta y modificadores**: misma migracion agrega
    `fn_add_offer_deal_idempotent` (misma bitacora; si la oferta viva falla en
    el servidor, alta normal con el MISMO id; un error de red ya no dispara el
    respaldo que duplicaba) y `fn_replace_order_item_modifiers` (DELETE+INSERT
    en una transaccion, SECURITY INVOKER con RLS, candado por item).
    Pendiente: aplicar la migracion y evidencia en Windows.
- [ ] Mantener una identidad canonica de orden/item/subcuenta al pasar entre
  copia local, Hub y nube. Bloquear dependencias de la misma orden aunque una
  accion use ID local y otra ID remoto; nunca resolver un item por parecido.
- [ ] Completar proyecciones LAN de subcuentas, pagos parciales, ajustes de
  orden, descuentos, propinas, credito/saldo y cierres online. Validar totales,
  impuestos y estado de mesa contra la misma fuente de verdad.
- [ ] Persistir **antes de enviar** la intencion completa de cobro (cuenta,
  items, metodo, importe, vuelto, moneda, NCF, referencia, indice de split,
  empleado y operacion). Recuperarla tras cierre abrupto/reinicio; no iniciar
  un cobro distinto al reabrir el modal.
  - Avance 2026-09-29, **cobro dividido**: `PaymentIntentJournal`
    (`lib/core/offline/payment_intent_journal.dart`) guarda el plan (metodos,
    montos, referencia, cuenta bancaria, `attempt_id`, fecha, nota de venta,
    camino offline y NCF de papel) antes del primer envio y cada abono
    confirmado. Al reabrir el cobro de la misma cuenta se retoma bloqueado con
    los mismos indices (el servidor deduplica por orden/subcuenta/metodo/
    `split_sequence`); si la cuenta cambio, solo avisa; offline no reencola lo
    ya encolado ni pide otro NCF. Tests: `payment_intent_journal_test` (8).
    Pendiente: modal simple, salida supervisada para descartar un intento,
    evidencia en Windows.
- [ ] Crear comando transaccional de pago en el Hub que bloquee la cuenta,
  valide saldo/version y guarde pagos, cierre, fiscal, movimiento de caja y
  outbox atomicamente. En split, definir si la unidad atomica es el plan entero
  o cada abono, y hacer visible el progreso durable; nunca cobrar dos veces.
  - Avance 2026-09-29, **bloqueo por cuenta con internet** (migracion
    `20260929_0002`, **sin aplicar**; `supabase/tests/payment_attempt_lock_local_test.sh`
    35/35): candado por orden con vencimiento (`order_payment_attempts`),
    `fn_payment_attempt_acquire` (dice quien cobra, lo ya cobrado por otros
    intentos y el siguiente `split_sequence`), `fn_process_payment_v3_attempt`
    (envuelve la v3 viva, renueva y suelta el candado) y trigger en `payments`
    que rechaza cualquier cobro de otro intento con candado vigente (tambien
    builds viejos, modal simple y replay offline). El cobro dividido toma el
    candado antes de grabar, cobra solo el restante de un cobro anterior a
    medias sin chocar con el indice unico, y va offline si no hay red para
    tomarlo. Tests: `payment_attempt_lock_test` (12). Pendiente: candado por
    LAN en el Hub cuando no hay WAN, modal simple con candado propio,
    evidencia en Windows.
- [ ] Eliminar rutas de pago que salten del Hub a Supabase durante modo Hub.
  Timeout significa estado desconocido: consultar por `operation_id` antes de
  reintentar. Completar auditoria del modal simple y callbacks de impresion.
- [ ] Persistir y reintentar metadata bancaria **sin repetir el cobro**;
  probar credito, pagos mixtos, devoluciones/anulaciones y cierre de caja.
- [ ] Validar reserva y consumo NCF en dos PC, reinicios, agotamiento de rango,
  huecos y conciliacion con nube. Acordar con responsable fiscal que documento
  se permite cuando la emision electronica externa no responde; no anunciar
  aprobacion externa offline.

### P0. Impresion local confiable

- [ ] Inventariar rutas reales: USB en caja, USB en PC remota, TCP/LAN,
  Bluetooth si aplica, cocina, precuenta, factura, reimpresion y comprobantes
  de caja. Asociar cada impresora a host/area y guardar configuracion util
  localmente, con version para evitar IP/host obsoletos.
- [ ] Crear **outbox de impresion local durable** por trabajo, `job_id`, tipo,
  impresora, bytes o plantilla/version, estado y `idempotency_key`. Guardar
  antes de enviar; el fallo de WAN nunca debe desviar el unico respaldo a una
  cola cloud. Drenar al volver agente/impresora, incluso tras reinicio.
- [ ] Distinguir `pendiente`, `aceptado por agente`, `enviado a impresora`,
  `confirmacion fisica si disponible` y `fallido`. HTTP `202` solo indica cola.
  No informar "impreso" ni repetir automaticamente un trabajo de resultado
  fisico ambiguo sin politica explicita de reimpresion/copia.
- [ ] Probar primero agente local cuando la impresora esta en esta PC, luego
  host LAN verificado; no depender del lookup cloud del host. Para USB remota o
  TCP exigir LAN activa; si cae, conservar el trabajo pendiente y avisar.
- [ ] Reintentar con backoff, limite y visibilidad de fallos; soportar
  impresora apagada, sin papel, cable desconectado, IP cambiada, agente
  reiniciado, host remoto apagado y respuesta perdida. Evitar ticket duplicado
  en cocina al recuperar la red.
- [ ] Probar tickets fisicos para 58/80 mm y modelos soportados, raster/ESC-POS,
  caracteres, corte y gaveta. Un test de pagina exitoso no valida factura o
  comanda: ejecutar cada flujo real.

### P1. Cocina, caja y sincronizacion

- [ ] Validar dos meseros agregando/modificando/anulando items de la misma
  mesa y cocina recibiendo eventos y cambios de estado en vivo. Al reiniciar
  cualquier cliente, reconstruir desde snapshot + log del Hub sin perder
  orden, notas, modificadores o asignacion de area.
- [ ] Hacer transaccionales en Hub apertura/cierre de caja, movimientos,
  arqueo, devoluciones y motivos de auditoria; serializar cambios concurrentes
  y mostrar pendientes no conciliados en cierre.
- [ ] Reconciliar Hub -> nube y nube -> Hub por ID y version, con deduplicacion
  de servidor para cada tipo de comando. No sobrescribir hechos de inventario
  o pagos por una copia mas reciente pero incompleta.
- [ ] Definir politica explicita para ordenes parcialmente subidas a nube al
  perder WAN. No migrarlas silenciosamente de autoridad ni bloquear ventas
  independientes; mostrar conflicto y flujo de resolucion.
- [ ] Mantener cola ordenada por dependencias, reintentos con backoff, errores
  permanentes visibles y auditoria. Nunca borrar pendientes al salir/cambiar
  negocio sin confirmacion y exportacion/recuperacion segura.
- [ ] Asegurar que reiniciar caja/mesero entre escritura y acuse conserva
  exactamente una operacion; restaurar snapshots, mappings y progreso sin
  depender de memoria de la pantalla.

### P2. Administracion completa sin internet

- [ ] Inventario: CRUD de productos/almacenes/lotes, ajustes, transferencias,
  conteos y stock compartido en Hub. Aplicar deltas y recepciones en
  transacciones, no sobrescribir stock absoluto ante cambios concurrentes.
- [ ] Compras: guardar pedido, lineas, proveedor, recepcion parcial/total y
  cuenta por pagar localmente. Una recepcion repetida no duplica existencias,
  costo ni deuda.
- [ ] Usuarios: crear/desactivar empleados y cambiar PIN/permisos desde una
  autoridad local con auditoria y validacion por comando. Definir politica
  segura para cortes de mas de 24 horas, revocacion y credenciales cloud
  diferidas; no mantener acceso indefinido por accidente.
- [ ] Configuracion: editar precios, impuestos, impresoras, zonas y reglas de
  negocio localmente con versiones, permisos y resolucion de ediciones
  simultaneas. Propagar a cada cliente sin pisar cambios mas nuevos.
- [ ] Reportes: calcular desde hechos locales ventas del dia, caja, impuestos,
  pagos, inventario y compras; indicar alcance/frescura. Permitir buscar y
  reimprimir comprobantes locales sin WAN; conciliar cifras al volver la nube.
- [ ] Integraciones externas: persistir solicitud, estado y reintento; nunca
  simular autorizacion de banco, DGII u otro servidor que no fue contactado.

### P2. Resiliencia, seguridad y rendimiento

- [ ] Evaluar Hub como servicio Windows independiente de la ventana MangoPOS;
  arrancar automaticamente y recuperar tras crash/actualizacion. Si se agrega
  failover, exigir replica durable, fencing y prueba de particion de LAN.
- [ ] Respaldar y restaurar base del Hub, outbox, trabajos de impresion y
  reservas fiscales cifradas. Ensayar disco lleno/corrupto y restauracion en
  otro equipo sin perder hechos ni reutilizar NCF.
- [ ] Autenticar cada dispositivo y cada comando LAN; aislar negocios,
  revocar tokens, proteger datos en reposo y en transito en la LAN elegida.
  Revisar endpoints legacy antes de confiar en una LAN no administrada.
- [ ] Medir p50/p95 de abrir mesa, agregar item, propagar a cocina, cobrar,
  aceptar impresion y sincronizar, con WAN activa y caida. Fijar presupuestos
  de latencia a partir de mediciones reales y eliminar esperas cloud en modo
  Hub; no usar los tests unitarios como benchmark.
- [ ] Ofrecer tablero de diagnostico: modo/Hub, ultimo sync, pendientes,
  conflictos, expiracion PIN/NCF, salud de impresoras, causa del ultimo error y
  opcion segura de exportar evidencia sin revelar PIN o tokens.

## 4. Matriz minima de pruebas de aceptacion

Entorno: caja Windows Hub, dos meseros Windows, cocina, impresora USB en caja e
impresora LAN/USB remota. Misma version y negocio. Preparar automaticamente
antes del corte, sin elegir manualmente IP ni Hub. Repetir con mas de un negocio
para comprobar aislamiento. Registrar version, migraciones, hora, `operation_id`
anonimizado, resultado local y resultado cloud tras reconexion.

| Prueba | Resultado obligatorio |
|---|---|
| Cortar solo WAN; mantener router/LAN | Mesas, items, cocina, pagos e impresion local siguen; clientes ven la caja sin configurar nada. |
| Reiniciar cada mesero sin WAN | Recupera sesion autorizada, pedido y outbox; no duplica al reintentar. |
| Reiniciar caja entre persistencia y respuesta | Cliente descubre Hub al volver; exactamente un efecto por operacion. |
| Dos PC editan/cobran misma cuenta | Estado consistente; no doble cobro, saldo negativo ni cierre prematuro. |
| Cobro split interrumpido en cada abono | Progreso durable, importes y NCF correctos tras reiniciar. |
| Perder acuse de alta de item/pago/impresion | Reintento con mismo ID no crea duplicados; estado ambiguo visible. |
| Apagar/desconectar impresora y restaurarla | Trabajo durable y visible; reintento seguro; verificar papel, no solo HTTP. |
| Cortar tambien LAN | No se promete sync entre PC; operacion local permitida es durable y se concilia luego. |
| WAN ausente mas de 24 horas | Politica de PIN definida, probada y visible; nunca acceso accidental por permiso vencido. |
| Inventario, compra, usuarios y ajustes sin WAN | Cada escritura persiste en Hub, aparece en clientes y concilia una vez. |
| Reconectar WAN con pendientes y conflictos | Nada desaparece ni se duplica; tablero explica que se aplico y que requiere intervencion. |
| Disco lleno, fallo de caja y restauracion | No confirmar operaciones no persistidas; recuperar desde respaldo sin doble autoridad. |

Automatizar pruebas de contrato y fallos de transporte para cada fila; ejecutar
ademas pruebas fisicas con impresoras y red reales. Guardar evidencia de p50/p95,
conteos de pendientes antes/despues, importes, NCF y hojas impresas.

## 5. Regla de salida

No declarar "100% offline" hasta que **todas** las casillas del alcance elegido
esten cerradas y la matriz anterior pase en Windows con WAN cortada. En
particular: cero ventas/pagos/items duplicados o perdidos; cero NCF reutilizados;
ningun ticket encolado presentado como impreso; administracion ejecutable en
Hub; sincronizacion conciliada; recuperacion tras reinicio; latencia medida y
diagnosticos comprensibles. Una prueba fallida reabre la casilla correspondiente.

Las politicas de fiscalidad, acceso durante cortes largos, reimpresion de
resultado ambiguo y aprovisionamiento de equipos nuevos requieren decision de
producto/negocio antes de implementarse; no deben resolverse con un fallback
silencioso que comprometa dinero, seguridad o cumplimiento.
