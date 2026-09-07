# Import de catálogo — BARRA PAYÁN

Negocio: **BARRA PAYAN BEIBOLISTA** · `e0aef218-ab95-4ba4-b8ef-036fab1c07c7`
Fuente: dos fotos del menú impreso (2026-09-07). No hay CSV ni export de POS.

## Resumen

| | |
|---|---|
| **Productos** | **54** |
| Categorías | 4 |
| Sándwiches / Otros → SANDWICHERA | 14 |
| Jugos / Bebidas → JUGUERA | 40 |
| Modificadores (Adicionales) | 5, enganchados a los 10 sándwiches |
| Impuesto | ITBIS 18% **incluido en el precio** (`tax_mode='inclusive'`) |
| Inventario | ninguno — el menú no trae costos ni existencias |

## Orden de ejecución

| # | Archivo | Qué hace |
|---|---|---|
| 0 | `00_diagnostico.sql` | ✅ **Corrido 2026-09-07, todo verde** (ver abajo) |
| 1 | `01_staging.sql` | Tabla intermedia con los 54 productos |
| 2 | `02_catalogo.sql` | Categorías + productos |
| 3 | `03_impuestos.sql` | Vincula el ITBIS 18% |
| 4 | `04_areas.sql` | JUGUERA / SANDWICHERA (N:M + legacy) |
| 5 | `05_modificadores.sql` | Grupo "Adicionales" |
| 6 | `06_verificacion.sql` | Chequeos + borrado del staging |
| 7 | `07_ajuste_precios.sql` | Opcional: corregir precios ya cargados |

`99_rollback.sql` deshace los pasos 2-5, y **aborta solo** si algún producto ya se vendió.

---

## ✅ Diagnóstico previo — corrido el 2026-09-07

| Chequeo | Resultado |
|---|---|
| Negocio | BARRA PAYAN BEIBOLISTA · Restaurante · RD · `active` |
| ITBIS 18% | existe, activo, `is_service_fee = false` ✓ |
| Canales del ITBIS | zona, manual, venta rápida, para llevar, delivery — los 5 |
| Áreas | `juguera` y `sandwichera`, activas, **0 impresoras** ⚠ |
| Catálogo previo | vacío (0 categorías, 0 productos, 0 grupos) — sin riesgo de duplicados |

Pendiente de revisar: `business_settings.service_fee_enabled` debe estar en `false`.

## ⚠ Antes de correr nada: confírmame 6 precios

En la foto 2, la columna de precios de **OTRAS BEBIDAS** está tachada y
desgastada. Estos 6 los leí con poca certeza — puse mi mejor lectura, pero
dos me huelen raro y los quiero confirmar contigo:

| Producto | Lo que puse | Duda |
|---|---|---|
| Agua | **175** | ¿$175 el agua? Podría ser $75 |
| Leche | **145** | Se lee entre $145 y $175 |
| Chocolate | **175** | Borroso |
| Café Dominicano | **225** | Raro que cueste más que el Café con Leche ($175). ¿Será $125? |
| Cortadito | **225** | Borroso |
| Expreso | **225** | Borroso |

Los otros 48 productos se leen sin ambigüedad.

Dos caminos: corrígemelos y regenero con `python3 scripts/build_import_e0aef218.py`
**antes** de cargar, o carga ya y ajústalos después con `07_ajuste_precios.sql`
(el paso 2 inserta con NOT EXISTS, así que re-correrlo NO pisa precios).

---

## Decisiones tomadas

**Precios con impuesto dentro.** Dijiste "impuestos incluidos", así que los 54
entran con `tax_mode = 'inclusive'` y vinculados al ITBIS 18%. El Club Sándwich
de $450 se cobra $450; el ITBIS se desglosa hacia adentro (base $381.36 +
ITBIS $68.64). Si entraran como `exclusive`, el POS cobraría $531 y el menú
sería mentira.

**El vínculo del impuesto es obligatorio, no cosmético.** `menu_item_taxes` es
la ÚNICA fuente del impuesto por producto desde el PRD 2.5 — ya no hay fallback
a `default_tax_rate`. Un producto sin fila ahí factura **ITBIS 0.00 ante la
DGII** aunque el impuesto exista y esté activo. Por eso los pasos 2 y 3 van
juntos: entre uno y otro el catálogo está fiscalmente roto.

**Ley 10%: no se cobra.** No se vincula ningún impuesto de servicio, y el
paso 3 aborta si `is_service_fee` está encendido. El diagnóstico también revisa
que `business_settings.service_fee_enabled` esté en `false`: encendido cobraría
un 10% por orden que el menú de Barra Payán no anuncia.

**Jugos: 2 productos por sabor.** NAT y CA son Natural (en agua) y Con Leche.
No se pueden modelar como un producto + modificador porque la diferencia no es
fija: es $25 en unos sabores y $50 en otros.

**Adicionales: modificadores.** Así el extra viaja pegado al sándwich —sale
debajo de su ítem en la comanda de la SANDWICHERA— en vez de ser una línea
suelta que el cocinero no sabe a cuál de los tres sándwiches de la mesa
pertenece.

**Áreas: se resuelven por nombre, no por código.** De tu foto solo se conocen
los nombres (JUGUERA / SANDWICHERA); el `code` real se lee de la propia fila.
Se escriben **los dos** mecanismos a propósito: la tabla N:M
`menu_item_print_areas` (fuente de verdad) y el legacy `print_area_code`, que
`fn_add_item_from_menu` copia al `order_item`. El lookup N:M tiene timeout
online — sin el legacy correcto, un bache de red manda los sándwiches a la
juguera.

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

Las descripciones del menú entran en `description`. La del Sándwich de Jamón y
Queso está parcialmente tapada en la foto ("Jamón de pierna c…"); puse
"Jamón de pierna, queso danés o cheddar y salsas."

### Otros → SANDWICHERA

| Producto | Precio |
|---|---|
| Tostada Especial | 200 |
| Tostada | 50 |
| Tostada de Ajo | 60 |
| Servicio de Papas | 120 |

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

| Producto | Precio | |
|---|---|---|
| Agua | 175 | ⚠ confirmar |
| Refresco | 175 | |
| Leche | 145 | ⚠ confirmar |
| Café con Leche | 175 | |
| Capuccino Italiano | 175 | |
| Capuccino Caramelo | 225 | |
| Capuccino Suizo | 225 | |
| Mocachino | 175 | |
| Chocolate | 175 | ⚠ confirmar |
| Café Dominicano | 225 | ⚠ confirmar |
| Cortadito | 225 | ⚠ confirmar |
| Expreso | 225 | ⚠ confirmar |

### Adicionales (modificadores de los 10 sándwiches)

| Opción | +Precio |
|---|---|
| Queso cheddar o danés | 95 |
| Pollo o Pierna | 100 |
| Jamón | 75 |
| Salami | 55 |
| Huevo | 30 |

`min_select 0 / max_select 5`: todos opcionales, se pueden elegir varios.
`max_qty_per_option` queda en su default (1) — para "2 huevos" hay que añadir
el modificador dos veces. Dime si lo quieres distinto.

Las tostadas y las papas quedaron **fuera** del grupo. Si también les ponen
adicionales, se agregan a la lista del paso 5.

---

## Pendientes que NO resuelve este import

1. **Las dos áreas están "Sin impresora"** (se ve en tu foto). La comanda se
   genera pero no sale por ningún lado. Hay que vincular la impresora de cada
   área en Ajustes → Impresoras → Comandas por impresora.
2. ~~El ITBIS 18% tiene que existir y estar activo~~ — confirmado en el
   diagnóstico.
3. **Sin inventario ni costos.** El menú no los trae. Si quieren descontar
   existencias hay que armar recetas aparte.
4. **Sin códigos de barra ni SKU.** No aplican a este negocio.

## Nota técnica

`menu_item_groups` puede tener una columna `position` en la BD viva que no está
en las migraciones del repo (el código Dart la lee). El paso 5 no la
especifica, contando con que tenga default. Si el INSERT falla por eso, la
transacción revierte sola y no queda nada a medias — avísame y la agrego.
