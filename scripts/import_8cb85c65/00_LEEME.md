# Carga del menú: EL RINCÓN DE ADDA

Negocio: `8cb85c65-ae49-4384-a678-0d8a201a955e`
Fuente: 11 fotos de la carta impresa (2026-10-16). No trae códigos ni costos, así que los productos se emparejan por nombre.

## Cómo se corre

1. **`00_diagnostico.sql`**: solo lee y devuelve una tabla. Lo importante: que haya **un ITBIS 18% y una Ley 10%** activos (sección 2), las áreas de comanda con su impresora (sección 3) y si el catálogo ya tiene alguno de estos productos (sección 6).
2. **`IMPORT_COMPLETO.sql`**: pégalo entero en el SQL Editor y dale Run. Al final sale un reporte de 19 filas.
3. (`99_rollback.sql`): borra los 135 productos, los grupos de modificadores que queden sin productos y las categorías que queden vacías. Aborta si alguno ya se vendió.

Los tres `.sql` y `catalogo_revision.csv` se generan con `python3 build_import_8cb85c65.py` a partir de `catalogo.py` y de las plantillas `_tpl_*.sql`. **Para cambiar un precio, un nombre, una categoría o un modificador, edita `catalogo.py` y vuelve a correr el build.**

## Qué carga

135 productos con **ITBIS 18% + Ley 10% incluidos** (`inclusive`): el cliente paga lo que dice la carta y los dos impuestos salen de adentro (Churrasco $1,200 = base 937.50 + ITBIS 168.75 + Ley 93.75). Las descripciones de la carta van en `menu_items.description`. No se cargan costos ni inventario.

| Categoría | Productos | Área |
|---|---|---|
| ENTRADAS | 6 | cocina |
| ENSALADAS | 6 | cocina |
| PASTAS | 6 | cocina |
| PIZZAS | 11 | cocina |
| CARNES | 12 | cocina |
| PESCADOS Y MARISCOS | 18 | cocina |
| ESPECIALIDADES | 6 | cocina |
| GUARNICIONES | 5 | cocina |
| TRAGOS PROPIOS | 6 | bar |
| TRAGOS TRADICIONALES | 23 | bar |
| SHOTS | 7 | bar |
| VINOS | 11 | bar |
| CERVEZAS | 4 | bar |
| BEBIDAS | 14 | bar |

## Modificadores (10 grupos, 30 enlaces)

| Grupo | Tipo | Opciones | Productos |
|---|---|---|---|
| Tipo de pasta | obligatorio | Linguine, Espagueti, Plumitas (Penne), Rigatoni | las 6 pastas |
| Proteína para la pasta | opcional, varios | Pollo +150, Res +200, Mariscos (indicar cuál) +400 | las 6 pastas |
| Término de la carne | obligatorio | Rojo, Medio rojo, Término medio, Tres cuartos, Bien cocido | los 6 cortes de res |
| Plancha o parrilla | obligatorio | A la plancha, A la parrilla | Lomo de Cerdo, los 2 Filete de Salmón |
| Frito o al vapor | obligatorio | Frito, Al vapor | Chillo Entero |
| Preparación del marisco | obligatorio | Al grill, A la criolla, En vinagreta, En salsa cremosa | Camarones, Pulpo |
| Salsa a elegir | obligatorio | A la criolla, En vinagreta, En salsa cremosa | Lambí, Lambí y Pulpo |
| Vegetales | obligatorio | Al grill, Salteados, Al vapor | Vegetales (guarnición) |
| Papas | obligatorio | Fritas, Salteadas, Al vapor, En puré | Papas (guarnición) |
| Con o sin alcohol | obligatorio | Sin alcohol +0, Con alcohol +50 | Piña Colada ($400), Smoothie de Fresa ($450) |

Obligatorio = `single`, min = max = 1: la caja no deja agregar el producto sin escoger. Los grupos son del negocio y se buscan por nombre; si ya existe uno, se reusa con esta configuración y sus opciones que no estén en la lista se apagan.

## Diagnóstico de prod (2026-10-16)

- ITBIS 18% y LEY 10.0% activos, sin `is_service_fee`; la Ley por orden está apagada.
- COCINA (`cocina`) y BAR (`bar`) tienen 2 impresoras cada una, y hay un solo menú, MENU PRINCIPAL.
- Había 2 productos creados a mano en BEBIDAS (posición 0):
  - **AGUA DASANI** $50, con una venta: es el «Agua» de la carta y **conserva su nombre**.
  - **JUGO DE LIMON** $150, sin ventas: es la «Limonada Natural» y **se renombra**.
- No se duplica ninguno de los dos, y el rollback no los borra.
- BEBIDAS conserva su posición 0, así que en la caja sale antes que ENTRADAS. Se reordena en la app si hace falta.

## Decisiones

- **Usuario (2026-10-16):** ITBIS + Ley incluidos. En Piña Colada y Smoothie de Fresa, el precio bajo es sin alcohol y el alto con alcohol. AGUA DASANI y JUGO DE LIMON se reusan, como se explica arriba.
- **Pastas:** cada salsa es un producto ("Pasta Alfredo" $600…). El tipo de pasta es obligatorio y la proteína suma.
- **Mojito de Pitahaya//Limón** y **Margarita Limón//Fresa** se partieron en 2 productos cada uno, al mismo precio (como los mojitos de AZOTEA).
- **Especialidades x2P** van como "(2 personas)".
- **Nombres corregidos:** 19 Crimemenes → 19 Crimes, Johnny Walker → Johnnie Walker, "crégano" → orégano y "sazonado especias" → "sazonado con especias" en las descripciones. El segundo «Filete de Salmón» pasa a «Filete de Salmón en Salsa de Ajo».
- **Término de la carne** no está en la carta: lo agregué yo como obligatorio en los 6 cortes de res. Si no lo quieren, se apaga en la app o se quita de `catalogo.py`.

## Dudas para el dueño (columna `duda` de `catalogo_revision.csv`)

- **Pasta Marinara a $1,070**, cuando las otras salsas cuestan entre 600 y 750: ¿lleva mariscos?
- **"Mariscos (un marisco a elegir)"** en la pasta: ¿cuáles? Por ahora es una sola opción y el mesero anota cuál.
- **Filete de Mero Barsa**, "preparado a su elección": la carta no dice las opciones, así que va sin modificador. ¿"Barsa" está bien escrito?
- **Copa de Casillero del Diablo a $800** y la botella a $1,400–1,500.
- **Bogle Tinto**: en la foto un reflejo tapa el nombre ("Bogle Ti…").
- **Frozen a $250**: ¿qué sabores?
- **"Bruquetas"** va como en la carta.

## Cómo escoge las áreas

- **Cocina:** usa un área activa con code `cocina`/`kitchen`/`kitchen_hot`/`comida` (o con ese nombre). Si no hay, reactiva una apagada o crea "Cocina" (`cocina`) sin impresora.
- **Bar:** usa un área con code `bar`/`barra` (o con ese nombre). Si no hay, reactiva una apagada o crea "Bar" (`bar`) sin impresora.
- Si la cocina está apagada en Ajustes, los productos quedan sin área.
- Un área creada por la carga sale ✗ en las filas 12 y 13 del reporte hasta que le vincules la impresora en la app.
- Las pizzas van a la cocina. Si tienen un horno con impresora aparte, hay que crear esa área y mover la categoría.

## Aborta sin tocar nada si…

- no hay exactamente un ITBIS 18% activo, o exactamente una Ley 10% activa;
- la Ley tiene `is_service_fee = true`, o la Ley por orden (`service_fee_enabled`) está encendida, porque se cobraría doble;
- un renglón de la carta cae en dos productos del catálogo, o un producto cae en dos renglones;
- hay dos grupos de modificadores con el mismo nombre;
- hay más de un menú activo.

## Ensayo local (2026-10-16)

`ensayo/run_tests.sh` corre en PG15 (puerto 5451) con `ensayo/stub.sql`. La cabecera del script explica cómo arrancar el servidor. Escenarios:

- **S1**, negocio vacío con ITBIS + Ley: 135 productos y 17 ✓. Los únicos ✗ son las impresoras de la Cocina y el Bar recién creados.
- **S2**, re-corrida: no duplica nada.
- **S3**, rollback y re-import: funciona.
- **S4**, con una venta: el rollback aborta.
- **S5**, con catálogo previo: COCINA `kitchen_hot` y BARRA `barra` con impresora, "19 Crimemenes" vendido, una pizza llamada "Cuatro Quesos", y "TERMINO DE LA CARNE" mal armado con la opción "Azul". Da **19/19 ✓**: renombra a 19 Crimes, no toca la pizza "Cuatro Quesos", arma el grupo de término y apaga "Azul", y le quita el término a Pollo a la Plancha.
- **S6** (sin Ley), **S7** (Ley con `is_service_fee`), **S8** (Ley por orden), **S9** (dos menús), **S10** (dos "Agua") y **S13** (dos ITBIS): aborta.
- **S11**, cocina apagada: sin áreas, 19/19.
- **S12**, `menu_item_groups` sin la columna `position`: carga igual.
- **S14**, réplica del estado real según el diagnóstico de prod: **19/19 ✓**. Quedan 135 productos (los 2 existentes reusados, sin duplicar) y la re-corrida sale igual. El rollback borra 133 y deja AGUA DASANI y Limonada Natural.

## Después de la carga

- Vincular las impresoras a Cocina y Bar si la carga las creó.
- Venta de prueba: una pasta con proteína, un Ribeye con término y una Piña Colada con alcohol. Hay que confirmar que la comanda sale por COCINA y por BAR, que la factura muestra ITBIS y Ley incluidos, y que la Piña Colada cobra $450.
