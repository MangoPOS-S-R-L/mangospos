-- =============================================================================
-- UNIF_1_aplicar.sql — Estancia Nueva · CAFETERÍA (85924083)
--
-- UNA SOLA BODEGA: la principal. Todo lo que haya en las demás se muda a la
-- principal y las demás se APAGAN (no se borran: su kardex queda).
--
-- Y LA EXISTENCIA DE LO CONTADO EL 01-OCT QUEDA EN:
--     contado (cafetería + almacén, del JSON)
--   + todo lo que se movió DESPUÉS del corte (ventas restan; compras, mermas,
--     anulaciones, producción... cuentan con su signo)
--   El corte = 2026-10-01 11:55:00-04 (hora RD): la cafetería se contó en la mañana,
--   antes de abrir (dueño, 13-oct; en la app se empezó a contar a las 11:55 y
--   la primera venta fue 12:58). Así se descuentan TODAS las ventas. El
--   almacén (PC-2026-000004) se contó a las 14:24, pero de ahí no se vende: lo
--   que se vendió antes salió de los estantes ya contados.
--   Los ajustes de los conteos del 01-oct NO cuentan: el JSON los reemplaza
--   (si no, el almacén se sumaría dos veces).
--   Lo que NO se contó conserva su número; solo se muda a la principal.
--
-- PASOS (todo en una transacción; si algo no cuadra, no queda nada hecho):
--   0. Guardias: ya corrido, una sola principal, conteo del almacén, conteos
--      abiertos (salvo PC-2026-000002) o posteriores, transferencias sin
--      cerrar, códigos ambiguos, ajustes MANUALES después del corte.
--   1. Respaldo en public.zz_backup_unif_almacen_85924083.
--   2. PC-2026-000002 (conteo de la cafetería empezado el 01-oct en la app y
--      abandonado, congelado con la foto de ese día) → cancelado: aplicarlo
--      hoy pisaría todo. La principal pasa a llamarse «Almacén Principal».
--      Las otras bodegas: is_active=false, is_main=false, shows_in_pos=false;
--      warehouse_sections_enabled=false. Órdenes de compra pendientes
--      (draft/sent/partial) que apuntaban a otra bodega → la principal.
--   3. Órdenes ABIERTAS que consumieron de otra bodega se recalculan con
--      consume_inventory_from_order: su consumo pasa a la principal (si no, al
--      anular un ítem devolvería la mercancía a una bodega apagada).
--   4. Mudanza: transfer_out/transfer_in (saldo positivo) o ajuste de
--      corrección (saldo negativo) de cada bodega a la principal.
--   5. Ajuste por conteo en la principal: objetivo − lo que hay.
--      Con capas de costo encendidas (fifo/lifo/average): las ventas desde el
--      corte salieron SIN capa (faltante). Las capas que crea esta corrida se
--      netean de eso, para que lo que queda en capas = la existencia.
--   6. Verificación: otras bodegas en 0, contados = objetivo, no contados
--      con el mismo total de antes, una sola bodega activa.
--
-- ANTES: correr UNIF_0_diagnostico.sql. DESHACER: UNIF_9_deshacer.sql.
-- GENERADO por build_unificar_almacen.py (196 códigos). Editar el
-- .py o el _tpl, no este archivo.
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '300s';

create temp table _conteo (
  codigo      text primary key,
  descripcion text not null,
  caf         numeric not null,
  alm         numeric not null,
  total       numeric not null
) on commit drop;

insert into _conteo (codigo, descripcion, caf, alm, total) values
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
    ('8002230000302', 'BOTELLA  APEROL', 0, 5, 5);

-- Respaldo y bitácora del reporte. RLS encendido y sin políticas: no se ve
-- por la API, solo desde el SQL Editor.
create table if not exists public.zz_backup_unif_almacen_85924083 (
  id        bigserial primary key,
  corrida   timestamptz not null,
  tipo      text not null,
  ref_id    uuid,
  orden     int,
  datos     jsonb not null
);
alter table public.zz_backup_unif_almacen_85924083 enable row level security;

do $unif$
declare
  v_biz    constant uuid := '85924083-2e8e-4e64-8192-808ee24674ed';
  PC   constant text := 'PC-2026-000004';
  PC_ABANDONADO constant text := 'PC-2026-000002';
  CORTE constant timestamptz := '2026-10-01 11:55:00-04';
  NOMBRE_PRINCIPAL constant text := 'Almacén Principal';
  REF  constant text := 'unificacion_almacen_20261013';
  TZ   constant text := 'America/Santo_Domingo';
  -- AJUSTES MANUALES (reference_type stock_adjustment o vacío) hechos después
  -- del corte sobre ítems contados. Los de documentos (p. ej. anular una
  -- recepción directa) cuentan siempre, como la compra que anulan.
  --   'abortar' → no aplica nada y avisa (por defecto)
  --   'sumar'   → cuentan, como una compra o una merma
  --   'ignorar' → no cuentan (el conteo del 01-oct manda)
  AJUSTES_MANUALES constant text := 'abortar';

  v_run   timestamptz := clock_timestamp();
  v_main  uuid;
  v_main_name text;
  v_pc    uuid;
  v_corte timestamptz;
  v_n     int;
  v_txt   text;
  v_ord   uuid;
  v_reorders int := 0;
  v_compras int := 0;
  v_apagadas text;
  v_cancelado text;
  v_metodo text;
  v_capa record;
  v_item record;
  v_need numeric;
  v_take numeric;
  v_neteado numeric := 0;
begin
  -- ---------------------------------------------------------------------
  -- 0. Guardias
  -- ---------------------------------------------------------------------
  -- Corrida previa SIN deshacer = movimientos REF sin su inverso.
  if exists (select 1 from public.inventory_movements m
              where m.business_id = v_biz and m.reference_type like REF || '%'
                and not exists (select 1 from public.inventory_movements u
                                 where u.reference_type = 'deshacer_' || REF
                                   and u.reference_id = m.id)) then
    raise exception 'YA SE CORRIÓ (hay movimientos %). Para repetir, primero UNIF_9_deshacer.sql.', REF;
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'inventory_movements'
                    and column_name = 'reason_code')
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'warehouses'
                       and column_name = 'shows_in_pos') then
    raise exception 'Faltan columnas (inventory_movements.reason_code o warehouses.shows_in_pos): no se aplicó nada.';
  end if;

  select count(*) into v_n
  from public.warehouses
  where business_id = v_biz and coalesce(is_main, false) and coalesce(is_active, true)
    and name <> '__IN_TRANSIT__';
  if v_n <> 1 then
    raise exception 'Se esperaba UNA bodega principal activa y hay %. Marcar la principal en la app y volver a correr.', v_n;
  end if;

  select id, name into v_main, v_main_name
  from public.warehouses
  where business_id = v_biz and coalesce(is_main, false) and coalesce(is_active, true)
    and name <> '__IN_TRANSIT__';

  v_corte := CORTE;

  -- El conteo del almacén: sus ajustes los reemplaza el JSON.
  select id into v_pc
  from public.physical_count_sessions
  where business_id = v_biz and code = PC and status = 'completed';
  if v_pc is null then
    raise exception 'No está el conteo % completado (el almacén del JSON). No se aplicó nada.', PC;
  end if;

  if exists (select 1 from public.warehouses
              where business_id = v_biz and id <> v_main and name = NOMBRE_PRINCIPAL) then
    raise exception 'Ya hay otra bodega llamada «%». No se aplicó nada.', NOMBRE_PRINCIPAL;
  end if;

  -- Conteos abiertos: el abandonado del 01-oct se cancela abajo; otro, aborta.
  select string_agg(code || ' (' || status || ')', ', ') into v_txt
  from public.physical_count_sessions
  where business_id = v_biz and status in ('draft', 'in_progress')
    and not (code = PC_ABANDONADO
             and coalesce((frozen_at at time zone TZ)::date, date '2026-10-01')
                 = date '2026-10-01');
  if v_txt is not null then
    raise exception 'Hay conteos abiertos: %. Cerrarlos o cancelarlos antes.', v_txt;
  end if;

  select string_agg(code, ', ') into v_txt
  from public.physical_count_sessions
  where business_id = v_biz and status = 'completed'
    and (frozen_at at time zone TZ)::date > date '2026-10-01';
  if v_txt is not null then
    raise exception 'Hay conteos completados DESPUÉS del 01-oct (%): decidir si mandan ellos o el JSON. No se aplicó nada.', v_txt;
  end if;

  select count(*) into v_n
  from public.stock_transfers
  where business_id = v_biz and status in ('sent', 'pending_approval');
  if v_n > 0 then
    raise exception 'Hay % transferencias sin cerrar: recibirlas o cancelarlas antes.', v_n;
  end if;

  -- Emparejar por código: sku primero; si no hay sku, código de barras.
  create temp table _match on commit drop as
  select c.*,
         (select count(*) from public.inventory_items i
           where i.business_id = v_biz and i.sku = c.codigo)     as n_sku,
         (select count(*) from public.inventory_items i
           where i.business_id = v_biz and i.barcode = c.codigo) as n_bc,
         null::uuid as item_id
  from _conteo c;

  update _match m
     set item_id = (select i.id from public.inventory_items i
                     where i.business_id = v_biz and i.sku = m.codigo)
   where m.n_sku = 1;
  update _match m
     set item_id = (select i.id from public.inventory_items i
                     where i.business_id = v_biz and i.barcode = m.codigo)
   where m.n_sku = 0 and m.n_bc = 1;

  select string_agg(codigo || ' ' || descripcion, '; ') into v_txt
  from _match where item_id is null and not (n_sku = 0 and n_bc = 0);
  if v_txt is not null then
    raise exception 'Códigos con más de un insumo (ambiguos): %. No se aplicó nada.', v_txt;
  end if;

  select string_agg(z.codigos, ' | ') into v_txt
  from (select string_agg(codigo, ' y ') as codigos from _match
         where item_id is not null group by item_id having count(*) > 1) z;
  if v_txt is not null then
    raise exception 'Dos códigos del conteo caen en el MISMO insumo: %. No se aplicó nada.', v_txt;
  end if;

  select count(*) into v_n from _match where item_id is not null;
  if v_n < 147 then
    raise exception 'Solo % de % códigos existen en este negocio: ¿es el negocio correcto? No se aplicó nada.',
      v_n, (select count(*) from _match);
  end if;

  -- ---------------------------------------------------------------------
  -- 1. Respaldo
  -- ---------------------------------------------------------------------
  insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, ref_id, datos)
  select v_run, 'warehouse', w.id, to_jsonb(w)
  from public.warehouses w where w.business_id = v_biz;

  insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, ref_id, datos)
  select v_run, 'business_settings', v_biz, to_jsonb(s)
  from public.business_settings s where s.business_id = v_biz;

  insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, ref_id, datos)
  select v_run, 'stock', s.warehouse_id,
         jsonb_build_object('item_id', s.item_id, 'quantity', s.quantity)
  from public.inventory_stock s
  join public.warehouses w on w.id = s.warehouse_id
  where w.business_id = v_biz and s.quantity <> 0;

  insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, ref_id, datos)
  select v_run, 'count_session', s.id, to_jsonb(s)
  from public.physical_count_sessions s
  where s.business_id = v_biz and s.code = PC_ABANDONADO
    and s.status in ('draft', 'in_progress');

  -- ---------------------------------------------------------------------
  -- 2. Una sola bodega
  -- ---------------------------------------------------------------------
  -- El conteo abandonado del 01-oct: congelado con la foto de ese día, si
  -- alguien lo aplicara hoy pisaría la existencia. Igual que el botón
  -- Cancelar de la app (fn_physical_count_cancel), con su motivo.
  update public.physical_count_sessions
     set status = 'cancelled', cancelled_at = now(),
         cancellation_reason = 'Abandonado el 01-oct; la cafetería se cargó con '
                               || 'la unificación de almacenes del 13-oct'
   where business_id = v_biz and code = PC_ABANDONADO
     and status in ('draft', 'in_progress')
  returning code into v_cancelado;

  update public.warehouses
     set name = NOMBRE_PRINCIPAL
   where id = v_main and name <> NOMBRE_PRINCIPAL;

  select string_agg(name, ', ' order by name) into v_apagadas
  from public.warehouses
  where business_id = v_biz and id <> v_main and name <> '__IN_TRANSIT__'
    and coalesce(is_active, true);

  update public.warehouses
     set is_active = false, is_main = false, shows_in_pos = false
   where business_id = v_biz and id <> v_main and name <> '__IN_TRANSIT__'
     and (coalesce(is_active, true) or coalesce(is_main, false) or shows_in_pos);

  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'business_settings'
                and column_name = 'warehouse_sections_enabled') then
    execute 'update public.business_settings set warehouse_sections_enabled = false
              where business_id = $1 and warehouse_sections_enabled' using v_biz;
  end if;

  -- Órdenes de COMPRA pendientes que apuntan a una bodega que se apaga: al
  -- recibirlas, la mercancía caería en esa bodega. Pasan a la principal.
  insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, ref_id, datos)
  select v_run, 'purchase_order', po.id,
         jsonb_build_object('warehouse_id', po.warehouse_id, 'status', po.status)
  from public.purchase_orders po
  where po.business_id = v_biz and po.warehouse_id <> v_main
    and po.status::text in ('draft', 'sent', 'partial');

  update public.purchase_orders po
     set warehouse_id = v_main
   where po.business_id = v_biz and po.warehouse_id <> v_main
     and po.status::text in ('draft', 'sent', 'partial');
  get diagnostics v_compras = row_count;

  -- ---------------------------------------------------------------------
  -- 3. Órdenes abiertas que consumieron de otra bodega
  -- ---------------------------------------------------------------------
  for v_ord in
    select distinct z.reference_id
    from (select im.reference_id
            from public.inventory_movements im
            join public.orders o on o.id = im.reference_id
           where im.business_id = v_biz
             and im.reference_type = 'order' and im.movement_type = 'sale'
             and im.warehouse_id <> v_main
             and o.status in ('open', 'sent', 'served')
             and coalesce(o.status_ext::text, 'open') not in ('paid', 'void')
           group by im.reference_id, im.warehouse_id, im.item_id
          having sum(im.quantity) <> 0) z
  loop
    perform public.consume_inventory_from_order(v_ord);
    v_reorders := v_reorders + 1;
  end loop;

  -- ---------------------------------------------------------------------
  -- Objetivo de cada ítem contado = contado + lo movido después del corte
  -- ---------------------------------------------------------------------
  create temp table _post on commit drop as
  select im.item_id,
         sum(im.quantity) as todo,
         coalesce(sum(im.quantity) filter (
                    where im.movement_type = 'adjustment'
                      and coalesce(im.reference_type, '') in ('', 'stock_adjustment')), 0)
           as ajustes,
         count(*) filter (where im.movement_type = 'adjustment'
                            and coalesce(im.reference_type, '') in ('', 'stock_adjustment'))
           as n_ajustes
  from public.inventory_movements im
  join public.warehouses w on w.id = im.warehouse_id
  where im.business_id = v_biz
    and im.created_at > v_corte
    and w.name <> '__IN_TRANSIT__'
    and coalesce(im.reference_type, '') not like '%unificacion_almacen%'
    -- coalesce: con reference_type o reference_id en NULL (compras, ajustes
    -- a mano) el `not (...)` daría NULL y el movimiento se perdería.
    and not coalesce(im.reference_type = 'physical_count'
                     and im.reference_id in (
                       select s.id from public.physical_count_sessions s
                        where s.business_id = v_biz and s.status = 'completed'
                          and (s.frozen_at at time zone TZ)::date = date '2026-10-01'),
                     false)
    and im.item_id in (select item_id from _match where item_id is not null)
  group by im.item_id;

  select count(*) into v_n from _post where n_ajustes > 0;
  if v_n > 0 and AJUSTES_MANUALES = 'abortar' then
    raise exception '% ítems contados tienen AJUSTES MANUALES después del corte. Ver la sección 5 del diagnóstico y poner AJUSTES_MANUALES = sumar o ignorar. No se aplicó nada.', v_n;
  end if;

  create temp table _obj on commit drop as
  select m.codigo, m.descripcion, m.item_id, m.total,
         coalesce(p.todo, 0)
           - case when AJUSTES_MANUALES = 'ignorar' then coalesce(p.ajustes, 0) else 0 end
           as post
  from _match m
  left join _post p on p.item_id = m.item_id
  where m.item_id is not null;

  -- Total de cada ítem en todas las bodegas, ANTES de mudar (para verificar
  -- que a los no contados no les cambia nada).
  create temp table _antes on commit drop as
  select s.item_id, sum(s.quantity) as q
  from public.inventory_stock s
  join public.warehouses w on w.id = s.warehouse_id
  where w.business_id = v_biz and w.name <> '__IN_TRANSIT__'
  group by s.item_id;

  -- ---------------------------------------------------------------------
  -- 4. Mudanza a la principal
  -- ---------------------------------------------------------------------
  create temp table _mudanza on commit drop as
  select s.warehouse_id, w.name as bodega, s.item_id, s.quantity,
         nullif(coalesce(i.cost, 0), 0) as cost
  from public.inventory_stock s
  join public.warehouses w on w.id = s.warehouse_id
  join public.inventory_items i on i.id = s.item_id
  where w.business_id = v_biz and w.id <> v_main and w.name <> '__IN_TRANSIT__'
    and s.quantity <> 0;

  insert into public.inventory_movements
    (business_id, warehouse_id, item_id, movement_type, quantity,
     cost_per_unit, reference_id, reference_type, reason_code, notes)
  select v_biz, x.warehouse_id, x.item_id,
         (case when x.quantity > 0 then 'transfer_out' else 'adjustment' end)::public.movement_type,
         -x.quantity, x.cost, v_main, REF,
         case when x.quantity < 0 then 'correction' end,
         'Unificación de almacenes: pasa a ' || NOMBRE_PRINCIPAL
  from _mudanza x;

  insert into public.inventory_movements
    (business_id, warehouse_id, item_id, movement_type, quantity,
     cost_per_unit, reference_id, reference_type, reason_code, notes)
  select v_biz, v_main, x.item_id,
         (case when x.quantity > 0 then 'transfer_in' else 'adjustment' end)::public.movement_type,
         x.quantity, x.cost, x.warehouse_id, REF,
         case when x.quantity < 0 then 'correction' end,
         'Unificación de almacenes: viene de ' || x.bodega
  from _mudanza x;

  -- ---------------------------------------------------------------------
  -- 5. Ajuste por conteo en la principal
  -- ---------------------------------------------------------------------
  create temp table _aj on commit drop as
  select o.item_id, o.codigo, o.descripcion, o.total, o.post,
         o.total + o.post as objetivo,
         coalesce((select s.quantity from public.inventory_stock s
                    where s.warehouse_id = v_main and s.item_id = o.item_id), 0) as en_principal
  from _obj o;

  insert into public.inventory_movements
    (business_id, warehouse_id, item_id, movement_type, quantity,
     cost_per_unit, reference_id, reference_type, reason_code, notes)
  select v_biz, v_main, a.item_id, 'adjustment'::public.movement_type,
         a.objetivo - a.en_principal,
         nullif(coalesce(i.cost, 0), 0), v_pc, REF || '_conteo', 'physical_count',
         format('Conteo 01-oct (cafetería + almacén) = %s; movido después del conteo = %s',
                a.total, a.post)
  from _aj a
  join public.inventory_items i on i.id = a.item_id
  where a.objetivo - a.en_principal <> 0;

  -- Capas de costo (solo si el motor está encendido). Las ventas desde el
  -- corte salieron sin capa y quedaron como faltante; las capas que acaba de
  -- crear esta corrida (la mudanza y el ajuste) traen la cantidad completa.
  -- Sin esto, lo que queda en capas superaría la existencia en lo ya vendido
  -- Por cada par bodega-insumo, la más nueva primero, hasta capas = existencia:
  --   · en la principal se recortan SOLO capas de esta corrida;
  --   · en las bodegas apagadas (quedan en 0 para siempre) cualquier capa que
  --     sobre: nadie la consumiría y la valuación por capas la contaría.
  select coalesce(bs.inventory_costing_method, 'last_price') into v_metodo
  from public.business_settings bs where bs.business_id = v_biz;

  if coalesce(v_metodo, 'last_price') <> 'last_price'
     and to_regclass('public.inventory_cost_layers') is not null then
    for v_item in
      select l.warehouse_id, l.item_id,
             sum(l.quantity_remaining)
               - greatest(coalesce(max(s.quantity), 0), 0) as exceso
      from public.inventory_cost_layers l
      join public.warehouses w on w.id = l.warehouse_id
      left join public.inventory_stock s
        on s.warehouse_id = l.warehouse_id and s.item_id = l.item_id
      where l.business_id = v_biz and w.name <> '__IN_TRANSIT__'
        and l.quantity_remaining > 0
        and (l.warehouse_id <> v_main
             or exists (select 1 from public.inventory_cost_layers l2
                          join public.inventory_movements m2 on m2.id = l2.source_movement_id
                         where l2.warehouse_id = l.warehouse_id and l2.item_id = l.item_id
                           and l2.quantity_remaining > 0
                           and m2.reference_type like REF || '%'))
      group by l.warehouse_id, l.item_id
      having sum(l.quantity_remaining)
               - greatest(coalesce(max(s.quantity), 0), 0) > 0
    loop
      v_need := v_item.exceso;
      for v_capa in
        select l.id, l.quantity_remaining
        from public.inventory_cost_layers l
        left join public.inventory_movements m on m.id = l.source_movement_id
        where l.business_id = v_biz and l.warehouse_id = v_item.warehouse_id
          and l.item_id = v_item.item_id and l.quantity_remaining > 0
          and (v_item.warehouse_id <> v_main
               or coalesce(m.reference_type, '') like REF || '%')
        order by l.seq desc
      loop
        exit when v_need <= 0;
        v_take := least(v_capa.quantity_remaining, v_need);
        update public.inventory_cost_layers
           set quantity_remaining = quantity_remaining - v_take,
               notes = concat_ws(' · ', notes,
                                 'neteada ' || v_take || ' por ventas sin capa desde el corte')
         where id = v_capa.id;
        insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, ref_id, datos)
        values (v_run, 'capa_neteada', v_capa.id,
                jsonb_build_object('warehouse_id', v_item.warehouse_id,
                                   'item_id', v_item.item_id, 'cantidad', v_take));
        v_need := v_need - v_take;
        v_neteado := v_neteado + v_take;
      end loop;
    end loop;
  end if;

  -- ---------------------------------------------------------------------
  -- 6. Verificación: si algo no cuadra, se deshace todo
  -- ---------------------------------------------------------------------
  select count(*) into v_n
  from public.inventory_stock s
  join public.warehouses w on w.id = s.warehouse_id
  where w.business_id = v_biz and w.id <> v_main and w.name <> '__IN_TRANSIT__'
    and s.quantity <> 0;
  if v_n > 0 then
    raise exception 'VERIFICACIÓN: quedan % existencias fuera de la principal. No se aplicó nada.', v_n;
  end if;

  select count(*) into v_n
  from _aj a
  left join public.inventory_stock s on s.warehouse_id = v_main and s.item_id = a.item_id
  where coalesce(s.quantity, 0) <> a.objetivo;
  if v_n > 0 then
    raise exception 'VERIFICACIÓN: % ítems contados no quedaron en su objetivo. No se aplicó nada.', v_n;
  end if;

  select count(*) into v_n
  from (
    select coalesce(x.item_id, y.item_id) as item_id,
           coalesce(x.q, 0) as antes, coalesce(y.q, 0) as despues
    from _antes x
    full join (select s.item_id, sum(s.quantity) as q
                 from public.inventory_stock s
                 join public.warehouses w on w.id = s.warehouse_id
                where w.business_id = v_biz and w.name <> '__IN_TRANSIT__'
                group by s.item_id) y on y.item_id = x.item_id
  ) z
  where z.item_id not in (select item_id from _obj)
    and z.antes <> z.despues;
  if v_n > 0 then
    raise exception 'VERIFICACIÓN: % ítems NO contados cambiaron de total. No se aplicó nada.', v_n;
  end if;

  select count(*) into v_n
  from public.warehouses
  where business_id = v_biz and coalesce(is_active, true) and name <> '__IN_TRANSIT__';
  if v_n <> 1 then
    raise exception 'VERIFICACIÓN: quedaron % bodegas activas. No se aplicó nada.', v_n;
  end if;

  -- ---------------------------------------------------------------------
  -- Reporte (queda guardado en la tabla de respaldo, tipo = 'reporte')
  -- ---------------------------------------------------------------------
  insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, orden, datos)
  select v_run, 'reporte', r.orden,
         jsonb_build_object('concepto', r.concepto, 'resultado', r.resultado)
  from (
    select 1 as orden, 'Bodega única (principal)' as concepto,
           NOMBRE_PRINCIPAL || case when v_main_name <> NOMBRE_PRINCIPAL
                                    then ' (antes «' || v_main_name || '»)' else '' end
             as resultado
    union all
    select 2, 'Bodegas apagadas', coalesce(v_apagadas, 'ninguna (ya era una sola)')
    union all
    select 3, 'Corte (ventas descontadas desde)',
           to_char(v_corte at time zone TZ, 'DD/MM/YYYY HH24:MI') || ' hora RD'
    union all
    select 3, 'Conteo abandonado cancelado', coalesce(v_cancelado, 'ninguno')
    union all
    select 4, 'Órdenes abiertas recalculadas a la principal', v_reorders::text
    union all
    select 4, 'Órdenes de compra pendientes pasadas a la principal', v_compras::text
    union all
    select 5, 'Mudanza a la principal',
           (select format('%s ítems · %s u desde %s bodega(s)', count(distinct item_id),
                          round(coalesce(sum(quantity), 0), 2), count(distinct warehouse_id))
              from _mudanza)
    union all
    select 6, 'Códigos del conteo',
           (select format('%s líneas · %s encontradas · %s no existen en el sistema',
                          count(*), count(item_id),
                          count(*) filter (where item_id is null)) from _match)
    union all
    select 7, 'No existen (no se cargaron)',
           coalesce((select string_agg(codigo || ' ' || descripcion || ' = ' || total, '; ')
                       from _match where item_id is null), 'ninguno')
    union all
    select 8, 'Contado → objetivo',
           (select format('contado %s u · movido después del conteo %s u · objetivo %s u',
                          round(sum(total), 2), round(sum(post), 2), round(sum(objetivo), 2))
              from _aj)
    union all
    select 9, 'Ajuste por conteo en la principal',
           (select format('%s ítems · +%s u / %s u · valor RD$%s',
                          count(*) filter (where a.objetivo <> a.en_principal),
                          round(sum(greatest(a.objetivo - a.en_principal, 0)), 2),
                          round(sum(least(a.objetivo - a.en_principal, 0)), 2),
                          to_char(sum((a.objetivo - a.en_principal) * coalesce(i.cost, 0)),
                                  'FM999,999,990.00'))
              from _aj a join public.inventory_items i on i.id = a.item_id)
    union all
    select 10, 'Ajustes manuales después del corte',
           (select format('%s ítems (%s)', count(*), AJUSTES_MANUALES)
              from _post where n_ajustes > 0)
    union all
    select 11, 'Quedan en NEGATIVO (salió más de lo contado)',
           (select format('%s%s', count(*),
                          coalesce(': ' || string_agg(descripcion || ' ' || trim_scale(objetivo), '; '), ''))
              from _aj where objetivo < 0)
    union all
    select 12, 'Capas de costo (' || coalesce(v_metodo, 'last_price') || ')',
           case when coalesce(v_metodo, 'last_price') = 'last_price'
                then 'motor apagado: nada que netear'
                else 'neteadas ' || trim_scale(v_neteado) || ' u (ventas sin capa desde el corte; bodegas apagadas en 0)'
           end
    union all
    select 13, 'Verificación', '✓ otras bodegas en 0 · contados = objetivo · no contados intactos · 1 bodega activa'
  ) r;

  raise notice 'OK — bodega única "%": unificación aplicada.', v_main_name;
end
$unif$;

commit;

-- Reporte de esta corrida (la última).
select (b.datos->>'concepto') as concepto, (b.datos->>'resultado') as resultado
from public.zz_backup_unif_almacen_85924083 b
where b.tipo = 'reporte'
  and b.corrida = (select max(corrida) from public.zz_backup_unif_almacen_85924083
                    where tipo = 'reporte')
order by b.orden;
