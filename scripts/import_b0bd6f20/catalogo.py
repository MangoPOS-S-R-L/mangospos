# Catálogo de LA COCINA MEXICANA AUTENTICA (business
# b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee), curado a mano a partir de
# _fuente.csv ("Catalogo de productos (Transformados)" del sistema anterior,
# 07/10/2026 01:59 PM, 190 filas).
#
# Cada fila del CSV (por su "Indentificador Unico") cae en UNA de estas cosas:
#   PRODUCTOS  → un producto de la caja;
#   VARIANTES  → una opción del modificador OBLIGATORIO de un producto
#                (Cantarito 1800 → Silver / Reposado / Añejo...);
#   EXTRAS     → una opción del grupo opcional "Extras" de los platos de cocina;
#   OMITIDAS   → no se carga (repetida o cargo de delivery).
# El build aborta si una fila del CSV no está en ninguna o está en dos.
#
# Decisiones del usuario (07-oct-2026):
#   * variantes = producto + modificador obligatorio con el precio más bajo de
#     base y la diferencia como precio del modificador (estilo Toast). También
#     TOSTADAS y ENCHILADA, que el usuario ya había subido genéricos;
#   * categoría Extra = grupo de modificadores opcional "Extras" en los platos
#     de cocina; "Carnes 700" queda como producto;
#   * "Delivery 100 … 450" NO se cargan (y los que ya estaban se desactivan):
#     la caja cobra el delivery propio como cargo exento al cobrar;
#   * ITBIS 18% + Ley 10% incluidos en el precio (inclusive), a TODO lo activo
#     del negocio. La Ley se copia de la sucursal de Ágora (6e18428f). AGUA
#     sin ITBIS, como en Ágora;
#   * manda el precio del CSV, también sobre lo que ya estaba subido.
#
# Para corregir algo: edítalo aquí y corre `python3 build_import_b0bd6f20.py`.

import csv
import os

HERE = os.path.dirname(os.path.abspath(__file__))

# Negocio del que se copia la Ley 10% si este no la tiene.
LEY_ORIGEN = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'

# (nombre, posición, área). Las 7 primeras YA EXISTEN en el negocio (con su
# emoji); se emparejan por letras y números, así que no se duplican. El área
# es la de la comanda ('cocina' o 'bar'): la usan las filas del CSV que la
# traen vacía.
CATEGORIAS = [
    ('ENTRADAS 🥨', 10, 'cocina'),
    ('TACOS 🌮', 20, 'cocina'),
    ('PLATOS MEXICANOS 🌯', 30, 'cocina'),
    ('BEBIDAS🥤', 40, 'bar'),
    ('Postres', 50, 'bar'),
    ('DELIVERY', 60, 'cocina'),
    ('EXTRAS', 70, 'cocina'),
    # nuevas
    ('SIN ALCOHOL', 41, 'bar'),
    ('CERVEZA', 42, 'bar'),
    ('CAFÉ', 43, 'bar'),
    ('CANTARITOS', 44, 'bar'),
    ('MARGARITAS', 45, 'bar'),
    ('MICHELADAS', 46, 'bar'),
    ('MOJITOS', 47, 'bar'),
    ('COCTELES', 48, 'bar'),
    ('MEZCAL', 49, 'bar'),
    ('DON JULIO RESERVA', 51, 'bar'),
    ('OTROS TEQUILAS EXCLUSIVOS', 52, 'bar'),
    ('OTROS TEQUILAS', 53, 'bar'),
]

# Categoría del CSV → categoría de la caja.
CAT_CSV = {
    'Entradas': 'ENTRADAS 🥨',
    'Platos Mexicanos': 'PLATOS MEXICANOS 🌯',
    'Tostadas': 'PLATOS MEXICANOS 🌯',
    'Tacos': 'TACOS 🌮',
    'Postres': 'Postres',
    'Cantaritos': 'CANTARITOS',
    'Margaritas': 'MARGARITAS',
    'Micheladas': 'MICHELADAS',
    'Mojitos': 'MOJITOS',
    'Cocteles': 'COCTELES',
    'Don Julio Reserva': 'DON JULIO RESERVA',
    'Otros Tequilas Exclusivos': 'OTROS TEQUILAS EXCLUSIVOS',
    'Otros Tequilas': 'OTROS TEQUILAS',
    'Mezcal': 'MEZCAL',
    'Sin Alcohol': 'SIN ALCOHOL',
    'Cerveza': 'CERVEZA',
    'Extra': 'EXTRAS',
    'Café': 'CAFÉ',
    'Delivery': 'DELIVERY',
    'Bebidas': 'BEBIDAS🥤',
}

# Categorías cuyos productos son bebidas (menu_items.is_beverage).
BEBIDAS = {'BEBIDAS🥤', 'SIN ALCOHOL', 'CERVEZA', 'CAFÉ', 'CANTARITOS', 'MARGARITAS',
           'MICHELADAS', 'MOJITOS', 'COCTELES', 'MEZCAL', 'DON JULIO RESERVA',
           'OTROS TEQUILAS EXCLUSIVOS', 'OTROS TEQUILAS'}

# id del CSV → (nombre, descripción o None, nota o None). El nombre se carga
# en MAYÚSCULAS, como lo que ya subió el usuario. La categoría, el precio y el
# área salen del CSV.
PRODUCTOS = {
    # Entradas
    '5':   ('Choriqueso', None, None),
    '2':   ('Mini Flautas', None, None),
    '4':   ('Mini Sopes', None, None),
    '3':   ('Nachos 3 Compadres', None, None),
    '132': ('Nachos con Guacamole', None, None),
    # Platos Mexicanos
    '21':  ('Burrito', None, None),
    '16':  ('Chilaquiles', None, None),
    '24':  ('Chimichanga', None, None),
    '28':  ('Fajitas', None, None),
    '9':   ('Flautas de Papa y Chorizo', None, None),
    '8':   ('Flautas de Pollo', None, None),
    '31':  ('Gringa', None, 'la 187 es la misma (mismo precio): se carga una'),
    '6':   ('Huevos Rancheros', None, None),
    '7':   ('Huevos Rancheros Divorciados', None, None),
    '13':  ('Quesadilla de Chorizo', None, None),
    '15':  ('Quesadilla de Pollo', None, None),
    '188': ('Sopa de Tortillas', None, None),
    '10':  ('Sopes de Papa y Chorizo', None, None),
    '11':  ('Sopes de Pollo', None, None),
    '12':  ('Sopes de Tinga de Pollo', None, None),
    # Tacos
    '51':  ('Chamorro de Cerdo', None, None),
    '46':  ('Tacos', None, None),
    '42':  ('Tacos a la Zimbron', '3 unidades', None),
    '37':  ('Tacos al Pastor', '4 unidades', None),
    '183': ('Tacos de Chilorio', None, None),
    '43':  ('Tacos de Birria', '4 unidades', None),
    '38':  ('Tacos de Carnitas Michoacanas', '4 unidades', None),
    '44':  ('Tacos de Cochinita Pibil', '4 unidades', None),
    '41':  ('Tacos de Tinga de Pollo', '4 unidades', None),
    '217': ('Unidad de Taco', None, None),
    # Postres (el CSV los manda al Bar)
    '206': ('Brownie a la Moda', None, None),
    '229': ('Churros', None, None),
    '52':  ('Pie de Limón', None, None),
    # Cantaritos sin variantes
    '186': ('Cantarito 400 Conejos', None, None),
    '68':  ('Cantarito Gran Cava Extra Añejo', None, None),
    '69':  ('Cantarito Grand Mayan Extra Añejo', None, None),
    '184': ('Cantarito Mezcal Mitre', None, 'área vacía en el CSV → Bar'),
    '185': ('Cantarito Montelobos', None, 'área vacía en el CSV → Bar'),
    # Margaritas
    '192': ('Margarita de Chinola', None, None),
    '193': ('Margarita de Coco', None, None),
    '72':  ('Margarita de Fresa', None, None),
    '70':  ('Margarita de Limón', None, None),
    '71':  ('Margarita de Tamarindo', None, None),
    '209': ('Margarita de Limón a la Roca', None, None),
    # Micheladas
    '76':  ('Chelada', None, None),
    '75':  ('Michelada de Tamarindo', None, None),
    '74':  ('Michelada de Mango', None, None),
    '73':  ('Michelada Tradicional', None, None),
    # Mojitos
    '198': ('Mojito de Chinola', None, None),
    '79':  ('Mojito de Coco', None, None),
    '80':  ('Mojito de Fresa', None, None),
    '78':  ('Mojito de Jamaica', None, None),
    '77':  ('Mojito de Limón', None, None),
    # Cocteles
    '201': ('Aperol Spritz', None, None),
    '210': ('Averna', None, None),
    '189': ('Baileys', None, None),
    '216': ('Diego Rivera', None, None),
    '148': ('Mezcalita', None, 'en el CSV: "Mezcalita - Nueva"'),
    '82':  ('Paloma', None, None),
    '81':  ('Sangría de Jamaica', None, None),
    '202': ('Tequila Sunrise', None, None),
    # Don Julio Reserva
    '84':  ('Don Julio Añejo (Shot)', None, None),
    '83':  ('Don Julio Reposado (Shot)', None, None),
    '85':  ('Francisco Gonzales Extra Añejo (Shot)', None, None),
    # Otros Tequilas Exclusivos
    '89':  ('Amor Mío Blanco (Shot)', None, None),
    '90':  ('Clase Azul Reposado (Shot)', None, None),
    '87':  ('Gran Cava de Oro Extra Viejo (Shot)', None,
            'en el CSV: "Grand Cava"; el cantarito dice "Gran Cava"'),
    '86':  ('Grand Mayan Extra Viejo (Shot)', None, None),
    # Otros Tequilas
    '97':  ('1800 Añejo (Shot)', None, None),
    '96':  ('1800 Reposado (Shot)', None, None),
    '95':  ('1800 Silver (Shot)', None, None),
    '98':  ('1800 Ultra Añejo Cristalino (Shot)', None, None),
    '92':  ('Agavita Reposado (Shot)', None, None),
    '91':  ('Agavita Silver (Shot)', None, None),
    '227': ('Gran Malo (Shot)', None,
            'la 88 es la misma (mismo precio, en Otros Tequilas Exclusivos): se carga una'),
    '101': ('Herradura Añejo (Shot)', None, None),
    '100': ('Herradura Reposado (Shot)', None, None),
    '99':  ('Herradura Silver (Shot)', None, None),
    '102': ('Herradura Ultra Añejo (Shot)', None, None),
    '94':  ('José Cuervo Reposado (Shot)', None, None),
    '93':  ('José Cuervo Silver (Shot)', None, None),
    # Mezcal
    '218': ('Contraluz Mezcal', None, None),
    '105': ('Mezcal 400 Conejos (Shot)', None, None),
    '219': ('Ojo de Tigre', None, None),
    # Sin Alcohol
    '115': ('Agua Dasani', None, 'es el AGUA ya subido; sin ITBIS, como en Ágora'),
    '112': ('Chinola Frozen', None, None),
    '110': ('Fresa Frozen', None, None),
    '107': ('Horchata', None, None),
    '200': ('Jugo de Cereza', None, None),
    '109': ('Jugo de Chinola', None, None),
    '215': ('Jugo de Fruit Punch', None, None),
    '108': ('Jugo de Limón', None, None),
    '248': ('Limonada de Coco', None, None),
    '111': ('Limonada Frozen', None, None),
    '205': ('Tamarindo Frozen', None, None),
    '106': ('Té de Jamaica', None, None),
    # Cerveza
    '147': ('Clamato', None, None),
    '119': ('Corona', None, None),
    '120': ('Heineken', None, None),
    '122': ('Modelo Negra', None, None),
    '121': ('Modelo Rubia', None, None),
    '117': ('Presidente Light', None, None),
    '116': ('Presidente Normal', None, None),
    '118': ('Stella Artois', None, None),
    # Extra
    '249': ('Carnes', None, 'queda como producto (no como extra)'),
    # Café
    '129': ('Café con Leche', None, None),
    '130': ('Cortadito', None, None),
    '131': ('Espresso', None, None),
    # Delivery (combos; el CSV no les pone área → Cocina)
    '213': ('Fiestón de Tacos', None, 'en el CSV: "A. Fieston de tacos"; área vacía → Cocina'),
    '214': ('Combo Rosario', None, 'área vacía en el CSV → Cocina'),
    # Bebidas
    '178': ('Jugos Naturales', None, None),
}

# Producto con modificador obligatorio. clave → (producto, categoría de la
# caja, qué se elige). El grupo se llama "<producto> · <qué se elige>".
GRUPOS_VARIANTE = {
    'tostadas':        ('Tostadas', 'PLATOS MEXICANOS 🌯', 'Tipo'),
    'enchilada':       ('Enchilada', 'PLATOS MEXICANOS 🌯', 'Tipo'),
    'cachetadas':      ('Cachetadas', 'TACOS 🌮', 'Corte'),
    'c_1800':          ('Cantarito 1800', 'CANTARITOS', 'Tequila'),
    'c_agavita':       ('Cantarito Agavita', 'CANTARITOS', 'Tequila'),
    'c_don_julio':     ('Cantarito Don Julio', 'CANTARITOS', 'Tequila'),
    'c_herradura':     ('Cantarito Herradura', 'CANTARITOS', 'Tequila'),
    'c_jose_cuervo':   ('Cantarito José Cuervo', 'CANTARITOS', 'Tequila'),
    'mangonada':       ('Mangonada', 'COCTELES', 'Alcohol'),
    'pina_colada':     ('Piña Colada', 'COCTELES', 'Alcohol'),
    'jarritos':        ('Jarritos', 'BEBIDAS🥤', 'Sabor'),
    'refresco':        ('Refresco', 'SIN ALCOHOL', 'Sabor'),
    'arizona':         ('Arizona', 'BEBIDAS🥤', 'Sabor'),
    'refresco_sabor':  ('Refrescos Sabores', 'BEBIDAS🥤', 'Sabor'),
    'soda_can':        ('Soda Can', 'BEBIDAS🥤', 'Sabor'),
}

# id del CSV → (clave del grupo, nombre de la opción, nota o None).
VARIANTES = {
    '181': ('tostadas', 'Cerdo', 'la 35 es la misma a $600: se deja $650 (el código más nuevo)'),
    '33':  ('tostadas', 'Chilorio', None),
    '36':  ('tostadas', 'Papa y Chorizo', None),
    '32':  ('tostadas', 'Pollo', None),
    '34':  ('tostadas', 'Tinga de Pollo', None),
    '167': ('enchilada', 'Pollo', None),
    '190': ('enchilada', 'Queso', 'en el CSV: "Enchilada queso - A"'),
    '146': ('enchilada', 'Suiza', 'la ENCHILADA SUIZA suelta (inactiva) no se toca'),
    '246': ('cachetadas', 'Tenderloin', None),
    '245': ('cachetadas', 'NY Steak', None),
    '244': ('cachetadas', 'Ribeye', None),
    '57':  ('c_1800', 'Silver', None),
    '58':  ('c_1800', 'Reposado', None),
    '59':  ('c_1800', 'Añejo', None),
    '60':  ('c_1800', 'Añejo Cristalino', None),
    '53':  ('c_agavita', 'Silver', None),
    '54':  ('c_agavita', 'Gold', None),
    '67':  ('c_don_julio', 'Reposado', None),
    '66':  ('c_don_julio', 'Añejo', None),
    '65':  ('c_don_julio', 'Extra Añejo', None),
    '63':  ('c_herradura', 'Reposado', 'en el CSV: "Herrtadura"'),
    '64':  ('c_herradura', '818 Reposado', 'en el CSV: "Herrtadura"'),
    '61':  ('c_herradura', 'Añejo', 'en el CSV: "Herrtadura"'),
    '62':  ('c_herradura', 'Cristalino Ultra', 'en el CSV: "Herrtadura"'),
    '55':  ('c_jose_cuervo', 'Silver', None),
    '56':  ('c_jose_cuervo', 'Reposado', None),
    '197': ('mangonada', 'Sin alcohol', None),
    '196': ('mangonada', 'Con alcohol', None),
    '203': ('pina_colada', 'Con alcohol', None),
    '204': ('pina_colada', 'Sin alcohol', None),
    '114': ('jarritos', 'Tamarindo', None),
    '134': ('jarritos', 'Mandarina', None),
    '135': ('jarritos', 'Toronja', None),
    '136': ('jarritos', 'Fruit Punch', None),
    '137': ('jarritos', 'Limón', None),
    '138': ('jarritos', 'Piña', None),
    '199': ('jarritos', 'Guayaba', None),
    '113': ('refresco', 'Coca Cola', None),
    '133': ('refresco', 'Sprite', None),
    '145': ('refresco', 'Soda', None),
    '226': ('refresco', 'Zero', None),
    '230': ('refresco', 'Squirt', None),
    '231': ('refresco', 'Sidral Manzana', None),
    '232': ('refresco', 'Sangría Señorial', None),
    '233': ('refresco', 'Boing Mango', None),
    '195': ('arizona', 'Ice Tea', 'área vacía en el CSV → Bar'),
    '242': ('arizona', 'Strawberry Kiwi', 'área vacía en el CSV → Bar'),
    '221': ('refresco_sabor', 'Rojo', 'área vacía en el CSV → Bar'),
    '222': ('refresco_sabor', 'Uva', 'área vacía en el CSV → Bar'),
    '223': ('refresco_sabor', 'Merengue', 'área vacía en el CSV → Bar'),
    '225': ('refresco_sabor', 'Sprite', 'área vacía en el CSV → Bar'),
    '224': ('refresco_sabor', 'Soda', 'área vacía en el CSV → Bar'),
    '236': ('soda_can', 'Canada Dry Ginger', None),
    '237': ('soda_can', 'Canada Dry Blackberry', None),
    '238': ('soda_can', 'Dr Pepper', None),
    '239': ('soda_can', 'Dr Pepper Blackberry', None),
    '240': ('soda_can', 'Dr Pepper Cherry', None),
    '241': ('soda_can', 'Squirt Toronja', None),
}

# Precio que corrige al del CSV: id → (precio, por qué).
_JARRITOS = ('el CSV trae los sabores a $250 (Sin Alcohol) y "Jarritos. - Guava" a $175 '
             '(Bebidas, código más nuevo); el usuario lo subió a $175')
PRECIOS = {fid: (175.0, _JARRITOS) for fid in ('114', '134', '135', '136', '137', '138', '199')}

# Grupo opcional, de varias opciones, para los productos de cocina.
GRUPO_EXTRAS = 'Extras'
EXTRAS = {
    '191': 'Extra crema',
    '128': 'Extra salsa ranchera',
    '127': 'Extra tortillas',
    '126': 'Extra frijoles',
    '125': 'Extra guacamole',
    '123': 'Pico de gallo',
    '159': 'Otro extra',
    '228': 'Extra queso',
    '124': 'Extra de pollo',
}
# Opciones que no vienen en el CSV: las subió el usuario como producto.
EXTRAS_SIN_FILA = [('Extra de carne', 150.0), ('Extra nachos', 100.0)]

OMITIDAS = {
    '187': 'repetida de la 31 (Gringa, $800)',
    '35':  'repetida de la 181 (Tostadas de Cerdo); esta a $600, se deja la de $650',
    '88':  'repetida de la 227 (Gran Malo, $450)',
    '220': 'Jarritos Guava = Jarritos Guayaba; su precio ($175) es el de todos los sabores',
    '158': 'cargo de delivery: se cobra con el delivery de la caja',
    '157': 'cargo de delivery: se cobra con el delivery de la caja',
    '156': 'cargo de delivery: se cobra con el delivery de la caja',
    '155': 'cargo de delivery: se cobra con el delivery de la caja',
    '154': 'cargo de delivery: se cobra con el delivery de la caja',
    '153': 'cargo de delivery: se cobra con el delivery de la caja',
    '152': 'cargo de delivery: se cobra con el delivery de la caja',
    '151': 'cargo de delivery: se cobra con el delivery de la caja',
}

# Montos rápidos del cargo de delivery (Ajustes → Modos de negocio). Se ponen
# solo si el negocio no tiene ninguno.
DELIVERY_PRESETS = [100, 150, 200, 250, 300, 350, 400, 450]


# ▶ Lo que ya está en la caja (00_diagnostico.sql del 07-oct-2026: 39
# productos, 38 activos, todos SIN impuesto y con el legacy en 'kitchen_hot',
# un área que no existe). Nombre EXACTO en la caja → decisión.
def ya(producto, antes):
    """Es ese producto de la lista: no se duplica. Conserva nombre y categoría;
    toma el precio del CSV, ITBIS + Ley, su área, el menú y sus modificadores."""
    return {'accion': 'ya_subido', 'producto': producto, 'precio_antes': antes}


def fuera(area, extras=False, impuestos='itbis_ley'):
    """No está en el CSV: conserva nombre, precio y categoría; toma su área y
    los impuestos ('no_tocar' los deja como están)."""
    return {'accion': 'fuera_csv', 'area': area, 'extras': extras, 'impuestos': impuestos}


DESACTIVAR = {'accion': 'desactivar'}
MANTENER = {'accion': 'mantener'}

EXISTENTES = {
    'BURRITO':                    ya('Burrito', 650),
    'CHILAQUILES':                ya('Chilaquiles', 700),
    'CHIMICHANGA':                ya('Chimichanga', 700),
    'CHORIQUESO':                 ya('Choriqueso', 600),
    'FLAUTAS DE POLLO':           ya('Flautas de Pollo', 600),
    'MINI FLAUTAS':               ya('Mini Flautas', 500),
    'NACHOS CON GUACAMOLE':       ya('Nachos con Guacamole', 250),
    'QUESADILLA DE CHORIZO':      ya('Quesadilla de Chorizo', 650),
    'QUESADILLA DE POLLO':        ya('Quesadilla de Pollo', 600),
    'TACOS':                      ya('Tacos', 650),
    'TACOS AL PASTOR':            ya('Tacos al Pastor', 700),
    'TACOS CHILORIO':             ya('Tacos de Chilorio', 700),
    'TACOS DE BIRRIA':            ya('Tacos de Birria', 750),
    'TACOS DE CARNITA MICHOACAN': ya('Tacos de Carnitas Michoacanas', 650),
    'UNIDAD DE TACO':             ya('Unidad de Taco', 250),
    'TOSTADAS':                   ya('Tostadas', 650),
    'ENCHILADA':                  ya('Enchilada', 800),
    'AGUA':                       ya('Agua Dasani', 50),
    'JARRITOS':                   ya('Jarritos', 175),
    'JUGOS NATURALES':            ya('Jugos Naturales', 0),
    'REFRESCOS':                  ya('Refrescos Sabores', 0),
    'SODA CAN':                   ya('Soda Can', 0),
    'ENCHILADA SUIZA':            MANTENER,      # inactiva; ahora es opción de ENCHILADA
    'DELIVERY 100':               DESACTIVAR,
    'DELIVERY 150':               DESACTIVAR,
    'DELIVERY 200':               DESACTIVAR,
    'DELIVERY 250':               DESACTIVAR,
    'DELIVERY 300':               DESACTIVAR,
    'DELIVERY 350':               DESACTIVAR,
    'DELIVERY 400':               DESACTIVAR,
    'DELIVERY 450':               DESACTIVAR,
    'EXTRA GUACAMOLE':            DESACTIVAR,    # ahora son opciones de Extras
    'Extra Queso':                DESACTIVAR,
    'EXTRA DE CARNE':             DESACTIVAR,
    'Extra Nachos':               DESACTIVAR,
    'TACO DOBLE DECKERS':         fuera('cocina', extras=True),
    'TACOS FIESTAS':              fuera('cocina', extras=True),
    'GANSITO MARINELA GRANDE':    fuera('bar'),  # Postres, como los del CSV
    'Carne Cocida Natural xlb':   fuera('cocina', impuestos='no_tocar'),  # exclusive
}

# Productos de la lista con otro juego de impuestos (por defecto ITBIS + Ley).
IMPUESTOS = {'Agua Dasani': 'ley'}

# Grupos de modificadores que ya existían con el mismo nombre que uno de la
# carga: el rollback no los borra. (El diagnóstico dio 0 grupos.)
GRUPOS_PREEXISTENTES = []


def filas_csv():
    rows = list(csv.reader(open(os.path.join(HERE, '_fuente.csv'), encoding='utf-8')))
    hdr = rows[5]
    assert hdr[0].startswith('Indentificador') and hdr[10] == 'Precio', hdr
    out = []
    for r in rows[6:]:
        if not r or not r[0].strip():
            continue
        fid = r[0].strip()
        precio, nota = PRECIOS.get(fid, (float(r[10]), ''))
        out.append({
            'id': fid,
            'producto_csv': r[3].strip(),
            'area_csv': r[5].strip(),
            'categoria': r[7].strip(),
            'precio_csv': float(r[10]),
            'precio': precio,
            'nota_precio': nota,
        })
    return out


def _partes(producto_csv):
    """'Cantarito 1800 - Silver' → ('Cantarito 1800', 'Silver')."""
    base, _, pres = producto_csv.partition(' - ')
    if not _:
        base, pres = producto_csv.rstrip(' -'), ''
    return base.strip().rstrip('.').strip(), pres.strip()


def _area(fila):
    a = fila['area_csv'].lower()
    if a:
        assert a in ('cocina', 'bar'), fila
        return a
    return {c[0]: c[2] for c in CATEGORIAS}[CAT_CSV[fila['categoria']]]


def claves(fila, *extra):
    """Nombres con los que este renglón podría estar ya en la caja."""
    base, pres = _partes(fila['producto_csv'])
    ks = {fila['producto_csv'].rstrip(' -'), base}
    if pres:
        ks.add(f'{base} {pres}')
    ks.update(e for e in extra if e)
    return sorted(ks)


def _upper(s):
    return s.upper()


def armar():
    filas = filas_csv()
    assert len(filas) == 190, len(filas)
    por_id = {f['id']: f for f in filas}
    assert len(por_id) == len(filas), 'ids repetidos en el CSV'
    assert set(CAT_CSV) == {f['categoria'] for f in filas}, 'categoría del CSV sin mapear'
    cats = {c[0] for c in CATEGORIAS}
    assert set(CAT_CSV.values()) <= cats

    destinos = [PRODUCTOS, VARIANTES, EXTRAS, OMITIDAS]
    for f in filas:
        n = sum(f['id'] in d for d in destinos)
        assert n == 1, f'la fila {f["id"]} ({f["producto_csv"]}) está en {n} destinos'
    for d in destinos + [PRECIOS]:
        for k in d:
            assert k in por_id, f'la fila {k} no existe en el CSV'

    productos = []

    # Productos simples.
    for fid, (name, desc, nota) in PRODUCTOS.items():
        f = por_id[fid]
        productos.append({
            'code': fid, 'titulo': name, 'name': _upper(name),
            'categoria': CAT_CSV[f['categoria']], 'area': _area(f),
            'price': f['precio'], 'description': desc, 'grupo': None, 'opciones': [],
            'claves': claves(f, name), 'nota': nota or f['nota_precio'], 'filas': [fid],
        })

    # Productos con variantes.
    for gk, (name, cat, etiqueta) in GRUPOS_VARIANTE.items():
        assert cat in cats, (gk, cat)
        ops = [(fid, v) for fid, v in VARIANTES.items() if v[0] == gk]
        assert len(ops) >= 2, gk
        fs = [por_id[fid] for fid, _ in ops]
        assert len({f['categoria'] for f in fs}) == 1, (gk, {f['categoria'] for f in fs})
        areas = {_area(f) for f in fs}
        assert len(areas) == 1, (gk, areas)
        base = min(f['precio'] for f in fs)
        orden = sorted(ops, key=lambda o: (por_id[o[0]]['precio'], list(VARIANTES).index(o[0])))
        opciones = [{'code': fid, 'name': v[1], 'delta': por_id[fid]['precio'] - base,
                     'precio_csv': por_id[fid]['precio_csv'], 'orden': (i + 1) * 10,
                     'claves': claves(por_id[fid]),
                     'nota': '; '.join(x for x in (v[2], por_id[fid]['nota_precio']) if x)}
                    for i, (fid, v) in enumerate(orden)]
        # El producto casa por su nombre o por la base del CSV que comparten
        # TODAS sus filas ("Soda Can."). Lo demás es de la opción: el nombre
        # completo ("Cantarito 1800 - Silver") y una base propia de una sola
        # fila ("Enchilada suiza", "Tostadas de Cerdo").
        bases = {_llave(_partes(f['producto_csv'])[0]) for f in fs}
        k = {name} | (bases if len(bases) == 1 else set())
        for o in opciones:
            o['claves'] = [c for c in o['claves'] if _llave(c) not in {_llave(x) for x in k}]
        productos.append({
            'code': 'G-' + gk, 'titulo': name, 'name': _upper(name), 'categoria': cat,
            'area': areas.pop(), 'price': base, 'description': None,
            'grupo': f'{name} · {etiqueta}', 'opciones': opciones,
            'claves': sorted(k), 'nota': '', 'filas': [o[0] for o in orden],
        })

    por_titulo = {_llave(p['titulo']): p for p in productos}
    assert len(por_titulo) == len(productos), 'nombres repetidos en la lista'
    for p in productos:
        p['impuestos'] = IMPUESTOS.get(p['titulo'], 'itbis_ley')
        p['existente'] = None
    for t in IMPUESTOS:
        assert _llave(t) in por_titulo, t

    # Lo que ya está en la caja.
    existentes = []
    for nombre, d in EXISTENTES.items():
        e = dict(d, existente=nombre)
        assert e['accion'] in ('ya_subido', 'fuera_csv', 'desactivar', 'mantener'), nombre
        if e['accion'] == 'ya_subido':
            p = por_titulo[_llave(e['producto'])]
            assert p['existente'] is None, f'{p["titulo"]} tiene dos ya subidos'
            p['existente'] = nombre
            p['claves'].append(nombre)
            e['producto'] = p['name']
        if e['accion'] == 'fuera_csv':
            assert e['area'] in ('cocina', 'bar') and e['impuestos'] in ('itbis_ley', 'ley', 'no_tocar')
        existentes.append(e)

    # Posición dentro de la categoría: orden alfabético.
    for cat in cats:
        ps = sorted((p for p in productos if p['categoria'] == cat), key=lambda p: _llave(p['name']))
        for i, p in enumerate(ps, 1):
            p['posicion'] = i

    # Una llave que cae en dos productos se queda solo con el que se llama así
    # ("jarritos" es de Jarritos, no de otro).
    dueno = {}
    for p in productos:
        for c in p['claves']:
            dueno.setdefault(_llave(c), set()).add(p['name'])
    for p in productos:
        p['claves'] = sorted({_llave(c) for c in p['claves']
                              if len(dueno[_llave(c)]) == 1 or _llave(c) == _llave(p['name'])})
        assert _llave(p['name']) in p['claves'], p['name']
        if p['existente']:
            assert _llave(p['existente']) in p['claves'], p['existente']

    grupos = [p['grupo'] for p in productos if p['grupo']] + [GRUPO_EXTRAS]
    assert len(grupos) == len({_llave(g) for g in grupos})

    extras = [{'code': fid, 'name': n, 'delta': por_id[fid]['precio'], 'orden': 0,
               'claves': claves(por_id[fid], n)}
              for fid, n in EXTRAS.items()]
    extras += [{'code': '—', 'name': n, 'delta': precio, 'orden': 0, 'claves': [n]}
               for n, precio in EXTRAS_SIN_FILA]
    extras.sort(key=lambda e: (e['delta'], _llave(e['name'])))
    for i, e in enumerate(extras, 1):
        e['orden'] = i * 10

    omitidas = [{'code': fid, 'producto_csv': por_id[fid]['producto_csv'],
                 'precio': por_id[fid]['precio'], 'motivo': m,
                 'claves': claves(por_id[fid])}
                for fid, m in OMITIDAS.items()]
    return productos, extras, omitidas, existentes


def _llave(s):
    import unicodedata
    s = unicodedata.normalize('NFD', s.lower())
    s = ''.join(c for c in s if unicodedata.category(c) != 'Mn')
    return ' '.join(''.join(c if c.isalnum() else ' ' for c in s).split())
