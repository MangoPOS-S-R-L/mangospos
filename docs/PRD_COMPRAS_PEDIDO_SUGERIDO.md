# PRD — Compras: pedido sugerido, mínimos en lote, comparador de precios y caja dentro de caja

**Estado:** D1–D9 CONFIRMADAS por el dueño (2026-09-15). **F0–F4 y F5a implementadas**; migraciones 0003–0007 **APLICADAS en prod el 2026-09-15** (0003–0006 verificadas); 0008 (F4) APLICADA y verificada el mismo día (Penda: 677 pares insumo × suplidor, 79 insumos con 2+ suplidores, 19 donde el suplidor del pedido está ≥ 5% sobre el más barato; 0 vínculos hasta la próxima recepción); sin commit y sin desplegar la app; F5a en código (0009 sin aplicar); F5b pendiente. Diagnóstico de prod corrido
(2026-09-15, `supabase/DIAGNOSTICO_compras.sql`).
**Fecha:** 2026-09-15. **Cliente que lo pidió:** La Penda Express (requerimiento formal del 31-08, puntos
«mínimos de compra ajustables», «pedido por suplidor con filtro», «proyección del sistema»), más el
modelo de presentaciones de Toast (caja dentro de caja).

Continúa la F3 de `PRD_ALMACENES_REQUISICION_COMPRAS.md`.

---

## 1. Qué se pidió

| # | Necesidad | En una frase |
|---|---|---|
| 1 | Mínimos en lote | Ajustar el mínimo de cientos de insumos de una vez, filtrando, con un mínimo sugerido por el consumo real |
| 2 | Orden de compra por suplidor de un golpe | Del pedido sugerido salen las órdenes en borrador, una por suplidor, en una sola acción |
| 3 | Proyección con tiempo de entrega | Cuánto pedir según lo que se consume, lo que tarda el suplidor, lo que ya viene en camino y lo ya pedido |
| 4 | Comparador de precios | Para cada insumo, qué cobra cada suplidor: último precio, promedio, tendencia, en costo por unidad base |
| 5 | Caja dentro de caja | Presentaciones de dos niveles: «Caja de 24 Latas de 355 mL» |

---

## 2. Lo que ya existe (no se reconstruye)

- **Reorden** (`v_inventory_reorder_suggestions`, `inventory_reorder_view.dart`): agrupa por suplidor y crea una
  orden por grupo. Base del «pedido sugerido».
- **Rotación** (`fn_inventory_rotation_analysis`): consumo por día y días de cobertura. Materia prima de la
  proyección.
- **Mínimo por almacén** (`inventory_stock.min_stock`, `fn_inventory_set_warehouse_min_stock`), uno a uno.
- **Proveedores**: `lead_time_days`, `min_order_amount` y `supplier_items` (código, unidad y empaque de compra,
  precio de lista, mínimo de compra), APLICADOS en prod. `preferred_supplier_id` está en el repo
  (20260813_0001) pero **NO en prod** (B8).
- **Precio real de cada compra**: la recepción clásica escribe el movimiento `purchase` con
  `reference_type = 'purchase_order'` y `reference_id` = id de la ORDEN (no del renglón), así que el suplidor
  sale directo de `purchase_orders.supplier_id`.
- **Órdenes y recepción con conduce** (`fn_receive_purchase_order_v2`): el stock y el costo entran AL RECIBIR,
  con el costo real (`purchase_reception_lines.actual_unit_cost`).
- **Documento de la orden**: PDF, impresión y compartir (`goods_receipt_pdf.dart`).
- **Catálogo de unidades y equivalencias** (`unit_catalog.dart`, `unit_conversion.dart`): conversión entre
  clases, contenido automático, «24 ea / Caja».

---

## 3. Defectos encontrados al mapear (van primero, en F0)

| # | Defecto | Efecto |
|---|---|---|
| B1 | «Crear OC» del reorden inserta `status = 'pending'`, que no existe en el enum `purchase_status` | **CONFIRMADO en prod**: el enum es draft/sent/partial/received/cancelled y NUNCA se creó una orden `REORD-` |
| B2 | Las órdenes del reorden no guardan unidad ni empaque de compra (quedan con `pack_size = 1`) | Se muestran y reciben en unidad base: «8520 mL» en vez de «1 Caja» |
| B3 | El reorden elige el suplidor de la ÚLTIMA orden (incluye borradores y canceladas) e ignora `preferred_supplier_id` | Se pide al suplidor equivocado |
| B4 | `supplier_items.last_price` no tiene unidad definida y a veces se guarda el costo por unidad base junto a «Caja»; `pack_size` y `min_order_qty` nunca se escriben; desvincular BORRA la fila | El precio de lista no es comparable ni sirve para la orden |
| B5 | Crear orden no es atómico (cabecera y líneas por separado) y el número se calcula leyendo el último + 1 | Cabeceras huérfanas y números repetidos con dos cajeros |
| B6 | La rotación cuenta como consumo TODO movimiento negativo, incluidas transferencias (pasan por `__IN_TRANSIT__`) | La proyección pediría de más en negocios con varios almacenes |
| B7 | Reorden y stock bajo solo miran el mínimo GLOBAL, nunca el del almacén; la fecha esperada es «hoy + 3» fija | No sirve para almacenes por área |
| B8 | `inventory_items.preferred_supplier_id` **no existe en prod**: la migración 20260813_0001 nunca se aplicó | No hay «suplidor preferido» que respetar hasta aplicarla (F0) |
| B9 | Un `stock_adjustment` de **+16,571,950,421** en Penda (CARIBAS PLATANITOS AJO: código de barras escrito en la cantidad) | Ese insumo nunca saldría en el pedido; y la rotación lo cuenta como entrada. Corregir el dato antes (pendiente #3 de Penda) |

---

## 4. Cómo se calcula (propuesta)

Todo en **unidad base** dentro de la base; la presentación se aplica solo al mostrar y al redondear.

```
consumo_diario   = (ventas + producción + mermas) de los últimos N días ÷ N        [D1]
                   — sin transferencias, sin ajustes de conteo
en_tránsito      = transferencias enviadas y no recibidas hacia el almacén
en_orden         = pendiente de recibir de órdenes enviadas / parciales (no borradores)
días_objetivo    = tiempo_de_entrega_del_suplidor + días_de_cobertura (parámetro de pantalla)
objetivo         = consumo_diario × días_objetivo + mínimo (colchón de seguridad)    [D2]
sugerido_base    = max(0, objetivo − existencia − en_tránsito − en_orden)
sugerido_compra  = redondeo HACIA ARRIBA a empaques del suplidor, respetando su mínimo de compra   [D7]
mínimo_sugerido  = consumo_diario × (tiempo_de_entrega + días_de_colchón)
```

**Suplidor de cada insumo** [D3]: `preferred_supplier_id` (requiere aplicar 20260813_0001, ver B8) → el único vínculo
activo en `supplier_items` → el de la última orden RECIBIDA. **Tiempo de entrega** [D9]: el del suplidor → el
por defecto que se escribe en la pantalla (se puede corregir por suplidor desde ahí mismo). **Precio** para la orden: precio de lista del vínculo (por empaque) → último costo real
recibido de ese suplidor → costo del insumo.

**Lo que mostró Penda en prod (60 días, 2026-09-15):**

| Tipo | Referencia | Movimientos | ¿Cuenta como consumo? |
|---|---|---:|---|
| sale | order | 20,096 | Sí |
| purchase | purchase_order | 1,054 | No (entrada; es la fuente de precios) |
| purchase | direct_receipt | 224 | No (entrada; fuente de precios) |
| adjustment | stock_adjustment | 108 | No (incluye el error de CARIBAS, B9) |
| purchase | initial_stock | 73 | No |
| waste | manual_outflow | 44 | Sí |
| adjustment | item_merge | 42 | No |
| adjustment | direct_receipt_cancel | 11 | No |
| transfer_in / transfer_out | stock_transfer | 8 / 8 | No |

No hay movimientos de producción todavía. Penda registra las compras **ya recibidas**: 287 órdenes, todas en
`received`, y **0 recepciones con conduce**. Por eso, para Penda, «ya pedido» será casi siempre 0 y los precios
reales salen de los movimientos de compra, no de `purchase_reception_lines`.

**Maestro de suplidores de Penda (bloque 4):** 92 suplidores activos y 2,308 insumos activos, pero **0** con
tiempo de entrega, **0** con pedido mínimo, **0** con WhatsApp, **0** vínculos insumo–suplidor, **0** precios de
lista y sin columna de suplidor preferido. **El pedido sugerido tiene que funcionar con el maestro VACÍO:**
el suplidor sale del historial de compras, el tiempo de entrega usa un valor por defecto [D9] y los vínculos
se siembran desde las compras reales [D8].

---

## 5. Fases

Cada fase se entrega sola, degrada si la migración no está aplicada (42703/PGRST204) y no toca a los negocios
sin inventario (`inventory_mode = 'none'` o sin insumos).

### F0 — Arreglos (B1–B5), sin pantallas nuevas — ✅ IMPLEMENTADA 2026-09-15 (sin aplicar, sin commit)

**Entregado:**
- Migración `20260915_0003_compras_f0_orden_atomica_y_suplidor.sql` (+ROLLBACK): `fn_purchase_order_create`
  (atómica, `PO-00000` bajo candado, idempotente, solo draft/sent, SECURITY INVOKER),
  `fn_purchase_resolve_suppliers` (preferido → único vínculo → última compra recibida por las 3 puertas),
  columnas aseguradas (incluye `preferred_supplier_id` = B8) y `last_price` documentado por unidad de compra.
- `supabase/SEMBRAR_vinculos_suplidor.sql` (+ROLLBACK) para D8 — herramienta lista; se CORRE con la parte
  del negocio, no con el sistema.
- App: registro de compra y Reorden usan la función atómica (con vuelta al camino viejo si no está aplicada);
  Reorden usa el resolver, redondea a cajas (D7), crea en borrador con foto del empaque y fecha según tiempo de
  entrega (D9); desvincular = desactivar; «declarar» guarda el precio por caja; el diálogo de vínculo pide
  contenido y mínimo de compra.
- Pruebas: `supabase/tests/compras_f0_local_test.sh` (orden, resolver, siembra, rollbacks y el VERIFICAR, todo
  en verde), `test/core/purchase_quantity_test.dart` (12). `flutter analyze` limpio; 672 pruebas de core,
  inventario y compras en verde.
- Verificación en prod después de aplicar: `supabase/VERIFICAR_20260915_0003_compras.sql`.

**Plan original:**
- Reorden: `status = 'draft'`, líneas con unidad y empaque de compra redondeadas al empaque, suplidor
  preferido primero, fecha esperada = hoy + `lead_time_days`.
- `supplier_items`: `last_price` = **precio por unidad de compra** (documentado en la columna); el formulario de
  vínculo escribe `pack_size` y `min_order_qty`; desvincular = `is_active = false`.
- Aplicar `20260813_0001` (suplidor preferido) tras cotejarla contra la base viva (B8).
- **Sembrar `supplier_items` desde el historial** [D8]: un vínculo por insumo × suplidor con compras recibidas,
  con el último precio por empaque y el empaque del insumo. Por negocio, idempotente (no pisa vínculos
  existentes), con respaldo y ROLLBACK. En Penda sale de las 287 órdenes y las recepciones directas con suplidor.
- RPC `fn_purchase_order_create` atómica con numeración bajo advisory lock (mismo patrón que el conduce
  `RM-00001`); el registro de compra y el reorden la usan.

### F1 — Motor de proyección (SQL, solo lectura) — ✅ IMPLEMENTADA 2026-09-15 (sin aplicar, sin commit)
- Migración `20260915_0004_compras_f1_proyeccion.sql` (+ `_ROLLBACK`), exige la 0003 (se aborta sin ella).
- `fn_purchase_projection(p_business_id, p_warehouse_id, p_coverage_days = 7, p_days_back = 30,
  p_default_lead_time_days = 2, p_safety_days = 3, p_supplier_id, p_only_needed)`, `stable`, SECURITY INVOKER:
  una fila por insumo activo (sin `service` ni `combo`) con existencia, en tránsito, ya pedido, consumo,
  días de ventana, consumo diario, mínimo y su origen (`almacen` / `insumo`), tiempo de entrega y si es el de
  por defecto, objetivo, sugerido en base, días que cubre, mínimo sugerido, suplidor / presentación / costo de
  `fn_purchase_resolve_suppliers` y costo estimado. Ordena por costo estimado.
- **Consumo NETO**: `sale` (las devoluciones de venta restan) + `waste` + `production_out`. Sin transferencias,
  ajustes ni compras (B6).
- **Ventana real**: se divide entre los días de historia del insumo, hasta `p_days_back` (un insumo de 10 días no
  sale a un tercio de su consumo).
- **Por almacén** (D5): existencia, consumo, tránsito y órdenes de ese almacén, y el mínimo del almacén si lo
  tiene. Sin almacén: todo el negocio, sin `__IN_TRANSIT__` ni almacenes inactivos.
- **En tránsito** = transferencias `sent` hacia un almacén que cuenta. Entre negocios la línea todavía no tiene
  `target_item_id` (se llena al recibir): se casa como `fn_inventory_resolve_item_for_business`, por SKU y luego
  por nombre. Límite: con RLS el usuario tiene que poder ver el insumo del negocio que envía.
- **Ya pedido** = pendiente de órdenes `sent` / `partial`; los borradores no cuentan.
- **Existencia negativa = 0** (`20260915_0006_compras_existencia_negativa.sql`, misma firma): un negativo es consumo sin
  su entrada registrada; restarlo tal cual hacía pedir de más. La columna `stock` lo devuelve crudo y la pantalla
  avisa «Existencia negativa: revisa conteo o compras». Prueba P9 y rollback en `compras_f1_local_test.sh`.
- **Verificación en prod (2026-09-15, `VERIFICAR_compras_F0_F2.sql`)**: todo OK. Penda, Almacén Principal, 7 días:
  2,305 insumos evaluados, 212 con pedido (144 de esos sin suplidor, los 212 con entrega por defecto), costo
  estimado RD$141,882, **856 ms** (límite de `authenticated` = 8 s). Suplidor: 1,733 sin suplidor, 575 por última
  compra. Costo: 1,449 del insumo, 569 de última compra, 290 sin costo. **126 insumos con existencia negativa** → 0006.
  Detalle para el negocio: `supabase/DIAGNOSTICO_pedido_sugerido_penda.sql`.
- El redondeo a empaques y al mínimo de compra [D7] NO va en SQL: lo hace la app con
  `lib/core/inventory/purchase_quantity.dart` (`roundUpToPurchase`), para que al editar se recalcule sin ir a la base.
- Prueba: `supabase/tests/compras_f1_local_test.sh` (P0–P8, guardia, idempotencia, VERIFICAR, ROLLBACK) en verde.
  Verificación en prod: `supabase/VERIFICAR_20260915_0004_proyeccion.sql` (Penda, Almacén Principal).

### F2 — Pantalla «Pedido sugerido» (reemplaza a Reorden) — ✅ IMPLEMENTADA 2026-09-15 (sin aplicar, sin commit)
- Migración `20260915_0005_compras_f2_ordenes_en_lote.sql` (+ `_ROLLBACK`), exige la 0003.
  `fn_purchase_orders_create_batch(business, warehouse, orders jsonb, status = 'draft', idempotency_key)`:
  cada orden pasa por `fn_purchase_order_create` (mismas validaciones, PO-00000 seguidos), **todo o nada**,
  un suplidor por orden sin repetir, llave `llave:suplidor`, y el error dice qué suplidor falló.
  Prueba `supabase/tests/compras_f2_local_test.sh` (L1–L9, guardia, rollback) en verde.
  Verificación: `supabase/VERIFICAR_20260915_0005_lote.sql`.
- Lógica pura `lib/core/inventory/suggested_order.dart` (13 pruebas): `ProjectionLine`, `LineEdit`,
  `resolveOrderLine` (empaques con `roundUpToPurchase`, costo por unidad de compra → base),
  `buildSupplierOrders` (agrupa por suplidor efectivo; «sin suplidor» al final y no se crea),
  `missingForMinimum`, tiempo de entrega (suplidor → proyección → por defecto), `supplierOrderMessage`
  (sin costos) y `whatsappOrderLink` (10 dígitos → prefijo 1).
- Repositorio `lib/data/repositories/purchase_projection_repository.dart`: proyección **paginada de 1,000 en
  1,000** (PostgREST corta ahí; Penda tiene 2,308 insumos, por eso la función ordena también por `item_id`),
  suplidores con `select *` (términos opcionales) y el lote. Ambas RPC degradan con tri-estado.
- Pantalla `lib/presentation/inventory/view/purchase_suggested_order_view.dart`, en la misma ruta
  `/inventory/reorder` (mismo permiso). Filtros: almacén, cobertura (3/7/15/30 días), «solo lo que falta»
  (por defecto), clasificación, suplidor, búsqueda. Por suplidor: entrega, líneas por pedir, total y aviso de
  pedido mínimo. Por línea: existencia, en camino, ya pedido, consumo/día (con los días de historia), días que
  alcanza, mínimo, sugerido; cantidad **en empaques** con su equivalente en base y lo que sobra, costo por
  unidad de compra con su origen, cambiar de suplidor (buscador). «Crear en borrador» confirma, crea todo en
  un lote con llave derivada del contenido (doble toque o reintento no duplica) y muestra las órdenes con
  «Ver orden» y «Mandar por WhatsApp» (si no abre o no hay número, copia el pedido).
- Degradación: sin 0004 muestra la vista vieja de Reorden; sin 0005 crea orden por orden con la misma llave.
- Pendiente de F2: el comparador de precios al lado del cambio de suplidor va en F4; imprimir el pedido sale
  del detalle de la orden. La pantalla no se ha probado a mano contra datos reales.

### F3 — Mínimos en lote — ✅ IMPLEMENTADA 2026-09-15 (sin aplicar, sin commit)
- Migración `20260915_0007_compras_f3_minimos_en_lote.sql` (+ `_ROLLBACK`). Aborta si faltan
  `user_has_business_permission(uuid, text)`, `user_business_role(uuid, uuid)` o `inventory_stock.min_stock`.
- `fn_inventory_set_min_stock_bulk(negocio, almacén, cambios jsonb)`, SECURITY DEFINER (porque `inventory_stock` no
  tiene policy de escritura), `lock_timeout` propio de 5 s, EXECUTE quitado a public/anon:
  - sin almacén → `inventory_items.min_stock` (quitar = 0); con almacén → `inventory_stock.min_stock` (quitar = null,
    rige el general; crea la fila con existencia 0 si hace falta; quitar lo que no existe no crea nada; la existencia
    nunca se toca);
  - permiso: propietario/administrador/gerente o `inventario.productos.crear_editar` (el mismo del RLS de insumos);
  - todo o nada; valida uuid, número ≥ 0 o null, insumo repetido (por uuid, no por texto), insumo y almacén del
    negocio, sin `__IN_TRANSIT__`; devuelve `{updated, unchanged, scope}` y no reescribe lo que ya tenía ese valor.
  - Prueba `supabase/tests/compras_f3_local_test.sh` (general, almacén, permisos, V1–V9, EXECUTE, rollback) en verde.
    Verificación: `supabase/VERIFICAR_20260915_0007_minimos.sql`.
- Lógica pura `lib/core/inventory/min_stock_bulk.dart` (12 pruebas): rotación igual a NTILE(10) de
  `fn_inventory_rotation_analysis` pero con el consumo limpio de la proyección, `roundMinStock` (entero si se cuenta,
  centésimas si se pesa), acciones en lote, `realMinStockChanges` (solo lo que cambia) y Excel de ida y vuelta
  (exporta con «Mínimo nuevo» vacío; importa por ID y si no por SKU único, «quitar» borra, coma decimal, errores por
  fila).
- Repositorio `lib/data/repositories/min_stock_bulk_repository.dart`: límites generales y mínimos propios paginados de
  1,000 en 1,000.
- Pantalla `lib/presentation/inventory/view/min_stock_bulk_view.dart`, ruta `/inventory/min-stock` (permiso de ruta
  `inventario.acceso`; guardar exige `inventario.productos.crear_editar` en la sesión y lo vuelve a validar la base),
  tarjeta «Mínimos en lote» en el hub. Alcance: mínimo general o propio de un almacén; colchón 2/3/5/7 días;
  filtros por clasificación, suplidor, rotación, «solo lo que cambia» y búsqueda. Por fila: rotación, existencia,
  consumo, suplidor, entrega, actual (general/propio/rige el general), sugerido con «usar», máximo y «Nuevo» con aviso
  «sobre el máximo». Nada se guarda hasta «Guardar N» (confirma; si cambias de almacén con cambios pendientes,
  pregunta). Importar carga los cambios SIN guardar y muestra los errores por fila.
- No se ha probado a mano contra datos reales.

### F4 — Comparador de precios — ✅ IMPLEMENTADA 2026-09-15 (0008 APLICADA, sin commit)
- Vista/RPC por insumo × suplidor desde el **costo real recibido**, nunca borradores. Fuentes, en este orden:
  movimientos `purchase` de órdenes (`reference_type = 'purchase_order'`, suplidor de la orden), de recepciones
  directas (`'direct_receipt'`, suplidor opcional de la cabecera) y de recepciones con conduce
  (`'purchase_reception_line'`). Penda hoy solo tiene las dos primeras. Cada precio: último precio, fecha, promedio ponderado de N días, mín/máx,
  cantidad de compras, tendencia (último vs. anterior distinto), precio de lista declarado; todo normalizado a
  costo por unidad base y mostrado también por empaque.
- Pantalla por insumo y panel dentro del pedido sugerido («este suplidor está 12% más caro»).
- Al recibir: actualizar `supplier_items.last_price` por empaque y crear el vínculo si no existía [D4].


**Entregado:**
- Migración `20260915_0008_compras_f4_precios.sql` (+ `_ROLLBACK`), exige la 0003:
  - `supplier_items.last_price_at` / `last_price_source` ('manual' | 'recepcion') y un trigger BEFORE que sella los
    cambios a mano (la app no cambia).
  - **D4, el precio se aprende al recibir**: trigger AFTER INSERT en `inventory_movements` con `WHEN movement_type =
    'purchase'` y las tres puertas (las ventas no pagan nada). `last_price` = costo real × contenido (presentación del
    vínculo si trae unidad y contenido; si no, la del insumo), crea el vínculo si no existe, nunca pisa un precio más
    nuevo, no reactiva vínculos desactivados, ignora documentos ya anulados, y si falla avisa (WARNING) sin bloquear
    la recepción.
  - **Anular vuelve a aprender**: al pasar a `cancelled` una recepción directa, un conduce o una orden, el precio de
    esos insumos (solo los aprendidos de recepción, nunca los manuales) vuelve a la última compra válida o se vacía.
  - `fn_purchase_price_comparison(negocio, insumos, días = 90)`, INVOKER: último costo y fecha, anterior distinto y
    tendencia, promedio ponderado/mín/máx/compras/cantidad de la ventana, contenido, precio de lista con fecha y
    fuente, vínculo, si es el suplidor del pedido sugerido, puesto y % sobre el más barato. Sin anulados.
  - Prueba `supabase/tests/compras_f4_local_test.sh` (D1–D10, C1–C6, A1–A7, rollback) en verde. Verificación:
    `supabase/VERIFICAR_20260915_0008_precios.sql`.
  - OJO al aplicar: crear el trigger en `inventory_movements` toma un candado breve (lock_timeout 5 s).
- Lógica pura `lib/core/inventory/price_comparison.dart` (6 pruebas): `SupplierPrice`, `cheaperAlternative`
  (activo, precio de ≤ 90 días, ahorro ≥ 5%; sin compras propias no sugiere), `trendLabel`.
- Repositorio `lib/data/repositories/price_comparison_repository.dart` (tandas de 300 insumos, páginas de 1,000,
  tri-estado).
- Diálogo `lib/presentation/inventory/view/widgets/price_comparison_dialog.dart` («Precios de …», ventana 30/90/180
  días, «El más barato», «Del pedido sugerido», tendencia, promedio, rango, lista y «Pedirle a este»).
- Insumos: «Comparar precios» en el menú de cada fila (visible para todos).
- Pedido sugerido: los precios llegan después de la lista; aviso «SB está 12% más barato» (abre el comparador),
  botón «Comparar precios» junto a «Cambiar suplidor»; elegir desde el comparador mueve la línea con el último costo
  de ese suplidor (D3: sugiere, no cambia solo).
- **Para la parte del negocio**: `SEMBRAR_vinculos_suplidor.sql` inserta `last_price` sin fecha ni fuente; con la 0008
  aplicada quedarían selladas como «manual» de hoy. Ajustar el script antes de correrlo (poner la bandera de
  recepción y la fecha de la última compra).
- No se ha probado a mano contra datos reales.
### F5 — Caja dentro de caja — F5a ✅ IMPLEMENTADA 2026-09-15 (sin aplicar, sin commit); F5b pendiente
- Tabla `inventory_item_presentations` (insumo, unidad, cantidad que contiene, unidad contenida): Lata = 355 mL,
  Caja = 24 Lata. El factor efectivo (8520 mL) se calcula.
- **Compatibilidad**: `inventory_items.purchase_unit/pack_size` sigue siendo la presentación de compra por
  defecto, APLANADA (Caja = 8520 mL). Todo lo que hoy convierte con un solo `pack_size` (compras, recepción,
  kardex, costos, RPCs, analytics) sigue funcionando sin cambios.
- Lo que cambia: etiquetas («1 Caja · 24 Latas · 8.52 L»), recetas y modificadores aceptan cualquier
  presentación, conteo en presentaciones sueltas, líneas de orden en cualquier presentación,
  `supplier_items` apunta a una presentación.


**F5a — entregado (modelo + ficha del insumo):**
- Migración `20260915_0009_compras_f5_presentaciones.sql` (+ `_ROLLBACK`, que borra la tabla y deja el pack aplanado):
  - `inventory_item_presentations` (hasta 5 por insumo; cada una contiene la base o una presentación que contiene la
    base; `base_qty` aplanado; una sola «de compra»), índices únicos (nombre por insumo sin mayúsculas, una de compra),
    RLS igual a `inventory_items` (leer = miembro; escribir = `inventario.productos.crear_editar`) y trigger que impide
    apuntar a un insumo de otro negocio.
  - `fn_inventory_item_presentations_save(insumo, lista)`, INVOKER + chequeo explícito del permiso (EXECUTE solo
    authenticated): reemplaza el juego en una transacción, valida (repetida, igual a la base, cantidad ≤ 0,
    contenedor inexistente, tres niveles, dos de compra, más de 5) y aplana la de compra en `purchase_unit`/`pack_size`.
    Sin «de compra» no toca la ficha.
  - Prueba `supabase/tests/compras_f5_local_test.sh` (P1–P4, V1–V10, S1–S6, rollback) en verde. Verificación:
    `supabase/VERIFICAR_20260915_0009_presentaciones.sql` (la fila 7 marca fichas cuya unidad de compra se cambió por
    fuera y ya no coincide con la presentación de compra).
- Lógica pura `lib/core/inventory/item_presentations.dart` (7 pruebas): mismas reglas que la base, `base_qty`,
  etiqueta «1 Caja · 24 Lata · 8.52 L» (mL → L, g → kg).
- Repositorio `lib/data/repositories/item_presentations_repository.dart` (tri-estado; `reason()` muestra el motivo
  de la base sin el código).
- Editor `lib/presentation/inventory/view/widgets/item_presentations_editor.dart` (4 pruebas de widget) dentro de
  `item_form_dialog`: filas «presentación = cantidad de [base | otra presentación]», ★ de compra, etiqueta y errores en
  vivo; renombrar actualiza a las que la contenían. Con una ★ válida, la unidad de compra de la ficha pasa a ser la
  etiqueta de esa presentación. Se guarda DESPUÉS del insumo; si falla, el insumo queda guardado y el siguiente
  «Guardar» lo actualiza (no crea otro).

**F5b — pendiente:** recetas y modificadores en cualquier presentación (hoy convierten con un solo `pack_size`),
conteo físico en presentaciones sueltas, líneas de orden en cualquier presentación, `supplier_items` apuntando a una
presentación, y mostrar la etiqueta encadenada en compras, recepción e Insumos.
---

## 6. Decisiones que necesito del dueño

| # | Pregunta | Recomendación |
|---|---|---|
| D1 | ¿Qué cuenta como consumo para proyectar? | Ventas + producción + mermas. **Sin** transferencias ni ajustes de conteo |
| D2 | ¿El mínimo es colchón (se suma a lo que se consume mientras llega) o piso (nunca pedir menos que llegar al mínimo)? | **Colchón**: con piso, el stock cae por debajo del mínimo mientras llega el pedido |
| D3 | ¿A qué suplidor se le pide cada insumo? | Preferido → único vínculo → última compra recibida. El comparador **sugiere** cambiar, no cambia solo |
| D4 | ¿Al recibir se actualiza solo el precio de lista del suplidor y se crea el vínculo? | **Sí**: hoy nadie lo mantiene a mano y queda viejo |
| D5 | ¿La proyección y la orden son por almacén o por negocio? | Por el **almacén que se elija** (Principal por defecto); con áreas encendidas, cada área pide lo suyo |
| D6 | Los insumos **no tienen categoría**. ¿Se filtra por clasificación + almacén + suplidor, o se agrega categoría de insumo? | Empezar con clasificación + almacén + suplidor; agregar `categoría` de insumo solo si hace falta |
| D7 | ¿Redondear siempre hacia arriba al empaque y al mínimo de compra del suplidor? | **Sí**, con aviso de cuánto sobra |
| D8 | Penda tiene 0 vínculos insumo–suplidor. ¿Se siembran desde las compras reales? | **Sí**, una vez por negocio, sin pisar lo que ya exista |
| D9 | Ningún suplidor tiene tiempo de entrega. ¿Qué se usa mientras tanto? | Un valor por defecto en la pantalla (sugerido: 2 días), editable por suplidor ahí mismo |

---

## 7. Qué NO entra

- Envío automático de órdenes al suplidor sin revisión humana.
- Presupuestos/cotizaciones a varios suplidores con respuesta.
- Pronóstico estacional (días de la semana, temporadas): la proyección es consumo promedio de N días.
- Cambiar la política de costo (sigue siendo último precio, se mueve al recibir).

## 8. Riesgos

- **La base viva diverge del repo** en compras (B1 puede no fallar en prod): correr
  `supabase/DIAGNOSTICO_compras.sql` antes de F0.
- **Proyección con historial corto**: Penda tiene inventario serio desde el conteo del 01-09; con menos de N días
  de datos, el consumo diario sale bajo. La pantalla debe decir con cuántos días calculó.
- **Compras que no pasan por el sistema** (café, crema, pasta en Penda): el consumo sí baja el stock, pero sin
  recepciones el comparador no tiene precios y la proyección pide lo que nunca se registró.
