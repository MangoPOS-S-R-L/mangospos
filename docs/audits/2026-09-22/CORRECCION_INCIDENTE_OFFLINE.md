# Continuidad de mesas y cocina ante caída de internet

22 de septiembre de 2026. Cambios locales sobre `881067cf`; sin despliegue ni cambios en el servidor.

El usuario reportó que al perder internet en un evento no podía agregar productos ni enviar a cocina. Se encontraron rutas compatibles con ese bloqueo: las mutaciones seguían intentando nube y el método de impresión «local» consultaba configuración, ruteo y datos remotos. Sin logs ni versión del equipo del evento, no se atribuye con certeza aquel incidente a una única causa.

## Correcciones implementadas

- **Agregar productos:** cuando la conexión está caída, o una operación reciente confirmó un fallo de transporte, se usa el flujo local. Se evita encadenar timeouts durante 20 segundos mientras el detector confirma la caída. El escáner puede resolver nombre, precio e impuestos desde el catálogo previamente descargado. Si falta la configuración fiscal necesaria, se informa; no se inventan impuestos.
- **Enviar a cocina:** el envío local usa configuración, rutas e impresoras cacheadas, sin consultar Supabase. Respeta productos destinados a varias áreas y también se usa si hay ítems temporales pendientes de subir aunque ya haya vuelto internet. El envío online observa conjuntamente los errores de sus consultas iniciales para permitir el fallback.
- **Impresora inaccesible:** se conserva la operación con las áreas entregadas y pendientes, y se muestra el pendiente. No se afirma que salió el papel si el transporte falló. Las rondas sucesivas conservan entradas independientes en la cola; no se reemplaza una comanda anterior por otra de la misma mesa.
- **Sincronización:** un solo sync local por negocio, mutaciones de cola serializadas dentro del proceso y poda sobre el estado vigente. Las acciones que llegan durante una llamada remota se conservan. Una acción en procesamiento no absorbe nuevas modificaciones. También se corrigió un futuro de limpieza del uplink Hub que podía esperarse a sí mismo.
- **Identidad:** se deduplica por ID de operación. Dos operaciones distintas con contenido similar siguen siendo distintas; las huellas semánticas antiguas no sirven para descartar operaciones nuevas, tanto en la cola como en el uplink Hub.
- **Inventario:** un timeout durante replay conserva la acción como pendiente/fallida; ya no reencola silenciosamente y retorna como si el servidor la hubiera aplicado.
- **Pagos divididos:** se guardan y reproducen secuencia, cierre de orden/check y tipo fiscal solicitado. Esto corrige el contrato del cliente; no certifica aún el RPC instalado ni la proyección de abonos en el Hub.
- **Guardado:** se comprueba el resultado de escritura de snapshots y de la cola web. Los snapshots de órdenes usan la misma política durable que ya tenía la cola: si Keychain no consigue persistir la clave, se guarda texto legible en disco para evitar perderlo al reiniciar. Es un compromiso explícito de cifrado en reposo; sigue pendiente definir una política uniforme de almacenamiento seguro. SharedPreferences no se convierte por esto en una base transaccional.

## Validación realizada

**Suite completa: 1,574 aprobadas, 1 omitida, 0 fallidas.** La omitida es la prueba preexistente de redondeo de centavos. Análisis de los once archivos de implementación/pruebas seleccionados: sin incidencias. `git diff --check`: sin problemas.

Se añadieron 13 regresiones:

| Archivo | Casos |
|---|---|
| `test/sales/offline_order_continuity_test.dart` | Mesa existente: agregar e imprimir sin consultas cloud; reconexión con ítems temporales; impresora caída; caché de impresora ausente; escáner por ID; ruteo cocina/bar con fallo parcial; fallo de las consultas iniciales online |
| `test/core/offline/offline_queue_concurrency_test.dart` | Encolado durante sync; 20 encolados concurrentes; dos conteos diferentes y reintento del mismo ID; dos rondas de cocina con estados independientes |
| `test/core/offline/offline_replay_integrity_test.dart` | Conservación del contrato de pago dividido; timeout del repositorio real de inventario sin falso éxito |

Las pruebas usan SQLite en memoria, HTTP simulado y transporte de impresión simulado. Las pruebas de venta ejecutan los handlers reales de `SalesViewModel` con estado inicial preparado; no prueban el arranque completo, el navegador, hardware ni una red real. La recuperación de snapshot se prueba leyendo lo guardado, no matando/reiniciando un dispositivo.

```sh
flutter test --no-pub --reporter expanded
flutter test --no-pub --reporter expanded test/core/offline/offline_queue_concurrency_test.dart test/core/offline/offline_replay_integrity_test.dart test/sales/offline_order_continuity_test.dart
```

## Qué falta para garantizar el evento completo

1. **Certificar la plataforma usada.** La app nativa y la web no tienen las mismas garantías de arranque, persistencia ni acceso a impresoras. Preparar cada terminal con catálogo, impuestos, permisos, mesas y rutas antes del evento. El indicador de preparación ya se implementó localmente en el seguimiento: ver [detalle del indicador](INDICADOR_PREPARACION_OFFLINE.md). Sigue pendiente certificar cada plataforma con equipos reales.
2. **Ensayo físico con WAN desconectada y LAN activa:** arrancar, abrir caja/mesas, agregar/modificar productos, enviar varias rondas a cocina/bar, cobrar con métodos combinados, salir y reabrir mesas, reiniciar equipos y reconectar. Contar tickets y reconciliar ventas, pagos, caja e inventario. No basta el modo offline del simulador.
3. **Autoridad y recuperación entre equipos:** verificar Hub, cocina en pantalla (el guard del host detectado en la auditoría sigue pendiente), proyección correcta de pagos parciales, respaldo, partición de LAN y recuperación del primario.
4. **Integridad de extremo a extremo:** estado+outbox en una transacción durable, dependencias de operaciones fallidas y deduplicación transaccional en servidor ante respuesta perdida después del commit. El candado añadido coordina el proceso actual, no varias pestañas o procesos independientes. Las herramientas de limpieza/reintento manual de la cola necesitan esa misma garantía transaccional.
5. **Impresión pendiente y reinicios:** recuperación/reintento local aunque WAN continúe caída, entrega parcial a varias impresoras de una misma área y corte entre entrega física y guardado del ACK. Esta corrección no promete impresión física exactamente una vez. Un área pendiente se conserva para replay; eso no equivale a un worker local de reintento ya certificado.
6. **Resto de cobertura:** PIN/roster de 24 h, política fiscal offline, arranque web, crédito, compras y otros módulos siguen según la matriz del diagnóstico. Las operaciones antiguas ya encoladas sin datos de cierre de split requieren reconciliación; no se reconstruyen campos ausentes por adivinación.

Perder internet no debe detener una terminal preparada. Perder también Wi-Fi/LAN impide que equipos separados se comuniquen: para mantener cocina y varios puestos sin WAN se necesita red local operativa, o conexiones físicas/directas compatibles con cada equipo. El cambio todavía debe instalarse y pasar este ensayo antes de anunciar soporte offline completo.
