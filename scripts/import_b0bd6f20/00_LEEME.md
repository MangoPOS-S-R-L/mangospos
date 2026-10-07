# Carga del catálogo: LA COCINA MEXICANA AUTENTICA (b0bd6f20)

Negocio: `b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee`, creado el 07-oct-2026. Es otra sucursal de la marca de Ágora (`6e18428f`).

**Fuente:** `_fuente.csv`, el "Catalogo de productos (Transformados)" del sistema anterior (07/10/2026 01:59 PM, 190 filas, costos en 0). La complementa el **diagnóstico de prod del 07-oct**, que encontró 39 productos ya subidos a mano, **todos sin impuesto** y con el legacy en `kitchen_hot` (un área que no existe), además de:
- ningún área de comanda;
- solo el ITBIS, sin Ley;
- DELIVERY 100…450 como productos;
- `delivery_fee_required = true` con los montos rápidos vacíos.

## Estado

- **07-oct: `IMPORT_COMPLETO.sql` CORRIDO EN PROD.** El reporte dio 20 ✓ y los 3 ✗ esperados: las impresoras de Cocina y Bar, y Carne Cocida.
- **Falta correr `02_modificadores_foodtropolis.sql`.** Deja los modificadores igual que en FOODTROPOLIS (`800e4643`), de donde se clonaron los 38 productos que ya estaban.
  - Copia los 19 grupos al momento de correrlo y los liga por nombre de producto.
  - Pone SIN + Extras en los 38 platos.
  - Agrega a REFRESCOS Rojo, Uva y Merengue ($50) y Sangría Señorial y Boing Mango ($200); a JUGOS NATURALES, Fruit Punch ($150).
  - Quita los grupos de la carga que chocan (Tostadas · Tipo, Soda Can · Sabor, Refrescos Sabores · Sabor, Jarritos · Sabor y Refresco · Sabor), el producto REFRESCO y los 4 jugos sueltos.
  - Pone SODA CAN, REFRESCOS y JUGOS NATURALES en $0, porque el precio lo pone la opción, como en Foodtropolis.
  - Lo que ya se vendió se desactiva en vez de borrarse.
  - Avisos (⚠): SODA CAN se puede vender en $0 porque sus 3 grupos son opcionales, igual que en Foodtropolis; y JARRITOS + Mundet Sidral da $375.
- Después del 02, **`IMPORT_COMPLETO.sql` ya no se re-corre**: aborta solo, porque volvería a crear los grupos que el 02 quitó.
- `01_modificadores_foodtropolis.sql` (solo lee) lista los grupos de las 3 sucursales: Ágora, Foodtropolis y Real Food Park.
- Ensayo del 02: `ensayo/run_tests_02.sh`, sobre `replica.sql` + `replica_foodtropolis.sql` + el IMPORT. Los 5 escenarios salen bien.

## Cómo se corre

1. **`IMPORT_COMPLETO.sql`**: pégalo entero en el SQL Editor y dale Run. Al final sale un reporte de 23 filas.
2. Vincula una impresora a **Cocina** y otra a **Bar** en la app (Ajustes → Impresoras). Las filas 19 y 20 salen ✗ hasta entonces.
3. Decide con el dueño **Carne Cocida Natural xlb**: es exclusive y está sin impuesto, así que la fila 23 sale ✗.
4. (`99_rollback.sql`) deshace la carga y aborta si algo ya se vendió.

`00_diagnostico.sql` sirve para volver a mirar el estado. Si aparece un producto activo nuevo que no está en `EXISTENTES`, la carga aborta y lo lista.

Todo se genera con `python3 build_import_b0bd6f20.py` desde `catalogo.py` y `_tpl_*.sql`. **No edites los `.sql`.**

## Qué deja

**126 productos de la lista** (104 nuevos y 22 que ya estaban): 36 van a la Cocina y 90 al Bar. Contando lo que ya estaba fuera del CSV, quedan **130 productos activos**, todos con área válida, en el menú y con impuestos.

| Decisión del usuario (07-oct) | Cómo queda |
|---|---|
| Variantes | **15 productos con modificador obligatorio**. La base es el precio más bajo y la opción suma la diferencia. Ejemplo: CANTARITO 1800 a $500, con Silver, Reposado, Añejo +50 y Añejo Cristalino +150. TOSTADAS y ENCHILADA, que estaban subidos genéricos, ahora piden el tipo |
| Extras | **Grupo opcional "Extras"** con 11 opciones (las 9 del CSV más Extra de carne y Extra nachos, que estaban como producto) en los 38 productos de cocina. Los 4 extras sueltos se desactivan |
| Delivery | Los 8 DELIVERY se **desactivan** y se ponen los montos rápidos 100…450. El cargo exento lo pide la caja al cobrar |
| Precios | **Manda el CSV**: 12 ya subidos cambian de precio, por ejemplo BURRITO 650→700, SODA CAN 0→100 y REFRESCOS 0→50. Excepción: JARRITOS a $175, como lo subiste. El CSV trae los sabores a $250 y "Jarritos. - Guava" a $175 en una categoría más nueva |
| Impuestos | **ITBIS 18% + Ley 10% incluidos en todo lo activo**. AGUA lleva solo la Ley, como en Ágora. Carne Cocida no se toca |
| Ley 10% | **Copia exacta de la de Ágora**: `include_in_ecf = false`, no cobra para llevar. Aborta si alguna columna trae un uuid de Ágora |
| Áreas | Se crean **Cocina** (`cocina`) y **Bar** (`bar`). Escribe la N:M y el legacy `print_area_code` |
| Categorías | Reusa las 7 existentes ("TACOS 🌮"...) y crea 12 en MAYÚSCULAS. Los productos nuevos también van en MAYÚSCULAS, como los subidos |

## Lo que ya estaba (`EXISTENTES` en `catalogo.py`)

- **22 `ya_subido`:** son productos de la lista. Conservan nombre y categoría; toman el precio del CSV, ITBIS + Ley, su área y sus modificadores.
  - El emparejamiento no salía solo en tres: AGUA = Agua Dasani, REFRESCOS = Refrescos Sabores (Rojo, Uva, Merengue…) y TACOS DE CARNITA MICHOACAN.
- **4 `fuera_csv`:** se quedan y toman área e impuestos.
  - TACO DOBLE DECKERS y TACOS FIESTAS van a Cocina, con Extras.
  - GANSITO MARINELA GRANDE va al Bar, como los postres del CSV.
  - Carne Cocida va a Cocina, sin tocar sus impuestos.
- **12 `desactivar`:** los 8 DELIVERY y los 4 extras sueltos.
- **1 `mantener`:** ENCHILADA SUIZA, que estaba inactiva y ahora es una opción de ENCHILADA.

## Correcciones a la fuente

- **Repetidas, se carga una:** Gringa (31/187), Gran Malo (227/88) y Tostadas de Cerdo. De esta se deja $650, el código más nuevo, sobre la 35 a $600.
- **Nombres:** "Herrtadura" → Herradura, "Grand Cava de Oro" → Gran Cava de Oro y "A. Fieston de tacos" → Fiestón de Tacos.
- Los shots llevan "(Shot)" en el nombre, y los tacos de 3 y 4 unidades lo dicen en la descripción.
- **Área vacía en el CSV, se usa la de su categoría:** Cantarito Mezcal Mitre, Montelobos, Arizona y Refrescos Sabores van al Bar; Fiestón de Tacos y Combo Rosario, a la Cocina.
- Los postres van al Bar, como dice el CSV.

## Rollback

- Borra los 104 productos nuevos y los 16 grupos de modificadores.
- Devuelve los precios de los ya subidos y reactiva los DELIVERY y los extras.
- **No** revierte la Ley, las áreas, ni los impuestos y áreas de lo que ya estaba. Volver a "sin impuesto y apuntando a `kitchen_hot`" sería volver a dejarlos rotos.

## Ensayo local (07-oct-2026)

`ensayo/run_tests.sh` corre en PG15 (puerto 5449) sobre `ensayo/replica.sql`, la copia del estado de prod según el diagnóstico.

- **S1, carga:** 20 ✓ y los 3 ✗ esperados (dos impresoras y Carne Cocida).
- **S2, re-corrida:** no duplica nada.
- **S3–S5:**
  - el rollback deja 39 productos con los precios de antes;
  - el re-import funciona;
  - el rollback aborta si hay una venta.
- **S6:** un producto activo nuevo sin decisión, aborta.
- **S7–S9:** Ágora sin Ley, la Ley con una columna uuid y la Ley por orden encendida; las tres abortan.
- **S10, con impresoras y la Ley creada a mano:** 22 ✓ y solo Carne Cocida ✗.
