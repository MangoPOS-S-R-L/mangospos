# Catálogo de EL RINCÓN DE ADDA (restaurante: pizza artesanal, cortes de carne,
# mariscos y cócteles). Fuente: 11 fotos de la carta impresa enviadas el
# 2026-10-16. No hay códigos ni costos: se empareja por nombre.
#
# Para cambiar un precio, un nombre, una categoría o un modificador: edita
# este archivo y corre `python3 build_import_8cb85c65.py`. No edites los .sql.
#
# Decisiones del usuario (2026-10-16):
#   * ITBIS 18% + Ley 10% INCLUIDOS en el precio (tax_mode 'inclusive').
#   * Piña Colada (400 y 450) y Smoothie de Fresa (450 y 500): el precio
#     bajo es SIN alcohol y el alto CON alcohol → opción obligatoria.
#   * El diagnóstico de prod (16-oct) trajo 2 productos creados a mano en
#     BEBIDAS: «AGUA DASANI» $50 (con una venta) es el «Agua» de la carta y
#     conserva su nombre; «JUGO DE LIMON» $150 es la «Limonada Natural» y se
#     renombra. Ninguno se duplica.

# (nombre, posición, área). Área: 'cocina' o 'bar'. La comida va primero.
CATEGORIAS = [
    ('ENTRADAS',             10, 'cocina'),
    ('ENSALADAS',            11, 'cocina'),
    ('PASTAS',               12, 'cocina'),
    ('PIZZAS',               13, 'cocina'),
    ('CARNES',               14, 'cocina'),
    ('PESCADOS Y MARISCOS',  15, 'cocina'),
    ('ESPECIALIDADES',       16, 'cocina'),
    ('GUARNICIONES',         17, 'cocina'),
    ('TRAGOS PROPIOS',       30, 'bar'),
    ('TRAGOS TRADICIONALES', 31, 'bar'),
    ('SHOTS',                32, 'bar'),
    ('VINOS',                33, 'bar'),
    ('CERVEZAS',             34, 'bar'),
    ('BEBIDAS',              35, 'bar'),
]

# Grupos de modificadores. Son del negocio entero y se buscan por nombre.
#   tipo 'uno'   → obligatorio, se escoge exactamente 1 (radio).
#   tipo 'extra' → opcional, se pueden marcar varios (sin máximo).
# opciones: (nombre, recargo)
GRUPOS = [
    ('Tipo de pasta', 'uno', [
        ('Linguine', 0), ('Espagueti', 0), ('Plumitas (Penne)', 0), ('Rigatoni', 0)]),
    ('Proteína para la pasta', 'extra', [
        ('Pollo', 150), ('Res', 200), ('Mariscos (indicar cuál)', 400)]),
    ('Término de la carne', 'uno', [
        ('Rojo', 0), ('Medio rojo', 0), ('Término medio', 0),
        ('Tres cuartos', 0), ('Bien cocido', 0)]),
    ('Plancha o parrilla', 'uno', [
        ('A la plancha', 0), ('A la parrilla', 0)]),
    ('Frito o al vapor', 'uno', [
        ('Frito', 0), ('Al vapor', 0)]),
    ('Preparación del marisco', 'uno', [
        ('Al grill', 0), ('A la criolla', 0), ('En vinagreta', 0), ('En salsa cremosa', 0)]),
    ('Salsa a elegir', 'uno', [
        ('A la criolla', 0), ('En vinagreta', 0), ('En salsa cremosa', 0)]),
    ('Vegetales', 'uno', [
        ('Al grill', 0), ('Salteados', 0), ('Al vapor', 0)]),
    ('Papas', 'uno', [
        ('Fritas', 0), ('Salteadas', 0), ('Al vapor', 0), ('En puré', 0)]),
    ('Con o sin alcohol', 'uno', [
        ('Sin alcohol', 0), ('Con alcohol', 50)]),
]

PASTA = ['Tipo de pasta', 'Proteína para la pasta']
TERMINO = ['Término de la carne']

# Producto: (nombre en la caja, precio, descripción, grupos, nombre impreso si
# es distinto, duda para el dueño). Los productos de cada categoría van en el
# orden de la carta.
# El nombre impreso TAMBIÉN sirve para emparejar con un producto que ya exista
# (y se renombra), salvo con alias=False: las salsas sueltas de las pastas
# («Cuatro Quesos» agarraría una pizza) y los tragos que se partieron en dos.
# alias='TEXTO' empareja con ese nombre exacto del catálogo actual.
# existente=True: el producto ya estaba antes de la carga (creado a mano en la
# app); el rollback NO lo borra.
def P(nombre, precio, desc='', grupos=(), impreso=None, duda='', alias=True,
      existente=False):
    if isinstance(alias, str):
        al = alias
    else:
        al = (impreso or nombre) if alias else nombre
    return dict(name=nombre, price=precio, desc=desc, grupos=list(grupos),
                impreso=impreso or nombre, duda=duda, alias=al, existente=existente)


CARTA = {
    'ENTRADAS': [
        P('Carpaccio de Lomito', 470,
          'Finas láminas de lomito de res, acompañadas de queso parmesano, champiñones '
          'frescos, aceite de oliva extra virgen y un delicado toque de limón.'),
        P('Aros de Calamar Rebozados', 470,
          'Aros de calamar ligeramente empanizados y dorados, servidos con limón fresco '
          'y aderezo especial de la casa.'),
        P('Bruquetas de Camarón', 700,
          'Pan artesanal tostado con camarones salteados y queso mozzarella gratinado.',
          duda='«Bruquetas» va como en la carta (¿Brusquetas?).'),
        P('Bruquetas Caprese', 450,
          'Pan artesanal tostado con tomates frescos, mozzarella gratinada, albahaca y '
          'aceite de oliva extra virgen.'),
        P('Croquetas de Pollo', 360,
          'Crujientes croquetas de pollo artesanal, acompañadas de salsa tártara.'),
        P('Focaccia', 250,
          'Masa horneada con aceite de oliva extra virgen, queso parmesano y orégano.',
          duda='La carta dice «crégano»: se corrigió a orégano en la descripción.'),
    ],
    'ENSALADAS': [
        P('Ensalada Verde', 300,
          'Mezcla de lechugas frescas, tomate, pepino y zanahoria, acompañada de aderezo '
          'especial de la casa.'),
        P('Ensalada Caprese', 420,
          'Tomates frescos, mozzarella, hojas de albahaca y reducción de vinagre balsámico.'),
        P('Ensalada César', 350,
          'Lechuga romana, queso parmesano, crutones y el tradicional aderezo César.'),
        P('Ensalada César con Pollo', 400,
          'Lechuga romana, queso parmesano, crutones, pechuga de pollo y el tradicional '
          'aderezo César.'),
        P('Ensalada César con Camarones', 600,
          'Lechuga romana, queso parmesano, crutones, camarones y el tradicional aderezo '
          'César.'),
        P('Ensalada de Aguacate', 250,
          'Aguacate fresco sobre una cama de lechugas, aliñado con aceite de oliva extra '
          'virgen, sal y pimienta.'),
    ],
    # La carta: "Elija su pasta" (4) + "Acompañe con la salsa" (precio) +
    # "Añada su proteína" (recargo). La salsa es el producto.
    'PASTAS': [
        P('Pasta Alfredo', 600, grupos=PASTA, impreso='Alfredo', alias=False),
        P('Pasta Carbonara', 650, grupos=PASTA, impreso='Carbonara', alias=False),
        P('Pasta Marinara', 1070, grupos=PASTA, impreso='Marinara', alias=False,
          duda='$1,070 contra 600-750 de las otras salsas: ¿lleva mariscos?'),
        P('Pasta Caprese', 750, grupos=PASTA, impreso='Caprese', alias=False),
        P('Pasta a la Crema', 600, grupos=PASTA, impreso='Crema', alias=False),
        P('Pasta Cuatro Quesos', 750, grupos=PASTA, impreso='Cuatro Quesos', alias=False),
    ],
    'PIZZAS': [
        P('Pizza Romana', 700, 'Jamón, maíz dulce, pepperoni y mozzarella.'),
        P('Pizza Prosciutto e Funghi', 600, 'Jamón, champiñones frescos y queso mozzarella.'),
        P('Pizza Prosciutto', 600, 'Jamón y abundante queso mozzarella.'),
        P('Pizza Caprese', 600, 'Tomates cherry, mozzarella fresca y albahaca.'),
        P('Pizza de Vegetales', 700,
          'Pimientos tricolores, cebolla, champiñones y maíz dulce.'),
        P('Pizza Pepperoni', 650, 'Pepperoni y queso mozzarella.'),
        P('Pizza Cuatro Quesos', 750, 'Mozzarella, parmesano, cheddar y queso azul.'),
        P('Pizza Marinera', 1100, 'Camarones, aros de calamar y queso mozzarella.'),
        P('Pizza Chicken Crispy', 600, 'Pollo crujiente, mozzarella y salsa de tomate.'),
        P('Pizza El Rincón de Adda', 750,
          'Pollo, maíz dulce, vegetales frescos, champiñones y aceitunas negras.'),
        P('Pizza de Atún y Cebolla', 700, 'Atún, cebolla y queso mozzarella.'),
    ],
    'CARNES': [
        P('Churrasco Prime Importado', 1200,
          'Jugoso corte de res Prime preparado a la parrilla.', TERMINO),
        P('Flap Meat Prime Angus', 1700,
          'Corte premium de gran sabor y excelente marmoleo, cocinado al grill.', TERMINO),
        P('Picaña Prime Importada', 1100,
          'Tradicional corte brasileño asado a la parrilla.', TERMINO),
        P('Ribeye Prime Importado', 2500,
          'Corte premium de intenso marmoleo y extraordinaria jugosidad.', TERMINO),
        P('T-Bone Angus Choice Importado', 2600,
          'Clásico corte con filete y New York Strip en una sola pieza.', TERMINO),
        P('Tomahawk Angus Choice Importado (2.5 lb)', 5000,
          'Imponente corte con hueso largo, ideal para compartir.', TERMINO,
          impreso='Tomahawk Angus Choice Importado (2.5lb)'),
        P('Pollo a la Plancha', 600, 'Pechuga marinada y cocinada a la plancha.'),
        P('Pechuga de Pollo a la Crema', 600, 'Pechuga de pollo marinada con salsa a la crema.'),
        P('Pollo a la Torre', 720,
          'Pechuga de pollo a la plancha acompañada de berenjena, queso fresco y cebolla '
          'caramelizada.'),
        P('Lomo de Cerdo', 750,
          'Preparado a la plancha o a la parrilla con salsa al brandy.',
          ['Plancha o parrilla']),
        P('Chuleta de Cerdo', 600, 'Jugosa chuleta de cerdo a la parrilla en salsa brandy.'),
        P('Costillas de Cerdo', 600,
          'Costillas tiernas cocinadas lentamente hasta alcanzar su máxima suavidad.'),
    ],
    'PESCADOS Y MARISCOS': [
        P('Chillo Entero', 1500, 'Disponible frito o al vapor.', ['Frito o al vapor']),
        P('Filete de Mero Barsa', 700, 'Delicado filete de mero preparado a su elección.',
          duda='«a su elección» sin opciones en la carta: no se le puso modificador. '
               '¿«Barsa» es correcto?'),
        P('Lomo de Atún Rojo', 1200, 'Atún rojo fresco sellado a la perfección.'),
        P('Filete de Salmón', 1000, 'Salmón fresco preparado a la plancha o al grill.',
          ['Plancha o parrilla']),
        P('Filete de Salmón en Salsa de Ajo', 1000,
          'Salmón fresco preparado a la plancha o al grill en salsa de ajo.',
          ['Plancha o parrilla'], impreso='Filete de Salmón (en salsa de ajo)',
          duda='La carta trae dos «Filete de Salmón» a $1,000; el segundo es en salsa de ajo.'),
        P('Lambí', 700, 'Preparado a la criolla, en vinagreta o en salsa cremosa.',
          ['Salsa a elegir']),
        P('Ceviche de Mero', 600,
          'Mero fresco marinado en jugo de limón con cebolla morada, cilantro y ají.'),
        P('Masa de Cangrejo', 950, 'Preparada al estilo criollo.'),
        P('Camarones', 900, 'A elegir: al grill, a la criolla, en vinagreta o en salsa cremosa.',
          ['Preparación del marisco']),
        P('Pulpo', 900, 'Preparado al grill, a la criolla, en vinagreta o en salsa cremosa.',
          ['Preparación del marisco']),
        P('Calamar a la Plancha', 850, 'Calamar fresco sellado a la plancha con finas hierbas.'),
        P('Aros de Calamar Salteados', 700,
          'Aros de calamar salteados acompañados de salsa brandy.',
          impreso='Aros de calamar salteado'),
        P('Cola de Langosta', 2200, 'Cola de langosta a la parrilla con mantequilla de ajo.'),
        P('Cazuela de Mariscos', 1000,
          'Exquisita combinación de camarones, calamares, mejillones y pescado fresco en una '
          'delicada salsa marinera.'),
        P('Sopa de Mariscos', 1000,
          'Combinación de camarones, calamares, mejillones y pescado fresco.'),
        P('Salpicón de Mariscos', 950, 'Camarones, calamares, mejillones y pescado fresco.'),
        P('Lambí y Pulpo', 800, 'Mezcla de lambí y pulpo en la salsa de su preferencia.',
          ['Salsa a elegir']),
        P('Mejillones al Vapor', 600, 'Mejillones frescos cocidos al vapor con ajo.'),
    ],
    'ESPECIALIDADES': [
        P('Parrillada Mar y Tierra (2 personas)', 2500,
          'Combinación de carnes premium y mariscos frescos para compartir.',
          impreso='Parrillada Mar y Tierra x2P'),
        P('Parrillada Mixta (2 personas)', 1800,
          'Selección de carnes a la parrilla acompañadas de guarniciones.',
          impreso='Parrillada Mixta x2P'),
        P('Parrillada de Mariscos (2 personas)', 2600,
          'Exquisita variedad de mariscos frescos preparados a la parrilla.',
          impreso='Parrillada de Mariscos x2P'),
        P('Paella (2 personas)', 2500,
          'Arroz preparado con mariscos y vegetales, sazonado con especias.',
          impreso='Paella x2P'),
        P('Mofongo de Camarones', 800,
          'Mofongo de plátano verde con camarones salteados en cremosa salsa.'),
        P('Mofongo de Pollo', 600,
          'Mofongo de plátano verde acompañado de pollo salteado en cremosa salsa.'),
    ],
    'GUARNICIONES': [
        P('Arroz Blanco', 100),
        P('Vegetales', 100, 'Al grill, salteados o al vapor.', ['Vegetales'],
          impreso='Vegetales al grill, salteados o al vapor'),
        P('Papas', 100, 'Fritas, salteadas, al vapor o en puré.', ['Papas'],
          impreso='Papas fritas, salteadas, al vapor o en puré'),
        P('Tostones', 100),
        P('Pan con Ajo', 150),
    ],
    'TRAGOS PROPIOS': [
        P('Addana Apple', 500),
        P('Addita', 400),
        P('Papá Chelo', 600),
        P('La Ex', 450),
        P('La Rabiosa', 450),
        P('La Insoportable', 350),
    ],
    'TRAGOS TRADICIONALES': [
        P('Piña Colada', 400, 'Sin alcohol $400 · con alcohol $450.', ['Con o sin alcohol']),
        P('Watermelon Sunset', 350),
        P('Wild Forest', 400),
        P('Ruso Blanco', 500),
        P('Ruso Negro', 450),
        P('Vodka Sunrise', 500),
        P('Vodka Tonic', 450),
        P('Screwdriver', 500),
        P('Pink Tonic', 600),
        P('Gin Tonic', 500),
        P('Mojito de Pitahaya', 550, impreso='Mojito de Pitahaya//Limón', alias=False),
        P('Mojito de Limón', 550, impreso='Mojito de Pitahaya//Limón', alias=False),
        P('Mojito de Morir Soñando', 550),
        P('Mojito de Chinola', 600),
        P('Margarita de Limón', 500, impreso='Margarita Limón//Fresa', alias=False),
        P('Margarita de Fresa', 500, impreso='Margarita Limón//Fresa', alias=False),
        P('Margarita de Chinola', 600),
        P('Cuba Libre', 500),
        P('Cuba Libre Doble Reserva', 600),
        P('Smoothie de Fresa', 450, 'Sin alcohol $450 · con alcohol $500.',
          ['Con o sin alcohol']),
        P('Limonada Coco', 500),
        P('Sangría', 400),
        P('Frozen', 250, duda='$250, el más barato de los tragos: ¿de qué sabores?'),
    ],
    'SHOTS': [
        P('Shot de Canelilla', 200),
        P('Shot de Barceló', 300),
        P('Shot de Baileys', 300),
        P('Shot de Tequila', 300),
        P('Trago Johnnie Walker Black Label', 450,
          impreso='Trago Johnny Walker Black Label'),
        P('Trago Old Parr', 350),
        P("Trago Jack Daniel's", 500),
    ],
    'VINOS': [
        P('Porto Tinto', 3500),
        P('Casillero del Diablo Tinto Merlot', 1400),
        P('Bogle Tinto', 2500,
          duda='En la foto se lee «Bogle Ti…» (tapado por un reflejo).'),
        P('Casillero del Diablo Cabernet Tinto', 1500),
        P('19 Crimes', 2500, impreso='19 Crimemenes'),
        P('Carlo Rossi', 1000),
        P('Copa de Vino de la Casa', 300),
        P('Copa de Vino Porto', 800),
        P('Copa de Vino 19 Crimes', 800),
        P('Copa de Vino Casillero del Diablo', 800,
          duda='La copa a $800 y la botella a $1,400-1,500: ¿seguro?'),
        P('Copa de Vino Bogle', 500),
    ],
    'CERVEZAS': [
        P('Cerveza Corona', 250),
        P('Cerveza Presidente', 200),
        P('Cerveza Smirnoff', 250),
        P('Cerveza Modelo', 250),
    ],
    'BEBIDAS': [
        P('Jugo de Sandía con Limón', 200),
        P('Limonada Natural', 150, impreso='Limonada natural', alias='JUGO DE LIMON',
          existente=True, duda='Ya existía como «JUGO DE LIMON» (sin ventas): se renombra.'),
        P('Jugo de Chinola', 150),
        P('Jugo de Piña', 150),
        P('Café Negro', 50),
        P('AGUA DASANI', 50, impreso='Agua', existente=True,
          duda='Ya existía y tiene ventas: es el «Agua» de la carta y conserva su nombre.'),
        P('Enriquillo', 50),
        P('Agua Tónica', 50),
        P('Refresco Coca Cola Peq.', 50),
        P('Refresco Merengue Peq.', 50),
        P('Refresco Naranja Peq.', 50),
        P('Refresco Seven Up Peq.', 50),
        P('Refresco Sprite Peq.', 50),
        P('Refresco Coca Cola 2 Litros', 250),
    ],
}


def productos():
    area = {c[0]: c[2] for c in CATEGORIAS}
    grupos = {g[0] for g in GRUPOS}
    assert set(CARTA) == set(area), 'CARTA y CATEGORIAS no cuadran'
    out = []
    for cat, ps in CARTA.items():
        for i, p in enumerate(ps, start=1):
            assert all(g in grupos for g in p['grupos']), (p['name'], p['grupos'])
            out.append(dict(p, categoria=cat, area=area[cat], posicion=i))
    nombres = [p['name'].lower() for p in out]
    assert len(nombres) == len(set(nombres)), 'nombre repetido en la carta'
    return out
