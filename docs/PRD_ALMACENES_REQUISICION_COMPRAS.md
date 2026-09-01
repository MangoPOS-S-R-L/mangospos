# PRD — Almacenes por sección, requisición y compra por suplidor

**Fecha:** 2026-08-31
**Estado:** aprobado en alcance, sin implementar
**Bandera:** `business_settings.warehouse_sections_enabled` (apagada por defecto)

> **Arranque real (2026-08-31):** el negocio tiene **un solo almacén** y el
> primer conteo físico es mañana. Los demás almacenes se crean durante la
> semana. Nada de este PRD sale antes del conteo — ver §9.

---

## 1. Qué pidió el cliente

Un restaurante que opera con almacén central y áreas de producción separadas:

| Almacén | Responsable | Área de producción |
|---|---|---|
| Almacén General | Santiago (encargado de almacén) | — |
| Almacén de Cocina | Jesús | Cocina |
| Bar | Jesús | Bar |
| Food Shop | Jesús | Food Shop |
| Almacén de Mermas | — | — (destino de desperdicio) |
| Almacén Estancia Nueva | — | — (préstamos) |

Y once necesidades: mínimos de compra ajustables, pedido por suplidor con filtro,
proyección del sistema, almacenes por sección, requisición de almacén a cocina,
activos fijos, ajuste de insumos al preparar, transferencias, recetarios,
documento de desperdicios y material gastable para llevar.

---

## 2. El hallazgo que condiciona todo lo demás

**Hoy la venta descuenta siempre del almacén principal.**

`consume_inventory_from_order` (última versión en
`supabase/migrations/20260613_0001_finished_product_direct_inventory.sql`)
resuelve la bodega así:

```sql
select id into v_main_warehouse_id
  from public.warehouses w
 where w.business_id = v_business_id
 order by w.is_main desc, w.created_at asc nulls first, w.id asc
 limit 1;
```

Una sola bodega para todo el negocio. Si se abren los seis almacenes sin tocar
esta función pasa lo siguiente:

1. Santiago despacha 10 kg de queso de General a Cocina → General baja 10.
2. Cocina vende las pizzas → **la venta vuelve a descontar de General**.
3. General se va en negativo, Cocina nunca baja y el conteo no cuadra nunca.

Los almacenes por sección **no son una pantalla nueva: son un cambio en el motor
de consumo**. Esa es la Fase 1 y todo lo demás depende de ella.

Lo mismo aplica a las funciones que leen stock para el auto-86
(`20260516_0014_menu_items_stock_view.sql`, `20260516_0015_auto_86.sql`):
hoy suman todas las bodegas; con secciones tienen que mirar la del área o el
producto se apaga en el menú teniendo mercancía en Cocina.

---

## 3. Decisiones tomadas

| Tema | Decisión |
|---|---|
| Consumo de venta | Del almacén del **área de producción** del producto |
| Requisición | **Pull con despacho parcial**: cocina pide → almacén despacha lo que hay → cocina recibe |
| Responsable de almacén | **Candado + aprobación**: solo él (y admin/dueño) despacha, ajusta y aprueba su bodega |
| Activos fijos | **Catálogo** con responsable, ubicación y estado. Sin depreciación |
| Proyección | **Consumo real del kardex + días de cobertura + lead time del proveedor** |
| Mínimos | Edición masiva + por almacén + sugerido por el sistema + importar/exportar Excel |
| Mermas | La merma **se transfiere al Almacén de Mermas**, no solo descuenta |
| Gastables | **Receta de empaque por producto**, con alcance por línea (para llevar / también en local) |
| Préstamos | Salida con **devolución pendiente** y saldo por devolver |
| Suplidores | Catálogo con precios + filtro en toda la compra + comparación + una OC por suplidor |
| Recetarios | Sub-recetas + costo/margen + ficha imprimible + rendimiento y merma |
| Arranque | **Conteo físico inicial** por almacén, todos en cero |
| Alcance | Detrás de bandera por negocio |
| Documentos | Requisición, merma, orden de compra y préstamo/devolución, todos imprimibles |

---

## 4. Qué ya existe (no se reconstruye)

Antes de escribir una línea, esto ya está en producción o en el repo:

- **Bodegas** con lista de insumos copiable (`fn_inventory_copy_warehouse_items`).
- **Mínimo por bodega**: `inventory_stock.min_stock` +
  `fn_inventory_set_warehouse_min_stock` — migración `20260819_0001`, **sin aplicar**.
- **Transferencias** con workflow de aprobación (`20260516_0009`) y estados
  `pending_approval → sent → received | cancelled`.
- **Producción**: `production_orders` + `production_order_lines`, con consumo de
  insumos, rendimiento real y recálculo del costo del terminado (`20260516_0008`).
  Esto ya cubre "ajuste de insumos cuando un producto se prepara".
- **Recetas** que apuntan a un `inventory_item` en vez de a un producto del menú
  (`recipes.inventory_item_id`, `20260516_0007`): las **sub-recetas ya existen a
  nivel de datos**, falta la interfaz.
- **Rotación**: `fn_inventory_rotation_analysis` ya calcula `outflow_per_day` y
  `days_of_supply` — es la materia prima de la proyección.
- **Sugerencias de reorden** agrupadas por proveedor con creación de OC
  (`v_inventory_reorder_suggestions`).
- **Proveedores** con términos de pago, lead time y monto mínimo
  (`20260819_0003`, **sin aplicar**) y proveedor preferido por insumo (`20260813_0001`).
- **Conteo físico** con modo ciego, recuento y valuación.
- **Mermas** como salidas con motivo (`kAdjustReasons`: rotura, vencido, robo,
  donación, corrección).
- **`order_items.is_takeout`** por ítem: el sistema ya sabe qué se va para llevar.
- **Conduce de recepción** térmico + PDF (`20260828_0001`) — el molde para los
  documentos nuevos.

---

## 5. Modelo de datos

### 5.1 Almacenes

```sql
alter table public.warehouses
  add column if not exists warehouse_type text not null default 'general'
    check (warehouse_type in ('general','production','waste','loan')),
  add column if not exists production_area_id uuid references public.print_areas(id),
  add column if not exists keeper_employee_id uuid references public.employees(id),
  add column if not exists requires_requisition boolean not null default false;

-- Un área de producción no puede tener dos almacenes: la venta no sabría de cuál descontar.
create unique index if not exists uq_warehouses_production_area
  on public.warehouses (business_id, production_area_id)
  where production_area_id is not null;

-- Un solo almacén de mermas por negocio.
create unique index if not exists uq_warehouses_waste
  on public.warehouses (business_id)
  where warehouse_type = 'waste';
```

`production_area_id` apunta a `print_areas`, que es donde ya viven Cocina, Bar y
Food Shop, y que ya rutea los productos vía `menu_item_print_areas` (N:M) o el
legacy `menu_items.print_area_code`. **No se inventa un catálogo de áreas nuevo.**

### 5.2 Resolución de la bodega de consumo

Función nueva `fn_resolve_consumption_warehouse(business_id, menu_item_id)` con
cadena de fallback explícita:

1. Bandera apagada → almacén principal (comportamiento actual, intacto).
2. Producto con **un** área en `menu_item_print_areas` que tenga almacén → ese.
3. Producto con **varias** áreas → la de menor `print_areas.sort_order`, con el
   caso registrado en `notes` del movimiento para poder auditarlo.
4. Producto sin área o área sin almacén → almacén principal.

Se llama desde `consume_inventory_from_order`, desde la reversión al anular
(`20260517_0002`) y desde el consumo de gastables. **Un solo lugar donde se
decide, o los tres flujos se desincronizan.**

### 5.3 Requisición

```sql
create table public.requisitions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  code text not null,                    -- REQ-00001, mismo patrón que RM/PROD
  status text not null default 'draft'
    check (status in ('draft','pending','partial','dispatched','received','cancelled')),
  from_warehouse_id uuid not null references public.warehouses(id),  -- a quién se le pide
  to_warehouse_id   uuid not null references public.warehouses(id),  -- quién pide
  requested_by uuid, requested_at timestamptz not null default now(),
  dispatched_by uuid, dispatched_at timestamptz,
  received_by uuid, received_at timestamptz,
  notes text
);

create table public.requisition_lines (
  id uuid primary key default gen_random_uuid(),
  requisition_id uuid not null references public.requisitions(id) on delete cascade,
  inventory_item_id uuid not null references public.inventory_items(id),
  requested_qty  numeric not null check (requested_qty > 0),
  dispatched_qty numeric,               -- null = todavía no se despachó
  received_qty   numeric,
  unit text not null,
  line_notes text
);
```

Flujo: `pending` → el almacén despacha línea por línea → si despachó menos de lo
pedido en alguna línea queda `partial` (y el faltante es visible y reclamable),
si despachó todo queda `dispatched` → cocina confirma y pasa a `received`.

**El stock se mueve en el despacho, no en la solicitud.** Reusa
`fn_inventory_transfer_send` por debajo para no duplicar el motor de movimientos:
la requisición es el documento y la autorización; la transferencia es el asiento.

### 5.4 Merma con almacén destino

La merma deja de ser un ajuste negativo y pasa a ser un **traslado al Almacén de
Mermas**, con documento:

```sql
create table public.waste_documents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  code text not null,                    -- MER-00001
  status text not null default 'draft'
    check (status in ('draft','pending_approval','approved','cancelled')),
  from_warehouse_id uuid not null references public.warehouses(id),
  reason_code text not null,             -- mismo catálogo de kAdjustReasons
  reported_by uuid, approved_by uuid, approved_at timestamptz,
  total_cost numeric not null default 0, -- valuado al costo del momento
  notes text
);
-- waste_document_lines: item, qty, unit, unit_cost, line_notes
```

Al aprobarse genera `transfer_out` del almacén de origen y `transfer_in` al
almacén de mermas. Lo perdido queda contable y visible: se puede sacar el costo
de la merma del mes en una sola consulta, en vez de reconstruirlo del kardex.
La baja definitiva del Almacén de Mermas es un ajuste aparte, mensual.

### 5.5 Gastables

```sql
create table public.packaging_recipes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  menu_item_id uuid references public.menu_items(id) on delete cascade,
  category_id  uuid references public.categories(id) on delete cascade,
  -- uno de los dos: por producto o por categoría entera
  is_active boolean not null default true
);

create table public.packaging_recipe_lines (
  id uuid primary key default gen_random_uuid(),
  packaging_recipe_id uuid not null references public.packaging_recipes(id) on delete cascade,
  inventory_item_id uuid not null references public.inventory_items(id),
  quantity numeric not null check (quantity > 0),
  unit text not null,
  applies_to text not null default 'takeout'
    check (applies_to in ('takeout','dine_in','both'))
);
```

`applies_to` es el check que pediste. La bolsa y el foam son `takeout`; la
servilleta, el individual y el palillo son `both`; el mantel de papel es
`dine_in`. En la interfaz se ve como una casilla **"También aplica para consumo
en el local"** sobre la línea, no como un enum crudo.

El consumo corre dentro de `consume_inventory_from_order`, leyendo
`order_items.is_takeout` de cada ítem, y descuenta del almacén del área del
producto (los gastables de cocina salen de Cocina, los del bar del Bar).

### 5.6 Catálogo por suplidor

Aplicar `20260819_0003_supplier_terms_and_items.sql` (ya escrita, sin aplicar) y
extender `supplier_items` con `pack_size`, `pack_unit`, `supplier_sku` y
`last_price_at` para comparar precios reales entre suplidores.

### 5.7 Activos fijos

```sql
create table public.fixed_assets (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  code text not null,                    -- AF-00001
  name text not null,
  category text,                          -- equipo, mobiliario, vajilla, uniforme
  serial_number text, purchase_date date, purchase_cost numeric,
  assigned_to_employee_id uuid references public.employees(id),
  location_warehouse_id uuid references public.warehouses(id),
  location_note text,
  condition text not null default 'good'
    check (condition in ('good','needs_repair','damaged','lost','retired')),
  photo_url text, notes text
);
-- fixed_asset_movements: asignación, traslado, cambio de estado, baja
```

**No entra en la valuación de inventario ni en el costo de venta.** Es un
registro paralelo: qué hay, dónde está, quién responde por eso.

### 5.8 Préstamos

Se modela como transferencia con devolución:

```sql
alter table public.stock_transfers
  add column if not exists is_loan boolean not null default false,
  add column if not exists loan_due_date date,
  add column if not exists loan_returned_at timestamptz,
  add column if not exists loan_parent_id uuid references public.stock_transfers(id);
```

La devolución es una transferencia inversa que apunta al préstamo original con
`loan_parent_id`. Vista de "prestado y sin devolver" = préstamos sin devolución
que los cubra. Si nunca vuelve, se cierra facturándolo o como merma.

### 5.9 Permisos

Códigos nuevos en `access_control_catalog.dart` **y** en el catálogo de la base
de datos — si el código no está en la tabla, el join del RPC lo descarta en
silencio y el permiso no hace nada:

```
inventario.requisiciones.crear
inventario.requisiciones.despachar
inventario.requisiciones.recibir
inventario.mermas.crear
inventario.mermas.aprobar
inventario.almacenes.gestionar
inventario.minimos.editar
inventario.activos.acceso
inventario.activos.gestionar
compras.suplidores.catalogo
```

El candado por almacén no es un permiso más: es un chequeo adicional en las
funciones de despacho, ajuste y aprobación —
`warehouses.keeper_employee_id = <empleado actual>` o el usuario es
admin/dueño. Va en la base de datos, no en la interfaz: si vive solo en Flutter,
cualquier cliente viejo lo salta.

---

## 6. Fases

### F0 — Cimientos ✅ IMPLEMENTADO (2026-08-31, sin commit)

Migración `20260901_0001_warehouse_sections.sql` (+ ROLLBACK), **sin aplicar**:
`warehouses.warehouse_type` / `production_area_id` → `print_areas` /
`keeper_employee_id` → `employees` / `requires_requisition`, más los índices
únicos (un área un almacén; un solo almacén de mermas) y
`business_settings.warehouse_sections_enabled` apagada.

App:
- `BusinessFeatures.warehouseSectionsEnabled` (campo y columna listos). El
  **interruptor NO se muestra todavía**: ningún código lee la bandera hasta
  F1, y uno inerte es peor que ausente — alguien lo prende creyendo que ya
  cambió el consumo, y el día del despliegue de F1 la venta empieza a
  descontar de otro almacén sin que nadie lo haya decidido ese día. El sitio
  donde va está marcado con comentario en `business_features_view.dart`.
- `WarehouseType` (enum con etiqueta y descripción) y
  `InventoryWarehouseDetail` extendido con tipo, área, responsable y sus
  nombres resueltos por el join.
- `InventoryRepository`: SELECT con las columnas nuevas y **degradación**
  (`42703` / `PGRST200` / `PGRST204` → vuelve al SELECT viejo y lo deja
  anotado para la sesión); `createWarehouse`/`updateWarehouse` con los campos
  nuevos y el mismo reintento; `getProductionAreas` y `getKeeperCandidates`
  para los selectores.
- Formulario de almacén: casilla **"Está asignado a un área de producción"**
  → selector de área obligatorio; si no, selector de uso
  (General / Mermas / Préstamos). Selector de responsable siempre. Si el
  servidor no tiene la migración, guarda igual y avisa qué se perdió.
- Tarjeta de almacén: debajo del nombre se lee `Área · Responsable` (la
  dirección queda de respaldo) y distintivo de MERMAS / PRÉSTAMOS.

`flutter analyze` limpio en todo lo tocado. Los 6 tests que fallan en la suite
ya fallaban antes (cierre de caja e impresión raster), verificado con stash.

**Pendiente de F0:** aplicar `20260901_0001`, más `20260819_0001` (mínimo por
bodega), `0002` (copiar lista) y `0003` (términos de suplidores). Probar en la
app y commitear.

**No expuesto a propósito (misma regla para los dos):** `requires_requisition`
y el interruptor de la bandera existen en la base y en el modelo, pero no en
la interfaz. Un control que todavía no hace nada confunde y, peor, deja que
alguien lo prenda hoy y el comportamiento cambie solo el día que se despliegue
la fase que lo lee. `requires_requisition` lo expone F2; la bandera, F1.

**Aplicar la migración NO cambia nada para los negocios existentes** —
verificado: ninguna función usa `warehouses%ROWTYPE`, no hay triggers sobre la
tabla, las dos referencias del esquema piden columnas nombradas (no `select
*`), el único INSERT nombra sus columnas, y los dos índices únicos son
parciales, así que nacen vacíos con todo en `general` y sin área. Las dos
salvedades: crear los índices toma un lock exclusivo breve (milisegundos en
esa tabla, pero aplicar fuera de hora pico), y si PostgREST no recarga su
caché de esquema, las columnas nuevas responden `PGRST204`/`PGRST200` y la app
degrada al comportamiento viejo en vez de romperse.

### F1 — Consumo por área (**la fase riesgosa**) — ESCRITA, SIN APLICAR

Se descubrió algo que simplifica: **`consume_inventory_from_order` es una sola
función** y el trigger de anulación (`20260517_0002`) la reusa. No hay tres
caminos que sincronizar, hay uno.

**Paso 1 — `20260901_0002_resolve_consumption_warehouse.sql`** (aditivo puro,
aplicable cuando sea): `fn_resolve_consumption_warehouse(business, menu_item,
default)` con la cadena bandera → N:M → legacy `print_area_code` → desempate
determinista por `display_order`/nombre/id → default. Nadie la llama todavía.

Dos decisiones del resolvedor que parecen detalle:
- Filtra por `warehouses.is_active` pero **no** por `print_areas.is_active`:
  desactivar un área es una decisión de impresión y no debería mover en
  silencio de dónde sale la mercancía.
- Es `stable` y en SQL plano para que el planificador la pueda insertar: se
  invoca una vez por renglón de la orden.

**Paso 2 — `20260901_0003_consume_by_area.sql`** (⚠️ cotejar antes de
aplicar): reconcilia por **par (insumo, bodega)** en vez de por insumo. Dos
platos de la misma orden pueden salir de bodegas distintas, y el mismo insumo
puede consumirse desde Cocina en un renglón y desde Bar en otro.

Con la bandera apagada el resolvedor devuelve null en todos los renglones, el
`coalesce` cae en la bodega de siempre y todos los pares comparten esa única
bodega: **la reconciliación por insumo de antes, byte por byte de
comportamiento**.

Propiedad que se corrige sola: si una orden ya tenía consumo en la principal y
después se prende la bandera, la reconciliación devuelve lo consumido en la
principal y lo descuenta de la bodega del área. El consumo **se muda, no se
duplica**. Igual si se le cambia el área a un producto con órdenes abiertas.

En los combos el área la manda el **componente** (es lo que se prepara); si no
tiene, se prueba con la del combo antes de caer en la bodega por defecto.

**Cotejo obligatorio antes de aplicar:** `supabase/COTEJO_antes_de_F1.sql`.
La base viva diverge del repositorio y la 0003 está construida sobre
`20260613_0001`, que es lo último que tiene el repo.

**Paso 3 — `20260901_0004_availability_by_area.sql`**: la vista
`v_menu_items_stock` y `fn_recompute_menu_items_availability` (auto-86) miran
la bodega del área, resuelta con la MISMA función que decide el consumo. Sin
eso el menú y el inventario se contradicen: el plato se ve disponible con la
mercancía en otra bodega, o se apaga solo teniéndola en la suya. Escrita sobre
las definiciones VIVAS (cotejadas 2026-08-31), no sobre las del repositorio.

**F1 (0001, 0002, 0003) APLICADA EN PRODUCCIÓN el 2026-08-31.** Verificado:
el resolvedor existe, los dos triggers de `order_items` están,
`inventory_mode='advanced'`, bandera en `false` → inerte.

**Trampa que casi muerde:** PostgreSQL no valida las referencias dentro del
cuerpo de una función plpgsql al crearla — las resuelve al ejecutarla. Aplicar
la 0003 sin la 0002 crea la función sin protestar y revienta la primera vez
que alguien agrega un ítem; como los triggers de `order_items` la invocan en la
misma transacción, el ítem no se guarda y la POS deja de tomar pedidos.
Verificación: `supabase/URGENTE_verificar_F1_aplicada.sql`.

**Dos cosas que el cotejo destapó y NO se corrigen acá** (cambiarlas movería el
comportamiento de todos los negocios hoy):
1. La bodega virtual `__IN_TRANSIT__` entra en la suma de disponibilidad:
   mercancía en camino contada como vendible. Con la bandera prendida deja de
   pasar solo, porque nunca es la bodega resuelta.
2. `fn_recompute_menu_items_availability` recorre productos vía `recipes`. Los
   terminados con link directo (`menu_items.inventory_item_id` sin receta, que
   es como los crea `20260613_0002`) **nunca se auto-apagan**. La vista sí los
   cubre, así que el badge "Agotado" funciona; sólo falla el auto-86. En un
   catálogo retail como el de Penda eso es casi todo el menú.

**Al cotejar esta zona, ojo con el repositorio:** tiene versiones intermedias
que no son las que están vivas. La vista viva viene de `20260613_0003` (la de
`20260516_0014` no tiene el ramo del link directo) y el auto-86 de
`20260517_0001` (la de `20260516_0015` no tiene `allow_negative_sale`). Agarrar
la equivocada para un ROLLBACK borra funcionalidad en silencio.

**Pendiente de F1:**
- Aplicar la `20260901_0004` (no está validada contra un servidor: no hay
  Postgres local. Va dentro de una transacción, así que un error hace rollback
  solo).
- Conteo físico inicial de cada almacén de producción.
- Exponer el interruptor de la bandera en Ajustes (hoy está comentado).
- **Se prueba con un negocio antes de ofrecerla.**

### F1b — «Mostrar esta bodega en el punto de venta» (2026-08-31)

Salió de un caso real: un bar con dos almacenes (Bar y Principal) que quiere
que los meseros solo puedan vender lo que hay en el Bar.

El área de producción resuelve **por producto** y sirve a un restaurante donde
cada plato sale de un lado. Un bar con dos almacenes no piensa así: piensa
«el punto de venta es el Bar, el otro es el depósito». Obligarlo a rutear
productos a un área para expresar eso lo hace dar una vuelta larga — y en la
prueba real el dueño terminó marcando el área *Bar* sobre la *Bodega
Principal*, que es exactamente cómo se lee el control cuando no es el correcto.

**`20260901_0005_warehouse_pos_source.sql`**: `warehouses.shows_in_pos`, una
sola por negocio (índice único parcial), más un escalón nuevo en el resolvedor:

    área del producto (detrás de warehouse_sections_enabled)
      → bodega marcada shows_in_pos
      → la bodega por defecto de siempre

**No va detrás de `warehouse_sections_enabled`**, a diferencia del área: la
casilla ES el acto deliberado, se prende en una bodega concreta y se apaga
destildándola. La bandera sigue gobernando solo la resolución por área, que
cambia el menú entero de golpe.

**Muestra y descuenta de la misma bodega**, porque el resolvedor lo usan las
dos puntas: `v_menu_items_stock` (el grid) y `consume_inventory_from_order`
(la venta). Mostrar el Bar y descontar del Principal haría que el inventario
del bar no significara nada.

App: casilla en el formulario de bodega, con aviso en rojo cuando se marca
(«si esta bodega está vacía, el menú se bloquea entero»); la tarjeta muestra
`Punto de venta · Área · Responsable`; el repositorio baja la marca de las
demás bodegas antes de escribir, para que marcar la segunda reemplace a la
primera en vez de tirar 23505.

Guía de puesta en marcha: `supabase/CONFIGURAR_bar_dos_almacenes.sql` — su
consulta 2 simula qué productos se van a bloquear antes de tildar nada.

**Requiere la 0004 aplicada.** Sin ella la vista sigue sumando las dos
bodegas: el grid mostraría el total mientras la venta descuenta del Bar, que
es la peor combinación posible.

### Qué ve la POS, según cómo esté configurado el negocio

| Negocio | Producto | Qué muestra el grid |
|---|---|---|
| Sin bandera y sin bodega marcada | cualquiera | **la suma de todas** (comportamiento histórico) |
| Con una bodega marcada `shows_in_pos` | sin área | solo esa bodega |
| Con la bandera de áreas prendida | con área | solo la bodega de su área |
| Con la bandera de áreas prendida | **sin área** | solo la bodega principal |

La última fila es la que se corrigió el 2026-08-31. Antes, un producto sin área
mostraba la suma de todas las bodegas mientras la venta le descontaba solo de
la principal: el grid prometía existencia que la venta no podía sacar de ahí y
la principal se iba a negativo con mercancía sobrando en las otras.

Las **tres puntas usan el mismo respaldo**: la vista, `consume_inventory_from_order`
y `fn_recompute_menu_items_availability`. Con criterios distintos, el auto-86
dejaría activo lo que el grid ya está bloqueando.

**Aviso al prender la bandera sin haber asignado áreas:** todos los productos
caen en la bodega principal y la POS deja de ver lo que hay en las demás. Es
coherente con lo que ya hacía la venta, pero es un cambio visible. La consulta
3 de `supabase/CONFIGURAR_areas_por_almacen.sql` lo muestra antes de prender.

### F1c — Varias bodegas en el punto de venta, con cascada (2026-08-31)

Decisión del dueño después de discutirlo: poder marcar la casilla en **varias**
bodegas, que el grid muestre la **suma** y que la venta descuente de la
principal primero y siga con la siguiente.

Se le advirtió el riesgo y lo reafirmó, así que se construyó — pero resolviendo
el problema de fondo en vez de sólo levantar el índice único.

**Por qué no alcanzaba con `drop index`:** la reconciliación trabaja por par
(insumo, bodega) y resolvía UNA bodega por producto. La barra tiene 6, se
venden 10, la resolución salta a la nevera → la reconciliación **devuelve los 6
a la barra y descuenta los 10 de la nevera**. Nevera en −10 y barra con
existencia ya vendida.

**`20260901_0006_pos_multi_warehouse.sql`:**
- `fn_resolve_area_warehouse` — la bodega del área, o NULL. Separada para
  distinguir «resolvió por área» de «cayó en la cascada».
- `fn_pos_stock_warehouses` — el conjunto **ordenado**: `[la del área]` si
  tiene, las marcadas en orden de cascada si no, NULL = todas.
- La vista y el auto-86 suman sobre ese conjunto.
- `consume_inventory_from_order` **reparte en cascada**: waterfall con
  funciones de ventana, la última bodega absorbe el excedente.

**El cupo de cada bodega es la existencia COMO SI esta orden no hubiera
pasado** (`stock + lo que esta orden ya le sacó`, menos lo reservado por área
en esa misma bodega). Sin eso, cada recálculo correría el reparto solo —la
bodega ya descontada parecería más vacía— y los movimientos rebotarían.

**Lo que sigue sin poder hacerse:** otras órdenes sí mueven el cupo entre
recálculos, así que el reparto de una orden **abierta** puede ajustarse
mientras esté abierta. Es correcto (refleja la existencia real) pero deja
rastro en el kardex.

**Sin probar contra un servidor** — no hay Postgres local. Verificación sobre
datos reales: `supabase/VERIFICAR_cascada.sql`, cuya consulta 4 es la prueba de
fuego: una venta que supere la existencia de la primera bodega tiene que salir
en **dos** movimientos, no en uno.

App: se quitó `_clearPosSource` (ya no hay que desmarcar la anterior) y se
reescribió el texto de la casilla.

### Cuándo usar cada mecanismo (caso real, 2026-08-31)

Hay dos formas de decidir de qué bodega sale un producto y **no compiten**:
resuelven problemas distintos.

**Bodega del punto de venta (`shows_in_pos`)** — una sola por negocio. Para el
negocio que piensa «el punto de venta es el Bar, el otro es el depósito».
Una casilla, sin rutear nada.

**Área de producción** — resuelve POR PRODUCTO. Para el negocio donde el mismo
insumo se vende de dos formas: *Brugal botella* sale del Food Shop y *Brugal
trago* del Bar. Son dos `menu_items` distintos sobre el mismo
`inventory_item`, y cada uno tiene que leer de su bodega.

**Por qué NO se pueden marcar dos bodegas para la POS y sumarlas:** en el caso
del Brugal, la suma mostraría el mismo total en los dos productos y ninguno
diría la verdad. El problema no es «cuánto hay en total», es «cuánto hay del
lado que corresponde a ESTE producto». El índice único que impide marcar dos
no es una limitación a levantar: es la regla correcta.

Guía de puesta en marcha por áreas: `supabase/CONFIGURAR_areas_por_almacen.sql`
— su consulta 3 simula, sin prender la bandera, qué bodega y qué número va a
ver cada producto, contra lo que muestra hoy.

El interruptor de la bandera **vuelve a estar visible** en Ajustes → Funciones del
negocio: ya no es inerte (0002 y 0003 están en producción) y hay un caso real
que lo necesita.

### F2 — Requisición — MOTOR LISTO (2026-09-01), interfaz pendiente

`20260902_0001_requisitions.sql` (+ ROLLBACK), sin aplicar:

- Tablas `requisitions` / `requisition_lines`, con `pending → partial |
  dispatched → received`, y `cancelled` sólo desde `pending` (después del
  despacho ya hay mercancía moviéndose: eso sería una devolución, no una
  cancelación).
- **El stock se mueve en el despacho, reusando `fn_inventory_transfer_send`.**
  La requisición es el documento y la autorización; la transferencia es el
  asiento. Con dos motores de movimientos se desincronizarían al primer
  cambio.
- `fn_can_dispatch_warehouse` — el candado del responsable, **en la base**.
  Owner y admin siempre pueden (si el responsable no está, la operación no se
  tranca) y una bodega sin responsable no restringe a nadie.
- **Despachar exige ser el responsable Y tener rol owner/admin/manager**,
  porque es lo que ya pide `fn_inventory_transfer_send`. Se comprueba en el
  RPC de la requisición para fallar con mensaje claro antes de escribir nada,
  en vez de reventar a mitad. Si hiciera falta que despache un empleado de rol
  menor, hay que tocar el gate de la función de transferencias — decisión
  aparte.
- `dispatched_qty`: NULL = sin despachar; **0 = se despachó y de eso no
  había**. Son respuestas distintas y el faltante (`requested - dispatched`)
  queda a la vista para reclamarlo.
- Al recibir se cierra la transferencia con lo realmente recibido, que es lo
  que saca la mercancía de `__IN_TRANSIT__`. `p_lines` sólo hace falta para
  declarar una diferencia.
- RLS de sólo lectura: **toda escritura pasa por los RPC**, que son los que
  aplican el candado.
- Los tres permisos quedan insertados **en el catálogo de la BD**, no sólo en
  Flutter — un código ausente ahí lo descarta en silencio el join del RPC y el
  gate no deja pasar a nadie.

**Interfaz (2026-09-01, sin commit):** `Inventario → Requisiciones`, ruta
`/inventory/requisitions`.

- **Bandeja con tres pestañas que son tres roles** mirando la misma tabla:
  «Por despachar» le habla al almacén, «Por recibir» a quien pidió,
  «Historial» a nadie en particular.
- **Pedir mercancía**: elige a quién le pide y para qué bodega, y al lado de
  cada cantidad muestra *cuánto hay en la bodega de origen*. No bloquea pedir
  de más —el almacén decide qué entrega— pero evita el pedido a ciegas.
- **Despachar**: propone entregar lo pedido pero **nunca más de lo que hay**
  (sugerir un número imposible sólo produce un error al guardar), avisa en
  amarillo cuando el despacho va a quedar parcial, y valida contra la
  existencia antes de mandar.
- Los códigos de error del RPC se traducen: `NOT_WAREHOUSE_KEEPER` sale como
  «Solo el responsable de la bodega de origen puede despachar». Un código
  crudo no le dice a nadie qué hacer.
- Si falta la migración, la pantalla lo dice en vez de mostrar una lista vacía
  que parece «no hay pedidos».

**El documento (2026-09-01):** A4, no térmico. Es el papel que se firma y se
archiva, y lleva **dos firmas al pie** — «Encargado de área» y «Encargado de
almacén principal» —, que fue el pedido explícito del dueño.

- `lib/presentation/inventory/services/requisition_pdf.dart`, botón en cada
  tarjeta de la bandeja.
- Debajo de cada línea de firma va el nombre del responsable de esa bodega si
  está configurado; si no, va el nombre de la bodega y la raya queda para
  escribirlo a mano. **El documento no puede depender de que alguien haya
  llenado el campo.**
- Las columnas «Despachado» y «Faltante» sólo aparecen **después** del
  despacho: antes, todas las líneas figurarían como faltantes de su totalidad.
  Y el faltante se imprime sólo donde lo hay — una columna llena de ceros
  esconde justo el renglón que hay que reclamar.
- El texto se sanea (em-dash, flechas, elipsis): la fuente base del PDF es
  Helvetica WinAnsi y esos glifos saldrían como cuadros. Mismo criterio que
  `ReportExporter`.

**F2 COMPLETA.**

### F3 — Compra
- Pantalla de mínimos masiva con filtros por almacén, proveedor y categoría.
- Mínimo sugerido a partir de `fn_inventory_rotation_analysis`.
- Importación Excel del maestro (la exportación ya existe).
- Catálogo por suplidor con precios y presentaciones.
- Proyección: `consumo_diario × (cobertura + lead_time) − stock − en_tránsito`.
- Filtro de suplidor en reorden, alertas y maestro.
- Comparador de precios y generación de una OC por suplidor de un golpe.

### F4 — Mermas
- Documento de merma con aprobación y traslado al Almacén de Mermas.
- Reporte de merma del mes valuada, por área y por motivo.

### F5 — Gastables
- Recetas de empaque con la casilla de "también en el local".
- Consumo automático por `is_takeout`.

### F6 — Recetarios
- Sub-recetas anidadas (los datos ya existen), con control de recursión.
- Costo por porción, margen y alerta cuando el costo sube.
- Rendimiento y merma de receta (1 kg crudo → 800 g limpio).
- Ficha técnica imprimible con foto y pasos.

### F7 — Activos fijos
- Catálogo, asignación, estados, historial de movimientos.

### F8 — Préstamos
- Salida con devolución pendiente, comprobantes y vista de saldo.

---

## 7. Riesgos

1. **El consumo por área toca el corazón del inventario.** Un error deja de
   descontar o descuenta doble, y no se nota hasta el conteo de fin de mes. Va
   detrás de bandera, con pruebas y un negocio piloto.
2. **Productos en varias áreas** (un combo que sale de cocina y bar): hay que
   elegir de cuál bodega descontar cada insumo. La regla de la Fase 1 es
   determinista y auditable, pero la solución fina es asignar el insumo al área,
   no el producto. Queda anotado para una fase posterior.
3. **La base viva diverge de las migraciones del repo.** Verificar con
   `pg_get_functiondef` antes de reemplazar cualquier función de consumo.
4. **Hay migraciones escritas y sin aplicar** que este PRD da por puestas
   (`20260819_0001`, `0002`, `0003`). Aplicarlas es parte de F0.
5. **El candado por responsable puede trancar la operación** si Jesús no está.
   Admin y dueño siempre pueden; se registra en la bitácora quién saltó el candado.

---

## 8. Qué NO entra

- Depreciación contable de activos fijos.
- Proyección con estacionalidad por día de semana (se evalúa cuando haya 6
  semanas de historia limpia con el consumo por área andando).
- Asignación de insumos a área (en vez de productos a área).
- Compra automática: el sistema sugiere, Santiago decide.

---

## 9. Arranque real: el conteo de mañana

El negocio opera hoy con **un solo almacén**. Mañana se hace el primer conteo
físico sobre ese almacén y durante la semana se crean Cocina, Bar, Food Shop,
Mermas y Estancia Nueva.

Con un solo almacén el sistema se comporta exactamente como hoy: la venta
descuenta del principal y no hay nada que resolver por área. **Eso es lo
correcto** — el conteo de mañana no necesita ninguna de las fases de este PRD y
no se debe tocar nada del motor de consumo antes de tenerlo cuadrado.

### 9.1 Verificado: el conteo está listo

`20260801_0002_physical_count_blind_recount.sql` **sí está aplicada en
producción** (verificado 2026-08-31 contra `pg_proc` e
`information_schema.columns`):

- `fn_physical_count_create` existe **una sola vez** con los 4 argumentos
  (`p_business_id, p_warehouse_id, p_notes, p_is_blind`). Sin sobrecarga vieja
  conviviendo, así que no hay riesgo de `PGRST203` por ambigüedad.
- `fn_physical_count_request_recount(uuid, uuid[])` existe — el recuento de
  segunda vuelta funciona.
- Columnas puestas: `is_blind` en sesiones; `first_count_quantity`,
  `recount_requested`, `recounted_at`, `stock_at_complete`,
  `applied_variance`, `unit_cost` y `variance_value` en líneas.

Eso significa que el conteo de mañana tiene lo que necesita:

- **Modo a ciegas**: quien cuenta no ve el stock del sistema.
- **Ajuste contra stock vivo**: el stock termina exactamente en lo contado,
  aunque se venda algo entre congelar y completar.
- **Congelado completo**: entran todos los insumos activos, no solo los que ya
  tienen fila de stock. En un primer conteo eso es lo que permite registrar los
  sobrantes que el sistema nunca supo que existían.
- **Valuación**: congela el costo y calcula el valor de la diferencia.

La consulta de verificación queda en `supabase/VERIFICAR_conteo_fisico.sql` para
correrla en cualquier otro negocio antes de su primer conteo. **Correr una
sentencia a la vez**: el SQL Editor de Supabase solo muestra el resultado de la
última.

### 9.2 Orden de la semana

1. **Hoy:** ✅ verificado, `20260801_0002` está aplicada. Queda probar crear
   una sesión de conteo a ciegas contra el almacén único y revisar unidades y
   costos del catálogo (ver §9.3).
2. **Mañana:** conteo del almacén único, con el negocio cerrado o antes de
   abrir. Aunque el ajuste ahora es contra stock vivo, contar mientras se vende
   obliga a perseguir el movimiento.
3. **Después del conteo:** aplicar `20260819_0001` (mínimo por bodega),
   `20260819_0002` (copiar lista de insumos) y `20260819_0003` (términos y
   catálogo de suplidores). Ninguna cambia comportamiento con un solo almacén.
4. **Durante la semana:** F0 — crear los cinco almacenes restantes con su tipo,
   su responsable y su área de producción. **La bandera sigue apagada**: los
   almacenes existen y se pueden llenar, pero la venta sigue descontando del
   General. Es la única forma de poblarlos sin descuadrar.
5. **Cuando Cocina, Bar y Food Shop tengan stock real** (por conteo o por
   requisición): recién ahí se prende la bandera y arranca F1.

El orden importa: prender el consumo por área con las bodegas de producción en
cero manda a Cocina a stock negativo desde la primera venta.

### 9.3 Lo que sí conviene revisar antes de contar

Ya no hay bloqueador técnico, pero un primer conteo se tuerce por otras vías:

- **Unidades ambiguas.** Los insumos que quedaron en `unidad` genérica se
  cuentan mal: quien cuenta no sabe si anota botellas, onzas o mililitros.
  Revisar los que no tienen unidad real antes de imprimir la hoja de conteo.
- **Insumos con costo cero.** El conteo igual funciona, pero la valuación de la
  diferencia sale en cero y se pierde la mitad del valor del ejercicio.
- **Sesiones de conteo abiertas.** Si quedó una sin completar ni cancelar,
  estorba. Se revisa con la consulta 5 del archivo de verificación.
- **Contar con el negocio cerrado.** El ajuste ahora es contra stock vivo, así
  que no se descuadra — pero contar mientras se vende obliga a perseguir el
  movimiento.
