-- =============================================================================
-- UNIF_0_diagnostico.sql — Estancia Nueva · CAFETERÍA (85924083)
--
-- Unificar el inventario en UNA sola bodega (la principal, que pasa a llamarse
-- «Almacén Principal») con el conteo del 01-oct (cafetería + almacén) MENOS
-- lo que se movió después del corte 2026-10-01 11:55:00-04 (la cafetería se contó en la
-- mañana, antes de abrir: se descuentan todas las ventas).
--
-- SOLO LEE. Es UNA sola consulta: el SQL Editor muestra solo el último
-- resultado. Correr ANTES de UNIF_1_aplicar.sql y pasar el resultado.
--
-- GENERADO por build_unificar_almacen.py desde
-- inventario_estancia_nueva_2026-10-01.json (196 códigos de cafetería).
-- Editar el .py o el _tpl, no este archivo.
-- =============================================================================
with
p as (
  select '85924083-2e8e-4e64-8192-808ee24674ed'::uuid    as b,
         'PC-2026-000004'::text    as pc_corte,
         'PC-2026-000002'::text as pc_abandonado,
         '2026-10-01 11:55:00-04'::timestamptz as corte,
         'America/Santo_Domingo'::text as tz
),
conteo (codigo, descripcion, caf, alm, total) as (
  values
    ('016000264694', 'BARRAS NATURE VALLERY', 23, 30, 53),
    ('5000329002230', 'BOTELLA BEEFEATER LONDON', 1, 0, 1),
    ('4750021000157', 'BOTELLA STOLI', 1, 5, 6),
    ('5000299225028', 'CHIVA 18 BOTELLA', 1, 0, 1),
    ('764090052850', 'CRACHI MAS MAS ROCKY', 1, 0, 1),
    ('044000020071', 'GALLETA MINI CHIPS AHOY', 8, 10, 18),
    ('044000020170', 'GALLETA MINI OREO', 20, 10, 30),
    ('044000020255', 'GALLETA RITZ BITS CHEESE', 1, 40, 41),
    ('027800072723', 'GALLETAS KEEBLER CHIPS DELUXE', 5, 0, 5),
    ('044000061494', 'GALLETAS MINI OREO GOLDEN', 8, 60, 68),
    ('3147699118344', 'GIBSON,S PINK PREMIUN GIN', 1, 2, 3),
    ('034856008187', 'GOMITAS WELCH PEQUEÑAS', 75, 66, 141),
    ('038000219856', 'KELLOGGS  APPLE JACKS', 7, 10, 17),
    ('038000219474', 'KELLOGGS  POPS', 1, 8, 9),
    ('038000219528', 'KELLOGGS COCOA KRISPIES', 2, 8, 10),
    ('038000219634', 'KELLOGGS FROSTED FLAKES', 1, 12, 13),
    ('00985234', 'KINDER JOY', 41, 30, 71),
    ('021000010875', 'MAC & CHEESE MACARRONES', 17, 24, 41),
    ('038000184949', 'PRINGLES CEBOLLA LATA GRANDE', 2, 3, 5),
    ('038000846748', 'PRINGLES CREMA Y CEBOLLA', 2, 16, 18),
    ('038000846731', 'PRINGLES ORIGINAL', 4, 10, 14),
    ('038000846755', 'PRINGLES QUESO', 1, 8, 9),
    ('1232', 'SIBONEY 1920 BOTELLA 700 ML', 1, 0, 1),
    ('1186', 'SOPA ISIM POLLO', 7, 90, 97),
    ('757528048532', 'TAKIS FUEGO PEQUEÑO', 42, 0, 42),
    ('5011166081104', 'WHITLEY NEILL GIN BLOOD ORANGE', 1, 2, 3),
    ('5011166068020', 'WHITLEY NEILL GIN BLUE DISTILLER,S', 1, 2, 3),
    ('5011166081128', 'WHITLEY NEILL GIN RHUBARB', 1, 2, 3),
    ('073390002022', 'AIR HEADS', 32, 0, 32),
    ('110000100678', 'BABY BOTTLE POP', 6, 80, 86),
    ('016000439894', 'BARRAS NATURE VALLEY CHEWY FRUIT NUT', 8, 0, 8),
    ('040000000327', 'CHOCOLATE M&M AMARILLO', 2, 113, 115),
    ('040000602040', 'CHOCOLATE MILKYWAY', 5, 24, 29),
    ('040000004356', 'CHOCOLATE TWIX 2 COOKIE BARS', 3, 5, 8),
    ('7500478001200', 'CHOKIS MIX CHOCOLATE', 7, 0, 7),
    ('7501000604685', 'CHOKIS RELLENA', 2, 0, 2),
    ('7500478013609', 'EMPERADOR CHOCOLATE BEE CAM', 3, 0, 3),
    ('7500478013616', 'EMPERADOR VAINILLA CAM', 7, 0, 7),
    ('7500478012404', 'EMPERADOR VAINILLA CS PEQUEÑA', 2, 0, 2),
    ('7501000601745', 'FLORENTINA DULCE DE LECHE CAJETA', 1, 0, 1),
    ('7501000601738', 'FLORENTINAS FRESA', 5, 0, 5),
    ('7501000634118', 'GALLETA AVENA QUAKER DE ALMEN/GRANOLA DR', 4, 0, 4),
    ('7501000634132', 'GALLETA AVENA QUAKER FRESA ROJAS', 5, 0, 5),
    ('1135', 'GALLETAS CUQUI AVENA CON COCO', 11, 0, 11),
    ('1136', 'GALLETAS CUQUI CHOCOLOSCHI', 3, 0, 3),
    ('1133', 'GALLETAS CUQUI SALUDABLE VAINILLA', 4, 0, 4),
    ('854929006557', 'LENGUITAS SOUR BELTS', 12, 400, 412),
    ('7467515320048', 'MISSCOOKIE CLASICA', 9, 0, 9),
    ('1115', 'MISSCOOKIE CLASICA COCO', 2, 0, 2),
    ('7467515320079', 'MISSCOOKIE CLASICA JENJIBRE', 3, 0, 3),
    ('016000507661', 'NATURE VALLEY PROTEIN', 4, 4, 8),
    ('041116005343', 'PUSHPOP', 24, 96, 120),
    ('110000100238', 'RING POP', 16, 80, 96),
    ('040000514251', 'SNICKERS', 7, 11, 18),
    ('014113911856', 'WONDERFUL PISTACHIOS', 8, 0, 8),
    ('7463172803320', '7 UP REFRESCO', 9, 0, 9),
    ('049000409772', 'AGUA DASANI GRANDE', 3, 0, 3),
    ('049000551808', 'AGUA DASANI PEQUEÑA', 40, 340, 380),
    ('7465383000321', 'CANADA DRY AGUA TONICA', 13, 12, 25),
    ('7465383000307', 'CANADA DRY SODA 400ML', 11, 48, 59),
    ('049000071993', 'COCA COLA SIN AZUCAR', 4, 24, 28),
    ('049000057638', 'COCA-COLA 400ML', 8, 24, 32),
    ('049000057676', 'COUNTRY CLUB FRAMBUESA 400ML', 11, 0, 11),
    ('049000057669', 'COUNTRY CLUB MERENGUE 400ML', 9, 0, 9),
    ('7460548000147', 'GATORADE DE MELON GRANDE FIERCE 600ML', 2, 5, 7),
    ('7460548000178', 'GATORADE LEMON LIME', 4, 9, 13),
    ('7460548000161', 'GATORADE MORADO UVA GRANDE 600ML', 11, 80, 91),
    ('7460548000185', 'GATORADE NARANJA  ORANGE GRANDE 600ML', 7, 22, 29),
    ('7460548000017', 'GATORADE PEQUEÑO AZUL/ BLUE COOL 350ML', 8, 70, 78),
    ('7460548000048', 'GATORADE PEQUEÑO NARANJA 350 ML', 9, 0, 9),
    ('7460548000024', 'GATORADE PEQUEÑO ROJO/ FRUIT PUNCH 350M', 2, 71, 73),
    ('7460548000031', 'GATORADE PEQUEÑO UVA 350 ML', 15, 55, 70),
    ('7460548000154', 'GATORADE ROJO GRANDE/FRUIT PUNCH 600ML', 2, 46, 48),
    ('7460548002127', 'GATORADE ZERO AZUL BERRY BLUE 500ML', 17, 47, 64),
    ('7460548002134', 'GATORADE ZERO ROJO 500 ML', 18, 10, 28),
    ('7460548002141', 'GATORLIT MORA AZUL 12/591 ML', 4, 48, 52),
    ('7460548002165', 'GATORLIT RECOVER UVA 12/591ML', 5, 33, 38),
    ('096619204212', 'JUGO KIRKLAND ACAI BLUEBERRY', 1, 0, 1),
    ('096619204205', 'JUGO KIRKLAND DRAGON FRUIT', 2, 0, 2),
    ('096619192328', 'JUGO KIRKLAND LEMONADE', 1, 0, 1),
    ('096619204014', 'JUGO KIRKLAND TROPICAL MANGO', 2, 0, 2),
    ('7463172803467', 'RED ROCK FRAMBUESA', 15, 0, 15),
    ('7463172803528', 'RED ROCK MERENGUE', 4, 0, 4),
    ('7463172803580', 'RED ROCK UVA', 1, 0, 1),
    ('049000057690', 'SPRITE 400 ML', 2, 12, 14),
    ('1239', 'SPRITE SIN AZUCAR 400 ML', 4, 0, 4),
    ('4014086096518', '5,0 ORIGINAL CRAFT BEER', 16, 0, 16),
    ('4014086096365', '5,0 ORIGINAL PILS BEER', 12, 17, 29),
    ('8002270676819', 'AGUA SAN PEREGRINO ARANCIATA', 2, 0, 2),
    ('1215', 'ALHAMDRA RESERVAS 1925 BOTELLA', 33, 0, 33),
    ('8412598004964', 'CERVEZA 1906 LA MIL NUEVE', 4, 0, 4),
    ('08787337', 'CERVEZA BLUE MOON BELGION WHITE', 28, 48, 76),
    ('03456217', 'CERVEZA MILLER BOTELLA - 12OZ', 28, 0, 28),
    ('4066600303336', 'CERVEZA PAULANER DUNKEL 500 ML', 20, 0, 20),
    ('4066600060741', 'CERVEZA PAULANER WEISSBIER RUBIA 500ML', 6, 0, 6),
    ('1231', 'CERVEZA PERONI CERO 21/330 ML', 17, 24, 41),
    ('087975903550', 'CERVEZA SAPPORO LIGHT', 14, 0, 14),
    ('74601325', 'CERVEZA THE ONE', 17, 0, 17),
    ('07199044', 'COORS LIGHT BOTELLA', 1, 0, 1),
    ('08780936', 'COORS ORIGINAL BANQUET BOTELLA - 12OZ', 71, 144, 215),
    ('7503044233180', 'CORONA CERO 355ML', 10, 0, 10),
    ('7503034941200', 'CORONA EXTRA 330ML', 46, 48, 94),
    ('7503034941217', 'CORONITA EXTRA', 20, 0, 20),
    ('9002490204006', 'ENERGIZANTE RED BULL 250 ML PEQUEÑO', 18, 48, 66),
    ('3263280120470', 'ESPUMANTE JP CHENET FIZZY ROSE LATA 250', 4, 0, 4),
    ('072890004994', 'HEINEKEN BOTELLA PEQUEÑA 330 ML', 13, 24, 37),
    ('072890006196', 'HEINEKEN BOTELLA SIN ALCOHOL', 7, 0, 7),
    ('01833225', 'MICHELOB ULTRA 330 ML', 174, 372, 546),
    ('75031589', 'MODELO NEGRA 330 ML', 7, 0, 7),
    ('7463172802996', 'MODELO RUBIA ESPECIAL 330ML', 10, 0, 10),
    ('8008440222008', 'PERONI 330 ML', 25, 0, 25),
    ('74621774', 'PRESIDENTE LIGHT 12OZ', 22, 24, 46),
    ('74621767', 'PRESIDENTE REGULAR 12 OZ', 19, 0, 19),
    ('8002270916588', 'SANPELLEGRINO TONICA', 13, 0, 13),
    ('082000727477', 'SMIRNOFF ICE GREEN APPLE', 18, 0, 18),
    ('082000723844', 'SMIRNOFF ICE ORIGINAL 355 ML', 14, 0, 14),
    ('7501064199141', 'STELLA ARTOIS 330 ML', 6, 72, 78),
    ('635985500018', 'WHITE CLAW BLACK CHERRY LATA', 9, 0, 9),
    ('632565000029', 'AGUA FIJI 1 LITRO', 7, 24, 31),
    ('632565000012', 'AGUA FIJI 500ML', 4, 72, 76),
    ('8002270966576', 'AGUA PANNA PEQUENA 500ML', 10, 96, 106),
    ('8000815355250', 'AGUA PANNA TUSCANY 1 LT', 9, 43, 52),
    ('842595135534', 'C4 ENERGY BITTEN CITRUS', 5, 0, 5),
    ('842595136050', 'C4 ENERGY GUMMY SPLASH', 1, 0, 1),
    ('842595109368', 'C4 ENREGY ORANGE', 1, 0, 1),
    ('07811102', 'CANADA DRY GINGER ALE BLACKBERRY 24/12', 6, 60, 66),
    ('07844508', 'CANADA DRY GINGER ALE FRUIT SPLASH', 14, 0, 14),
    ('07811403', 'CANADA DRY GINGER ALE LATA 24 /12', 27, 0, 27),
    ('7460548002189', 'GATORLIT RECOVER FRESA KIWIT', 5, 40, 45),
    ('7460548002172', 'GATORLIT RECOVER NARANJA', 4, 0, 4),
    ('893919001301', 'ICELANDIC AGUA MINERAL 1 LT', 11, 18, 29),
    ('893919001509', 'ICELANDIC AGUA MINERAL 750ML CHUPI', 4, 39, 43),
    ('790330021270', 'JUGO RICA FRUIT PUNCH', 28, 0, 28),
    ('790330021171', 'JUGO RICA MANZANA', 14, 0, 14),
    ('790330021089', 'JUGO RICA NARANJA 100% CON AZUCAR', 15, 0, 15),
    ('790330021140', 'JUGO RICA NARANJA 100% SIN AZUCAR', 17, 0, 17),
    ('01208500', 'MOUNTAIN DEW VERDE REGULAR', 15, 12, 27),
    ('016571910327', 'SPARKLING ICE KIWI STRAWBERRY', 10, 34, 44),
    ('016571911256', 'SPARKLING ICE LEMON LIME', 12, 31, 43),
    ('016571953867', 'SPARKLING LATA BLACK RASPBERRY', 7, 41, 48),
    ('016571953843', 'SPARKLING LATA BLUE RASPBERRY', 10, 42, 52),
    ('016571952839', 'SPARKLING LATA STRAWBERRY CITRUS', 15, 6, 21),
    ('016571954369', 'SPARKLINK ICE FRUIT PUNCH', 5, 13, 18),
    ('650240063213', 'SUEROX FRESA-KIWI', 3, 15, 18),
    ('650240069192', 'SUEROX FRUTOS ROJOS TROPICALES', 5, 18, 23),
    ('650240063220', 'SUEROX MANZANA', 6, 6, 12),
    ('7501000636921', 'MAMUT 30G', 21, 0, 21),
    ('7501000610228', 'MINI CHOKIS', 19, 0, 19),
    ('1149', 'RANCH EXCITANT GRANDE', 3, 0, 3),
    ('1653265', 'RANCH NACH EXCITANT PEQ.', 5, 0, 5),
    ('750894603404', 'RANCH NACH PIZZA PEQ.', 6, 0, 6),
    ('750894614288', 'RANCH NACHO QUESO PEQ.', 11, 0, 11),
    ('750894606399', 'RANCHITA DE QUESO GRANDE', 1, 0, 1),
    ('750894612550', 'TAQUE CHILETOR PEQ', 13, 0, 13),
    ('750894611645', 'YUMMIPOP QUESO PEQ.', 6, 0, 6),
    ('750894610709', 'ZAMBOS PLATANO CEVICHE PEQ.', 28, 0, 28),
    ('750894607181', 'ZAMBOS PLATANO MADURITO GRANDE', 4, 0, 4),
    ('750894602131', 'ZAMBOS PLATANO MADURITO PEQ.', 32, 0, 32),
    ('750894602988', 'ZAMBOS PLATANO ORIGINAL PEQ.', 28, 0, 28),
    ('750894613571', 'ZAMBOS PLATANO TAJIN PEQ', 22, 0, 22),
    ('750894606719', 'ZIBAS PAPA CLASICAS PEQ.', 5, 0, 5),
    ('1222', 'ZIBAS PAPA JALAPEÑA PEQ', 3, 0, 3),
    ('750894611812', 'ZIBAS PAPA MIEL MOSTAZA PEQ', 6, 0, 6),
    ('750894611799', 'ZIBAS PAPA QUESO  PEQ', 9, 0, 9),
    ('110000100280', 'EMPANADA DE PIZZA', 39, 0, 39),
    ('110000100281', 'EMPANADA DE POLLO CREMA', 53, 0, 53),
    ('110000100282', 'EMPANADA DE QUESO', 51, 0, 51),
    ('110000100464', 'EMPANADITAS CATIVIA', 12, 0, 12),
    ('1175', 'PAN MEDIA BANGUETTE', 16, 0, 16),
    ('110000100277', 'PORCION CARNE SALADA', 19, 0, 19),
    ('1176', 'QUESO MOZZARELLA RICA', 2, 0, 2),
    ('110000100308', 'QUIPE DE CABRA Y CEBOLLA CARAMELIZADA', 76, 0, 76),
    ('110000100309', 'QUIPE DE POLLO', 66, 0, 66),
    ('110000100310', 'QUIPE DE RES', 75, 0, 75),
    ('110000100657', 'SERVICIO DE CHICHARRON', 16, 0, 16),
    ('5000267190150', 'WHISKY JOHNINIE NEGRO BOTELLA', 0, 2, 2),
    ('5000267107776', 'WHISKY JOHNINIE GOLD BOTELLA', 0, 3, 3),
    ('7460855238066', 'TRIPLE RESERVA BOTELLA', 0, 2, 2),
    ('3263285152896', 'TEQUILA AGAVITA', 0, 5, 5),
    ('016571910303', 'SPARKLING ICE BLACK RASPBERRY', 0, 48, 48),
    ('7460736904721', 'ROM MACORIX BLANCO 700ML', 0, 17, 17),
    ('8410702039628', 'PROVENTO JAUME SERRA CAVA BRUT', 0, 15, 15),
    ('7503018819501', 'OJO DE TIGRE 750ML', 0, 1, 1),
    ('9661931395', 'KIRKLAND CHOCOLATE SOFT & CHEWY', 0, 27, 27),
    ('038000219740', 'KELLOGGS  FROOT LOOPS', 0, 12, 12),
    ('110000100671', 'ICE POPS NIEVE DE FRUTAS', 0, 120, 120),
    ('3147690060703', 'GIBSON,S LONDON DRY GIN', 0, 1, 1),
    ('044000020361', 'GALLETA TEDDY GRAHAMS', 0, 6, 6),
    ('044000011703', 'GALLETAS MINI OREO CHOCOLATE', 0, 20, 20),
    ('044000020187', 'GALLETA NUTTER BUTTER BITES', 0, 4, 4),
    ('110000100585', 'EXTRA VIEJO BOTELLA', 0, 2, 2),
    ('7460855233498', 'DOBLE RESERVA BOTELLA', 0, 5, 5),
    ('040000000310', 'CHOCOLATE M&M MARRON', 0, 87, 87),
    ('1049', 'BOTELLA LICOR FERNET BRANCA', 0, 5, 5),
    ('5000299618073', 'BOTELLA BEEFEATER PINK STRAWBERRY', 0, 1, 1),
    ('8002230000302', 'BOTELLA  APEROL', 0, 5, 5)
),
wh as (
  select w.id, w.name, coalesce(w.is_main, false) as is_main,
         coalesce(w.is_active, true) as is_active, w.created_at,
         to_jsonb(w) as j, w.name = '__IN_TRANSIT__' as transito
  from public.warehouses w, p
  where w.business_id = p.b
),
-- La misma regla que usa la venta para elegir la bodega por defecto.
principal as (
  select id, name from wh
  where not transito
  order by is_main desc, created_at asc nulls first, id asc
  limit 1
),
-- id = el conteo del almacén (sus ajustes los reemplaza el JSON);
-- frozen_at = la hora de corte elegida (no la del conteo del almacén).
corte as (
  select (select s.id from public.physical_count_sessions s
           where s.business_id = p.b and s.code = p.pc_corte) as id,
         p.corte as frozen_at
  from p
),
ses as (
  select s.id, s.code, s.status, s.frozen_at, s.completed_at, w.name as bodega,
         s.status = 'completed'
           and (s.frozen_at at time zone p.tz)::date = date '2026-10-01' as campania
  from public.physical_count_sessions s
  join public.warehouses w on w.id = s.warehouse_id, p
  where s.business_id = p.b
),
it as (
  select ii.id, ii.sku, ii.barcode, ii.name, coalesce(ii.cost, 0) as cost
  from public.inventory_items ii, p
  where ii.business_id = p.b
),
-- Emparejar por código: sku primero; si no hay sku, código de barras.
mt as (
  select c.*, x.n_sku, x.n_bc,
         case when x.n_sku = 1 then (select it.id from it where it.sku = c.codigo)
              when x.n_sku = 0 and x.n_bc = 1
                then (select it.id from it where it.barcode = c.codigo)
         end as item_id
  from conteo c
  cross join lateral (
    select (select count(*) from it where it.sku = c.codigo)     as n_sku,
           (select count(*) from it where it.barcode = c.codigo) as n_bc
  ) x
),
-- Lo que pasó DESPUÉS del corte y cuenta para el objetivo: todo, salvo los
-- ajustes de los conteos del 01-oct (el JSON los reemplaza), la bodega en
-- tránsito y lo que haya hecho esta misma unificación.
mov as (
  select im.item_id, im.warehouse_id, im.movement_type::text as tipo,
         im.quantity, im.reference_type,
         to_jsonb(im)->>'reason_code' as reason
  from public.inventory_movements im, p, corte k
  where im.business_id = p.b
    and im.created_at > k.frozen_at
    and im.warehouse_id not in (select id from wh where transito)
    -- coalesce: con reference_type o reference_id en NULL el `not (...)`
    -- daría NULL y el movimiento se perdería.
    and not coalesce(im.reference_type = 'physical_count'
                     and im.reference_id in (select id from ses where campania), false)
    and coalesce(im.reference_type, '') not like '%unificacion_almacen%'
),
st as (
  select s.item_id, s.warehouse_id, coalesce(s.quantity, 0) as q
  from public.inventory_stock s
  where s.warehouse_id in (select id from wh where not transito)
),
obj as (
  select mt.codigo, mt.descripcion, mt.item_id, mt.total,
         coalesce((select sum(mov.quantity) from mov
                    where mov.item_id = mt.item_id), 0) as post,
         coalesce((select sum(st.q) from st
                    where st.item_id = mt.item_id), 0) as actual
  from mt
  where mt.item_id is not null
),
filas (orden, seccion, item, detalle) as (
  -- 0 · Hora de corte: desde aquí se descuentan las ventas.
  select 0, '0 CORTE', 'ventas descontadas desde',
         to_char(p.corte at time zone p.tz, 'DD/MM/YYYY HH24:MI') || ' (hora RD)'
  from p
  union all
  select 0, '0 CORTE', p.pc_corte || ' (almacén)',
         coalesce((select s.status || ' · congelado '
                          || to_char(s.frozen_at at time zone p.tz, 'DD/MM/YYYY HH24:MI')
                     from public.physical_count_sessions s
                    where s.business_id = p.b and s.code = p.pc_corte),
                  '✗ NO EXISTE: el aplicar se niega')
  from p

  union all
  -- 1 · Ajustes del negocio que importan aquí.
  select 1, '1 AJUSTES', k.k, coalesce(bs.j->>k.k, '(columna no existe)')
  from (select to_jsonb(s) as j from public.business_settings s, p
         where s.business_id = p.b) bs
  cross join unnest(array['inventory_mode', 'warehouse_sections_enabled',
                          'transfers_require_approval',
                          'inventory_costing_method']) as k(k)

  union all
  -- 2 · Bodegas, con su existencia y lo que se movió en cada una.
  select 2, '2 BODEGAS',
         wh.name || case when wh.id = (select id from principal)
                         then '  ◀ PRINCIPAL (aquí cae la venta) → «Almacén Principal»'
                         when wh.transito then ''
                         when not wh.is_active then '  (ya apagada)'
                         else '  → se apaga' end,
         format('principal=%s · activa=%s · en_POS=%s · tipo=%s · área=%s · creada %s · id %s'
                || ' | existencia: %s ítems ≠0 (%s negativos), %s u, RD$%s'
                || ' | movimientos: %s; tras el corte: ventas %s u, otros %s u',
                wh.is_main, wh.is_active,
                coalesce(wh.j->>'shows_in_pos', '-'),
                coalesce(wh.j->>'warehouse_type', '-'),
                coalesce((select pa.name from public.print_areas pa
                           where pa.id::text = wh.j->>'production_area_id'), '-'),
                to_char(wh.created_at at time zone p.tz, 'DD/MM/YY HH24:MI'), wh.id,
                (select count(*) from public.inventory_stock s
                  where s.warehouse_id = wh.id and s.quantity <> 0),
                (select count(*) from public.inventory_stock s
                  where s.warehouse_id = wh.id and s.quantity < 0),
                (select round(coalesce(sum(s.quantity), 0), 2)
                   from public.inventory_stock s where s.warehouse_id = wh.id),
                (select to_char(coalesce(sum(s.quantity * it.cost), 0), 'FM999,999,990.00')
                   from public.inventory_stock s join it on it.id = s.item_id
                  where s.warehouse_id = wh.id),
                (select count(*) from public.inventory_movements im
                  where im.warehouse_id = wh.id),
                (select round(coalesce(-sum(mov.quantity), 0), 2) from mov
                  where mov.warehouse_id = wh.id and mov.tipo = 'sale'),
                (select round(coalesce(sum(mov.quantity), 0), 2) from mov
                  where mov.warehouse_id = wh.id and mov.tipo <> 'sale'))
  from wh, p

  union all
  -- 3 · Conteos físicos, y cuántas líneas coinciden con cada columna del JSON
  --     (dice si la parte de cafetería ya se cargó en alguna bodega).
  select 3, '3 CONTEOS', ses.code || ' · ' || ses.bodega,
         format('%s · congelado %s · cerrado %s · líneas %s, contadas %s, ajustadas %s'
                || ' · coinciden con JSON: cafetería %s, almacén %s, total %s%s',
                ses.status,
                coalesce(to_char(ses.frozen_at at time zone p.tz, 'DD/MM HH24:MI'), '-'),
                coalesce(to_char(ses.completed_at at time zone p.tz, 'DD/MM HH24:MI'), '-'),
                (select count(*) from public.physical_count_lines l
                  where l.session_id = ses.id),
                (select count(*) from public.physical_count_lines l
                  where l.session_id = ses.id and l.counted_quantity is not null),
                (select count(*) from public.physical_count_lines l
                  where l.session_id = ses.id and l.applied_adjustment_id is not null),
                (select count(*) from public.physical_count_lines l
                   join mt on mt.item_id = l.item_id
                  where l.session_id = ses.id and mt.caf > 0
                    and l.counted_quantity = mt.caf),
                (select count(*) from public.physical_count_lines l
                   join mt on mt.item_id = l.item_id
                  where l.session_id = ses.id and mt.alm > 0
                    and l.counted_quantity = mt.alm),
                (select count(*) from public.physical_count_lines l
                   join mt on mt.item_id = l.item_id
                  where l.session_id = ses.id and mt.total > 0
                    and l.counted_quantity = mt.total),
                case when ses.campania
                     then ' · CAMPAÑA 01-OCT: su ajuste lo reemplaza el JSON' else '' end)
  from ses, p

  union all
  select 3, '3 CONTEOS', p.pc_corte || ' vs columna almacén del JSON',
         (select format('%s diferencias%s', count(*),
                        coalesce(': ' || string_agg(it.name || ' (conteo ' || l.counted_quantity
                                 || ' / JSON ' || coalesce(mt.alm::text, 'no está') || ')', '; '), ''))
            from public.physical_count_lines l
            join corte k on k.id = l.session_id
            join it on it.id = l.item_id
            left join mt on mt.item_id = l.item_id
           where l.counted_quantity is not null
             and l.counted_quantity is distinct from coalesce(mt.alm, 0))
  from p

  union all
  -- 4 · ¿Hubo ventas el 01-oct alrededor del corte?
  select 4, '4 VENTAS 01-OCT', x.cual,
         format('%s movimientos, %s u', count(im.id), round(coalesce(-sum(im.quantity), 0), 2))
  from p
  cross join corte k
  cross join (values ('a) antes del corte'), ('b) después del corte, mismo día')) x(cual)
  left join public.inventory_movements im
    on im.business_id = p.b and im.movement_type = 'sale'
   and (im.created_at at time zone p.tz)::date = date '2026-10-01'
   and ((x.cual like 'a%' and im.created_at <= k.frozen_at)
     or (x.cual like 'b%' and im.created_at > k.frozen_at))
  group by x.cual

  union all
  select 4, '4 VENTAS 01-OCT', 'c) primera venta registrada en el negocio',
         coalesce(to_char(min(im.created_at) at time zone p.tz, 'DD/MM/YYYY HH24:MI'), 'ninguna')
  from p
  left join public.inventory_movements im
    on im.business_id = p.b and im.movement_type = 'sale'
  group by p.tz

  union all
  -- 5 · Qué se movió después del corte (lo que se va a descontar o sumar).
  select 5, '5 TRAS EL CORTE',
         mov.tipo || coalesce(' / ' || mov.reference_type, '') || coalesce(' / ' || mov.reason, ''),
         format('%s movimientos, %s u, %s ítems', count(*), round(sum(mov.quantity), 2),
                count(distinct mov.item_id))
  from mov
  group by mov.tipo, mov.reference_type, mov.reason

  union all
  -- 6 · Lo que impide aplicar (o merece aviso).
  select 6, '6 BLOQUEOS', 'conteos abiertos',
         coalesce(string_agg(ses.code || ' (' || ses.status || ')'
                             || case when ses.code = p.pc_abandonado
                                       and coalesce((ses.frozen_at at time zone p.tz)::date,
                                                    date '2026-10-01') = date '2026-10-01'
                                     then ' → el aplicar lo CANCELA' else ' ✗ BLOQUEA' end,
                             ', '), 'ninguno')
  from ses, p where ses.status in ('draft', 'in_progress')

  union all
  select 6, '6 BLOQUEOS', 'conteos completados DESPUÉS del 01-oct',
         coalesce(string_agg(ses.code || ' · ' || ses.bodega, ', '), 'ninguno')
  from ses, p
  where ses.status = 'completed'
    and (ses.frozen_at at time zone p.tz)::date > date '2026-10-01'

  union all
  select 6, '6 BLOQUEOS', 'transferencias sin cerrar', count(*)::text
  from public.stock_transfers t, p
  where t.business_id = p.b and t.status in ('sent', 'pending_approval')

  union all
  select 6, '6 AVISO', 'órdenes abiertas con consumo fuera de la principal',
         count(distinct z.reference_id)::text
  from (select im.reference_id
          from public.inventory_movements im
          join public.orders o on o.id = im.reference_id, p
         where im.business_id = p.b
           and im.reference_type = 'order' and im.movement_type = 'sale'
           and im.warehouse_id <> (select id from principal)
           and o.status in ('open', 'sent', 'served')
           and coalesce(o.status_ext::text, 'open') not in ('paid', 'void')
         group by im.reference_id, im.warehouse_id, im.item_id
        having sum(im.quantity) <> 0) z

  union all
  select 6, '6 AVISO', 'existencia en tránsito (__IN_TRANSIT__)',
         coalesce((select format('%s ítems, %s u', count(*), round(coalesce(sum(s.quantity), 0), 2))
                     from public.inventory_stock s
                    where s.warehouse_id in (select id from wh where transito)
                      and s.quantity <> 0), '0')

  union all
  -- 7 · Otras tablas que apuntan a una bodega que se va a apagar.
  select 7, '7 REFERENCIAS', c.table_name || '.' || c.column_name,
         x.n || ' filas apuntan a una bodega que no es la principal'
  from information_schema.columns c
  join information_schema.tables t
    on t.table_schema = c.table_schema and t.table_name = c.table_name
   and t.table_type = 'BASE TABLE'
  cross join lateral (
    select (xpath('/row/n/text()', query_to_xml(format(
             'select count(*) as n from public.%I where %I = any (%L::uuid[])',
             c.table_name, c.column_name,
             (select coalesce(array_agg(wh.id), '{}'::uuid[]) from wh
               where not wh.transito
                 and wh.id <> (select id from principal))::text),
           false, true, '')))[1]::text::int as n
  ) x
  where c.table_schema = 'public' and c.data_type = 'uuid'
    and c.column_name like '%warehouse%'
    and c.table_name not in ('warehouses', 'inventory_stock', 'inventory_movements',
                             'physical_count_sessions', 'physical_count_lines')
    and x.n > 0

  union all
  -- 8 · Cruce del conteo con el sistema y vista previa del resultado.
  select 8, '8 CRUCE', 'a) códigos del conteo (cafetería)',
         format('%s líneas · encontradas %s · no existen %s · ambiguas %s',
                count(*), count(mt.item_id),
                count(*) filter (where mt.n_sku = 0 and mt.n_bc = 0),
                count(*) filter (where mt.item_id is null
                                   and not (mt.n_sku = 0 and mt.n_bc = 0)))
  from mt

  union all
  select 8, '8 CRUCE', 'b) no existen en el sistema',
         coalesce(string_agg(mt.codigo || ' ' || mt.descripcion, '; '), 'ninguno')
  from mt where mt.n_sku = 0 and mt.n_bc = 0

  union all
  select 8, '8 CRUCE', 'c) ambiguos (más de un insumo con ese código)',
         coalesce(string_agg(mt.codigo || ' ' || mt.descripcion
                             || ' (sku ' || mt.n_sku || ', barras ' || mt.n_bc || ')', '; '),
                  'ninguno')
  from mt where mt.item_id is null and not (mt.n_sku = 0 and mt.n_bc = 0)

  union all
  select 8, '8 VISTA PREVIA', 'd) objetivo = contado + lo movido tras el corte',
         format('contado %s u · tras el corte %s u · objetivo %s u · hoy (todas las bodegas) %s u'
                || ' · ajuste neto %s u (+%s / %s) · valor del ajuste RD$%s',
                round(sum(obj.total), 2), round(sum(obj.post), 2),
                round(sum(obj.total + obj.post), 2), round(sum(obj.actual), 2),
                round(sum(obj.total + obj.post - obj.actual), 2),
                round(sum(greatest(obj.total + obj.post - obj.actual, 0)), 2),
                round(sum(least(obj.total + obj.post - obj.actual, 0)), 2),
                to_char(sum((obj.total + obj.post - obj.actual) * it.cost), 'FM999,999,990.00'))
  from obj join it on it.id = obj.item_id

  union all
  select 8, '8 VISTA PREVIA', 'e) quedarán en NEGATIVO (salió más de lo contado)',
         format('%s%s', count(*),
                coalesce(': ' || string_agg(obj.descripcion || ' (contado ' || trim_scale(obj.total)
                         || ', tras corte ' || trim_scale(obj.post) || ')', '; '), ''))
  from obj where obj.total + obj.post < 0

  union all
  select 8, '8 VISTA PREVIA', 'f) NO contados con existencia en otras bodegas (solo se mudan)',
         format('%s ítems, %s u', count(distinct st.item_id), round(coalesce(sum(st.q), 0), 2))
  from st
  where st.warehouse_id <> (select id from principal) and st.q <> 0
    and st.item_id not in (select mt.item_id from mt where mt.item_id is not null)

  union all
  select 8, '8 VISTA PREVIA', 'g) NO contados con existencia ≠ 0 (quedan con su número)',
         format('%s ítems', count(*))
  from (select st.item_id from st
         where st.item_id not in (select mt.item_id from mt where mt.item_id is not null)
         group by st.item_id having sum(st.q) <> 0) z
)
select orden, seccion, item, detalle
from filas
order by orden, seccion, item;
