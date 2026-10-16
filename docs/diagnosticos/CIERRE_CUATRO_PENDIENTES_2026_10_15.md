# Reimpresión íntegra y edición de grupos de venta

15 de octubre de 2026. Implementación de los cuatro pendientes de la revisión.
Código y migración preparados; sin despliegue ni cambios en datos de producción.

## 1. Reimpresión con parte del detalle ausente

La reimpresión usa el documento exacto y carga todas las páginas de productos,
incluidos los pagados. La lectura tiene orden estable por fecha e ID; ya no
se detiene en las primeras 500 líneas de una orden.

Antes de enviar papel contrasta subtotal, impuestos y descuento almacenados
de las líneas con los importes del documento. Una lista no vacía es
insuficiente: se bloquea también si falta parte del detalle, si hay IDs
repetidos o importes no finitos. La tolerancia se limita al redondeo de los
componentes por línea. También detecta una unidad gratis ausente cuando el
total cobrado coincide pero subtotal/descuento ya no coinciden.

El ámbito del documento completo requiere consultar las subcuentas facturadas
y las notas de venta. Un error de red o permisos al leer notas aborta; solo
la ausencia de esa tabla en servidores antiguos admite compatibilidad.

Esta validación contrasta los importes históricos disponibles; no reconstruye
productos perdidos ni sustituye sus nombres/cantidades por el catálogo actual.

## 2. Aumentar ofertas enviadas a cocina

La ronda ya enviada conserva su cantidad. El incremento crea una línea draft
con ID estable, mismo producto, precio de la venta, subcuenta y modificadores
con sus identidades de inventario. El servidor conserva el marcador y snapshot
de la oferta original; no convierte el incremento en producto ordinario.

El beneficio se calcula por paquetes completos dentro de cada subcuenta,
producto, promoción, regla y precio. Con botella de RD$250 y 4×3:

- 8→12: tres paquetes, descuento RD$750 y total RD$2,250.
- 4→8: dos rondas de cuatro con RD$250 de descuento cada una.
- 3→4: tres ya enviadas y una draft; juntas completan una oferta por RD$750.
- 8→6: un paquete de cuatro por RD$750 y dos unidades de RD$250; total RD$1,250.

El reparto nunca conserva fracciones del beneficio de un paquete incompleto.
Si el beneficio debe repartirse entre rondas, cada línea tiene como límite su
bruto. Las cortesías explícitas conservan su recorrido. Los movimientos entre
subcuentas recalculan la elegibilidad por cuenta; no dejan una unidad gratis
sin el resto del paquete en otra cuenta.

El KDS local conserva las rondas existentes. El borrador nuevo no se muestra
como enviado hasta el próximo envío a cocina.

## 3. Guardado offline del grupo

Editar o eliminar unidades desde el modal genera una sola acción
`edit_item_group`, con todas sus bases/versiones, altas, cambios y borrados.
Se guarda antes de aceptar el cambio local. La misma entrada contiene las
líneas resultantes y retiradas para recuperar el estado si la app se cierra
antes de actualizar su snapshot.

La cola solicita subida inmediata al guardarse y mantiene el mismo ID durante
reintentos. Hub, réplica y proyectores reciben el grupo entero. Las ediciones
posteriores adoptan las versiones confirmadas por los cambios anteriores del
mismo equipo. Un conflicto conserva el lote completo para resolución explícita;
no se marca como sincronizado ni se fuerza automáticamente.

La recuperación de copias sin orden (por ejemplo, datos de dirección de un
delivery que aún no empezó) sigue siendo compatible. Cambiar de mesa mientras
se guarda no permite que el grupo modifique la cuenta que se acaba de abrir.

## 4. Una sola transacción en el backend

`fn_apply_order_item_group` valida acceso al negocio, toma el mismo candado
de la orden que las ediciones/cobros y llama las funciones versionadas
existentes. Si cualquier línea tiene conflicto, revierte las anteriores,
sus versiones y las bitácoras de operaciones. Un error SQL posterior también
revierte el grupo entero.

`order_group_edit_ops` guarda únicamente los lotes aplicados. Repetir el ID y
su contenido devuelve el resultado anterior. Reutilizarlo para otra intención
es un error; perder la respuesta no agrega otra ronda. El alta debe estar
vinculada a una línea fuente incluida en las ediciones versionadas del lote.

`fn_reprice_order_offer_groups` centraliza el recálculo por subcuenta. La
migración añade su llamada a las ediciones relevantes sin sustituir el resto
de la función viva. El bypass del cálculo individual se limita a la
transacción agrupada, que recalcula los beneficios antes de confirmar.

## Instalación y reversa

1. Ejecutar los ensayos SQL locales y las pruebas indicadas abajo.
2. Aplicar en un clon reciente, en orden:
   - `20261014_0001_preserve_offer_packages_in_split.sql`.
   - `20261014_0002_offer_quantity_discount.sql`.
   - `20261015_0001_atomic_item_groups.sql`.
   - `20261015_0002_legacy_offer_group_rules.sql`.
3. Comprobar la migración en el clon y aplicar al servidor antes de instalar
   el cliente nuevo. Los grupos no tienen fallback a escrituras individuales:
   si falta la RPC, quedan pendientes y el servidor informa la migración.
4. Instalar el cliente y el Hub actualizados en todos los equipos del negocio.

La migración nueva no realiza backfill ni modifica ventas históricas. Su
rollback retira la RPC y los parches de funciones, conservando la bitácora de
lotes aplicados para que una reinstalación no duplique cambios. Ejecutar las
reversas en orden inverso a la instalación. No descartar colas pendientes.

Las ofertas sin snapshot admiten ahora recuperación desde la etiqueta histórica
N×M generada al vender, únicamente si el precio, la cantidad de paquetes completos
y el descuento guardados concuerdan. No se consulta el catálogo actual ni se
acepta el nombre como única evidencia. Si no se puede comprobar la regla, se
permite retirar toda la línea; un retiro parcial requiere revisar la venta.
Los documentos con detalle ya perdido no se reparan automáticamente.

## Regresiones

- `test/sales/offer_split_receipts_test.dart`: flujo real de reimpresión con
  orden parcial/completamente cobrada y detalle completo, vacío o parcial.
- `test/sales/issued_receipt_integrity_test.dart`: unidades gratis ausentes,
  datos inválidos, IDs repetidos y carga de 601 líneas en tres páginas.
- `test/sales/grouped_item_edit_test.dart`: paquetes completos al reducir o
  incrementar, rondas físicas separadas, cortesías, ámbito de subcuenta y KDS.
- `test/sales/sales_mutation_navigation_integrity_test.dart`: una sola acción
  durable, recuperación sobre snapshot antiguo y navegación a otra mesa.
- `test/core/offline/versioned_edit_replay_test.dart`: respuesta perdida,
  conflicto de lote y rebase de las ediciones posteriores.
- `supabase/tests/offer_split_receipts_local_test.sh`: precios/ediciones reales
  del repositorio en PostgreSQL desechable, validación de acceso, conflicto en
  segunda fila, error posterior, replay sin duplicación, rondas 3+1, 8→12,
  movimientos entre subcuentas y rollback/reinstalación sin cambiar datos.

## Resultado de la verificación

- Suite completa de Flutter, incluyendo la corrección del bloqueo legacy:
  **2,776 pruebas aprobadas y una omitida**.
- Ensayo PostgreSQL local: aprobado, incluyendo instalación repetida, conflictos,
  reintentos y rollback/reinstalación sin alterar los datos del ensayo.
- Análisis estático de los archivos revisados: sin errores. Conserva una
  advertencia y doce avisos informativos de código previo en la pantalla de
  ventas y sus pruebas de navegación; no se añadieron diagnósticos nuevos.
- `git diff --check`: aprobado.

Estos resultados validan la implementación local. La migración y los nuevos
cliente/Hub todavía deben desplegarse siguiendo el orden indicado arriba.

## Corrección del bloqueo reportado al retirar una unidad

La validación anterior rechazaba cualquier edición de una línea `[DEAL:]`
sin `[DEAL_RULE:]`, incluso su eliminación completa. Ese rechazo ocurría antes
de encolar y el mensaje terminaba como «Intenta de nuevo» al envolverlo en un
`StateError`.

La aplicación recupera reglas verificables y conserva el snapshot después del
primer retiro. El servidor reconstruye la misma regla sobre su fila original,
antes de modificar la cantidad; prevalece sobre marcadores enviados por el
cliente. La base de versión/valores se mantiene como la vio el operador. La
edición individual de una oferta recuperable usa también el lote durable.

Se cubren retiros 4→3, 8→7, 8→6 y 8→4, aumentos 4→8, 2×1, filas sin versión,
reintentos, catálogo ausente, datos contradictorios y borrado completo. La
migración nueva conserva el cálculo fiscal y no modifica ventas al instalarse.
El ensayo SQL pasó incluyendo instalación repetida y rollback/reinstalación.
Si las tres migraciones anteriores ya están aplicadas, solo falta ejecutar
`20261015_0002_legacy_offer_group_rules.sql` y actualizar el cliente/Hub. Esta
corrección no se ha aplicado desde aquí a producción.

Los otros mensajes del log son independientes de ese rechazo:

- `HubLease`: el servidor no expone `fn_hub_lease_acquire` con la firma esperada.
  Revisar la migración `20260914_0050_hub_leases.sql` y la caché de PostgREST.
  «Promoción» en ese log significa ascender otro equipo a Hub.
- MAC inválido: no se autenticaron blobs locales con la clave disponible.
  No demuestra por sí solo si hubo cambio de clave o corrupción. No se borraron
  colas, claves ni snapshots; su recuperación necesita diagnosticar el equipo.
- Bluetooth: respuesta duplicada del plugin; no participa en la validación de
  reglas que devolvió el error al retirar el producto.

## Vista previa de precuenta: MESA82

El payload enviaba el total de cada línea en `price`, pero el diálogo trataba
ese campo como precio unitario y volvía a multiplicarlo. Las líneas de RD$500
y RD$750 aparecían en RD$1,000 y RD$3,000 pese al total correcto de RD$1,250.

`buildPrecheckItemPayload` envía un `lineTotal` explícito, calculado con el
resumen canónico que incluye impuestos y descuentos, y reserva `price` para
el precio unitario. Se corrigieron tanto el recorrido normal como el offline.
La presentación separada por unidades reparte los centavos conservando el
importe completo. Los llamadores antiguos mantienen su contrato unitario.

La vista usa «Importe», cantidades sin decimales innecesarios y «Descuento
incluido» cuando el descuento es informativo. El encabezado no parte «CANT.»
y el total permanece visible al desplazar una cuenta sin abonos. El recorrido
de abonos mantiene el orden consumo/abono/diferencia. La precuenta impresa
también identifica el descuento informativo como incluido.

Validación de este ajuste: 47 pruebas aprobadas de precuenta, impuestos,
abonos e impresión; regresiones a 360, 390 y 800 píxeles, más revisión visual
de capturas locales. No requiere una migración adicional: se activa al
actualizar/recargar la aplicación.
