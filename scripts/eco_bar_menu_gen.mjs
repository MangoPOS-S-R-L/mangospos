#!/usr/bin/env node
// Generador del menú de ECO BAR & LOUNGE → SQL de inserción (categories + menu_items).
//
// Datos estructurados aquí; el script emite scripts/eco_bar_menu.sql listo para
// correr en el SQL editor del Supabase de prod. Precios SIN ITBIS (tax_mode
// 'exclusive', el default). Ítems con dos precios (brochetas, licores
// botella/trago, aguas por tamaño) se separan en ítems distintos.
//
// Uso:  node scripts/eco_bar_menu_gen.mjs > /dev/null   (escribe el .sql)

import fs from 'node:fs';
import crypto from 'node:crypto';

const BIZ = 'fc3065c8-cb40-45ad-bec1-aecb388001c1';
const OUT = new URL('./eco_bar_menu.sql', import.meta.url);

// d = descripción (opcional). Cada categoría tiene bev = is_beverage.
const MENU = [
  { cat: 'Antojos', bev: false, items: [
    { n: 'Picadera de salchichas picantes', p: 350, d: 'Salchichas sazonadas con especias cuidadosamente seleccionadas, con un equilibrio perfecto entre el calor y el sabor.' },
    { n: 'Picadera de embutidos & quesos', p: 850, d: 'Deliciosa variedad de embutidos y quesos de calidad premium.' },
    { n: 'Eco Tartar', p: 750, d: 'Tartar de atún fresco en salsa de la casa, cubos de aguacate y platanitos crocantes.' },
    { n: 'Brocheta de Pollo', p: 350, d: 'Sellada al fuego vivo en grill, marinada con hierbas, ajo y limón, con cubo de vegetales frescos y salsa de ajo y cilantro.' },
    { n: 'Brocheta de Camarón', p: 400, d: 'Sellada al fuego vivo en grill, marinada con hierbas, ajo y limón, con cubo de vegetales frescos y salsa de ajo y cilantro.' },
    { n: 'Brocheta Mixta', p: 450, d: 'Sellada al fuego vivo en grill, marinada con hierbas, ajo y limón, con cubo de vegetales frescos y salsa de ajo y cilantro.' },
    { n: 'Canasticas de Birria (3 Unid)', p: 650, d: 'Canastas de plátanos, birria reducida a 45m, queso mixto gratinado, sobre base de guacamole.' },
    { n: 'Canasticas de Camarones (3 Unid)', p: 700, d: 'Canastas de plátanos, camarones salteados en licor de coco, base de guacamole, queso mozzarella gratinado y pico de gallo.' },
    { n: 'Calamares fritos (7 Unid)', p: 350, d: 'Aros de calamares rebozados, con salsa tártara o picante hecha en casa.' },
    { n: 'Croquetas (3 Unid)', p: 400, d: 'Jugosas croquetas de berenjena y pollo con el toque al estilo Ecobar.' },
  ]},
  { cat: 'Entradas', bev: false, items: [
    { n: 'Tacos al Campo (2 Unid)', p: 400, d: 'Tacos mixtos con filete de pechuga de pollo y filete de res, repollo morado y salsa especial de la casa.' },
    { n: 'Tacos de Chicharrón (2 Unid)', p: 500, d: 'Chicharrón crocante en mantequilla de perejil y ajo, ensalada mixta en secret sauce, guacamole y pico de gallo.' },
    { n: 'Tacos Hermanos Trejo (3 Unid)', p: 450, d: 'Pollo desmechado con vegetales mixtos y queso mozzarella gratinado. Salsa picante aparte.' },
    { n: 'Camarones a la Roca', p: 650, d: 'Camarones tempura en salsa spicy mayo, con base de lechuga rizada.' },
    { n: 'Dumplings de Pork (5 Unid)', p: 450, d: 'Cerdo sazonado con especias, envuelto en fina masa de dumpling, al vapor o frito.' },
    { n: 'Alitas a la BBQ (3 Unid)', p: 450, d: 'Alitas de pollo bañadas en salsa BBQ al estilo Eco, o picantes.' },
    { n: 'Ceviche Ecológico', p: 550, d: 'Pescado blanco, maíz salado y maíz chulpi, plátanos verdes en esencia de ajo, bañado en salsa de tigre.' },
    { n: 'Deditos de pollo', p: 450, d: 'Con papas fritas y salsa rosa.' },
  ]},
  { cat: 'Rincocitos de los Ecopeques', bev: false, items: [
    { n: 'Nuggets', p: 350, d: 'Medallones de pollo acompañados de papas fritas y ketchup.' },
    { n: 'Croquetas Mágicas', p: 350, d: 'Peloticas esponjosas de jamón y queso acompañadas de queso fundido.' },
    { n: 'Mini Burguer Eco', p: 400, d: 'Hamburguesa angus certificada, ahogada en crema de queso.' },
    { n: 'Pasta Pirata', p: 400, d: 'Pasta al dente con mini albóndigas en salsa roja y queso parmesano.' },
    { n: 'Arroz Ninja', p: 400, d: 'Arroz frito salteado con huevito y pollo tierno en salsa de soya.' },
    { n: 'Taquitos Caribeños', p: 350, d: 'Mini taquitos de pollo desmechado y queso mozzarella derretido.' },
  ]},
  { cat: 'Platos Fuertes', bev: false, items: [
    { n: 'Chuletas Fresh Pig', p: 600, d: 'Sabrosas chuletas de cerdo fitness.' },
    { n: 'Pechuga de pollo a la parrilla', p: 400, d: 'Jugosa y aromática pechuga de pollo a la parrilla.' },
    { n: 'Ribeye', p: 2000, d: 'Corte de res con abundante marmoleado de grasa y jugoso sabor.' },
    { n: 'Eco Ribs BBQ', p: 800, d: 'Costillas baby procesadas a bajas temperaturas al estilo cajún.' },
    { n: 'Filet Mignon', p: 1400, d: 'Solomillo de res envuelto en bacon premium, con salsa de vino especial y porto.' },
    { n: 'Delicia de la Selva Negra', p: 1500, d: 'Filete de res angus certificado.' },
    { n: 'Churrasco a la Juliana', p: 1800, d: 'Especialidad de la parrilla, jugoso y lleno de sabor.' },
    { n: 'Lomo Saltado', p: 1950, d: 'Filete de lomo de res angus certificado, salteado en vegetales mixtos y papas baby.' },
  ]},
  { cat: 'Delicias del Mar', bev: false, items: [
    { n: 'Filete de Salmón del Pacífico', p: 900, d: 'Salmón de 8 onz. a la plancha con esencia de mantequilla y ajo.' },
    { n: 'Parrillada de mariscos', p: 2500, d: 'Rica variedad de frutos del mar adobada con pasión.' },
    { n: 'Camarones a la Eco criolla', p: 700, d: 'Camarones en salsa criolla con tomate, pimiento y especias.' },
    { n: 'Langosta Caribeña (por libra)', p: 1500, d: 'Langosta fresca con aceite de ajo, mantequilla exclusiva, sal, pimienta y salsa al ajillo. Precio por libra.' },
    { n: 'Chillo del Mar Caribe (por libra)', p: 1000, d: 'Chillo fresco sazonado y frito, crujiente por fuera y tierno por dentro. Precio por libra.' },
    { n: 'Mar y Tierra', p: 1800, d: 'Arroz frito a la plancha con vegetales mixtos, filete de res y camarón a la plancha, salsa de hongos en crema y queso, tierra crocante de tocineta.' },
    { n: 'Cazuela de Mariscos Ecológica', p: 900, d: 'Mariscos mixtos sellados y salteados, con vegetales ahumados al saltén triturados con crema.' },
  ]},
  { cat: 'Ensaladas', bev: false, items: [
    { n: 'Tropical Salad', p: 550, d: 'Mezcla refrescante de piña jugosa y camarones tiernos, aderezada con vinagreta especial.' },
    { n: 'Caeser Salad', p: 350, d: 'Lechuga romana, pan tostado, queso parmesano rallado y aderezo Caesar.' },
    { n: 'BBQ Salad', p: 550, d: 'Lechuga fresca en salsa ahumada con chicharrón de salmón, tomate, aguacate y tierra de pan crocante.' },
    { n: 'Ensalada Eco', p: 400, d: 'Tiras de pollo con cebolla, aguacate cremoso y tortilla crujiente.' },
  ]},
  { cat: 'Mofongo', bev: false, items: [
    { n: 'El Mofongo de Cayacoa', p: 900, d: 'Mofongo mixto de chicharrón y camarón con crema de queso fundido y tocineta crocante.' },
    { n: 'Mofongo de Pollo', p: 600, d: 'Mofongo con tierna carne de pollo sazonada.' },
    { n: 'Mofongo de Camarones', p: 800, d: 'Plátanos verdes machacados con camarones salteados.' },
    { n: 'Mofongo de Churrasco', p: 1400, d: 'Plátanos verdes machacados con salsa de queso y mozzarella, crocante de tocineta y 6 onz de churrasco.' },
  ]},
  { cat: 'Arroces al Estilo Ecobar', bev: false, items: [
    { n: 'Risotto Volcán', p: 1200, d: 'Risotto de hongos con 6 onz. de churrasco al grill y lluvia de parmesano.' },
    { n: 'Risotto de Camarón', p: 1100, d: 'Risotto en reducción de camarón y azafrán, cubo de aguacates ahumados, prosciutto crocante y parmesano.' },
    { n: 'Salvaje Rice', p: 850, d: 'Arroz de la selva negra salteado con vegetales frescos, esencia de coco y huevo pochado.' },
    { n: 'Eco Concón', p: 550, d: 'Fried rice al estilo Eco con huevo pochado. Acompañamiento (cargo adicional): Chicken / Beef / Shrimps / Chicharrón DOP$250.' },
  ]},
  { cat: 'Pastas', bev: false, items: [
    { n: 'Pasta del mar al tomate fresco', p: 850, d: 'Camarones, mejillones y calamares en salsa pomodoro casera. A elegir: penne, spaguetti o lingüini.' },
    { n: 'Pasta Alfredo', p: 550, d: 'Salsa Alfredo de mantequilla, crema, ajo y queso parmesano. A elegir: penne, spaguetti o lingüini.' },
    { n: 'Pasta a la Carbonara', p: 600, d: 'Crema de leche, tocino dorado y cebolla juliana. A elegir: penne, spaguetti o lingüini.' },
    { n: 'Pasta con Camarones', p: 800, d: 'Salsa cremosa con camarones, ajo, tomates cherry y hierbas frescas. A elegir: penne, spaguetti o lingüini.' },
    { n: 'Pesto de Camarones', p: 950, d: 'Cremosa salsa pesto con camarones salteados en mantequilla y ajo. A elegir: penne, spaguetti o lingüini.' },
    { n: 'Pasta Bolognesa', p: 550, d: 'Salsa boloñesa cocinada lentamente con carne de res, tomates maduros, vino tinto y finas hierbas. A elegir: penne, spaguetti o lingüini.' },
  ]},
  { cat: 'Hamburguesas', bev: false, items: [
    { n: 'Chicken Burguer Special', p: 700, d: 'Milanesa de pollo empanizada con crema de tocineta y puerro, lechuga, tomate, cebolla crocante y secret sauce.' },
    { n: 'Eco Burguer Special', p: 750, d: 'Hamburguesa angus certificada, ahogada en crema de hongos y queso.' },
    { n: 'La Ciclo Burguer', p: 650, d: 'Hamburguesa angus certificada, lonja de queso danés, tomate, pepinillo y cebolla caramelizada.' },
  ]},
  { cat: 'Guarniciones', bev: false, items: [
    { n: 'Tostones de mi tierra', p: 200, d: 'Dorados y crujientes.' },
    { n: 'Papas a la Francesa', p: 200, d: 'Papas fritas doradas y crujientes.' },
    { n: 'Papas Salteadas', p: 250, d: 'Trozos de papa al dente salteados en ajo y mantequilla con perejil.' },
    { n: 'Vegetales Salteados', p: 250, d: 'Combinación de verduras a la parrilla o salteadas.' },
    { n: 'Eco Puré de Papas', p: 250, d: 'Gratinado con queso parmesano, zumo y rayadura de limón verde.' },
    { n: 'Yuca Mash', p: 250, d: 'Puré de yuca suave con queso gratinado y crema.' },
  ]},
  { cat: 'Postres', bev: false, items: [
    { n: 'Romeo y Julieta', p: 400, d: 'Bizcocho bañado en chocolate, crema de dulce de leche y topping de suspiro. Pregunta por el postre del día.' },
  ]},
  { cat: 'Aguas / Saborizadas', bev: true, items: [
    { n: 'Agua San Pellegrino Cristal (750ml)', p: 350, d: 'Agua con gas.' },
    { n: 'Agua San Pellegrino Cristal (505ml)', p: 250, d: 'Agua con gas.' },
    { n: 'Agua Panna Cristal (750ml)', p: 250, d: 'Agua mineral de manantial.' },
    { n: 'Agua Panna Cristal (505ml)', p: 200, d: 'Agua mineral de manantial.' },
    { n: 'San Pellegrino Aranciata (330ml)', p: 200, d: 'Agua saborizada con gas.' },
    { n: 'San Pellegrino Melograno (330ml)', p: 200, d: 'Agua saborizada con gas.' },
    { n: 'San Pellegrino Aranciata Limón y Menta (330ml)', p: 200, d: 'Agua saborizada con gas.' },
    { n: 'San Pellegrino Aranciata Rossa (330ml)', p: 200, d: 'Agua con gas.' },
    { n: 'Agua Perrier Cristal (330ml)', p: 200, d: 'Agua saborizada con gas.' },
    { n: 'Dasani', p: 80, d: 'Agua natural.' },
  ]},
  { cat: 'Jugos / Mixers', bev: true, items: [
    { n: 'Gatorade', p: 100 },
    { n: 'Jarra Jugo de Naranja', p: 275 },
    { n: 'Jugo Clamato', p: 200 },
    { n: 'Jugos Motts (946ml)', p: 350 },
    { n: 'Jugos Naturales', p: 160 },
    { n: 'Redbull', p: 200 },
    { n: 'Aloe Vera Natural', p: 235 },
    { n: 'Canada Dry Soda', p: 120 },
    { n: 'Canada Dry Tónica', p: 120 },
    { n: 'Coca Cola', p: 65 },
    { n: 'Sprite', p: 65 },
    { n: 'Cranberry (946ml)', p: 350 },
  ]},
  { cat: 'Cócteles', bev: true, items: [
    { n: 'Eco Spritz', p: 450, d: 'Aperol / zumo de naranja / jugo de sandía / espumante / agua saborizada.' },
    { n: 'Cuba Libre', p: 400, d: 'Ron dark / Coca Cola.' },
    { n: 'Dreamers', p: 300, d: 'Tequila dorada / jugo de chinola / jugo de limón / sirope de jengibre / ginger beer.' },
    { n: 'Hotelero', p: 350, d: 'Ron dorado / crema de café / Bailey / amaretto / licor de melocotón / canela.' },
    { n: 'Higüey City', p: 300, d: 'Whisky blend / vermouth rosso / triple sec / zumo de limón / sirope de jengibre.' },
    { n: 'El Ecologista', p: 350, d: 'Vodka / jugo de piña / fresas / jarabe natural / zumo de limón / aroma de romero.' },
    { n: 'Eco Verde', p: 550, d: 'Jugo de pepino / zumo de limón / hoja de menta / sirope de jengibre.' },
    { n: 'Eco Punch', p: 200, d: 'Jugo de naranja / chinola / piña / sandía / sirope de canela / fresas maceradas.' },
    { n: 'Turista', p: 350, d: 'Ron blanco / ron dorado / licor de manzana / amarula / triple sec / licor de banana / sirope natural.' },
    { n: 'Basílica', p: 350, d: 'Ginebra / jugo de pepino / jugo de piña / zumo de limón / sirope de canela / licor de banana / angostura.' },
    { n: 'Margarita Eco', p: 400, d: 'Tequila / jugo de pepino / zumo de limón / azúcar líquida / triple sec / amaretto / angostura.' },
    { n: 'Las Tres Cruces', p: 300, d: 'Vodka / triple sec / zumo de limón / jugo de pitahaya / licor de menta verde / soda / jarabe de azúcar.' },
    { n: 'Fresa Colada (sin alcohol)', p: 250, d: 'Fresas / crema de coco / leche evaporada / jugo de piña.' },
    { n: 'Fresa Colada (con alcohol)', p: 350, d: 'Fresas / crema de coco / leche evaporada / jugo de piña / ron.' },
    { n: 'Mojito (Limón / Fresa / Chinola)', p: 350, d: 'Ron / hoja de menta / sirope natural / zumo a elección.' },
    { n: 'Mojito de Coco', p: 350, d: 'Ron / hoja de menta / sirope natural / zumo de preferencia.' },
    { n: 'Old Fashion', p: 400, d: 'Whisky bourbon / angostura / azúcar morena / martini rosso.' },
    { n: 'Piña Colada', p: 300, d: 'Crema de coco / jugo de piña / leche evaporada.' },
    { n: 'Piña Colada con Alcohol', p: 350, d: 'Crema de coco / jugo de piña / leche evaporada / ron blanco.' },
    { n: 'Campari Tónic', p: 350, d: 'Campari / tónica.' },
    { n: 'Mickey Mouse', p: 400, d: 'Seven Up / granadina. (Sin alcohol)' },
    { n: 'Amaretto Sour', p: 350, d: 'Disaronno / bourbon / jugo de limón / sirope natural.' },
    { n: 'Whiskey Sour', p: 450, d: 'Whisky de su preferencia / zumo de limón / sirope natural.' },
    { n: 'Moscow Mule', p: 350, d: 'Vodka / limón / sirope natural / ginger beer.' },
    { n: 'Eco Special', p: 300, d: 'Ginebra / licor de menta / jugo de chinola / sirope natural / zumo de limón y pepino.' },
    { n: 'Sanky Panky', p: 350, d: 'Ron blanco / Licor 43 / zumo de chinola / zumo de limón / jarabe de goma.' },
    { n: 'Negroni Ecobar', p: 550, d: 'Ron doble reserva / Aperol / amaro / garnish.' },
    { n: 'Beso Higüeyano', p: 350, d: 'Tequila blanco / Aperol / amaretto / zumo de limón / jarabe de goma.' },
    { n: 'Ecomule', p: 350, d: 'Ron blanco / ginger beer / zumo de limón / jarabe de goma.' },
    { n: 'Vodka Cinnamon', p: 300, d: 'Vodka / zumo de limón / sirope de canela y jengibre.' },
    { n: 'Eco Diversidad', p: 350, d: 'Zumo de chinola / amaretto / Leyenda / crema de coco / leche.' },
    { n: 'Eco Sangría', p: 450, d: 'Vino tinto o blanco / frutas frescas / sirope natural / licores.' },
    { n: 'Madre Tierra', p: 350, d: 'Ron dorado / tequila dorada / whisky / ginebra saborizada / jugo de pepino / ginger ale.' },
    { n: 'Martini Clásico', p: 350, d: 'Ginebra o vodka, decorado con aceitunas o twist de limón.' },
    { n: 'Lago Cristalino', p: 350, d: 'Aloe vera / jugo de pepino / fresas / jugo de toronja / sirope de Splenda.' },
    { n: 'Schweppes Ginger Ale', p: 550, d: 'Bebida gaseosa con sabor a jengibre natural.' },
    { n: 'Daikiri', p: 350, d: 'Ron, jugo de limón y azúcar, servido bien frío.' },
    { n: 'Caipiriña', p: 350, d: 'Cachaça, lima fresca, azúcar y hielo triturado.' },
    { n: 'Coco Loco', p: 400, d: 'Ron, crema de coco, jugo de piña y jugo de limón.' },
    { n: 'Michelada', p: 450, d: 'Cerveza, jugo de limón, salsa picante y sal.' },
    { n: 'Costa Azul', p: 300, d: 'Vodka / jugo de limón / sirope de albahaca / blue curaçao.' },
  ]},
  { cat: 'Rones', bev: true, items: [
    { n: 'Barceló Imperial (Botella)', p: 2500 }, { n: 'Barceló Imperial (Trago)', p: 380 },
    { n: 'Brugal 1888 (Botella)', p: 4000 }, { n: 'Brugal 1888 (Trago)', p: 420 },
    { n: 'Brugal Leyenda (Botella)', p: 2300 }, { n: 'Brugal Leyenda (Trago)', p: 350 },
    { n: 'Brugal Doble Reserva (Botella)', p: 1700 }, { n: 'Brugal Doble Reserva (Trago)', p: 300 },
    { n: 'Brugal XV (Botella)', p: 1500 }, { n: 'Brugal XV (Trago)', p: 250 },
    { n: 'Brugal Extra Viejo (Botella)', p: 1300 }, { n: 'Brugal Extra Viejo (Trago)', p: 200 },
  ]},
  { cat: 'Whiskey', bev: true, items: [
    { n: 'Buchanans 12 (Botella)', p: 4300 }, { n: 'Buchanans 12 (Trago)', p: 500 },
    { n: 'Buchanans 18 (Botella)', p: 8500 }, { n: 'Buchanans 18 (Trago)', p: 850 },
    { n: 'Buffalo Trace Bourbon (Botella)', p: 4500 }, { n: 'Buffalo Trace Bourbon (Trago)', p: 450 },
    { n: 'Chivas Regal 12 (Botella)', p: 4000 }, { n: 'Chivas Regal 12 (Trago)', p: 400 },
    { n: 'Chivas Regal 18 (Botella)', p: 8000 }, { n: 'Chivas Regal 18 (Trago)', p: 800 },
    { n: 'Dewars 12 años (Botella)', p: 2500 }, { n: 'Dewars 12 años (Trago)', p: 350 },
    { n: 'Dewars 8 años (Botella)', p: 1300 }, { n: 'Dewars 8 años (Trago)', p: 300 },
    { n: 'Fireball (Botella)', p: 2800 }, { n: 'Fireball (Trago)', p: 300 },
    { n: "Jack Daniel's (Botella)", p: 3500 }, { n: "Jack Daniel's (Trago)", p: 350 },
    { n: 'Jim Beam Bourbon (Botella)', p: 4000 }, { n: 'Jim Beam Bourbon (Trago)', p: 450 },
    { n: 'JW. Black Label (Botella)', p: 3000 }, { n: 'JW. Black Label (Trago)', p: 350 },
    { n: 'JW. Doble Black (Botella)', p: 4500 }, { n: 'JW. Doble Black (Trago)', p: 500 },
    { n: 'JW. Gold Label (Botella)', p: 5500 }, { n: 'JW. Gold Label (Trago)', p: 600 },
    { n: 'Old Parr 12 (Botella)', p: 4500 }, { n: 'Old Parr 12 (Trago)', p: 450 },
    { n: 'Glenfiddich 12 (Botella)', p: 6000 },
    { n: 'The Glenlivet Founders (Botella)', p: 4500 },
    { n: 'The Macallan 12 (Botella)', p: 11000 },
  ]},
  { cat: 'Vodka', bev: true, items: [
    { n: "Tito's Vodka", p: 2700 }, { n: 'Grey Goose', p: 3200 }, { n: 'Belvedere', p: 4000 },
    { n: 'Ketel One', p: 3000 }, { n: 'Absolut', p: 2300 }, { n: 'Stolichnaya', p: 2000 },
    { n: 'Eristoff', p: 1500 },
  ]},
  { cat: 'Ginebra', bev: true, items: [
    { n: 'Hendricks', p: 5750 }, { n: 'Tanqueray No Ten', p: 4000 }, { n: 'Tanqueray Sport', p: 2600 },
    { n: 'Tanqueray London', p: 3000 }, { n: 'Bombay Sapphire', p: 3000 }, { n: 'Bulldog', p: 3800 },
    { n: 'Beefeater Pink', p: 3500 }, { n: 'Beefeater', p: 2300 },
  ]},
  { cat: 'Tequila', bev: true, items: [
    { n: 'Don Julio Añejo', p: 7300 }, { n: 'Don Julio Blanco', p: 6800 }, { n: 'Don Julio Reposado', p: 7500 },
    { n: 'Patrón Silver', p: 6200 }, { n: 'Agavita Blanco', p: 2500 }, { n: 'Agavita Gold', p: 2500 },
  ]},
  { cat: 'Digestivos', bev: true, items: [
    { n: 'Sambuca Romana', p: 250 }, { n: 'Grappa Cellini Bianca', p: 250 },
    { n: 'Grappa Limoncello Cellini', p: 250 }, { n: 'Amaro Averna', p: 250 },
    { n: 'Frangelico', p: 250 }, { n: 'Baileys', p: 300 },
    { n: 'Kahlúa Licor de Café', p: 300 }, { n: 'Fernet Branca', p: 300 },
  ]},
  { cat: 'Gin Tonic', bev: true, items: [
    { n: 'Gin Tonic Eco', p: 350 }, { n: 'Gin Tonic Bulldog', p: 450 },
    { n: 'Gin Tonic Bombay Sapphire', p: 500 }, { n: 'Gin Tonic Hendricks', p: 550 },
    { n: 'Gin Tonic Tanqueray No. Ten', p: 500 }, { n: 'Gin Tonic Tanqueray Sport', p: 400 },
    { n: 'Gin Tonic Beefeater Pink', p: 450 }, { n: 'Gin Tonic Beefeater', p: 350 },
  ]},
  { cat: 'Copas de Vino', bev: true, items: [
    { n: 'Vino tinto de la casa', p: 300 }, { n: 'Vino blanco de la casa', p: 300 },
  ]},
  { cat: 'Vinos Tinto', bev: true, items: [
    { n: 'López de Haro Reserva', p: 2000, d: 'Rioja, España.' },
    { n: 'Protos 9 Meses', p: 2400, d: 'Ribera del Duero, España.' },
    { n: 'Emilio Moro Finca Resalso', p: 2000, d: 'Ribera del Duero, España.' },
    { n: 'Robert Mondavi Private Selection', p: 2200, d: 'Cabernet Sauvignon.' },
    { n: 'Woodbridge by Robert Mondavi', p: 1500, d: 'Cabernet Sauvignon, California.' },
    { n: '19 Crime Cali Red (Snoop Dog)', p: 2300, d: 'Red Blend, South Australia.' },
    { n: '19 Crimes The Banished', p: 2300, d: 'Red Blend, California.' },
    { n: 'Cantina Zaccagnini Montepulciano', p: 2000, d: "D'Abruzzo Sangiovese, Italia." },
    { n: 'Frontera After Midnight', p: 1500 },
    { n: 'Primitivo Borgo di Mandorlo', p: 2000, d: 'Red Blend, Italia.' },
    { n: 'Trapiche Malbec', p: 1500, d: 'Argentina.' },
    { n: 'Frontera Carmenere', p: 1500, d: 'Chile.' },
    { n: 'Josh Cellars Legacy', p: 2000 },
    { n: 'Beringer Red Crush', p: 1500, d: 'Red Blend, California.' },
    { n: 'Mureda Tempranillo', p: 1200 },
    { n: 'Knock Knock Red Blend', p: 1200 },
    { n: 'Próximo Marqués de Riscal', p: 1500 },
    { n: 'Woodbridge Cabernet Sauvignon', p: 1500 },
  ]},
  { cat: 'Vinos Blancos', bev: true, items: [
    { n: 'Beringer Main & Vine Chardonnay', p: 1500 },
    { n: 'Martín Códax - Albariño', p: 2000 },
    { n: 'Beringer Main & Vine Moscato', p: 1500 },
    { n: 'Gotas de Mar, Albariño', p: 2300 },
    { n: 'Knock Knock Sauvignon Blanc', p: 1200 },
    { n: 'Marqués de Riscal', p: 2000 },
    { n: 'Marqués de Vizhoja', p: 1500 },
    { n: 'Mureda Sauvignon Blanc', p: 1200 },
    { n: 'Torresella, Pinot Grigio', p: 1500 },
    { n: 'Woodbridge Sauvignon Blanc', p: 1500 },
    { n: 'Frontera Pinot Grigio', p: 1200 },
  ]},
  { cat: 'Vinos Rosado', bev: true, items: [
    { n: '19 Crime Cali Rose', p: 2300 },
    { n: 'Woodbridge White Zinfandel', p: 1500 },
    { n: 'Beringer White Zinfandel', p: 1500 },
  ]},
  { cat: 'Cava / Prosecco', bev: true, items: [
    { n: 'Segura Viuda Brut Reserva', p: 2000, d: 'España.' },
    { n: 'Segura Viuda Brut Rosé', p: 2000, d: 'España.' },
    { n: 'Prosecco Maschio', p: 2000, d: 'Italia.' },
    { n: 'Jaume Serra Cava', p: 1200 },
  ]},
  { cat: 'Champagne', bev: true, items: [
    { n: 'Perrier Jouet Grand Brut', p: 6600 },
    { n: 'Pommery Brut Royal', p: 4900 },
  ]},
  { cat: 'Cervezas', bev: true, items: [
    { n: 'Corona Extra', p: 195 }, { n: 'Erdinger Weissbier', p: 350 }, { n: 'Modelo Negra', p: 225 },
    { n: 'Modelo Especial', p: 210 }, { n: 'Stella Artois', p: 235 }, { n: 'Smirnoff Ice Green', p: 235 },
    { n: 'Presidente Light', p: 155 }, { n: 'Presidente Regular', p: 155 }, { n: 'Erdinger Alkoholfrei', p: 300 },
    { n: 'Paulaner Sin Alcohol', p: 450 }, { n: 'Heineken', p: 235 }, { n: 'Ginger Beer Gosling Lata', p: 195 },
    { n: 'Ginger Ale Lata C&C', p: 155 }, { n: 'Leffe Blonde', p: 235 }, { n: 'Paulaner con Alcohol', p: 235 },
    { n: 'Estrella Galicia', p: 235 }, { n: 'Coors Light', p: 235 },
  ]},
  { cat: 'Cigarros', bev: false, items: [
    { n: 'La Aurora 115 Aniversario', p: 550 }, { n: 'La Aurora Connecticut', p: 400 },
    { n: 'La Aurora Maduro Belicoso', p: 450 }, { n: 'La Aurora Maduro Robusto', p: 400 },
    { n: 'León Jimenes No. 5', p: 350 }, { n: 'Don Carlos Altagracia Premium', p: 500 },
  ]},
  { cat: 'Cigarrillos', bev: false, items: [
    { n: 'Lucky Strike Black', p: 275 }, { n: 'Marlboro Fresh Ice Peq.', p: 500 },
    { n: 'Marlboro Gold Peq.', p: 400 }, { n: 'Marlboro Rojo Peq.', p: 350 },
  ]},
  { cat: 'Café', bev: true, items: [
    { n: 'Café Americano', p: 140 }, { n: 'Café Expreso', p: 135 }, { n: 'Capuchino', p: 170 },
  ]},
];

// --- Emisión SQL -----------------------------------------------------------
const q = (s) => s === null || s === undefined ? 'null' : `'${String(s).replace(/'/g, "''")}'`;

let cats = [];
let items = [];
let catPos = 0;
let totalItems = 0;
for (const group of MENU) {
  catPos += 1;
  const catId = crypto.randomUUID();
  cats.push(`  (${q(catId)}, ${q(BIZ)}, ${q(group.cat)}, ${catPos}, true)`);
  let itemPos = 0;
  for (const it of group.items) {
    itemPos += 1;
    totalItems += 1;
    items.push(
      `  (${q(BIZ)}, ${q(catId)}, ${q(it.n)}, ${it.p.toFixed(2)}, 'exclusive', ${q(it.d ?? null)}, ${group.bev}, ${itemPos})`,
    );
  }
}

const sql = `-- Menú ECO BAR & LOUNGE — business ${BIZ}
-- Generado por scripts/eco_bar_menu_gen.mjs. Precios SIN ITBIS (tax_mode='exclusive').
-- ${cats.length} categorías, ${totalItems} ítems. Correr UNA vez en el SQL editor.
begin;

insert into public.categories (id, business_id, name, position, is_active) values
${cats.join(',\n')};

insert into public.menu_items
  (business_id, category_id, name, price, tax_mode, description, is_beverage, position) values
${items.join(',\n')};

commit;
`;

fs.writeFileSync(OUT, sql);
console.error(`✓ ${OUT.pathname}: ${cats.length} categorías, ${totalItems} ítems`);
