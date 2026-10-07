# Carga del catálogo: CAFETERIA MARICELA

Negocio: `1971ae49-935c-464a-9bfc-131d76a63be3`
Fuente: `~/Downloads/ReportInventarios_Todos.pdf`, el "Reporte General de Inventarios" del sistema anterior (06/10/2026 2:31 p. m.). Trae 111 productos con código, costo, precio y existencia, sin categorías. El CSV con el mismo nombre salió vacío (2 bytes).

## Cómo se corre

1. **`00_diagnostico.sql`**: solo lee y devuelve una tabla. Lo importante: el ITBIS, las áreas de comanda con su impresora y si el catálogo ya tiene alguno de estos productos (sección 6).
2. **`IMPORT_COMPLETO.sql`**: pégalo entero en el SQL Editor y dale Run. Al final sale un reporte de 14 filas.
3. (`99_rollback.sql`): borra los 111. Aborta si alguno ya se vendió.

Los tres `.sql` y `catalogo_revision.csv` se generan con `python3 build_import_1971ae49.py` a partir de `catalogo.py` y de las plantillas `_tpl_*.sql`. **Para cambiar un precio, un nombre o una categoría, edita `catalogo.py` y vuelve a correr el build.**

## Qué carga

111 productos con ITBIS 18% **incluido** (`inclusive`) y **sin Ley 10%**. El código del sistema viejo queda como SKU y el costo en `menu_items.cost`. No se crean insumos ni existencias.

| Categoría | Productos | Área |
|---|---|---|
| PICADERAS | 9 | cocina |
| BANDEJAS | 4 | cocina |
| HAMBURGUESAS | 6 | cocina |
| SANDWICHES Y TOSTADAS | 8 | cocina |
| MEXICANO | 9 | cocina |
| MOFONGOS | 4 | cocina |
| POLLO | 4 | cocina |
| CARNES | 5 | cocina |
| MARISCOS Y PESCADOS | 8 | cocina |
| COMIDA CRIOLLA | 7 | cocina |
| PASTAS | 4 | cocina |
| SOPAS Y ENSALADAS | 3 | cocina |
| POSTRES | 2 | cocina |
| COCTELES | 24 | bar |
| CERVEZAS | 3 | bar |
| LICORES Y VINOS | 7 | bar |
| BEBIDAS | 4 | bar |

## Decisiones (2026-10-06)

- **22 precios eran el neto de un precio redondo** (254.24 × 1.18 = 300.00): el sistema viejo les sumaba el ITBIS por fuera. Se cargan al precio final: Aperol 300, Corona 225, Presidente 180, Churrasco 1,300, Quesadillas 340, etc. La columna `nota_precio` de `catalogo_revision.csv` los marca.
- **QUESILLO 169.92 → 200** y **DULCE DE PIÑA CON LECHE 127.81 → 150**.
- **CERDO ASADO + CASABE va en 533.33**, como viene en el PDF. Falta que el dueño confirme el precio: costo y precio parecen 2/3 de 550 y 800.
- Se corrigen 9 nombres: BACON CHEESE BURGER, BLOODY MARY, BLUE LAGOON TROPICAL, MOSCOW MULE, RUM PUNCH, CASAMIGOS (×3) y PASTA CUATRO QUESOS.
- Solo catálogo y costo. Las existencias del PDF son casi todas de cócteles y platos (190 Raspberry Rum Fizz, 157 Aros de cebolla), así que no son stock real.
- JUGOS NATURALES va al bar.

## Cómo escoge las áreas

- **Cocina:** usa un área activa con code `cocina`/`kitchen`/`kitchen_hot`/`comida` (o con ese nombre). Si no hay, reactiva una apagada o crea "Cocina" (`cocina`) sin impresora.
- **Bar:** usa un área con code `bar`/`barra` (o con ese nombre). Si no hay, reactiva una apagada o crea "Bar" (`bar`) sin impresora.
- Si la cocina está apagada en Ajustes, los productos quedan sin área.
- Un área creada por la carga sale ✗ en las filas 11 y 12 del reporte hasta que le vincules la impresora en la app.

## Emparejamiento con lo que ya exista

Empareja por SKU (el código) o por nombre (el corregido o el del PDF), sin mayúsculas ni tildes. El que ya existe se actualiza y conserva su nombre, salvo que tenga el nombre con el error de tipeo. Se le quita cualquier impuesto que no sea el ITBIS. Aborta sin tocar nada en estos casos:
- un renglón cae en dos productos;
- un producto cae en dos renglones;
- un producto tiene el SKU de la lista pero otro nombre;
- falta el ITBIS 18% o hay más de uno;
- hay más de un menú activo.

## Ensayo local (2026-10-06)

`ensayo/run_tests.sh` corre en PG15 con `ensayo/stub.sql`. Para arrancar el servidor, ver la cabecera del script. Escenarios:

- **S1**, negocio vacío: 111 productos, 12 ✓. Los únicos ✗ son las impresoras de la Cocina y el Bar recién creados.
- **S2**, re-corrida: no duplica nada.
- **S3**, rollback y re-import: funciona.
- **S4**, con una venta: el rollback aborta.
- **S5**, con catálogo previo: COCINA `kitchen_hot` y BARRA `barra` con impresora, LEY vinculada, "Blody Marry" y una "Corona" vendida. Da 14/14: reusa las áreas y las categorías por nombre, renombra a BLOODY MARY y le quita la LEY.
- **S6** (SKU usado por otro producto), **S7** (dos "Nachos"), **S9** (sin ITBIS) y **S10** (dos menús): aborta.
- **S8**, cocina apagada: sin áreas, 14/14.
- **S11**, Ley por orden encendida: carga, pero la fila 5 sale ✗.

## Pendientes

- Precio real de CERDO ASADO + CASABE.
- 11 costos de relleno (10 o 15 en platos de 220 a 600: Aros, Nachos, Mozzarella, Sopa de camarones, Mero a la criolla, Paloma Casamigos...). Se cargan tal cual y conviene corregirlos en la app para que los márgenes salgan bien.
- Después de la carga: una venta de prueba con un plato y un trago, para confirmar que la comanda sale por COCINA y por BAR, y que la factura muestra el ITBIS incluido.
