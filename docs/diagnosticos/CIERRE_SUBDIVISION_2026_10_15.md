# Cierre de correcciones de subdivisión

15 de octubre de 2026. Las siete incidencias de la revisión están corregidas
en el código y cubiertas por pruebas locales. No se aplicó SQL ni se publicaron
clientes en producción desde esta tarea.

## Cambios realizados

| Incidencia | Corrección |
| --- | --- |
| La división igualitaria reutilizaba cuentas cobradas o facturadas. | El servidor excluye posiciones protegidas y rechaza cambios de productos pagados, anulados o pertenecientes a una cuenta protegida, incluso al resolver un conflicto con fuerza. |
| Se perdía importe al repartir productos con extras. | Cada fragmento conserva la receta por unidad, identificadores de modificadores, perfil fiscal y desglose de impuestos de la venta. Se verifica que el importe ordinario permanezca igual. |
| La RPC igualitaria no validaba pertenencia al negocio. | Ambas entradas validan acceso al negocio y toman el candado de la orden que usan los cobros. Se retira acceso anónimo. |
| La división manual podía quedar guardada a medias. | Una RPC confirma asignaciones, altas/bajas de cuentas y datos fiscales en una sola transacción. Un conflicto posterior revierte también lo anterior. |
| Unir cuentas nuevas descartaba identificadores de productos iguales. | Se conservan todas las filas físicas hasta confirmar. Se retiró la consolidación que escribía al cerrar el modal. |
| Recalcular perdía cliente, RNC y tipo de comprobante; el de una cuenta nueva no se guardaba. | El recálculo usa `copyWith`; los cambios fiscales forman parte de la confirmación completa. Una base fiscal desactualizada genera conflicto. |
| Mover rondas de una oferta dejaba un descuento desactualizado en pantalla. | Se recalculan las ofertas por cuenta tanto en el borrador como en el servidor. Las versiones enviadas corresponden a las filas originales, anteriores al cálculo visual. |

El caso de dos unidades de RD$250 con un extra de RD$50 por unidad conserva
RD$600 después de repartirlo. También se corrigió el redondeo de componentes
en medio centavo: dos partes de RD$300 no pasan a RD$600.02 en pantalla.

Con cerveza de RD$250 y oferta 4×3, las rondas de tres y una juntas suman
RD$750. Separarlas entre cuentas retira el beneficio: RD$750 + RD$250.
Reunirlas recupera una oferta completa. No se aplica un porcentaje por botella.

## Confirmación y reintentos

Los cambios manuales de productos, cliente, RNC y comprobante se guardan al
pulsar **Aplicar división**. La división igualitaria confirma desde su botón
**Aplicar**. La separación inicial de productos ordinarios en unidades sigue
siendo una operación al abrir el modal. Los productos ordinarios, incluidos
los que tienen extras, se preparan como unidades independientes. Los paquetes
de oferta conservan sus filas.

### Corrección adicional: productos ordinarios agrupados

El recorrido anterior continuaba si fallaba la RPC que separaba las unidades;
además, esa función excluía productos con modificadores. Por eso una fila de
tres productos podía trasladarse completa cuando se pretendía mover uno.

`20261015_0004_split_ordinary_items_to_units.sql` prepara cada producto
ordinario entero como una fila de cantidad uno, también cuando tiene extras.
Conserva el ID original en la primera unidad y copia extras por unidad,
identificadores de inventario, precio, descuento, impuestos históricos, autor,
notas, ruta de impresión y estado/tiempos de cocina. Los productos ya enviados
conservan ese estado. El descuento y el desglose fiscal se distribuyen con
redondeo acumulado para conservar los residuos sin importes negativos.

La preparación es transaccional e idempotente: un fallo al crear otra unidad
revierte también la primera y un reintento no genera productos adicionales.
Las cuentas cobradas/facturadas y los paquetes de oferta quedan protegidos.

Si falla la preparación o la lectura todavía devuelve un grupo ordinario
entero, el modal muestra **Reintentar preparación** y bloquea el reparto.
Ese segundo control también cubre una ronda agrupada añadida por otro equipo
entre preparar y leer. No se confirma una división sobre ese grupo en silencio.

Caso comprobado: tres jugos de RD$250 se muestran en tres filas; se mueve uno
a C2, otro a C3 y el tercero queda en la principal. El total sigue en RD$750.
Una oferta 4×3 de RD$750 que esté en esa misma orden mantiene su paquete.

La intención completa tiene un identificador estable. Si se pierde la respuesta,
el modal conserva ese identificador y el contenido para reintentar, bloqueando
nuevas ediciones mientras se resuelve la confirmación. El servidor devuelve el
resultado ya registrado y no vuelve a dividir. Reutilizar la misma llave con
otro contenido se rechaza. Esta retención del borrador es durante la sesión
del modal; no se añadió una cola offline de subdivisión.

La bitácora `bill_split_ops` solo registra transacciones aplicadas. No hay
fallback a varias escrituras si falta `fn_apply_bill_split`: el cliente avisa
que debe aplicarse la migración. Un conflicto requiere revisar o resolver
explícitamente; no se fuerza automáticamente.

## Instalación

1. Probar en un clon reciente del servidor, con las migraciones previas del
   proyecto ya aplicadas. Este cierre depende de las siguientes, en orden:
   - `20261014_0001_preserve_offer_packages_in_split.sql`.
   - `20261014_0002_offer_quantity_discount.sql`.
   - `20261015_0001_atomic_item_groups.sql`.
   - `20261015_0002_legacy_offer_group_rules.sql`.
   - `20261015_0003_atomic_bill_splits.sql`.
   - **`20261015_0004_split_ordinary_items_to_units.sql`**.
2. Aplicar las migraciones pendientes al servidor antes de instalar el cliente nuevo.
   No modifica ventas históricas ni ejecuta un backfill.
3. Actualizar los clientes y el Hub correspondientes en todos los equipos.
   Los clientes anteriores reciben la protección de la RPC igualitaria,
   pero sus recorridos manuales necesitan la actualización de la app.
4. Confirmar en el entorno de aceptación: división manual a dos destinos,
   unión, retiro de una subcuenta, cliente/RNC/comprobante nuevo, oferta 3+1,
   cobro de una subcuenta y posterior reparto de los productos restantes.
   Incluir tres productos ordinarios agregados/enviados juntos, con y sin extras,
   y comprobar que cada selección mueve solo uno.

La reversa de la preparación es
`20261015_0004_split_ordinary_items_to_units_ROLLBACK.sql`: restaura las dos
funciones anteriores de preparación y conserva su respaldo. Revertirla antes de
`20261015_0003_atomic_bill_splits_ROLLBACK.sql`, y este antes de sus
dependencias. Restaura las definiciones de la RPC igualitaria y del autocierre
capturadas al instalar, así como el recálculo de ofertas, y retira la entrada
nueva y sus auxiliares. Conserva la
bitácora y los respaldos para permitir reinstalar sin repetir operaciones.
Restaurar esas definiciones también retira sus protecciones nuevas: coordinar
la reversa con la versión de los clientes.

## Validación ejecutada

- Suite completa Flutter: **2,797 pruebas correctas, una omitida, cero fallidas**.
- Dieciséis pruebas de integridad del modal/repositorio: identificadores,
  metadatos, ofertas, rechazo total, reintentos estables, concurrencia de
  llamadas del modal y ausencia de fallback a escrituras individuales. Incluyen
  una prueba del widget real que muestra tres jugos y mueve solo uno al tocarlo.
- Ensayo PostgreSQL desechable: **104 aserciones correctas** entre ofertas,
  grupos, compatibilidad y subdivisión. Usa los cálculos de precios y los
  triggers reales de autocierre y protección de destinos del repositorio.
- SQL cubre extras e impuestos inclusivos/exclusivos, snapshot fiscal,
  cuentas cobradas, acceso de otro negocio, replay, conflicto después del
  primer traslado, intercambio de cuentas, rechazo de borrado con productos,
  cliente fiscal concurrente y ofertas 3+1.
- Instalar dos veces, revertir y reinstalar conserva los datos comprobados
  por hash de todas las filas de productos del ensayo.
- Analizador Dart: sin errores ni advertencias. El modal mantiene doce
  observaciones informativas preexistentes de estilo/API y contexto asíncrono.

Las pruebas locales no confirman que un servidor o equipo del negocio ya tenga
estos cambios instalados. Ese estado debe verificarse durante la instalación.
