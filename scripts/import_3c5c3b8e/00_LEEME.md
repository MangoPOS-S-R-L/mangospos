# Carga del catálogo: 007 BAR & SNACK

- **Negocio:** `3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c`. 007 BAR & SNACK, SRL, RNC 131-83115-1,
  Aut. Duarte Km 10½, Puñal, Santiago.
- **Fuente:** `PRODUCTOS 007.pdf`, el "Listado de artículos" del sistema anterior
  (14/09/2026 18:29) con 828 artículos. Trae código, costo, precio y existencia, pero
  **ninguna categoría**: las categorías las asignó el generador por palabra clave.

## ✅ Corrido en producción (15/09/2026)

Se corrió `IMPORT_COMPLETO.sql` sin el diagnóstico previo. El reporte salió con las 15 filas
en ✓: 828 productos (822 activos y 6 inactivos), 828 con solo el ITBIS 18% incluido, 828 en
el menú, 822 insumos, 181 existencias (2,955 unidades, RD$247,332.65), `inventory_mode = basic`,
771 códigos de barras y 0 repetidos.

**Ojo con el área:** Cocina estaba **encendida** y la única área que no es de sistema era
**CAJA (`caja`)**, con 1 impresora. Por la regla de "una sola área activa", los 828 productos
quedaron ruteados a CAJA.

Revisado después, sin problema:
- `printerless_kitchen = true`: la comanda **no sale en papel**, así que no hay doble ticket.
- Hay una sola impresora USB, "CAJA", conectada a las 4 áreas: `caja`, `cashier`, `fiscal`
  y `cash_close`.
- El negocio está registrado como `business_type = 'Bar / Lounge'` (no tiene el preset de
  tienda) y tiene `auto_print_order = true`.

Si operan como tienda, lo limpio es apagar Cocina desde la app. No hace falta tocar los productos.

## Cómo se corre

1. **`00_diagnostico.sql`** solo lee. Pégame el resultado.
2. **`IMPORT_COMPLETO.sql`** es la carga. Pégalo entero en el SQL Editor de Supabase y dale
   Run. Al final sale un reporte de 15 filas y todas deben decir ✓.
3. Después, cada caja tiene que volver a bajar el catálogo antes de escanear sin internet.
   El snapshot offline es de antes de la carga.

| Archivo | Para qué |
|---|---|
| `00_diagnostico.sql` | Negocio, impuestos, áreas, `kitchen_enabled`, bodegas, catálogo previo, columnas vivas |
| **`IMPORT_COMPLETO.sql`** | **La carga, en una sola transacción** (generado) |
| `99_rollback.sql` | La deshace. Aborta si algo ya se vendió o ya tuvo movimientos (generado) |
| `catalogo_revision.csv` | Una fila por producto: categoría, precio, costo, existencia, código de barras |
| `build_import_3c5c3b8e.py` | Lee el PDF y genera los dos `.sql` y el `.csv` desde `_tpl_*.sql` |
| `ensayo/` | Stub del esquema y `run_tests.sh` con los 16 escenarios |

**No edites los `.sql` generados.** Cambia reglas, correcciones o inactivos en el `.py` y
regenera:

```bash
python3 scripts/import_3c5c3b8e/build_import_3c5c3b8e.py "~/Downloads/PRODUCTOS 007.pdf"
```

Hace falta `pdftotext` de poppler. Sin `-layout`, `pdftotext` intercambia las columnas
Precio y Existencia, y el `.py` ya lo usa con `-layout`. Además aborta si lee un total
distinto de 828 o si queda algún producto sin categoría.

## Decisiones del dueño (15/09/2026)

| | |
|---|---|
| Catálogo | **Son los 828.** El listado no trae códigos 746 (Presidente, Brugal); se confirmó que no falta nada |
| Impuesto | ITBIS 18% **incluido** (`inclusive`). Trident Menta a $30 queda en base 25.42 + ITBIS 4.58. **Sin Ley 10%** |
| Inventario | **Inventario + existencia.** Los 822 activos llevan su insumo 1:1 (vendes 1, descuenta 1). Entra la existencia positiva y los 39 negativos entran en 0 |
| No mercancía | **Inactivos y sin inventario:** RENTA DE LOCAL ($30,000), BOTELLAS VACIAS, EMBUDO USO INTERNO, REFRIGERIO,JUGOS (costo 8,443 contra precio 1,375), AMPICILLIN y SANTA CXAROLINA MERLOT RESERVA (precio 0) |

## Qué escribe

- **Productos (`menu_items`):**
  - precio del listado y `tax_mode = 'inclusive'`;
  - costo, en `null` si el listado dice 0 (un 0 daría 100% de margen);
  - `sku` con el código del listado y `barcode` cuando el código es un GTIN;
  - `is_beverage` para las 7 categorías de bebidas;
  - `allow_negative_sale = true`.
- **`menu_item_taxes`:** solo el ITBIS. Sin esa fila la factura sale con ITBIS 0.00.
  Si el producto ya tenía otro impuesto vinculado, se le quita.
- **`menu_item_links`:** sin esta fila el producto no aparece en la caja. Reusa el menú
  activo o crea "Menú Principal". Aborta si hay más de uno.
- **Área de comanda:** ver abajo.
- **Inventario:**
  - un `inventory_items` por producto (`sku` = código) y el link directo
    `menu_items.inventory_item_id`, sin recetas;
  - la existencia inicial como movimiento `purchase` con `reference_type = 'initial_stock'`,
    una sola vez por insumo;
  - si `inventory_mode` está en `none`, lo pasa a `basic`. En `none` la venta no descuenta nada.

**Empareja por código, no por nombre.** El listado trae 8 nombres repetidos con códigos
distintos. Por nombre, los dos MUSCLE MILK compartirían insumo y vender uno descontaría el otro.

**Se puede volver a correr.** Un producto que ya existe se actualiza en precio, costo,
categoría, ITBIS, código de barras y área. **Conserva su nombre** y **no se reactiva** si lo
apagaste en la app. La existencia inicial no se vuelve a sumar.

### Por qué `allow_negative_sale = true`

608 productos arrancan en 0 porque el listado no los tenía contados. Hoy el auto-86 solo
apaga productos con **receta** (así lo dice el comentario de `fn_recompute_menu_items_availability`
en la mig 20260901_0006), y estos van por link directo, así que no desaparecerían. Aun así
se marca el flag para que no dependa de eso: el día que el auto-86 cubra el link directo,
media tienda desaparecería de la caja al primer escaneo.

### Bodega

La existencia entra en **la misma bodega de la que descuenta la venta**, con el mismo
`ORDER BY` de `consume_inventory_from_order`: `is_main desc, created_at asc nulls first, id asc`.
Si esa bodega está desactivada o es `__IN_TRANSIT__`, la carga aborta. Si no hay ninguna,
también aborta: la bodega no se crea.

## Área de comanda

| Situación del negocio | Qué hace |
|---|---|
| `kitchen_enabled = false` (el preset de tienda) | **Ninguna área.** La venta marca los ítems como listos sin comanda (`markOrderItemsAsReady`) |
| Cocina encendida y existe `bar` o `barra` | Todo va a esa área |
| Cocina encendida y hay una sola área activa | Todo va a esa área |
| Cocina encendida y **ninguna** área | **Aborta.** Cada venta fallaría con "productos sin área". Apaga Cocina o crea "Barra" |
| Cocina encendida y varias áreas, ninguna `bar`/`barra` | **Aborta** y lista las áreas |

Las áreas de sistema (`cashier`, `fiscal`, `cash_close`) no cuentan. Se escriben los dos
mecanismos, `menu_item_print_areas` y el legacy `print_area_code`, de acuerdo entre sí.

## Categorías (20)

| # | Categoría | Productos | | # | Categoría | Productos |
|---|---|---|---|---|---|---|
| 10 | Cervezas | 31 | | 110 | Chicles y caramelos | 47 |
| 20 | Licores | 29 | | 120 | Dulces típicos | 24 |
| 30 | Vinos y espumantes | 144 | | 130 | Barras de proteína | 24 |
| 40 | Premix y cócteles | 21 | | 140 | Despensa | 25 |
| 50 | Refrescos y energizantes | 32 | | 150 | Comida y helados | 2 |
| 60 | Jugos, tés y lácteos | 101 | | 160 | Cigarrillos y tabaco | 28 |
| 70 | Aguas | 17 | | 170 | Vapes | 19 |
| 80 | Snacks salados | 57 | | 180 | Farmacia, higiene y hogar | 19 |
| 90 | Galletas y bizcochos | 88 | | 190 | Automotriz | 79 |
| 100 | Chocolates | 24 | | 200 | Misceláneos | 17 |

Dentro de cada categoría van en orden alfabético. Las reglas son del `.py`; 7 productos
llevan corrección por código (BRUSCHETTINI y FOCACCIBITES cayeron en Automotriz por "OIL", las
aguas S. BERNARDO en Cervezas por "BERNARD", etc.). Para mover uno, agrega su código a
`CORRECCIONES` y regenera.

## Códigos de barras

- **771 con código de barras**, cotejados con el dígito de control.
- **21 de 11 dígitos entran con un 0 delante.** Son UPC-A a los que el sistema anterior les
  quitó el 0 inicial. Con el 0 validan, y así los emite la pistola: `76333113939` queda como
  `076333113939`. El código original queda en `sku`.
- **57 códigos internos** (de 2 a 7 dígitos: los dulces DR./D.R, 7UP LATA `780380`…) van solo
  en `sku`. La pistola también lee `sku`.
- **16 con dígito de control inválido** entran igual: casi todos de la serie interna
  `842332998121xx` (correas, silicón, cintas), más `784350600391` y `809552099283`.
- **`79033050072` RICA JUGO DE MANZANA LITRO** es un código roto: no valida ni con el 0 y
  queda sin código de barras. Ver punto 3 abajo.

## Para revisar con el dueño (no frenan la carga)

1. **Dulces típicos en dos juegos:** `DR.` (8020–8031, $155–200, casi sin existencia) y
   `D.R` (810–821, $70–225, con existencia). Parecen los mismos dulces con dos juegos de
   códigos y precios: PASTA DE LECHE RELL. NARANJA sale a $180 en `8022` y a $190 en `810`.
   Entran los 24.
2. **Nombres repetidos** (entran los dos, cada uno con su código):

   | Nombre | Códigos |
   |---|---|
   | CONCHA Y TORO CABERT 375ML | 7804320046044 $180 · 7804320688480 $210 |
   | SANTA CAROLINA SAUVIGNON BLANC | 7804350596328 $450 · 7804350600155 $195 |
   | MUSCLE MILK | 876063005951 $220 · 876063005968 $220 |
   | RICA NARANJA BANANA | 790330005133 $100 · 790330021805 $40 |
   | RICA NECTAR DE GUAYABA | 790330050065 $20 · 790330050607 $30 |
   | ROLLINO PISTACCHO | 8001585010103 $45 · 80633051 $45 |
   | QUEST PROTEIN BAR CHOCOLATE | 888849000418 $325 · 888849000456 $215 |
   | QUEST PROTEIN CARAMELO | 888849003495 $345 · 888849010103 $380 |

3. **RICA JUGO DE MANZANA LITRO** (`79033050072`, $85) parece la misma **RICA MANZANA LITRO**
   (`790330050072`, $90) con un dígito de menos.
4. **Activos con costo mayor o igual al precio** (se venden con pérdida):

   | Código | Producto | Costo | Precio |
   |---|---|---|---|
   | 797496862341 | TRANS TAPA-FUGAS | 1,464.75 | 100.00 |
   | 7788 | NESCAFE COOKIS CREAN | 1,632.82 | 1,000.00 |
   | 7804330983438 | SANTA RITA 120 1/2 SAUVIGNON BANC | 460.45 | 175.00 |
   | 840004098302 | AVENGERS MARTILLO DULCE | 105.00 | 75.00 |
   | 790690070154 | CONSTANZA MENTOL GRANDE | 115.25 | 95.00 |
   | 7702027402777 | NOSOTRAS TOALLAS NATURAL | 32.30 | 15.00 |
   | 7702026016616 | PAPEL DE BAÑOFAMILIA 2EN 1 | 38.14 | 25.00 |
   | 790330050041 | RICA NECTAR DE PERA 250 ML. | 20.94 | 20.00 |
   | 7750168002240 · 7891233 · 7702133853265 | OREO CHOCOLATE · GAROTO · CERTS AQUA SANDIA | = precio | |

5. **Activos sin costo** (el margen sale vacío): CARLSBERG LATA 330ML, PALO ALTO RESERV. MERLOT
   ($1,000), GALLETAS BUTTER COOKIES `8901972071888`, FRUTINAS GOMITAS y SILICON GUNK.
6. **39 negativos que entran en 0 y hay que contar.** Los más grandes: GALLETA DE AVENA −18,
   MAS-MAS CHOCOLATE −16, MILK CHOCOLATE BARRA −15, NOSOTRAS TOALLAS NATURAL −13,
   VIVE.100.ROJO.GRANDE −10, TRIDENT X SPLASH SANDIA −9 y NUTRI SNACKS MACADAMIA −8. La lista
   completa sale del `.csv` (existencia_listado < 0).
7. **HOD-DOG** ($65) es preparado. Con Cocina apagada no sale comanda: si lo preparan en otro
   lado, que lo sepan.

**Existencia que entra:** 181 productos, 2,955 unidades y RD$247,332.65 a costo. Lo que más
pesa: HEINEKEN GRANDE 152 u (RD$22,547), RED BULL 12 ONZ 99 u (RD$9,801) y OLI GELATINA
480 u (RD$9,322).

## Ensayo local (15/09/2026)

Se usó Postgres 15 local con un stub del esquema (`ensayo/stub.sql`: tablas de catálogo e
inventario más los triggers `trg_inventory_stock_sync` y `trg_inventory_movement_recost`).
No hay acceso a prod. Pasaron los 16 escenarios:

| Escenario | Resultado |
|---|---|
| S1 Tienda vacía, cocina apagada | 828 productos · 822 activos · 20 categorías · 822 insumos · 181 movimientos · 2,955 u · 828 con ITBIS · 0 áreas · 828 en el menú · `basic`. Reporte 15/15 ✓ |
| S2 Segunda corrida | 0 nuevos y 828 actualizados; ni insumos ni existencia se duplican. 15/15 ✓ |
| S3 Rollback y re-import | Queda en 0, vuelve a 828. 15/15 ✓ |
| S5 Cocina encendida con `bar` y `cocina` | Todo a `bar` (N:M y legacy). Solo sale ✗ en "impresoras", esperado |
| S6 Cocina encendida con una sola área | Usa esa área |
| S13 Catálogo previo: TRIDENT MENTA a $25 con Ley, área `bar`, insumo propio y vendido | Queda en $30, solo ITBIS, sin área, con su insumo reusado (no duplica). El rollback **aborta** por la venta |
| S16 Insumo con un movimiento de venta | El rollback **aborta** |
| S4, S7–S12, S14 · cocina encendida sin área · dos áreas sin bar · sin ITBIS · `service_fee_enabled` · dos menús · sin bodega · bodega desactivada · código repetido en dos productos | **Aborta sin escribir nada** |
| S15 `inventory_mode = 'advanced'` | Se respeta |

## Lo que la carga NO hace

- No crea bodega ni áreas de comanda, y no vincula impresoras.
- No renombra productos que ya existían ni reactiva los que apagaste.
- El rollback no regresa `inventory_mode` a `none` ni borra el menú.
- No corrige los costos ni los duplicados de arriba: eso queda para el dueño.
