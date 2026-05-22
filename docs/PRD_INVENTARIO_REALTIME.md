# PRD — Inventario en tiempo real con venta en negativo

**Estado:** Implementado (2026-05-17). Migraciones SQL aplicadas; pendiente release de la app a Play/App Store.

**Objetivo:** que el descuento de stock al vender refleje en vivo en todas las tablets del local, permita configurar por producto si se puede vender estando agotado, y devuelva inventario automáticamente al cancelar/editar items.

---

## 1. Contexto

### Problema operativo

Antes de esta entrega:

- El stock se descontaba en el backend al enviar a cocina (vía `consume_inventory_from_order` y `trg_inventory_stock_sync`), pero **la UI del cajero no se enteraba**: si Tablet A vendía 5 mojitos, Tablet B seguía viendo "10 disponibles" hasta que el cajero saliera de la pantalla y volviera.
- Cuando un insumo se agotaba, el trigger `auto-86` desactivaba el producto (`is_active=false`) — pero ese cambio tampoco llegaba en realtime, así que el cajero podía seguir pulsando el producto agotado y enviarlo a cocina.
- No había forma de configurar **por producto** si se permite vender en negativo. El comportamiento era global: agotado = oculto del menú.
- Al **cancelar o eliminar** un item ya enviado a cocina, el stock no se devolvía. La función `consume_inventory_from_order` solo insertaba movimientos negativos para el delta faltante; no manejaba el caso opuesto.

### Caso de uso del cliente

Un restaurante con bar tiene productos con perfiles distintos:

- **Comida** (burritos, tacos): conteo estricto. Si no hay ingredientes, no se vende. Producto desaparece del menú al agotarse.
- **Bebidas/mojitos**: conteo aproximado. El bar a veces "encuentra" stock no contabilizado o lo regulariza con la próxima compra. Quiere seguir vendiendo aunque el sistema indique agotado; los faltantes se saldan con la próxima recepción.

Requisito: que el admin decida **por producto** cuál de los dos comportamientos aplica.

---

## 2. Solución implementada

### Capa de datos (Supabase)

#### Migración `20260517_0001_allow_negative_sale.sql`

- Nueva columna `menu_items.allow_negative_sale boolean not null default false`.
- Reemplaza `fn_recompute_menu_items_availability` (auto-86) para respetar el flag: si `allow_negative_sale = true`, no desactiva el producto al agotarse y reactiva si venía de un auto-86 previo. Si `false`, comportamiento histórico intacto.

#### Migración `20260517_0002_inventory_revert_on_cancel.sql`

- Reescribe `consume_inventory_from_order` para que sea **reconciliadora**: calcula `expected_qty` (sumando solo items vivos con `status <> 'void'`) menos `net_consumed` (suma sign-aware de movimientos previos). Inserta un movimiento con signo opuesto al delta — negativo si falta consumir, positivo si hay que devolver. Idempotente: siempre converge a delta cero.
- El loop ahora itera sobre la **unión** de ingredientes en items vivos Y de los que ya tienen movimientos previos. Esto captura el caso de un item eliminado por completo (ya no aparece en `order_items` pero sí tenía movement viejo).
- Triggers nuevos:
  - `trg_order_items_reconcile_inventory_upd` — `AFTER UPDATE OF status, qty, quantity, product_id` con guard `WHEN` para no spamear.
  - `trg_order_items_reconcile_inventory_del` — `AFTER DELETE`.
- Ambos invocan `consume_inventory_from_order(order_id)`, lo cual ajusta el stock automáticamente al anular/editar/eliminar.

#### Migración `20260517_0003_realtime_inventory.sql`

- Agrega `inventory_stock` y `menu_items` a la publication `supabase_realtime`.
- Setea `REPLICA IDENTITY FULL` en ambas tablas para que los UPDATEs incluyan el row completo OLD/NEW (necesario para que el cliente compare `old.is_active != new.is_active`).

### Capa de cliente (Flutter)

#### `MenuItem` y `MenuProduct`

- Campo nuevo `allowNegativeSale` (default `false`) en ambos modelos, con mapeo en `fromMap` y `toInsert`/`copyWith`.
- `MenuProduct` también recibe `isInventoryTracked` para que el grid pueda validar.
- Las queries `_menuItemsSelect` y `_menuListSelect` del menu browser incluyen los nuevos campos.

#### Realtime listener — `menu_browser_viewmodel.dart`

- Suscribe al canal `rt:inventory_stock` (tabla `inventory_stock`, evento `*`).
- Debounce de **500 ms**: si llegan muchos eventos seguidos (orden con 10 items → 10 movements → trigger auto-86 → updates a menu_items), agrupa en un solo refresh.
- En cada disparo: re-ejecuta `_loadStockMap()` que consulta `v_menu_items_stock` y actualiza `state.stockByProductId`.
- `dispose()` cancela el channel y el timer.

#### Badge "Agotado" — `_StockBadge` en `table_order_screen.dart`

- Cuando `stockUnits <= 0` muestra texto **"Agotado"** en fondo rojo.
- Stock positivo conserva los rangos de color: verde (>20), amarillo (>5), naranja (≤5), rojo (≤0).

#### Bloqueo del tap — `table_order_screen.dart`

- Variable `blockedByStock = isInventoryTracked && !allowNegativeSale && stockUnits != null && stockUnits <= 0`.
- Cuando el producto está bloqueado, el `onTap` muestra un `SnackBar` rojo:
  > "{nombre} está agotado. Recibe stock o activa 'Vender aunque esté agotado' en el producto."
- No se llama al `onProductTap` original — el item no se agrega al carrito.

#### Toggle en formulario de producto

- Switch nuevo en `add_edit_product_dialog.dart` con título **"Vender aunque esté agotado"**, visible solo cuando "Inventariable" está activo.
- Texto explicativo debajo que cambia según el estado.
- `_allowNegativeSale` se propaga por la cadena: dialog → `onAdd`/`onUpdate` → `ProductsViewModel.addProduct/updateProduct` → `ProductsRepository.createProduct/updateProduct` → INSERT/UPDATE en `menu_items`.

---

## 3. Flujos de usuario

### Flujo 1 — Producto tracked SIN venta en negativo (comportamiento estricto)

1. Admin crea un burrito con "Inventariable: ON" y "Vender aunque esté agotado: OFF". Stock inicial 5.
2. Cajero vende 5 burritos → `consume_inventory_from_order` descuenta 5 → `inventory_stock.quantity = 0`.
3. Trigger `trg_movements_recompute_menu_availability` corre `fn_recompute_menu_items_availability`.
4. Como `allow_negative_sale = false`, marca `is_active = false`, `auto_disabled = true`.
5. Realtime emite UPDATE de `menu_items` → todas las tablets reciben el evento → re-fetch del catálogo → burrito desaparece del grid.
6. Cuando llega compra de +10 → trigger reactiva (is_active=true, auto_disabled=false) → realtime → burrito reaparece con stock 10.

### Flujo 2 — Producto tracked CON venta en negativo (bar / mojitos)

1. Admin crea el mojito con "Inventariable: ON" y "Vender aunque esté agotado: ON". Stock inicial 5.
2. Cajero vende 7 mojitos → stock va a -2.
3. Trigger auto-86 corre, ve el flag activo → **no desactiva** el producto.
4. Vista `v_menu_items_stock` devuelve `available_units = -2`.
5. Realtime propaga el cambio → badge en todas las tablets muestra "Agotado" rojo, pero el producto sigue clickeable.
6. Cajero sigue vendiendo. Cada venta deja stock más negativo (-3, -4, ...).
7. Llega recepción de compra de +20 → `trg_inventory_stock_sync` suma: `quantity = -4 + 20 = 16`.
8. Badge vuelve a "16" en verde. Sin intervención manual.

### Flujo 3 — Cancelación de item ya enviado a cocina

1. Cajero envía 3 mojitos a cocina → stock baja 3.
2. Cliente se arrepiente. Cajero anula la línea (`status = 'void'`).
3. `trg_order_items_reconcile_inventory_upd` dispara → `consume_inventory_from_order` recalcula: `expected = 0` (items voided no cuentan), `net_consumed = 3` → `delta = -3` → inserta movement positivo de +3.
4. Stock sube 3. Realtime propaga. Badge actualiza.

### Flujo 4 — Edición de cantidad

1. Cajero envía 5 mojitos. Stock baja 5.
2. Cajero cambia cantidad a 3.
3. Trigger UPDATE dispara → `expected = 3`, `net_consumed = 5` → `delta = -2` → movement positivo de +2.
4. Stock recupera 2.

### Flujo 5 — Carrera entre dos tablets

1. Stock muestra 1 burrito en ambas tablets.
2. Tablet A vende 1 → stock va a 0 → auto-86 desactiva → realtime propaga.
3. Tablet B (que aún no recibió el evento por una latencia de ~200 ms) ve el badge "1" y el cajero pulsa el botón.
4. Si el evento ya llegó: el grid filtra y el burrito ya no está.
5. Si el evento aún no llegó pero el catálogo cargado tiene `allow_negative_sale = false`: la validación cliente (`blockedByStock`) chequea `stockByProductId[id] <= 0` y bloquea con snackbar.
6. La capa cliente es la red de seguridad para la ventana de propagación.

---

## 4. Criterios de aceptación

| # | Criterio | Estado |
|---|---|---|
| 1 | Al vender, el stock descuenta en la BD vía `consume_inventory_from_order` | ✅ pre-existente |
| 2 | Otra tablet ve el cambio de stock sin recargar (badge actualiza ≤ 1 s) | ✅ entregado |
| 3 | Producto sin venta en negativo desaparece del menú al agotarse, en vivo | ✅ entregado |
| 4 | Producto con venta en negativo permanece visible con badge "Agotado" | ✅ entregado |
| 5 | El cajero no puede agregar producto agotado (sin venta en negativo) aun si el catálogo está rezagado | ✅ entregado |
| 6 | Cancelar/eliminar/editar un item devuelve el stock automáticamente | ✅ entregado |
| 7 | Admin configura el flag por producto desde el formulario de edición | ✅ entregado |
| 8 | Refresh inmediato del badge tras enviar a cocina en la misma tablet | ✅ pre-existente (refreshStock) |

---

## 5. Operación y deploy

### Migraciones requeridas (en orden)

1. `20260517_0001_allow_negative_sale.sql`
2. `20260517_0002_inventory_revert_on_cancel.sql`
3. `20260517_0003_realtime_inventory.sql`

Todas son **hacia atrás compatibles**: la columna `allow_negative_sale` tiene default `false`, la app anterior la ignora; la función reconciliada acepta cualquier estado previo; la publication agregada no afecta a clientes que no se suscriben.

### Aplicación

```bash
supabase db push
# o copiar el SQL y ejecutarlo en el dashboard de Supabase.
```

### Rollback

Cada migración tiene su archivo `_ROLLBACK.sql` correspondiente. La columna `allow_negative_sale` no se borra en el rollback de la 0001 para preservar backups; eliminarla a mano si se requiere `DROP COLUMN`.

### Configuración requerida en la BD

`business_settings.inventory_mode` debe ser **`'basic'`** o **`'advanced'`**. En modo `'none'`, `consume_inventory_from_order` aborta y el descuento jamás ocurre. Verificable con:

```sql
select bs.inventory_mode
from public.business_settings bs
where bs.business_id = '<uuid>';
```

---

## 6. Pendientes / mejoras futuras

### Mejora #1 — Validación pre-venta en backend (defensa en profundidad)

**Problema:** la validación cliente puede saltarse si un cajero usa una app modificada o si el catálogo está muy desactualizado. El backend acepta cualquier `fn_add_item_from_menu` sin chequear stock.

**Propuesta:** modificar `fn_add_item_from_menu` (o agregar trigger BEFORE en `order_items`) que aborte con error claro si el producto tiene `is_inventory_tracked = true`, `allow_negative_sale = false`, y stock disponible insuficiente para la cantidad pedida.

**Trade-off:** rompe el modo offline parcial (cuando la app envía items en cola tras recuperar conectividad). Hay que decidir si el bloqueo es estricto o suave (warning).

### Mejora #2 — Stock por bodega visible en el badge

Hoy el badge suma stock de todas las bodegas activas. Para negocios con múltiples bodegas, el cajero quizás quiere ver "5 en Bodega Principal, 0 en Bar". Requiere extender `v_menu_items_stock` y la UI.

### Mejora #3 — Historial de movimientos por producto en la UI

Cuando el cajero ve un badge "Agotado", no tiene contexto de cuándo se agotó ni por qué. Una pantalla en la ficha del producto que muestre los últimos movimientos (`inventory_movements`) ayudaría a auditar manualmente. Backend ya tiene los datos.

### Mejora #4 — Recetas multi-ingrediente en el badge

`v_menu_items_stock` solo expone productos con receta 1:1 (modo `basic`/Loyverse). Para recetas multi-ingrediente (modo `advanced`), no hay badge porque "stock del producto" depende del mínimo de varios insumos. Calcularlo en runtime sería costoso; una vista materializada podría ayudar.

### Mejora #5 — Alertas push de stock bajo

Cuando un insumo cae bajo el umbral mínimo, notificar al admin (push notification, email, Slack). El backend ya tiene `low_stock_badge_provider`; falta la pieza de delivery.

### Mejora #6 — Test de carrera (concurrencia)

Probar con dos tablets reales (no emuladores) que el realtime resuelve la carrera de venta simultánea sin doble venta de stock real. Documentar el peor caso de latencia observado.

---

## 7. Archivos tocados — referencia rápida

### SQL
- `supabase/migrations/20260517_0001_allow_negative_sale.sql` + ROLLBACK
- `supabase/migrations/20260517_0002_inventory_revert_on_cancel.sql` + ROLLBACK
- `supabase/migrations/20260517_0003_realtime_inventory.sql` + ROLLBACK

### Modelo y data
- `lib/data/models/menu_item.dart` — campo `allowNegativeSale`
- `lib/data/repositories/products_repository.dart` — INSERT/UPDATE con el campo

### ViewModels
- `lib/presentation/products/viewmodel/products_viewmodel.dart` — métodos `addProduct`/`updateProduct`
- `lib/presentation/sales/viewmodel/menu_browser_viewmodel.dart` — realtime channel + `MenuProduct` con nuevos campos

### UI
- `lib/presentation/products/widgets/add_edit_product_dialog.dart` — switch "Vender aunque esté agotado"
- `lib/presentation/products/view/products_view.dart` — propagación de callbacks
- `lib/presentation/sales/view/table_order_screen.dart` — badge "Agotado" y bloqueo de tap

---

## 8. Notas de diseño

- El default del flag (`false`) preserva el comportamiento histórico para todos los productos existentes. Hay que migrar conscientemente cada producto.
- El badge "Agotado" es la señal visual; la regla de bloqueo es contractual (configurada por admin) y vive en el flag.
- La función `consume_inventory_from_order` ahora es **idempotente y reconciliadora**: ejecutarla múltiples veces sobre la misma orden converge al mismo estado. Esto es lo que permite que los triggers en `order_items` la invoquen sin preocuparse de duplicar descuentos.
- El debounce de 500 ms en el realtime listener es un compromiso entre responsividad y carga: una orden de 10 items dispara cerca de 30 eventos en cascada (10 movements + 10 stock updates + ~10 menu_items updates si hay auto-86). Sin debounce el cliente haría 30 fetches; con 500 ms hace 1.
