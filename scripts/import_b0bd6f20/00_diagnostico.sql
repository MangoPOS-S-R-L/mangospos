-- ============================================================================
-- DIAGNÓSTICO PREVIO A LA CARGA — business b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee
-- Fuente: "Catalogo de productos (Transformados)", 07/10/2026, 190 filas.
--
-- CORRE ESTO PRIMERO Y PÉGAME EL RESULTADO. No escribe nada.
-- Es UNA sola consulta: el SQL Editor de Supabase solo muestra la última.
--    1) el negocio y sus ajustes (Ley por orden, cocina, delivery)
--    2) impuestos: ITBIS 18% y Ley 10% con sus canales
--    3) áreas de comanda (producción) y sus impresoras
--    4) menús, categorías y grupos de modificadores que ya hay
--    5) CADA producto que ya subiste y con qué fila del CSV casa  ← lo importante
--    6) cuántos de la lista faltan
--
-- Este archivo lo arma build_import_b0bd6f20.py. No lo edites a mano.
-- ============================================================================

with
biz as (
  select 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee'::uuid as id
),
-- Nombres (ya normalizados) con los que una fila del CSV podría estar en la
-- caja, y a qué va en la carga.
lista(k, destino, producto) as (
  values
    ('1800 anejo', '1800 AÑEJO (SHOT) (OTROS TEQUILAS, $550)', '1800 AÑEJO (SHOT)'),
    ('1800 anejo shot', '1800 AÑEJO (SHOT) (OTROS TEQUILAS, $550)', '1800 AÑEJO (SHOT)'),
    ('1800 reposado', '1800 REPOSADO (SHOT) (OTROS TEQUILAS, $400)', '1800 REPOSADO (SHOT)'),
    ('1800 reposado shot', '1800 REPOSADO (SHOT) (OTROS TEQUILAS, $400)', '1800 REPOSADO (SHOT)'),
    ('1800 silver', '1800 SILVER (SHOT) (OTROS TEQUILAS, $400)', '1800 SILVER (SHOT)'),
    ('1800 silver shot', '1800 SILVER (SHOT) (OTROS TEQUILAS, $400)', '1800 SILVER (SHOT)'),
    ('1800 ultra anejo cristalino', '1800 ULTRA AÑEJO CRISTALINO (SHOT) (OTROS TEQUILAS, $600)', '1800 ULTRA AÑEJO CRISTALINO (SHOT)'),
    ('1800 ultra anejo cristalino shot', '1800 ULTRA AÑEJO CRISTALINO (SHOT) (OTROS TEQUILAS, $600)', '1800 ULTRA AÑEJO CRISTALINO (SHOT)'),
    ('a fieston de tacos', 'FIESTÓN DE TACOS (DELIVERY, $2000)', 'FIESTÓN DE TACOS'),
    ('agavita reposado', 'AGAVITA REPOSADO (SHOT) (OTROS TEQUILAS, $300)', 'AGAVITA REPOSADO (SHOT)'),
    ('agavita reposado shot', 'AGAVITA REPOSADO (SHOT) (OTROS TEQUILAS, $300)', 'AGAVITA REPOSADO (SHOT)'),
    ('agavita silver', 'AGAVITA SILVER (SHOT) (OTROS TEQUILAS, $300)', 'AGAVITA SILVER (SHOT)'),
    ('agavita silver shot', 'AGAVITA SILVER (SHOT) (OTROS TEQUILAS, $300)', 'AGAVITA SILVER (SHOT)'),
    ('agua', 'AGUA DASANI (SIN ALCOHOL, $50)', 'AGUA DASANI'),
    ('agua dasani', 'AGUA DASANI (SIN ALCOHOL, $50)', 'AGUA DASANI'),
    ('amor mio blanco', 'AMOR MÍO BLANCO (SHOT) (OTROS TEQUILAS EXCLUSIVOS, $550)', 'AMOR MÍO BLANCO (SHOT)'),
    ('amor mio blanco shot', 'AMOR MÍO BLANCO (SHOT) (OTROS TEQUILAS EXCLUSIVOS, $550)', 'AMOR MÍO BLANCO (SHOT)'),
    ('aperol spritz', 'APEROL SPRITZ (COCTELES, $450)', 'APEROL SPRITZ'),
    ('arizona', 'ARIZONA (con modificador Arizona · Sabor)', 'ARIZONA'),
    ('arizona all natural', 'ARIZONA (con modificador Arizona · Sabor)', 'ARIZONA'),
    ('arizona all natural ice tea', 'ARIZONA · opción Ice Tea', 'ARIZONA'),
    ('arizona all natural strawberry kiwi', 'ARIZONA · opción Strawberry Kiwi', 'ARIZONA'),
    ('averna', 'AVERNA (COCTELES, $200)', 'AVERNA'),
    ('baileys', 'BAILEYS (COCTELES, $300)', 'BAILEYS'),
    ('brownie a la moda', 'BROWNIE A LA MODA (Postres, $550)', 'BROWNIE A LA MODA'),
    ('burrito', 'BURRITO (PLATOS MEXICANOS 🌯, $700)', 'BURRITO'),
    ('burrito burrito', 'BURRITO (PLATOS MEXICANOS 🌯, $700)', 'BURRITO'),
    ('cachetadas', 'CACHETADAS (con modificador Cachetadas · Corte)', 'CACHETADAS'),
    ('cachetadas ny steak', 'CACHETADAS · opción NY Steak', 'CACHETADAS'),
    ('cachetadas ribeye', 'CACHETADAS · opción Ribeye', 'CACHETADAS'),
    ('cachetadas tenderloin', 'CACHETADAS · opción Tenderloin', 'CACHETADAS'),
    ('cafe con leche', 'CAFÉ CON LECHE (CAFÉ, $150)', 'CAFÉ CON LECHE'),
    ('cantarito 1800', 'CANTARITO 1800 (con modificador Cantarito 1800 · Tequila)', 'CANTARITO 1800'),
    ('cantarito 1800 anejo', 'CANTARITO 1800 · opción Añejo', 'CANTARITO 1800'),
    ('cantarito 1800 anejo cristalino', 'CANTARITO 1800 · opción Añejo Cristalino', 'CANTARITO 1800'),
    ('cantarito 1800 reposado', 'CANTARITO 1800 · opción Reposado', 'CANTARITO 1800'),
    ('cantarito 1800 silver', 'CANTARITO 1800 · opción Silver', 'CANTARITO 1800'),
    ('cantarito 400 conejos', 'CANTARITO 400 CONEJOS (CANTARITOS, $700)', 'CANTARITO 400 CONEJOS'),
    ('cantarito agavita', 'CANTARITO AGAVITA (con modificador Cantarito Agavita · Tequila)', 'CANTARITO AGAVITA'),
    ('cantarito agavita gold', 'CANTARITO AGAVITA · opción Gold', 'CANTARITO AGAVITA'),
    ('cantarito agavita silver', 'CANTARITO AGAVITA · opción Silver', 'CANTARITO AGAVITA'),
    ('cantarito don julio', 'CANTARITO DON JULIO (con modificador Cantarito Don Julio · Tequila)', 'CANTARITO DON JULIO'),
    ('cantarito don julio anejo', 'CANTARITO DON JULIO · opción Añejo', 'CANTARITO DON JULIO'),
    ('cantarito don julio extra anejo', 'CANTARITO DON JULIO · opción Extra Añejo', 'CANTARITO DON JULIO'),
    ('cantarito don julio reposado', 'CANTARITO DON JULIO · opción Reposado', 'CANTARITO DON JULIO'),
    ('cantarito gran cava', 'CANTARITO GRAN CAVA EXTRA AÑEJO (CANTARITOS, $900)', 'CANTARITO GRAN CAVA EXTRA AÑEJO'),
    ('cantarito gran cava extra anejo', 'CANTARITO GRAN CAVA EXTRA AÑEJO (CANTARITOS, $900)', 'CANTARITO GRAN CAVA EXTRA AÑEJO'),
    ('cantarito grand mayan', 'CANTARITO GRAND MAYAN EXTRA AÑEJO (CANTARITOS, $900)', 'CANTARITO GRAND MAYAN EXTRA AÑEJO'),
    ('cantarito grand mayan extra anejo', 'CANTARITO GRAND MAYAN EXTRA AÑEJO (CANTARITOS, $900)', 'CANTARITO GRAND MAYAN EXTRA AÑEJO'),
    ('cantarito herradura', 'CANTARITO HERRADURA (con modificador Cantarito Herradura · Tequila)', 'CANTARITO HERRADURA'),
    ('cantarito herrtadura', 'CANTARITO HERRADURA (con modificador Cantarito Herradura · Tequila)', 'CANTARITO HERRADURA'),
    ('cantarito herrtadura 818 reposado', 'CANTARITO HERRADURA · opción 818 Reposado', 'CANTARITO HERRADURA'),
    ('cantarito herrtadura anejo', 'CANTARITO HERRADURA · opción Añejo', 'CANTARITO HERRADURA'),
    ('cantarito herrtadura cristalino ultra', 'CANTARITO HERRADURA · opción Cristalino Ultra', 'CANTARITO HERRADURA'),
    ('cantarito herrtadura reposado', 'CANTARITO HERRADURA · opción Reposado', 'CANTARITO HERRADURA'),
    ('cantarito jose cuervo', 'CANTARITO JOSÉ CUERVO (con modificador Cantarito José Cuervo · Tequila)', 'CANTARITO JOSÉ CUERVO'),
    ('cantarito jose cuervo reposado', 'CANTARITO JOSÉ CUERVO · opción Reposado', 'CANTARITO JOSÉ CUERVO'),
    ('cantarito jose cuervo silver', 'CANTARITO JOSÉ CUERVO · opción Silver', 'CANTARITO JOSÉ CUERVO'),
    ('cantarito mezcal mitre', 'CANTARITO MEZCAL MITRE (CANTARITOS, $950)', 'CANTARITO MEZCAL MITRE'),
    ('cantarito montelobos', 'CANTARITO MONTELOBOS (CANTARITOS, $600)', 'CANTARITO MONTELOBOS'),
    ('carnes', 'CARNES (EXTRAS, $700)', 'CARNES'),
    ('chamorro de cerdo', 'CHAMORRO DE CERDO (TACOS 🌮, $1800)', 'CHAMORRO DE CERDO'),
    ('chamorro de cerdo chamorro', 'CHAMORRO DE CERDO (TACOS 🌮, $1800)', 'CHAMORRO DE CERDO'),
    ('chelada', 'CHELADA (MICHELADAS, $350)', 'CHELADA'),
    ('chilaquiles', 'CHILAQUILES (PLATOS MEXICANOS 🌯, $700)', 'CHILAQUILES'),
    ('chilaquiles chilaquiles', 'CHILAQUILES (PLATOS MEXICANOS 🌯, $700)', 'CHILAQUILES'),
    ('chimichanga', 'CHIMICHANGA (PLATOS MEXICANOS 🌯, $700)', 'CHIMICHANGA'),
    ('chimichanga chimichanga', 'CHIMICHANGA (PLATOS MEXICANOS 🌯, $700)', 'CHIMICHANGA'),
    ('chinola frozen', 'CHINOLA FROZEN (SIN ALCOHOL, $250)', 'CHINOLA FROZEN'),
    ('choriqueso', 'CHORIQUESO (ENTRADAS 🥨, $650)', 'CHORIQUESO'),
    ('choriqueso choriqueso', 'CHORIQUESO (ENTRADAS 🥨, $650)', 'CHORIQUESO'),
    ('churros', 'CHURROS (Postres, $400)', 'CHURROS'),
    ('clamato', 'CLAMATO (CERVEZA, $100)', 'CLAMATO'),
    ('clase azul reposado', 'CLASE AZUL REPOSADO (SHOT) (OTROS TEQUILAS EXCLUSIVOS, $1450)', 'CLASE AZUL REPOSADO (SHOT)'),
    ('clase azul reposado shot', 'CLASE AZUL REPOSADO (SHOT) (OTROS TEQUILAS EXCLUSIVOS, $1450)', 'CLASE AZUL REPOSADO (SHOT)'),
    ('combo rosario', 'COMBO ROSARIO (DELIVERY, $1100)', 'COMBO ROSARIO'),
    ('contraluz mezcal', 'CONTRALUZ MEZCAL (MEZCAL, $600)', 'CONTRALUZ MEZCAL'),
    ('corona', 'CORONA (CERVEZA, $300)', 'CORONA'),
    ('cortadito', 'CORTADITO (CAFÉ, $100)', 'CORTADITO'),
    ('delivery 100', 'NO SE CARGA (fila 158: cargo de delivery: se cobra con el delivery de la caja)', null),
    ('delivery 150', 'NO SE CARGA (fila 157: cargo de delivery: se cobra con el delivery de la caja)', null),
    ('delivery 200', 'NO SE CARGA (fila 156: cargo de delivery: se cobra con el delivery de la caja)', null),
    ('delivery 250', 'NO SE CARGA (fila 155: cargo de delivery: se cobra con el delivery de la caja)', null),
    ('delivery 300', 'NO SE CARGA (fila 154: cargo de delivery: se cobra con el delivery de la caja)', null),
    ('delivery 350', 'NO SE CARGA (fila 153: cargo de delivery: se cobra con el delivery de la caja)', null),
    ('delivery 400', 'NO SE CARGA (fila 152: cargo de delivery: se cobra con el delivery de la caja)', null),
    ('delivery 450', 'NO SE CARGA (fila 151: cargo de delivery: se cobra con el delivery de la caja)', null),
    ('diego rivera', 'DIEGO RIVERA (COCTELES, $500)', 'DIEGO RIVERA'),
    ('don julio anejo', 'DON JULIO AÑEJO (SHOT) (DON JULIO RESERVA, $700)', 'DON JULIO AÑEJO (SHOT)'),
    ('don julio anejo shot', 'DON JULIO AÑEJO (SHOT) (DON JULIO RESERVA, $700)', 'DON JULIO AÑEJO (SHOT)'),
    ('don julio reposado', 'DON JULIO REPOSADO (SHOT) (DON JULIO RESERVA, $600)', 'DON JULIO REPOSADO (SHOT)'),
    ('don julio reposado shot', 'DON JULIO REPOSADO (SHOT) (DON JULIO RESERVA, $600)', 'DON JULIO REPOSADO (SHOT)'),
    ('enchilada', 'ENCHILADA (con modificador Enchilada · Tipo)', 'ENCHILADA'),
    ('enchilada pollo', 'ENCHILADA · opción Pollo', 'ENCHILADA'),
    ('enchilada pollo enchilada', 'ENCHILADA · opción Pollo', 'ENCHILADA'),
    ('enchilada queso', 'ENCHILADA · opción Queso', 'ENCHILADA'),
    ('enchilada queso a', 'ENCHILADA · opción Queso', 'ENCHILADA'),
    ('enchilada suiza', 'ENCHILADA · opción Suiza', 'ENCHILADA'),
    ('enchilada suiza enchilada suiza', 'ENCHILADA · opción Suiza', 'ENCHILADA'),
    ('espresso', 'ESPRESSO (CAFÉ, $100)', 'ESPRESSO'),
    ('extra', 'grupo Extras · Otro extra +100', null),
    ('extra crema', 'grupo Extras · Extra crema +50', null),
    ('extra de carne', 'grupo Extras · Extra de carne +150', null),
    ('extra de pollo', 'grupo Extras · Extra de pollo +200', null),
    ('extra frijoles', 'grupo Extras · Extra frijoles +100', null),
    ('extra guacamole', 'grupo Extras · Extra guacamole +100', null),
    ('extra nachos', 'grupo Extras · Extra nachos +100', null),
    ('extra queso', 'grupo Extras · Extra queso +150', null),
    ('extra salsa ranchera', 'grupo Extras · Extra salsa ranchera +50', null),
    ('extra tortillas', 'grupo Extras · Extra tortillas +50', null),
    ('fajitas', 'FAJITAS (PLATOS MEXICANOS 🌯, $850)', 'FAJITAS'),
    ('fajitas fajitas', 'FAJITAS (PLATOS MEXICANOS 🌯, $850)', 'FAJITAS'),
    ('fieston de tacos', 'FIESTÓN DE TACOS (DELIVERY, $2000)', 'FIESTÓN DE TACOS'),
    ('flauta de papa y chorizo', 'FLAUTAS DE PAPA Y CHORIZO (PLATOS MEXICANOS 🌯, $600)', 'FLAUTAS DE PAPA Y CHORIZO'),
    ('flauta de papa y chorizo flautas papa y chorizo', 'FLAUTAS DE PAPA Y CHORIZO (PLATOS MEXICANOS 🌯, $600)', 'FLAUTAS DE PAPA Y CHORIZO'),
    ('flautas de papa y chorizo', 'FLAUTAS DE PAPA Y CHORIZO (PLATOS MEXICANOS 🌯, $600)', 'FLAUTAS DE PAPA Y CHORIZO'),
    ('flautas de pollo', 'FLAUTAS DE POLLO (PLATOS MEXICANOS 🌯, $650)', 'FLAUTAS DE POLLO'),
    ('flautas de pollo flautas pollo', 'FLAUTAS DE POLLO (PLATOS MEXICANOS 🌯, $650)', 'FLAUTAS DE POLLO'),
    ('francisco gonzales extra anejo', 'FRANCISCO GONZALES EXTRA AÑEJO (SHOT) (DON JULIO RESERVA, $800)', 'FRANCISCO GONZALES EXTRA AÑEJO (SHOT)'),
    ('francisco gonzales extra anejo shot', 'FRANCISCO GONZALES EXTRA AÑEJO (SHOT) (DON JULIO RESERVA, $800)', 'FRANCISCO GONZALES EXTRA AÑEJO (SHOT)'),
    ('fresa frozen', 'FRESA FROZEN (SIN ALCOHOL, $300)', 'FRESA FROZEN'),
    ('gran cava de oro extra viejo shot', 'GRAN CAVA DE ORO EXTRA VIEJO (SHOT) (OTROS TEQUILAS EXCLUSIVOS, $900)', 'GRAN CAVA DE ORO EXTRA VIEJO (SHOT)'),
    ('gran malo', 'GRAN MALO (SHOT) (OTROS TEQUILAS, $450)', 'GRAN MALO (SHOT)'),
    ('gran malo shot', 'GRAN MALO (SHOT) (OTROS TEQUILAS, $450)', 'GRAN MALO (SHOT)'),
    ('grand cava de oro extra viejo', 'GRAN CAVA DE ORO EXTRA VIEJO (SHOT) (OTROS TEQUILAS EXCLUSIVOS, $900)', 'GRAN CAVA DE ORO EXTRA VIEJO (SHOT)'),
    ('grand cava de oro extra viejo shot', 'GRAN CAVA DE ORO EXTRA VIEJO (SHOT) (OTROS TEQUILAS EXCLUSIVOS, $900)', 'GRAN CAVA DE ORO EXTRA VIEJO (SHOT)'),
    ('grand mayan extra viejo', 'GRAND MAYAN EXTRA VIEJO (SHOT) (OTROS TEQUILAS EXCLUSIVOS, $800)', 'GRAND MAYAN EXTRA VIEJO (SHOT)'),
    ('grand mayan extra viejo shot', 'GRAND MAYAN EXTRA VIEJO (SHOT) (OTROS TEQUILAS EXCLUSIVOS, $800)', 'GRAND MAYAN EXTRA VIEJO (SHOT)'),
    ('gringa', 'GRINGA (PLATOS MEXICANOS 🌯, $800)', 'GRINGA'),
    ('gringa gringa', 'GRINGA (PLATOS MEXICANOS 🌯, $800)', 'GRINGA'),
    ('heineken', 'HEINEKEN (CERVEZA, $300)', 'HEINEKEN'),
    ('herradura anejo', 'HERRADURA AÑEJO (SHOT) (OTROS TEQUILAS, $500)', 'HERRADURA AÑEJO (SHOT)'),
    ('herradura anejo shot', 'HERRADURA AÑEJO (SHOT) (OTROS TEQUILAS, $500)', 'HERRADURA AÑEJO (SHOT)'),
    ('herradura reposado', 'HERRADURA REPOSADO (SHOT) (OTROS TEQUILAS, $450)', 'HERRADURA REPOSADO (SHOT)'),
    ('herradura reposado shot', 'HERRADURA REPOSADO (SHOT) (OTROS TEQUILAS, $450)', 'HERRADURA REPOSADO (SHOT)'),
    ('herradura silver', 'HERRADURA SILVER (SHOT) (OTROS TEQUILAS, $400)', 'HERRADURA SILVER (SHOT)'),
    ('herradura silver shot', 'HERRADURA SILVER (SHOT) (OTROS TEQUILAS, $400)', 'HERRADURA SILVER (SHOT)'),
    ('herradura ultra anejo', 'HERRADURA ULTRA AÑEJO (SHOT) (OTROS TEQUILAS, $600)', 'HERRADURA ULTRA AÑEJO (SHOT)'),
    ('herradura ultra anejo shot', 'HERRADURA ULTRA AÑEJO (SHOT) (OTROS TEQUILAS, $600)', 'HERRADURA ULTRA AÑEJO (SHOT)'),
    ('horchata', 'HORCHATA (SIN ALCOHOL, $250)', 'HORCHATA'),
    ('huevos rancheros', 'HUEVOS RANCHEROS (PLATOS MEXICANOS 🌯, $550)', 'HUEVOS RANCHEROS'),
    ('huevos rancheros divorciados', 'HUEVOS RANCHEROS DIVORCIADOS (PLATOS MEXICANOS 🌯, $550)', 'HUEVOS RANCHEROS DIVORCIADOS'),
    ('huevos rancheros divorciados huevos ranch div', 'HUEVOS RANCHEROS DIVORCIADOS (PLATOS MEXICANOS 🌯, $550)', 'HUEVOS RANCHEROS DIVORCIADOS'),
    ('jarritos', 'JARRITOS (con modificador Jarritos · Sabor)', 'JARRITOS'),
    ('jarritos fruit punch', 'JARRITOS · opción Fruit Punch', 'JARRITOS'),
    ('jarritos guava', 'NO SE CARGA (fila 220: Jarritos Guava = Jarritos Guayaba; su precio ($175) es el de todos los sabores)', null),
    ('jarritos guayaba', 'JARRITOS · opción Guayaba', 'JARRITOS'),
    ('jarritos limon', 'JARRITOS · opción Limón', 'JARRITOS'),
    ('jarritos mandarina', 'JARRITOS · opción Mandarina', 'JARRITOS'),
    ('jarritos pina', 'JARRITOS · opción Piña', 'JARRITOS'),
    ('jarritos tamarindo', 'JARRITOS · opción Tamarindo', 'JARRITOS'),
    ('jarritos toronja', 'JARRITOS · opción Toronja', 'JARRITOS'),
    ('jose cuervo reposado', 'JOSÉ CUERVO REPOSADO (SHOT) (OTROS TEQUILAS, $350)', 'JOSÉ CUERVO REPOSADO (SHOT)'),
    ('jose cuervo reposado shot', 'JOSÉ CUERVO REPOSADO (SHOT) (OTROS TEQUILAS, $350)', 'JOSÉ CUERVO REPOSADO (SHOT)'),
    ('jose cuervo silver', 'JOSÉ CUERVO SILVER (SHOT) (OTROS TEQUILAS, $350)', 'JOSÉ CUERVO SILVER (SHOT)'),
    ('jose cuervo silver shot', 'JOSÉ CUERVO SILVER (SHOT) (OTROS TEQUILAS, $350)', 'JOSÉ CUERVO SILVER (SHOT)'),
    ('jugo cereza', 'JUGO DE CEREZA (SIN ALCOHOL, $200)', 'JUGO DE CEREZA'),
    ('jugo de cereza', 'JUGO DE CEREZA (SIN ALCOHOL, $200)', 'JUGO DE CEREZA'),
    ('jugo de chinola', 'JUGO DE CHINOLA (SIN ALCOHOL, $200)', 'JUGO DE CHINOLA'),
    ('jugo de fruit punch', 'JUGO DE FRUIT PUNCH (SIN ALCOHOL, $250)', 'JUGO DE FRUIT PUNCH'),
    ('jugo de limon', 'JUGO DE LIMÓN (SIN ALCOHOL, $200)', 'JUGO DE LIMÓN'),
    ('jugos naturales', 'JUGOS NATURALES (BEBIDAS🥤, $150)', 'JUGOS NATURALES'),
    ('limonada coco', 'LIMONADA DE COCO (SIN ALCOHOL, $300)', 'LIMONADA DE COCO'),
    ('limonada de coco', 'LIMONADA DE COCO (SIN ALCOHOL, $300)', 'LIMONADA DE COCO'),
    ('limonada frozen', 'LIMONADA FROZEN (SIN ALCOHOL, $250)', 'LIMONADA FROZEN'),
    ('mangonada', 'MANGONADA (con modificador Mangonada · Alcohol)', 'MANGONADA'),
    ('mangonada con alcohol', 'MANGONADA · opción Con alcohol', 'MANGONADA'),
    ('mangonada sin alcohol', 'MANGONADA · opción Sin alcohol', 'MANGONADA'),
    ('margarita chinola', 'MARGARITA DE CHINOLA (MARGARITAS, $450)', 'MARGARITA DE CHINOLA'),
    ('margarita coco', 'MARGARITA DE COCO (MARGARITAS, $450)', 'MARGARITA DE COCO'),
    ('margarita de chinola', 'MARGARITA DE CHINOLA (MARGARITAS, $450)', 'MARGARITA DE CHINOLA'),
    ('margarita de coco', 'MARGARITA DE COCO (MARGARITAS, $450)', 'MARGARITA DE COCO'),
    ('margarita de fresa', 'MARGARITA DE FRESA (MARGARITAS, $500)', 'MARGARITA DE FRESA'),
    ('margarita de fresa fresa', 'MARGARITA DE FRESA (MARGARITAS, $500)', 'MARGARITA DE FRESA'),
    ('margarita de limon', 'MARGARITA DE LIMÓN (MARGARITAS, $450)', 'MARGARITA DE LIMÓN'),
    ('margarita de limon a la roca', 'MARGARITA DE LIMÓN A LA ROCA (MARGARITAS, $450)', 'MARGARITA DE LIMÓN A LA ROCA'),
    ('margarita de limon limon', 'MARGARITA DE LIMÓN (MARGARITAS, $450)', 'MARGARITA DE LIMÓN'),
    ('margarita de tamarindo', 'MARGARITA DE TAMARINDO (MARGARITAS, $450)', 'MARGARITA DE TAMARINDO'),
    ('margarita de tamarindo tamarindo', 'MARGARITA DE TAMARINDO (MARGARITAS, $450)', 'MARGARITA DE TAMARINDO'),
    ('margarita limon roca', 'MARGARITA DE LIMÓN A LA ROCA (MARGARITAS, $450)', 'MARGARITA DE LIMÓN A LA ROCA'),
    ('mezcal 400 conejos', 'MEZCAL 400 CONEJOS (SHOT) (MEZCAL, $550)', 'MEZCAL 400 CONEJOS (SHOT)'),
    ('mezcal 400 conejos shot', 'MEZCAL 400 CONEJOS (SHOT) (MEZCAL, $550)', 'MEZCAL 400 CONEJOS (SHOT)'),
    ('mezcalita', 'MEZCALITA (COCTELES, $500)', 'MEZCALITA'),
    ('mezcalita nueva', 'MEZCALITA (COCTELES, $500)', 'MEZCALITA'),
    ('michelada de mango', 'MICHELADA DE MANGO (MICHELADAS, $500)', 'MICHELADA DE MANGO'),
    ('michelada de tamarindo', 'MICHELADA DE TAMARINDO (MICHELADAS, $500)', 'MICHELADA DE TAMARINDO'),
    ('michelada de tamarindo michelada tam', 'MICHELADA DE TAMARINDO (MICHELADAS, $500)', 'MICHELADA DE TAMARINDO'),
    ('michelada mango', 'MICHELADA DE MANGO (MICHELADAS, $500)', 'MICHELADA DE MANGO'),
    ('michelada mango michelada mango', 'MICHELADA DE MANGO (MICHELADAS, $500)', 'MICHELADA DE MANGO'),
    ('michelada tradicional', 'MICHELADA TRADICIONAL (MICHELADAS, $500)', 'MICHELADA TRADICIONAL'),
    ('michelada tradicional michelada trad', 'MICHELADA TRADICIONAL (MICHELADAS, $500)', 'MICHELADA TRADICIONAL'),
    ('mini flautas', 'MINI FLAUTAS (ENTRADAS 🥨, $500)', 'MINI FLAUTAS'),
    ('mini flautas mini flautas', 'MINI FLAUTAS (ENTRADAS 🥨, $500)', 'MINI FLAUTAS'),
    ('mini sopes', 'MINI SOPES (ENTRADAS 🥨, $600)', 'MINI SOPES'),
    ('mini sopes mini sopes', 'MINI SOPES (ENTRADAS 🥨, $600)', 'MINI SOPES'),
    ('modelo negra', 'MODELO NEGRA (CERVEZA, $300)', 'MODELO NEGRA'),
    ('modelo rubia', 'MODELO RUBIA (CERVEZA, $300)', 'MODELO RUBIA'),
    ('mojito chinola', 'MOJITO DE CHINOLA (MOJITOS, $400)', 'MOJITO DE CHINOLA'),
    ('mojito de chinola', 'MOJITO DE CHINOLA (MOJITOS, $400)', 'MOJITO DE CHINOLA'),
    ('mojito de coco', 'MOJITO DE COCO (MOJITOS, $400)', 'MOJITO DE COCO'),
    ('mojito de coco mojito coco', 'MOJITO DE COCO (MOJITOS, $400)', 'MOJITO DE COCO'),
    ('mojito de fresa', 'MOJITO DE FRESA (MOJITOS, $400)', 'MOJITO DE FRESA'),
    ('mojito de fresa mojito fresa', 'MOJITO DE FRESA (MOJITOS, $400)', 'MOJITO DE FRESA'),
    ('mojito de jamaica', 'MOJITO DE JAMAICA (MOJITOS, $400)', 'MOJITO DE JAMAICA'),
    ('mojito de jamaica mojito jamaica', 'MOJITO DE JAMAICA (MOJITOS, $400)', 'MOJITO DE JAMAICA'),
    ('mojito de limon', 'MOJITO DE LIMÓN (MOJITOS, $400)', 'MOJITO DE LIMÓN'),
    ('mojito de limon mojito limon', 'MOJITO DE LIMÓN (MOJITOS, $400)', 'MOJITO DE LIMÓN'),
    ('nachos 3 compadres', 'NACHOS 3 COMPADRES (ENTRADAS 🥨, $450)', 'NACHOS 3 COMPADRES'),
    ('nachos con guacamole', 'NACHOS CON GUACAMOLE (ENTRADAS 🥨, $350)', 'NACHOS CON GUACAMOLE'),
    ('nachos con guacamole nachos con guacamole', 'NACHOS CON GUACAMOLE (ENTRADAS 🥨, $350)', 'NACHOS CON GUACAMOLE'),
    ('ojo de tigre', 'OJO DE TIGRE (MEZCAL, $450)', 'OJO DE TIGRE'),
    ('otro extra', 'grupo Extras · Otro extra +100', null),
    ('paloma', 'PALOMA (COCTELES, $450)', 'PALOMA'),
    ('paloma paloma', 'PALOMA (COCTELES, $450)', 'PALOMA'),
    ('pico de gallo', 'grupo Extras · Pico de gallo +100', null),
    ('pie de limon', 'PIE DE LIMÓN (Postres, $400)', 'PIE DE LIMÓN'),
    ('pie de limon pie limon', 'PIE DE LIMÓN (Postres, $400)', 'PIE DE LIMÓN'),
    ('pina colada', 'PIÑA COLADA (con modificador Piña Colada · Alcohol)', 'PIÑA COLADA'),
    ('pina colada con alcohol', 'PIÑA COLADA · opción Con alcohol', 'PIÑA COLADA'),
    ('pina colada sin alcohol', 'PIÑA COLADA · opción Sin alcohol', 'PIÑA COLADA'),
    ('presidente light', 'PRESIDENTE LIGHT (CERVEZA, $300)', 'PRESIDENTE LIGHT'),
    ('presidente light presi', 'PRESIDENTE LIGHT (CERVEZA, $300)', 'PRESIDENTE LIGHT'),
    ('presidente normal', 'PRESIDENTE NORMAL (CERVEZA, $300)', 'PRESIDENTE NORMAL'),
    ('presidente normal presi', 'PRESIDENTE NORMAL (CERVEZA, $300)', 'PRESIDENTE NORMAL'),
    ('quesadilla de chorizo', 'QUESADILLA DE CHORIZO (PLATOS MEXICANOS 🌯, $650)', 'QUESADILLA DE CHORIZO'),
    ('quesadilla de chorizo queda chorizo', 'QUESADILLA DE CHORIZO (PLATOS MEXICANOS 🌯, $650)', 'QUESADILLA DE CHORIZO'),
    ('quesadilla de pollo', 'QUESADILLA DE POLLO (PLATOS MEXICANOS 🌯, $650)', 'QUESADILLA DE POLLO'),
    ('quesadilla de pollo quesadillas', 'QUESADILLA DE POLLO (PLATOS MEXICANOS 🌯, $650)', 'QUESADILLA DE POLLO'),
    ('refresco', 'REFRESCO (con modificador Refresco · Sabor)', 'REFRESCO'),
    ('refresco boing mango', 'REFRESCO · opción Boing Mango', 'REFRESCO'),
    ('refresco coca cola', 'REFRESCO · opción Coca Cola', 'REFRESCO'),
    ('refresco sangria senorial', 'REFRESCO · opción Sangría Señorial', 'REFRESCO'),
    ('refresco sidral manzana', 'REFRESCO · opción Sidral Manzana', 'REFRESCO'),
    ('refresco soda', 'REFRESCO · opción Soda', 'REFRESCO'),
    ('refresco sprite', 'REFRESCO · opción Sprite', 'REFRESCO'),
    ('refresco squirt', 'REFRESCO · opción Squirt', 'REFRESCO'),
    ('refresco zero', 'REFRESCO · opción Zero', 'REFRESCO'),
    ('refrescos', 'REFRESCOS SABORES (con modificador Refrescos Sabores · Sabor)', 'REFRESCOS SABORES'),
    ('refrescos sabores', 'REFRESCOS SABORES (con modificador Refrescos Sabores · Sabor)', 'REFRESCOS SABORES'),
    ('refrescos sabores merengue', 'REFRESCOS SABORES · opción Merengue', 'REFRESCOS SABORES'),
    ('refrescos sabores rojo', 'REFRESCOS SABORES · opción Rojo', 'REFRESCOS SABORES'),
    ('refrescos sabores soda', 'REFRESCOS SABORES · opción Soda', 'REFRESCOS SABORES'),
    ('refrescos sabores sprite', 'REFRESCOS SABORES · opción Sprite', 'REFRESCOS SABORES'),
    ('refrescos sabores uva', 'REFRESCOS SABORES · opción Uva', 'REFRESCOS SABORES'),
    ('sangria de jamaica', 'SANGRÍA DE JAMAICA (COCTELES, $450)', 'SANGRÍA DE JAMAICA'),
    ('sangria de jamaica sangria', 'SANGRÍA DE JAMAICA (COCTELES, $450)', 'SANGRÍA DE JAMAICA'),
    ('soda can', 'SODA CAN (con modificador Soda Can · Sabor)', 'SODA CAN'),
    ('soda can canada dry blackberry', 'SODA CAN · opción Canada Dry Blackberry', 'SODA CAN'),
    ('soda can canada dry ginger', 'SODA CAN · opción Canada Dry Ginger', 'SODA CAN'),
    ('soda can dr pepper', 'SODA CAN · opción Dr Pepper', 'SODA CAN'),
    ('soda can dr pepper blackberry', 'SODA CAN · opción Dr Pepper Blackberry', 'SODA CAN'),
    ('soda can dr pepper cherry', 'SODA CAN · opción Dr Pepper Cherry', 'SODA CAN'),
    ('soda can squirt toronja', 'SODA CAN · opción Squirt Toronja', 'SODA CAN'),
    ('sopa de tortillas', 'SOPA DE TORTILLAS (PLATOS MEXICANOS 🌯, $600)', 'SOPA DE TORTILLAS'),
    ('sopes de papa y chorizo', 'SOPES DE PAPA Y CHORIZO (PLATOS MEXICANOS 🌯, $650)', 'SOPES DE PAPA Y CHORIZO'),
    ('sopes de papa y chorizo sope papa chorizo', 'SOPES DE PAPA Y CHORIZO (PLATOS MEXICANOS 🌯, $650)', 'SOPES DE PAPA Y CHORIZO'),
    ('sopes de pollo', 'SOPES DE POLLO (PLATOS MEXICANOS 🌯, $650)', 'SOPES DE POLLO'),
    ('sopes de pollo sope pollo', 'SOPES DE POLLO (PLATOS MEXICANOS 🌯, $650)', 'SOPES DE POLLO'),
    ('sopes de tinga de pollo', 'SOPES DE TINGA DE POLLO (PLATOS MEXICANOS 🌯, $700)', 'SOPES DE TINGA DE POLLO'),
    ('sopes de tinga de pollo sope tinga', 'SOPES DE TINGA DE POLLO (PLATOS MEXICANOS 🌯, $700)', 'SOPES DE TINGA DE POLLO'),
    ('stella artois', 'STELLA ARTOIS (CERVEZA, $300)', 'STELLA ARTOIS'),
    ('tacos', 'TACOS (TACOS 🌮, $700)', 'TACOS'),
    ('tacos a la zimbron', 'TACOS A LA ZIMBRON (TACOS 🌮, $600)', 'TACOS A LA ZIMBRON'),
    ('tacos a la zimbron 3 und', 'TACOS A LA ZIMBRON (TACOS 🌮, $600)', 'TACOS A LA ZIMBRON'),
    ('tacos al pastor', 'TACOS AL PASTOR (TACOS 🌮, $700)', 'TACOS AL PASTOR'),
    ('tacos al pastor 4 und', 'TACOS AL PASTOR (TACOS 🌮, $700)', 'TACOS AL PASTOR'),
    ('tacos chilorio', 'TACOS DE CHILORIO (TACOS 🌮, $750)', 'TACOS DE CHILORIO'),
    ('tacos chilorio tacos de chilorio', 'TACOS DE CHILORIO (TACOS 🌮, $750)', 'TACOS DE CHILORIO'),
    ('tacos de birria', 'TACOS DE BIRRIA (TACOS 🌮, $800)', 'TACOS DE BIRRIA'),
    ('tacos de birria 4 und', 'TACOS DE BIRRIA (TACOS 🌮, $800)', 'TACOS DE BIRRIA'),
    ('tacos de carnita michoacan', 'TACOS DE CARNITAS MICHOACANAS (TACOS 🌮, $700)', 'TACOS DE CARNITAS MICHOACANAS'),
    ('tacos de carnitas michoacanas', 'TACOS DE CARNITAS MICHOACANAS (TACOS 🌮, $700)', 'TACOS DE CARNITAS MICHOACANAS'),
    ('tacos de carnitas michoacanas 4 und', 'TACOS DE CARNITAS MICHOACANAS (TACOS 🌮, $700)', 'TACOS DE CARNITAS MICHOACANAS'),
    ('tacos de chilorio', 'TACOS DE CHILORIO (TACOS 🌮, $750)', 'TACOS DE CHILORIO'),
    ('tacos de cochinita pibil', 'TACOS DE COCHINITA PIBIL (TACOS 🌮, $750)', 'TACOS DE COCHINITA PIBIL'),
    ('tacos de cochinita pibil 4 und', 'TACOS DE COCHINITA PIBIL (TACOS 🌮, $750)', 'TACOS DE COCHINITA PIBIL'),
    ('tacos de tinga de pollo', 'TACOS DE TINGA DE POLLO (TACOS 🌮, $700)', 'TACOS DE TINGA DE POLLO'),
    ('tacos de tinga de pollo 4 und', 'TACOS DE TINGA DE POLLO (TACOS 🌮, $700)', 'TACOS DE TINGA DE POLLO'),
    ('tacos tacos', 'TACOS (TACOS 🌮, $700)', 'TACOS'),
    ('tamarindo frozen', 'TAMARINDO FROZEN (SIN ALCOHOL, $250)', 'TAMARINDO FROZEN'),
    ('te de jamaica', 'TÉ DE JAMAICA (SIN ALCOHOL, $200)', 'TÉ DE JAMAICA'),
    ('tequila sunrise', 'TEQUILA SUNRISE (COCTELES, $400)', 'TEQUILA SUNRISE'),
    ('tostadas', 'TOSTADAS (con modificador Tostadas · Tipo)', 'TOSTADAS'),
    ('tostadas de cerdo', 'TOSTADAS · opción Cerdo', 'TOSTADAS'),
    ('tostadas de cerdo tostada cerdo', 'NO SE CARGA (fila 35: repetida de la 181 (Tostadas de Cerdo); esta a $600, se deja la de $650)', null),
    ('tostadas de cerdo tostadas', 'TOSTADAS · opción Cerdo', 'TOSTADAS'),
    ('tostadas de chilorio', 'TOSTADAS · opción Chilorio', 'TOSTADAS'),
    ('tostadas de chilorio tostada chilorio', 'TOSTADAS · opción Chilorio', 'TOSTADAS'),
    ('tostadas de papa y chorizo', 'TOSTADAS · opción Papa y Chorizo', 'TOSTADAS'),
    ('tostadas de papa y chorizo tostada papa chorizo', 'TOSTADAS · opción Papa y Chorizo', 'TOSTADAS'),
    ('tostadas de pollo', 'TOSTADAS · opción Pollo', 'TOSTADAS'),
    ('tostadas de pollo tost pollo', 'TOSTADAS · opción Pollo', 'TOSTADAS'),
    ('tostadas de tinga de pollo', 'TOSTADAS · opción Tinga de Pollo', 'TOSTADAS'),
    ('tostadas de tinga de pollo tost tinga', 'TOSTADAS · opción Tinga de Pollo', 'TOSTADAS'),
    ('unidad de taco', 'UNIDAD DE TACO (TACOS 🌮, $250)', 'UNIDAD DE TACO'),
    ('unidad de taco unidad de taco', 'UNIDAD DE TACO (TACOS 🌮, $250)', 'UNIDAD DE TACO')
),
prods as (
  select mi.*,
         btrim(regexp_replace(
           translate(lower(mi.name), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun'),
           '[^a-z0-9]+', ' ', 'g')) as k,
         (select count(*) from public.order_items oi where oi.product_id = mi.id) as ventas
  from public.menu_items mi, biz
  where mi.business_id = biz.id
),
casa as (
  select p.id,
         string_agg(distinct l.destino, ' | ') as destino,
         count(distinct l.producto) as n_productos
  from prods p
  join lista l on l.k = p.k
  group by p.id
),
tx as (
  select t.*, to_jsonb(t) as j
  from public.taxes t, biz
  where t.business_id = biz.id
),
r(orden, sub, seccion, detalle) as (
  select 1, 0, '1 Negocio',
         format('%s · tipo=%s · estado=%s · creado %s',
                coalesce(b.j->>'business_name', b.j->>'name', '—'),
                coalesce(b.j->>'business_type', '—'),
                coalesce(b.j->>'status', '—'),
                left(coalesce(b.j->>'created_at', '—'), 10))
  from (select to_jsonb(x) as j from public.businesses x, biz where x.id = biz.id) b
  union all
  select 1, 0, '1 Negocio', '✗ NO EXISTE'
  where not exists (select 1 from public.businesses x, biz where x.id = biz.id)

  union all
  select 1, 1, '1 Ajustes',
         format('service_fee_enabled=%s · kitchen_enabled=%s · printerless_kitchen=%s · '
                'auto_print_order=%s · inventory_mode=%s · moneda=%s · '
                'delivery_fee_required=%s · delivery_fee_presets=%s',
                coalesce(s.j->>'service_fee_enabled', '—'),
                coalesce(s.j->>'kitchen_enabled', '—'),
                coalesce(s.j->>'printerless_kitchen', '—'),
                coalesce(s.j->>'auto_print_order', '—'),
                coalesce(s.j->>'inventory_mode', '—'),
                coalesce(s.j->>'currency_code', '—'),
                coalesce(s.j->>'delivery_fee_required', '—'),
                coalesce(s.j->>'delivery_fee_presets', '—'))
  from (select to_jsonb(bs) as j
        from public.business_settings bs, biz
        where bs.business_id = biz.id) s
  union all
  select 1, 1, '1 Ajustes', '✗ sin fila en business_settings'
  where not exists (select 1 from public.business_settings bs, biz where bs.business_id = biz.id)

  union all
  select 2, 0, '2 Impuesto',
         format('%s %s%% · activo=%s · is_service_fee=%s · include_in_ecf=%s · '
                'zona=%s manual=%s rápida=%s llevar=%s delivery=%s · productos vinculados=%s',
                t.name, t.rate,
                coalesce(t.j->>'is_active', '—'), coalesce(t.j->>'is_service_fee', '—'),
                coalesce(t.j->>'include_in_ecf', '—'),
                coalesce(t.j->>'apply_on_zone', '—'), coalesce(t.j->>'apply_on_manual', '—'),
                coalesce(t.j->>'apply_on_quick', '—'), coalesce(t.j->>'apply_on_takeout', '—'),
                coalesce(t.j->>'apply_on_delivery', '—'),
                (select count(*) from public.menu_item_taxes x where x.tax_id = t.id))
  from tx t
  union all
  select 2, 0, '2 Impuesto', '✗ el negocio no tiene ningún impuesto'
  where not exists (select 1 from tx)

  union all
  select 3, 0, '3 Área de comanda',
         format('%s (code %s) · activa=%s · impresoras=%s · productos=%s',
                a.name, a.code, a.is_active,
                (select count(*) from public.print_area_printers p where p.area_id = a.id),
                (select count(*) from public.menu_item_print_areas x
                 where x.print_area_id = a.id))
  from public.print_areas a, biz
  where a.business_id = biz.id
  union all
  select 3, 0, '3 Área de comanda', 'ninguna (la carga crea Cocina y Bar)'
  where not exists (select 1 from public.print_areas a, biz where a.business_id = biz.id)

  union all
  select 4, 0, '4 Menú',
         format('%s · activo=%s · productos enlazados=%s',
                m.name, m.is_active,
                (select count(*) from public.menu_item_links l where l.menu_id = m.id))
  from public.menus m, biz
  where m.business_id = biz.id
  union all
  select 4, 0, '4 Menú', 'ninguno (la carga crea "Menú Principal")'
  where not exists (select 1 from public.menus m, biz where m.business_id = biz.id)

  union all
  select 4, 1, '4 Catálogo',
         format('categorías=%s · productos=%s (activos %s) · con ventas=%s · '
                'grupos de modificadores=%s · tax_mode: inclusive %s / exclusive %s',
                (select count(*) from public.categories c, biz where c.business_id = biz.id),
                (select count(*) from prods),
                (select count(*) from prods where is_active),
                (select count(*) from prods where ventas > 0),
                (select count(*) from public.modifier_groups g, biz where g.business_id = biz.id),
                (select count(*) from prods where tax_mode = 'inclusive'),
                (select count(*) from prods where tax_mode = 'exclusive'))

  union all
  select 4, 2, '4 Categoría',
         format('%s · posición %s · activa=%s · productos activos=%s',
                c.name, c.position, c.is_active,
                (select count(*) from prods p where p.category_id = c.id and p.is_active))
  from public.categories c, biz
  where c.business_id = biz.id

  union all
  select 4, 3, '4 Grupo de modificadores',
         format('%s · min=%s max=%s · %s · activo=%s · productos=%s · opciones: %s',
                g.name, g.min_select, g.max_select,
                coalesce(to_jsonb(g)->>'display_type', '—'), g.is_active,
                (select count(*) from public.menu_item_groups y where y.group_id = g.id),
                coalesce((select string_agg(m.name || ' $' || m.price_delta, ', ')
                          from public.modifiers m where m.group_id = g.id), '—'))
  from public.modifier_groups g, biz
  where g.business_id = biz.id

  union all
  select 5, 0, '5 Ya subido',
         format('%s · $%s %s · activo=%s · %s · impuestos %s · área %s · grupos %s · ventas %s  →  %s',
                p.name, p.price, p.tax_mode, p.is_active,
                coalesce((select c.name from public.categories c where c.id = p.category_id), 'sin categoría'),
                coalesce((select string_agg(t.name || ' ' || t.rate || '%', '+' order by t.rate desc)
                          from public.menu_item_taxes x join public.taxes t on t.id = x.tax_id
                          where x.item_id = p.id), 'NINGUNO'),
                coalesce((select string_agg(a.code, ',')
                          from public.menu_item_print_areas x
                          join public.print_areas a on a.id = x.print_area_id
                          where x.menu_item_id = p.id), 'N:M —')
                  || ' / legacy ' || coalesce(p.print_area_code, '—'),
                (select count(*) from public.menu_item_groups y where y.menu_item_id = p.id),
                p.ventas,
                case when c.id is null then 'NO está en el CSV'
                     when c.n_productos > 1 then '⚠ casa con VARIOS: ' || c.destino
                     else c.destino end)
  from prods p
  left join casa c on c.id = p.id

  union all
  select 6, 0, '6 Resumen',
         format('productos de la lista: %s · ya subidos: %s · faltan: %s · '
                'productos del catálogo que no están en el CSV: %s',
                (select count(distinct producto) from lista where producto is not null),
                (select count(distinct l.producto) from lista l
                 where l.producto is not null and l.k in (select k from prods)),
                (select count(distinct l.producto) from lista l
                 where l.producto is not null
                   and l.producto not in (select l2.producto from lista l2
                                          where l2.producto is not null
                                            and l2.k in (select k from prods))),
                (select count(*) from prods p where p.id not in (select id from casa)))
)
select seccion, detalle
from r
order by orden, sub, detalle;
