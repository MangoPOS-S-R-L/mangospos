# Carga de catálogo — BARRA PAYÁN BEIBOLISTA

Negocio: `e0aef218-ab95-4ba4-b8ef-036fab1c07c7`
Fuente: dos fotos del menú impreso (2026-09-07). No hay CSV ni export de POS.

## Cómo se corre

**Un solo archivo: [`IMPORT_COMPLETO.sql`](IMPORT_COMPLETO.sql).** Pégalo entero
en el SQL Editor de Supabase y dale Run.

Va en **una sola transacción con la verificación adentro**: si al terminar
falta un producto, o alguno queda sin ITBIS, sin área, con el área legacy en
desacuerdo con la N:M, en `exclusive`, o con nombre duplicado — lanza excepción
y **revierte entero**. No puede dejar el catálogo a medias.

Se puede re-correr: inserta con `NOT EXISTS` contra `lower(name)`, así que no
duplica. Lo que **no** hace es actualizar precios ya cargados; para eso está
`07_ajuste_precios.sql`.

| Archivo | Para qué |
|---|---|
| **`IMPORT_COMPLETO.sql`** | **La carga. Es el único que necesitas.** |
| `99_rollback.sql` | Deshace todo. Aborta solo si algún producto ya se vendió. |
| `07_ajuste_precios.sql` | Corregir precios después de cargados |
| `00_diagnostico.sql` | Ya corrido ✅ (resultado abajo) |
| `por_pasos/` | Los mismos pasos separados, por si hace falta depurar uno |

Se regenera con `python3 scripts/build_import_e0aef218.py` (edita el `.py`, no
el `.sql`).

## Resumen

| | |
|---|---|
| **Productos** | **54** |
| Categorías | 4 |
| Sándwiches + Otros → SANDWICHERA | 14 |
| Jugos + Bebidas → JUGUERA | 40 |
| Modificadores | 5 "Adicionales", en los 10 sándwiches |
| Impuesto | ITBIS 18% **incluido en el precio** (`tax_mode='inclusive'`) |
| Inventario | ninguno — el menú no trae costos (`inventory_mode='none'`) |

## ✅ Diagnóstico previo — 2026-09-07

| Chequeo | Resultado |
|---|---|
| Negocio | BARRA PAYAN BEIBOLISTA · Restaurante · RD · `active` |
| ITBIS 18% | existe, activo, `is_service_fee = false` ✓ |
| Canales del ITBIS | zona, manual, venta rápida, para llevar, delivery — los 5 |
| Áreas | `juguera` y `sandwichera`, activas, **0 impresoras** ⚠ |
| Catálogo previo | vacío — sin riesgo de duplicados |
| `service_fee_enabled` | `false` ✓ (no cobran Ley 10%) |
| `currency_code` | DOP |

## ⚠ Seis precios por confirmar

La columna de precios de **OTRAS BEBIDAS** está tachada y desgastada en la
foto. Estos seis los leí con poca certeza; dos me huelen raro:

| Producto | Puse | Duda |
|---|---|---|
| Agua | 175 | ¿$175 el agua? Podría ser $75 |
| Café Dominicano | 225 | Sale más caro que el Café con Leche ($175). ¿$125? |
| Leche | 145 | se lee entre 145 y 175 |
| Chocolate | 175 | borroso |
| Cortadito | 225 | borroso |
| Expreso | 225 | borroso |

Los otros 48 se leen sin ambigüedad. Dos caminos: corregirlos en el `.py` y
regenerar **antes** de cargar, o cargar ya y ajustarlos después con
`07_ajuste_precios.sql`.

## Decisiones tomadas

**Precios con impuesto dentro.** "Impuestos incluidos" → los 54 con
`tax_mode='inclusive'` y vinculados al ITBIS. El Club Sándwich de $450 se cobra
$450; el ITBIS se desglosa hacia adentro (base $381.36 + ITBIS $68.64).
Verificado contra `fn_compute_item_totals`:
`subtotal = line_amount / (1 + rate/100)`. En `exclusive` el POS cobraría $531
y el menú sería mentira.

**El vínculo del impuesto no es cosmético.** `menu_item_taxes` es la ÚNICA
fuente del impuesto por producto desde el PRD 2.5 — ya no hay fallback a
`default_tax_rate` (aunque el negocio lo tenga en 18). Un producto sin fila ahí
factura **ITBIS 0.00 ante la DGII**. Por eso la verificación interna aborta si
queda uno solo sin vincular.

**Ley 10%: no se cobra.** No se vincula impuesto de servicio, y el script
aborta si alguien encendió `is_service_fee` o `service_fee_enabled`.

**Jugos: 2 productos por sabor.** NAT y CA son Natural (en agua) y Con Leche.
No se pueden modelar como producto + modificador porque la diferencia no es
fija: $25 en unos sabores, $50 en otros.

**Adicionales: modificadores.** Así el extra viaja pegado al sándwich —sale
debajo de su ítem en la comanda de la SANDWICHERA— en vez de ser una línea
suelta que el cocinero no sabe a cuál de los tres sándwiches de la mesa
pertenece. `fn_compute_item_totals` suma `mods_total` **antes** de extraer el
impuesto, así que los adicionales también quedan con el ITBIS dentro.

**Áreas: se resuelven por nombre.** Se escriben **los dos** mecanismos a
propósito: la N:M `menu_item_print_areas` (fuente de verdad) y el legacy
`print_area_code`, que `fn_add_item_from_menu` copia al `order_item`. El lookup
N:M tiene timeout online — sin el legacy correcto, un bache de red manda los
sándwiches a la juguera.

## Catálogo

### Sándwiches → SANDWICHERA

| Producto | Precio |
|---|---|
| Club Sándwich | 450 |
| Payán Especial | 310 |
| Sándwich Completo | 295 |
| Sándwich de Pierna | 295 |
| Sándwich de Pollo | 295 |
| Juancito Caminador | 250 |
| Sándwich de Jamón y Queso | 250 |
| Sándwich de Huevo y Queso | 250 |
| Sándwich de Salami y Queso | 250 |
| Derretido de Queso | 250 |

Las descripciones del menú van en `description`. La del Sándwich de Jamón y
Queso está tapada en la foto ("Jamón de pierna c…"); puse "Jamón de pierna,
queso danés o cheddar y salsas."

### Otros → SANDWICHERA

Tostada Especial 200 · Tostada 50 · Tostada de Ajo 60 · Servicio de Papas 120

### Jugos → JUGUERA (14 sabores × 2 = 28)

| Sabor | Natural | Con Leche |
|---|---|---|
| Limón | 150 | 175 |
| Chinola | 175 | 225 |
| Tamarindo | 125 | 175 |
| Cereza | 125 | 175 |
| Piña | 125 | 175 |
| Melón | 125 | 175 |
| Guineo | 125 | 175 |
| Fresa | 175 | 225 |
| Granadillo | 175 | 225 |
| Lechoza | 125 | 175 |
| Zapote | 125 | 175 |
| China | 175 | 225 |
| Mango | 175 | 225 |
| Pitahaya | 175 | 225 |

### Bebidas → JUGUERA

Agua 175 ⚠ · Refresco 175 · Leche 145 ⚠ · Café con Leche 175 ·
Capuccino Italiano 175 · Capuccino Caramelo 225 · Capuccino Suizo 225 ·
Mocachino 175 · Chocolate 175 ⚠ · Café Dominicano 225 ⚠ · Cortadito 225 ⚠ ·
Expreso 225 ⚠

### Adicionales (modificadores de los 10 sándwiches)

Queso cheddar o danés +95 · Pollo o Pierna +100 · Jamón +75 · Salami +55 ·
Huevo +30

`min_select 0 / max_select 5`: todos opcionales, se pueden elegir varios.
`max_qty_per_option` queda en 1 — para "2 huevos" hay que añadir el modificador
dos veces.

Las tostadas y las papas quedaron **fuera** del grupo. Si también llevan
adicionales, se agregan a `SANDWICHES` en el `.py`.

## Pendientes que este script NO resuelve

1. **JUGUERA y SANDWICHERA no tienen impresora vinculada.** Y el negocio tiene
   `auto_print_order = true`, así que el POS va a intentar imprimir la comanda
   en cada orden y no va a salir por ningún lado. Se vincula en
   Ajustes → Impresoras → Comandas por impresora.
2. **Sin inventario ni costos.** El menú no los trae y `inventory_mode='none'`.
   Si quieren descontar existencias hay que armar recetas aparte.
3. **Sin SKU ni códigos de barra.** No aplican a este negocio.

## Nota técnica

`menu_item_groups` puede tener una columna `position` en la BD viva que no está
en las migraciones del repo (el código Dart la lee). El script no la
especifica, contando con que tenga default. Si el INSERT falla por eso, la
transacción revierte sola y no queda nada a medias.
