# Import de catálogo — Business 882ef5a4-93eb-4e58-92c3-bf532e179d45

Fuente: `MLYH9X2TGPA28_catalog-2026-08-11-0140.csv` (export de Square, ubicación MONCION).

## Resumen

| | |
|---|---|
| Filas en el CSV | 1520 |
| Descartadas | 4 |
| **Productos a cargar** | **1516** |
| Categorías | 26 |
| Inventariables | 1374 |
| Con stock inicial > 0 | 1132 |
| Con código de barra | 1315 (incluye 33 rescatados del SKU) |
| A barra / a cocina | 1500 / 16 |

## Orden de ejecución

1. `01_staging.sql` — tabla intermedia con el catálogo
2. `02_catalogo.sql` — categorías + productos
3. `03_areas.sql` — áreas de producción (códigos `bar` / `cocina`, ya verificados)
4. `04_inventario.sql` — insumos, links, stock inicial, `inventory_mode`
5. `06_propina_ley.sql` — vincula el 10% (el ITBIS queda fuera a propósito)
6. `05_verificacion.sql` — chequeos y borrado del staging

`99_rollback.sql` deshace todo.

## Categorías

| # | Categoría | Productos | Inventariable | Área |
|---|---|---|---|---|
| 0 | Cerveza | 235 | sí | barra |
| 1 | Wine | 327 | sí | barra |
| 2 | Whiskey | 101 | sí | barra |
| 3 | Rum | 65 | sí | barra |
| 4 | Tequila | 69 | sí | barra |
| 5 | Vodka | 59 | sí | barra |
| 6 | Ginebra | 13 | sí | barra |
| 7 | Cognac | 22 | sí | barra |
| 8 | Brandy | 4 | sí | barra |
| 9 | Licores | 63 | sí | barra |
| 10 | Champaña | 66 | sí | barra |
| 11 | Pre-Mix | 50 | sí | barra |
| 12 | Mix | 16 | sí | barra |
| 13 | Tragos | 57 | **no** | barra |
| 14 | Cócteles | 21 | **no** | barra |
| 15 | Fiesta | 45 | **no** | barra |
| 16 | Comida | 16 | **no** | cocina |
| 17 | Hookah | 3 | **no** | barra |
| 18 | Jugos | 52 | sí | barra |
| 19 | Papitas | 16 | sí | barra |
| 20 | Chicle | 31 | sí | barra |
| 21 | Cigarros | 28 | sí | barra |
| 22 | Cigarrillos | 9 | sí | barra |
| 23 | Tabaco | 6 | sí | barra |
| 24 | E-Cig | 95 | sí | barra |
| 25 | Misc | 47 | sí | barra |

## Códigos de barra

`menu_items.barcode` ← GTIN de Square. Los 1.284 GTIN del CSV son 100%
numéricos y de longitud estándar (8/12/13/14), sin un solo duplicado.

Además se **rescataron 33** que estaban guardados en la columna SKU con
el GTIN vacío: sin esto quedarían sin escanear teniendo el número ahí mismo.
El filtro solo acepta lo que tiene forma de código de barras, así que los SKU
de proveedor (`Y198873`, `248300T`, `4090968`) se quedan donde están. Ninguno
de los rescatados choca con un GTIN existente ni entre sí.

Total con código de barra: **1315** de 1516.

| Producto | Código rescatado del SKU |
|---|---|
| Al Fakher Gum Mint 15000 Puff | `5061032894864` |
| Barefoot Pink Moscato 750ml | `085000020456` |
| Bartenura Moscato 750ml | `087752005644` |
| Blue Moon Belgian White 12oz | `08787337` |
| Bogle Pinot Noir 750ml | `080887496318` |
| Bud Light 16oz Alum | `01879528` |
| Budweiser 12oz | `01801624` |
| Captain Morgan Spice 50ml | `08731409` |
| Ciroc Manzana 50ml | `08252407` |
| Clamato 163 ml | `01485131` |
| Coors Light lata 12oz | `07199840` |
| Coors light 12oz | `07199044` |
| Gordon Gin 750ml | `08860236` |
| Goya Coconut Water 350 ml | `041331027854` |
| Guillotina de Cigarros(Cigar Cutter) | `36528222` |
| Landshark Lager 12oz | `01877928` |
| Leinenkugel’s summer shandy lemonade flavor 12oz | `03478112` |
| Michelob Ultra 12oz Lata | `01833429` |
| Michelob Ultra 16oz Alum | `01866524` |
| Miller Lite 12oz Lata | `03435418` |
| Moet Ice Rose Imp 750ml | `081753828004` |
| Motts Manzana 10oz | `01489438` |
| Myers’s Rum 750ml | `08771300` |
| N/A Pink Whitney 50ml | `08567507` |
| Perrier Agua 330 ml | `07478341` |
| Santero Moscato Chinola 750ml | `56565656` |
| Seagrams 7 American whisky 375ml | `08776509` |
| Smirnoff Green Apple 50ml | `08210003` |
| Smirnoff Naranja 50ml | `08239008` |
| Smirnoff Vodka 50ml | `08247201` |
| Starlight Carbon Rollo | `683964900403` |
| Sutter Home Red Sangria 187ml | `08521921` |
| The One 22oz | `74601127` |

## Descartados (4)

- **Buzzballz Rita 200ml** — nombre duplicado en el CSV
- **Líquido rethless de  grape refill** — precio no numérico: 'variable'
- **Motts Manzana 32oz** — nombre duplicado en el CSV
- **Voopco ARGUS unidad de tanque 3ml** — precio no numérico: 'variable'

## Cantidades negativas puestas en 0 (53)

El CSV las trae en rojo por ventas sin entrada registrada. Entran en 0; hay que contarlas físicamente.

- Presidente 22oz: `-105`
- Presidente Ligth cubetazo: `-86`
- Heineken Draft (Grifo) Vaso 16oz: `-73`
- Presidente Cubetazo: `-65`
- JW Black Label Tragos: `-36`
- Heineken 7oz: `-33`
- Corona Cubetazo: `-31`
- Hookah: `-31`
- Motts Manzana 32oz: `-31`
- Estrella, Jalisco 12oz: `-25`
- Perrier Agua 330 ml: `-24`
- Red Bull 250 ml: `-17`
- Buzzballz Straw Rita 200ml: `-15`
- Don Julio Reposado Tragos: `-15`
- Goya Coconut Water 350 ml: `-13`
- Hookah Recarga: `-11`
- Presidente Black 12oz: `-10`
- Casamigo Blanco Tragos: `-8`
- Heineken 22 oz: `-8`
- Bud Light 16oz Alum: `-7`
- Starbuzz carbón pk: `-7`
- Romeo & Julieta Reserva Real Verona: `-6`
- Seagrams JAMAICAN ME HAPPY 12oz: `-6`
- Aceitunas: `-5`
- Clamato 163 ml: `-5`
- Heineken Cubetazo: `-5`
- JW Gold Label Tragos: `-5`
- Nota75  líquido la 42 medio refill: `-5`
- Nota75 Líquido bubaloo   ice  refill: `-5`
- Paulaner Hefe-Weizen 12iz: `-5`
- Starlight Carbon Rollo: `-5`
- Papas fritas: `-4`
- República La Tuya 330ml: `-4`
- Brugal XV Trago: `-3`
- Chicle sin azúcar Eclipse: `-3`
- High Noon Vodka Selt Pera 12oz: `-3`
- Modelo Cubetazo: `-3`
- Orbit Gum Wintermint Gum: `-3`
- Cerdo Asado 1LB: `-2`
- Chicle Trident Island Berry Lima sin azúcar 1x14 piezas: `-2`
- Corona Sunbrew 12oz: `-2`
- Stella Artois 22oz: `-2`
- Frontera Carbenet 750ml: `-1`
- Frontera Sauv Blanc 750ml: `-1`
- Mahou Sin 12oz Lata: `-1`
- Mezcla para bebida de curaçao azul premium de 1 litro: `-1`
- New Voodoo Ranger Juicy Haze IPA 12oz Lata: `-1`
- Patrón Silver  375ml: `-1`
- Paulaner, Lager Original 12oz: `-1`
- Refil butano: `-1`
- Salchipapas: `-1`
- Surfside iced tea +vodka: `-1`
- Surfside peach tra +vodka: `-1`

## Costo mayor que el precio (4)

Se cargan igual, pero el margen sale negativo.

- **Aceituna fígaro**: costo 389.95 > precio 250
- **Cherries Goya**: costo 259.95 > precio 200
- **Minute Man refill  líquido de lemon**: costo 650 > precio 100
- **Presidente Ligth cubetazo**: costo 1500 > precio 1000

## Productos sin categoría en Square (24)

Mapeados a mano. Los que van a **Fiesta** son botella-en-mesa: precio alto,
sin costo y sin stock — el mismo patrón que el resto de esa categoría.

- 19 Crimes Cali Sweet 750ml → **Wine**
- Buchannan’s 18 → **Fiesta**
- Buzzballs Cranberry Blaster Cocktail 200ml → **Pre-Mix**
- Buzzballz Chillers Lemon Tea Cocktail → **Pre-Mix**
- Capriccio Sangria Blanca 750ml → **Wine**
- Flavor Beast Depositivo Blanco → **E-Cig**
- Four Loko purple 355ml → **Cerveza**
- Glenlivet 12Y → **Fiesta**
- Glenlivet Fouders Reserve → **Fiesta**
- Gold River rare reserve 700ml → **Whiskey**
- Harmony Bordeaux → **Wine**
- High Noon tequila princkly pear → **Cerveza**
- José Cuervo Gold → **Fiesta**
- José Cuervo Silver → **Fiesta**
- Ketel One → **Fiesta**
- Leyenda Cognac → **Fiesta**
- Lightstrike Orange Mango 16oz → **Cerveza**
- Pollo Deditos 6 + Guarnicion → **Comida**
- Refil butano → **Misc**
- Rombauer Napa Cab Sauv 750ml → **Wine**
- Siboney Blanco Ron 750ml → **Rum**
- TMT Straw Watermelon 15k → **E-Cig**
- Two Chicks limoncello lemonade → **Vodka**
- Upstate Apples Vodka 750ml → **Vodka**

## Impuestos

Los productos entran en `tax_mode = 'exclusive'`. El paso 6 vincula **solo la
Propina de Ley (10%)**; el **ITBIS 18% queda sin vincular a propósito**, aunque
el impuesto exista y esté activo en el negocio.

Dónde se cobra el 10% lo gobiernan los `apply_on` del impuesto, ya configurados:
zona ✓, manual ✓, delivery ✓, venta rápida ✗, para llevar ✗. El trago en mesa lo
cobra; la botella en el mostrador, no.

> ⚠ Mientras el ITBIS no se vincule, las facturas salen con ITBIS 0.00 ante la
> DGII. `menu_item_taxes` es la única fuente del impuesto por producto — PRD 2.5
> quitó el fallback a `business_settings.default_tax_rate`.

