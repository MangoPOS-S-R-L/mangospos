# Corrección de ofertas, división por productos y reimpresión

14 de octubre de 2026. Caso reportado: Medio Tiempo Bar, precuenta de orden
33558839 y reimpresión NCF B0200088787, correspondientes a órdenes distintas.

## Cambios implementados

- Las líneas `[DEAL:]` usan el contrato de `fn_compute_item_totals` vigente en
  el repositorio desde 20260630_0001: base anterior al descuento y descuento
  separado, aplicado una vez. El alta optimista usa la misma base mientras
  guarda. El desglose de una oferta inclusive ya no suma su descuento al
  subtotal mientras calcula el total por una ruta distinta.
- La división conserva cada alta de oferta como paquete independiente. La
  migración excluye ofertas de `fn_explode_items_to_units` y de la
  consolidación versionada. Los productos normales siguen separándose y
  consolidándose. El cliente tampoco une dos ofertas iguales en una línea.
- El cliente usa `fn_explode_items_for_split`. Si aún no existe esta RPC,
  conserva las líneas completas mediante el flujo legacy de la pantalla;
  nunca recurre a la función antigua de un servidor que parta ofertas.
- Los totales de subcuenta usan el resumen canónico: incluye correctamente
  los impuestos de productos exclusive, además de precios inclusive.
- La reimpresión busca el documento exacto por ID (o número, negocio y orden
  para un listado legacy). Su `check_id`, importe, fecha, cliente y número
  prevalecen sobre el pago representativo o el saldo mutable de la subcuenta.
  Los pagos se limitan al documento y a su ámbito; no se toma el último NCF
  de la orden. La misma selección sirve a notas de venta.
- Los importes históricos se conservan incluso si la diferencia con el
  catálogo actual es menor a un peso. Los impuestos se presentan desde los
  snapshots de la venta si cuadran con el documento; en otro caso, desde sus
  montos oficiales. No se aplican las tasas actuales del negocio a un NCF viejo.
- Si faltan productos o se intenta reimprimir cero con un pago registrado positivo,
  se muestra un error y no se envía papel. No se inventan productos ni importes.

## Migración y orden de instalación

1. Ejecutar `supabase/tests/offer_split_receipts_local_test.sh` en un entorno
   con PostgreSQL 15 y las pruebas Flutter indicadas abajo.
2. Aplicar **20261014_0001_preserve_offer_packages_in_split.sql** en un clon
   reciente y después en el servidor que atiende el negocio.
3. La migración verifica el contrato de precios de `fn_compute_item_totals` y
   la forma del bloque de consolidación de `fn_apply_order_edit`. Si difieren,
   revierte toda la transacción con un error descriptivo: revisar la función
   viva antes de publicar. No sustituir funciones a ciegas ni ejecutar un
   backfill de documentos emitidos para conseguir que pase la comprobación.
4. Verificar las dos RPC de separación, permisos, movimientos y eliminación
   de paquetes en una cuenta de prueba. La migración notifica la recarga del
   esquema de PostgREST.
5. Publicar e instalar el build corregido en caja y equipos que dividan
   cuentas. El código fuente y una prueba local no acreditan instalación.

La migración es compatible con la RPC antigua, serializa la separación con
el candado de la orden y valida acceso al negocio. El cambio de consolidación
se limita a su filtro: conserva el resto de la función viva y sus auditorías.
No cambia filas, ventas, pagos, documentos ni inventario histórico.

Rollback: `20261014_0001_preserve_offer_packages_in_split_ROLLBACK.sql` revierte
las definiciones y retira la RPC nueva sin tocar datos. El cliente nuevo deja
las líneas completas si se retira esa RPC. No volver a publicar un cliente
que calcule ofertas con el contrato anterior.

## Regresiones permanentes

- `test/sales/offer_split_receipts_test.dart`: reproducción histórica de los
  importes de la precuenta, ofertas inclusive/exclusive, paquetes al abrir y
  unir subcuentas, ausencia de RPC segura, documento con check desactualizado
  en el listado, factura con detalle ausente, orden parcialmente o totalmente
  cobrada, diferencia histórica inferior a RD$1 y protección del generador.
- `test/sales/sales_mutation_navigation_integrity_test.dart`: comprueba también
  la base y el descuento de una oferta cuyo guardado sigue en vuelo.
- `supabase/tests/offer_split_receipts_local_test.sh`: funciones de precios y
  edición del repositorio en Postgres desechable; separación de productos
  normales, preservación de ofertas y bitácora de altas, movimiento, replay
  de eliminación, acceso por negocio y bloqueo de eliminación facturada.
  Ejecuta la migración dos veces y rollback/reinstalación, comprobando que
  se conservan los datos. Esquema, negocio y datos son sintéticos; no valida
  inventario ni conectividad de producción.
- `test/fixtures/offer_split_receipts_legacy.json`: snapshots sintéticos de la
  reproducción SQL anterior al arreglo, para no depender de datos privados
  ni de una base remota al ejecutar las pruebas Flutter.

## Límites operativos

Las cuentas ya fraccionadas por una versión anterior no se reagrupan por
nombre: se perdería la distinción entre unidades asignadas legítimamente y
paquetes completos. Requieren revisión de cantidades, descuentos y subcuentas
antes de corregirlas. Tampoco se reconstruye una factura cuyo detalle se haya
perdido: se detiene la reimpresión y se solicita recargar/revisar el documento.

No se alteraron los registros reales de los dos comprobantes enviados. Para
concluir si hubo un cobro incorrecto o pérdida de productos hace falta
contrastarlos con sus filas SQL y los equipos implicados. Este cambio de código
no constituye despliegue ni recuperación automática de documentos históricos.

## Validación ejecutada

- Suite completa Flutter: **2,706 pruebas aprobadas, una omitida**.
- PostgreSQL local: migración, reinstalación, acceso, replay de eliminación y
  rollback aprobados; sin cambios en las filas por las operaciones de DDL.
- Pruebas finales de impresión y facturas: **393 aprobadas**.
- Análisis estático de los archivos modificados: sin incidencias.
- `git diff --check`: aprobado.

Los tests de guardado optimista, reimpresión y cálculo se ejecutaron también
por separado. La migración está preparada y probada localmente; **no se aplicó
al servidor de producción ni se publicó un build en este trabajo**.

## Ampliación: MESA79, reducción de dos ofertas 4×3 (15 de octubre)

Las capturas del 14 de octubre, 23:50, muestran 8 cervezas de RD$250 con
RD$500 de descuento y total RD$1,500. Tras quitar cuatro, la cuenta conserva
solo RD$125 de descuento y cobra RD$875: son RD$125 de más. Debe conservar
una oferta de RD$750, con RD$250 de descuento.

Se identificó el recorrido del cliente que produce esos importes: el modal
agrupado tomaba el descuento de la primera fila y el guardado volvía a
repartirlo sobre todas las filas originales, incluidas las que eliminaba.
Además, «Eliminar unidades» prorrateaba el descuento de una oferta y la cola
que cambia cantidades no recalculaba sus paquetes.

La corrección adicional:

- El modal parte del descuento de todas las filas. Cada oferta conserva su
  propio descuento; no se reparte a filas que desaparecen.
- La regla vendida queda en un snapshot interno `[DEAL_RULE:unidades:descuento]`,
  oculto en pantalla, notas y tickets. Cada fila conserva su identidad y regla
  al editar notas de un grupo. Con snapshot, cambios posteriores de la
  promoción no reinterpretan la venta.
- Las cantidades de ofertas se recalculan por paquetes completos. Ocho
  cervezas: descuento RD$500, total RD$1,500. Siete: descuento RD$250, total
  RD$1,500. Cuatro: descuento RD$250, total RD$750. Tres: sin oferta, RD$750.
- Guardado optimista, snapshot local, cola, rollback por rechazo y proyección
  del Hub conservan el descuento correspondiente a la cantidad.
- El backend aplica la regla antes del trigger de precios al cambiar unidades,
  incluyendo ediciones versionadas y operaciones provenientes de la cola.
  Conserva la regla original aunque un modal antiguo omita ese snapshot.
- Las cortesías explícitas conservan su recorrido. No se modificaron las
  fórmulas de impuestos ni se reescribieron documentos emitidos.

Aplicar **20261014_0002_offer_quantity_discount.sql** después de la migración
0001 de esta guía, primero en un clon y después en el servidor. Verificar que
el trigger de precios se ejecuta después del nuevo trigger (la migración lo
comprueba). Instalar el build que incluye las correcciones del modal,
recálculo de cantidades y proyección del Hub en todos los equipos.

Rollback adicional: **20261014_0002_offer_quantity_discount_ROLLBACK.sql**.
Retira el trigger sin borrar ventas ni snapshots. Las dos migraciones se
instalan dos veces y se prueban con rollback/reinstalación y hashes de filas.

Compatibilidad: una oferta antigua sin snapshot necesita la promoción
registrada y una cantidad compuesta de paquetes completos para inicializar la
regla con el descuento de esa venta. No hay backfill ni inferencia por nombre.
Si ya está fraccionada o falta su promoción, el servidor rechaza la reducción
que no puede resolver. Si está offline sin snapshot, el cliente conserva la
cantidad y pide conexión con el servidor. Las cuentas ya incorrectas, como la
de RD$875, necesitan revisión de sus filas y subcuentas antes de corregirlas;
este cambio no supone que fueron reparadas en producción.

Validación adicional: `test/sales/offer_quantity_discount_test.dart`, las
regresiones de navegación/mutaciones, ofertas/división/reimpresión, modal,
fidelidad y proyección del Hub; **92 pruebas Flutter aprobadas**. SQL local
aprobado con precios reales del repositorio, API versionada, replay, cambio de
promoción después de vender, 8→7→4→3→8, legacy consolidado, rechazo de legacy
incierto, cortesías y rollback. Análisis sin errores nuevos; pantalla y tests
existentes conservan avisos previos de lint. `git diff --check` aprobado.

**Esta ampliación tampoco se aplicó a producción ni se publicó un build.**

### Confirmación de la regla comercial de paquetes completos

El descuento de la oferta que se rompe se retira COMPLETO. Las botellas que
quedan de ese paquete se siguen cobrando individualmente; no se conserva un
porcentaje ni una fracción del beneficio. Con cervezas de RD$250 y 4×3:

| Botellas restantes | Ofertas completas | Unidades fuera de oferta | Descuento | Total |
| ---: | ---: | ---: | ---: | ---: |
| 8 | 2 | 0 | RD$500 | RD$1,500 |
| 7 | 1 | 3 | RD$250 | RD$1,500 |
| 6 | 1 | 2 | RD$250 | RD$1,250 |
| 5 | 1 | 1 | RD$250 | RD$1,000 |
| 4 | 1 | 0 | RD$250 | RD$750 |
| 3 | 0 | 3 | RD$0 | RD$750 |

Se amplió la reproducción al caso explícito 8→6: una fila de 8 y dos filas de
4 agrupadas en pantalla, retiro de unidades, modal, Hub, respaldo offline,
rechazo y traslado a subcuenta. SQL comprueba que la fila que pasa de 4 a 2
pierde sus RD$250 de descuento completos; la otra mantiene RD$250. Se agregó
el trigger real de totales al ensayo SQL para comprobar el traslado de check.

Esta ampliación detectó y corrigió un centavo de redondeo en la proyección del
Hub: en precios inclusive, el total se ancla al precio y modificadores de la
venta, igual que el resumen de la app. Antes, 8→6 podía producir RD$1,250.01
sumando componentes redondeados; ahora produce RD$1,250.00.

Última ejecución: **80 pruebas Flutter aprobadas** del conjunto de ofertas,
mutaciones, Hub y caché del Hub; ensayo SQL y rollback aprobados; análisis
estático del proyector y test sin incidencias. Incluye límites de paquete para
2×1, 3×2 y 4×2. No se publicó ni instaló en producción.
