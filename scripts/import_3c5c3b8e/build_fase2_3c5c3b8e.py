#!/usr/bin/env python3
"""Genera la FASE 2 de la carga del catálogo de 007 BAR & SNACK (3c5c3b8e).

La fase 1 (build_import_3c5c3b8e.py) cargó los 828 artículos de "PRODUCTOS 007.pdf".
Ese PDF resultó ser solo el tramo de códigos 7622201776664–9002490291709. Esta fase
carga lo que faltaba, desde el maestro crudo del sistema anterior (tabla ARTICULOS,
108 columnas ar_*).

Uso:
    python3 scripts/import_3c5c3b8e/build_fase2_3c5c3b8e.py [ruta/a/ARTICULO.csv]
    python3 scripts/import_3c5c3b8e/build_fase2_3c5c3b8e.py --clasificar   # solo imprime categorías

Escribe, desde las plantillas _tpl_*_fase2.sql:

    00_diagnostico_fase2.sql       solo lee; correr antes
    IMPORT_FASE2.sql               la carga, una sola transacción
    99_rollback_fase2.sql          la deshace
    catalogo_fase2_revision.csv    una fila por producto, para revisar

Editar ESTE archivo (reglas, correcciones, exclusiones) y regenerar; los .sql
generados no se tocan a mano.

OJO con el archivo de entrada: tiene que ser el CSV tal como salió del sistema
(ARTICULO.csv, 15/09/2026). La copia que pasó por Excel (ARTICULOS.csv) le borró el
0 inicial a 675 códigos: "004" y "04" quedan iguales a "4". El script lo detecta y aborta.
"""

import collections
import csv
import importlib.util
import re
import sys
import unicodedata
from datetime import date, datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Reusa del generador de la fase 1: categorías, reglas y la lógica de GTIN.
_spec = importlib.util.spec_from_file_location('fase1', HERE / 'build_import_3c5c3b8e.py')
fase1 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fase1)

ARGS = [a for a in sys.argv[1:] if not a.startswith('--')]
SOLO_CLASIFICAR = '--clasificar' in sys.argv
CSV_MAESTRO = Path(ARGS[0]).expanduser() if ARGS else Path.home() / 'Desktop' / 'ARTICULO.csv'
FASE1_CSV = HERE / 'catalogo_revision.csv'

TOTAL_MAESTRO = 3831          # filas del maestro (15/09/2026)
TOTAL_FASE1 = 828
TOTAL_ESPERADO = 1043         # activos que faltaban (decisión del dueño, 16/09/2026)

# "Activo" = vendió en los últimos 12 meses o tiene existencia. Las columnas
# ar_ene..ar_dic y ar_canven son acumuladas DE POR VIDA, no sirven para esto.
FECHA_CORTE = date(2026, 9, 16)
DIAS_ACTIVO = 365

# Categorías de la fase 1 con sus mismas posiciones (10, 20, ... 200) + 3 nuevas
# intercaladas. categories.position ordena las pestañas de la caja.
POSICION_CATEGORIA = {c: (i + 1) * 10 for i, c in enumerate(fase1.CATEGORIAS)}
POSICION_CATEGORIA.update({
    'Café y batidos': 75,          # después de Aguas
    'Helados': 155,                # después de Comida y helados
    'Souvenirs y regalos': 195,    # antes de Misceláneos
})
CATEGORIAS_NUEVAS = ['Café y batidos', 'Helados', 'Souvenirs y regalos']
CATEGORIAS = sorted(POSICION_CATEGORIA, key=POSICION_CATEGORIA.get)
BEBIDAS = set(fase1.BEBIDAS) | {'Café y batidos'}

# No son mercancía (uso interno, alquiler, recargas): quedan FUERA de la carga.
NO_MERCANCIA = re.compile(
    r'USO INT|RENTA DE LOCAL|MATERIALES DE OF|^RECARGAS|BOTELLAS VAC|REFRIGERIO|'
    r'FUNDA DE BASURA|GUANTES|^ENVASE|TAPAS PLASTICAS|VASO CLEAR|AZUCAR DIETA|'
    r'CARDO DE POLLO|SIMPLOT|CRISOL|MAYONESA BALDOM|PAPEL PVC|REMOVEDORES|'
    r'CATCHUP SOBRE|TAPA DOMO|TAPA VASO')

# Reglas de la fase 2. Se evalúan ANTES que las de la fase 1: el maestro trae
# familias que el PDF no tenía (helados, comida, café, cervezas 746) y varias
# reglas viejas se equivocan con ellas ("GUARAGUANO" contiene AGUA, "FORTUNA"
# contiene TUNA, los helados BON caen en galletas por "BIZCOCHO").
# Gana la PRIMERA que calza.
REGLAS_FASE2 = [
    ('Refrescos y energizantes', r'^DR PEPPER|CLUB SODA|AGUA TONICA'),
    ('Galletas y bizcochos', r'^CRACKETS'),
    ('Misceláneos', r'CHOPIN'),
    ('Dulces típicos', r'^D\.?R[\. ]|RASPADURA|CASTILLO PAQUETE|SANDWICH ORANGE|'
                       r'DULCE (DE GUAYABA|GOURMET)|MERMELADAS|DULCEDE COCO'),
    ('Souvenirs y regalos', r'GORRO|GORRAS|GUIRA|MARACAS|TAMBORA|MU[ÑN;]ECA|POSUELO|'
                            r'MAGNETO|DOMINOS DOMINICANOS|DURAG|VASO TERMICO|TAZAS? CON|'
                            r'ARREGLO|SAN VALE|EN CUERO|TERMO DECORADO'),
    ('Helados', r'\bBON\b|HELADO|MAGNU[MN]|MORDISC?K?O|TARRO|DON ALFONSO|PALETA (CHERRY|MORA)'),
    ('Café y batidos', r'AROMA CAFE|AROMA CAPUC|^CAFE-|CAPUCHINO|CAPUCCINO|FRA?PP?UCCINO|'
                       r'VASO GRANDE AROMA|NESCAFE\.(7|12|FRIO)|VASO PARA NESCAFE|'
                       r'FRESA CON|FRESA MELON|LECHOZA CON LECHE'),
    ('Comida y helados', r'SANDWICH|\bWRAP\b|EMPANADAS SURTIDAS|QUIPE|^PIZZA|DULCE FRIO|'
                         r'CROQUETA|CROISANT|BOLA (QUESO|DE YUCA)|PICADERA|BURRITO|'
                         r'SERVICIO DE|SOPAS? PREPARADAS|QUESO DE HOJA|QUESILLO|FLAN|'
                         r'GELATINA|TRES LECHES?|MAJARETE|^CHEESECAKE$|DONAS?\b|MUFFIN|'
                         r'MUFI|CINNAMON ROLL|BISCOCHOS DEL ENCANTO|PASTRY CHOCO|'
                         r'GUAYABA CHEESECAKE|QUESO SUPERIOR|GEO GEO'),
    ('Aguas', r'HIELO|\bAGUA\b(?! DE COCO)(?! DESTILADA)|PERRIER|DASANI|EVIAN|CLUB SODA|'
              r'SPARKLING|SPARKLIN|ICE SPARK|ICE CAFFEINE|PLANETA'),
    ('Premix y cócteles', r'WHITE CLAW|SMIRNOFF|KARMA|MOJITO JAVAPAY|BUZZ BALK|FOUR LOKO|'
                          r'BAMB?BOO|MIKES'),
    ('Cervezas', r'PRESIDENTE|BOHEMIA|ONE CERVEZA|ONE LATA|CORONA|CORONITA|MODELO|MICHELOB|'
                 r'MILLER|COORS|STELLA|DESPERADOS|DOS EQUIS|DUVEL|ERDINGER|PAULANER|BRUDER|'
                 r'LEFFE|MAREDSOUS|BLUE MOON|SOL CERVEZA|PADERBORNER|5\.0 ORI|9\.0|'
                 r'CER\.PONTE|HEINEKEN|CARLSBERG'),
    ('Licores', r'BRUGAL|BARCELO|BERCELO|MACORIX|SIBONEY|RIPIAO|LEGADO EL CABALLO|JOHNNIE|'
                r'JHONNIE|CHIVAS|BUCHANAN|BALLANTINE|GRAND OLD PAR|HENNE?SS?Y|BAILEYS|'
                r'KAHLUA|BACARDI|ABSOLUT|STOLI|\bTITO|CAYMAN|RED RUSSIA|GINEBRA|BERMUDEZ|'
                r'MACK ALBERT|KING,?S|KINGS LABEL|FIREBALL|SCARLETT|GITANO|PONCHE BORDAS|'
                r'MAMAJUANA|\bLICOR|WHISKY|TEQUILA|VODKA|\bRON\b|1000PIPERS|DEWARS|'
                r'SOMETHING SPECIAL|DON JULIO|BOMBAY'),
    ('Vinos y espumantes', r'19 CRIME|CULITOS|CARLOS? ROSSI|JP\.CHENET|MARQUEZ DE|TORREORIA|'
                           r'\bCAVA\b|\bVINO\b|SIDRA|FORTUNA BLUE|SFUMATURE'),
    ('Farmacia, higiene y hogar', r'DUREX|INTIMATE|ACETAMINOFEN|ALGHOS?\b|ALKA|AMPICILINA|'
                                  r'DICLOF|OMEPRAZOL|RESFRIDOL|REFRIDOL|SAL ANDREWS|'
                                  r'SILDENAFIL|VAPORUB|WINASOR|DEL AMOR|MIEL DE AMOR|'
                                  r'BABY WIPES|SUPER 100|TOALLA|PLATOS|^VASOS?\b|CUCHARAS|'
                                  r'NEVERA FOAM|SERVILLETA'),
    ('Refrescos y energizantes', r'GATORADE|GATORDE|GATORLIT|GATORLYTE|SUEROX|AQUALIT|MONSTER|'
                                 r'RED BULL|911 ENERG|COCA ?COLA|SPRITE|FANTA|PEPSI|'
                                 r'SEVEN.?UP|RED ROCK|COUNTRY CLUB|CANADA.?DRY|CANADRA|'
                                 r'MALTA|HATUEY -SODA|ENRRIQUILLO|COCO RICO|MABI|SUNKIST|'
                                 r'AGUA TONICA'),
    ('Despensa', r'AJO EN PASTA|CAFE BUSTELO|SAZON|HATUEY HIERBAS|CAT ?CHUP|SALCHICHA|JAJA|'
                 r'KELLOGGS|COMPOTA|SOPA|NISSIN|CUP NEODLES|ISSIMA|^LIMON|MANZANA (VERDE|ROJA)|'
                 r'NESCAFE|BUMBLE BEE|VINAGRE|QUESO MOZZARELLA'),
    ('Jugos, tés y lácteos', r'SNAPPLE|MOTTS|OCEAN SPRAY|CRAMBERRY|DEL VALLE|MINUTE MAID|'
                             r'APPLE&EVE|CAPRISUN|CLAMATO|\bV8\b|PETIT|FRUTA FRESCA|DR\+OWOC|'
                             r'YOGU?R|YOPLAIT|YOPLAY|YOKA|SUPLIGEN|GLUCERNA|LISTAMILK|'
                             r'CHOCO ?RICA|\bRICA\b|WATERMELON LEMONADE|AGUA DE COCO|'
                             r'JUGOS? |WELCHS GRAPE'),
    ('Cigarrillos y tabaco', r'MARLBORO|NEWPORT|PALL ?MALL|NACIONAL (GDE|PEQ)|PRINCIPE|TEREA|'
                             r'\bZYN\b|\bZIN\b|CIMARRON|TAINO|SIGARRO|CIGARR|DUNHILL|'
                             r'ENCENDEDORA|MACANUDO|AURORA'),
    ('Automotriz', r'AROMATE|PINITO|PIEDRA AROMA|LANILLA|LIMPIA CRISTAL|TAPA DE RADIADOR|'
                   r'LUBE FILTER|AGUA DESTILADA|AMBIENTADOR|GETSU|CORREA ROULUNDS|MOTOR OIL'),
    ('Barras de proteína', r'SLIM (CRUCHY|BROWNIE)|NATURE VALLEY|QUEST'),
    ('Chocolates', r'M ?& ?M|M Y M|KINDER|KIT ?KAT|MILKYWAY|SNICKERS|CORNY|ZERO CHOCOLATE|'
                   r'^(MINI )?NUTELLA|HERSHE|KISSES|MINI CHOCO MANI|TWIX'),
    ('Galletas y bizcochos', r'GUARINA|GAMESA|EMPERADOR|CHOKIS|DELICIAS|FLORENTINA|\bDINO\b|'
                             r'CRACKETS|MANTECAD|ALFAJO|FAMOUS AMOS|MOON PIE|KNOTTS|'
                             r'MARTIN (COCO|SUSPIRO)|TAW TAW|QUAKER|CUADRITOS DE LIMON|'
                             r'EMPANADAS DE GUAYABA|TRUQUITO|GALLET|COOKIE|BROWNIE|OREO|'
                             r'BIZCOCHO|MISSCOOKIE|COQUITOS|CLUB SOCIAL|RITZ'),
    ('Chicles y caramelos', r'TRIDENT|HALLS?\b|MENTOS|CLORETS|DOUBLEMINT|EXTRA (SPEAR|PEPPER)MINT|'
                            r'HUBBA|ICE BREAKERS|TIC TAC|BOLONES|BLOW POP|MENTAS?\b|ROCK PAPER|'
                            r'CARAMEL POPCORN|SKITTLES|WELCH|PALETA|GOMITAS'),
    ('Snacks salados', r'PRINGLES|TAKIS|LAYS|RUFFLES|RUFFES|DORITO|CHEETOS|FUNYUNS|TOSTITOS|'
                       r'CARIBAS|CARLES|MILAMAR|NATU ?CHIPS|HOJUELITAS|CHICHARRON|MOFONGO|'
                       r'ZAMBOS|TAQUERITOS|BRUSCHETTE|MARETTI|SEÑOR NACHO|CASABE|SABITOS|'
                       r'GUARAGUANO|PLANTERS|CARIBBEAD|DYNASTY|PUNTA RU[CS]IA|ALMENDRA|'
                       r'PISTACH|MARAÑON|CAJUIL|NUECES|NUT SACK|TRAIL MIX|SUPER MIX|YUMMI|'
                       r'COCALECAS|CHIPS DELUXES|JACK LINKS|^JL |HOT PEPPERONI|GRAMBERRIES|'
                       r'CRANBERRIES|FRUTAS TROPICALES|GRANOLA|SEMILLA|ROQUETE|\bMANI\b|'
                       r'TOSTONES|MADURITOS|PLATANITOS'),
    ('Misceláneos', r'LLAVERO|THERMO|DESTAPADOR|TARJETA|CORTADOR'),
]

# Correcciones por código, cuando la regla no alcanza.
CORRECCIONES = {}

# Posibles duplicados que se cargan igual, cada uno con su código (la pistola
# lee los dos). El dueño decide después cuál apagar.
NOTAS = {
    '   7622201776664': 'código con espacios; sin espacios es el de TRIDENT MENTA (fase 1): va sin código de barras',
    ' 4014086090370': 'código con espacio; sin él es el de 9.0 ORIGINAL: va sin código de barras',
}


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return 0.0


def fecha(s):
    s = (s or '').strip()
    for fmt in ('%d/%m/%Y', '%d-%b-%y'):
        try:
            return datetime.strptime(s, fmt).date()
        except ValueError:
            pass
    return None


def nombre(s):
    # El sistema anterior guardó la Ñ en otra codificación: sale como "—".
    s = s.replace('—', 'Ñ')
    return unicodedata.normalize('NFC', re.sub(r'\s+', ' ', s).strip())


def leer_fase1():
    with open(FASE1_CSV, encoding='utf-8') as fh:
        filas = list(csv.DictReader(fh))
    if len(filas) != TOTAL_FASE1:
        sys.exit(f'catalogo_revision.csv tiene {len(filas)} filas y la fase 1 fueron {TOTAL_FASE1}.')
    return filas


def leer_maestro():
    with open(CSV_MAESTRO, encoding='utf-8-sig', newline='') as fh:
        filas = list(csv.DictReader(fh))
    if len(filas) != TOTAL_MAESTRO:
        sys.exit(f'{CSV_MAESTRO.name}: {len(filas)} artículos; el maestro tiene {TOTAL_MAESTRO}.')
    codigos = [f['ar_codigo'] for f in filas]
    if any(re.fullmatch(r'\d\.\d+E\+\d+', c) for c in codigos):
        sys.exit('Hay códigos en notación científica: este CSV pasó por Excel. Usa ARTICULO.csv.')
    if sum(c.startswith('0') for c in codigos) < 600 or '004' not in codigos:
        sys.exit('Faltan los ceros iniciales de los códigos ("004" no está): este CSV pasó por '
                 'Excel. Usa ARTICULO.csv, el que salió directo del sistema.')
    return filas


def clasificar(nombre_mayus, codigo):
    if codigo in CORRECCIONES:
        return CORRECCIONES[codigo]
    for cat, patron in REGLAS_FASE2:
        if re.search(patron, nombre_mayus):
            return cat
    for cat, patron in fase1.REGLAS:
        if re.search(patron, nombre_mayus):
            return cat
    return None


def seleccionar(maestro, fase1_filas):
    codigos_f1 = {f['codigo'] for f in fase1_filas}
    seleccion, fuera = [], collections.Counter()
    for f in maestro:
        code = f['ar_codigo']
        if code in codigos_f1:
            fuera['ya en la fase 1'] += 1
            continue
        ult = fecha(f['ar_facven']) or fecha(f['ar_fecven'])
        vendio = ult is not None and (FECHA_CORTE - ult).days <= DIAS_ACTIVO
        existencia = num(f['ar_exitem'])
        if not (vendio or existencia > 0):
            fuera['dormido (sin venta en 12 meses y sin existencia)'] += 1
            continue
        name = nombre(f['ar_descri'])
        if NO_MERCANCIA.search(name.upper()):
            fuera['no es mercancía'] += 1
            continue
        seleccion.append(dict(
            code=code, name=name, cost=num(f['ar_ultcos']), price=num(f['ar_predet']),
            qty=existencia, ult_venta=ult, tasa=f['ar_tasaitb'], depto=f['de_codigo']))
    return seleccion, fuera


def preparar(filas, fase1_filas):
    sin_cat = []
    for f in filas:
        f['cat'] = clasificar(f['name'].upper(), f['code'])
        if f['cat'] is None:
            sin_cat.append(f"{f['code']} | {f['name']} | depto {f['depto']}")
    if sin_cat:
        sys.exit(f'{len(sin_cat)} sin categoría (agrega una regla o corrección):\n' + '\n'.join(sin_cat))

    barcodes_f1 = {f['codigo_barras'] for f in fase1_filas if f['codigo_barras']}
    nombres_f1 = {re.sub(r'[^A-Z0-9Ñ]', '', f['nombre'].upper()): f['codigo'] for f in fase1_filas}
    for f in filas:
        f['is_bev'] = f['cat'] in BEBIDAS
        f['qty0'] = max(f['qty'], 0.0)
        f['barcode'] = fase1.barcode_de(f['code'])
        notas = []
        if f['code'] in NOTAS:
            notas.append(NOTAS[f['code']])
        clave = re.sub(r'[^A-Z0-9Ñ]', '', f['name'].upper())
        if clave in nombres_f1:
            notas.append(f"mismo nombre que el código {nombres_f1[clave]} de la fase 1")
        if f['cost'] == 1.0 and f['price'] >= 10:
            # El sistema anterior usaba 1.00 como relleno (COORS GOLDEN a $185,
            # BALLANTINES a $1,300). Igual que el 0: entra sin costo.
            f['cost'] = 0.0
            notas.append('costo 1.00 de relleno en el sistema anterior: entra sin costo')
        if f['cost'] > 0 and f['cost'] >= f['price']:
            notas.append('costo mayor o igual al precio')
        if f['tasa'] != '18':
            notas.append(f"el sistema anterior le cobraba ITBIS {f['tasa']}%; entra al 18% incluido")
        f['nota'] = '; '.join(notas)

    if len(filas) != TOTAL_ESPERADO:
        sys.exit(f'Seleccioné {len(filas)} artículos y la carga acordada son {TOTAL_ESPERADO}.')
    dup_code = [c for c, n in collections.Counter(f['code'] for f in filas).items() if n > 1]
    if dup_code:
        sys.exit(f'Códigos repetidos en la selección: {dup_code}')
    bcs = collections.Counter(f['barcode'] for f in filas if f['barcode'])
    dup_bc = [b for b, n in bcs.items() if n > 1] + [b for b in bcs if b in barcodes_f1]
    if dup_bc:
        sys.exit(f'Códigos de barras repetidos (entre sí o con la fase 1): {dup_bc}')
    if any(f['price'] <= 0 for f in filas):
        sys.exit('Hay artículos activos con precio 0.')

    # Posición dentro de la categoría: alfabética, mezclando las DOS fases. La
    # caja ordena por position y después por nombre; sin renumerar, los nuevos
    # quedarían intercalados por empate.
    pos1 = []
    for cat in CATEGORIAS:
        grupo = [('f2', f['name'], f) for f in filas if f['cat'] == cat]
        grupo += [('f1', g['nombre'], g) for g in fase1_filas if g['categoria'] == cat]
        grupo.sort(key=lambda x: (x[1].upper(), x[0]))
        for i, (fase, _, obj) in enumerate(grupo, 1):
            if fase == 'f2':
                obj['pos'] = i
            else:
                pos1.append((obj['codigo'], cat, i))
    return filas, pos1


def q(s):
    return "'" + s.replace("'", "''") + "'"


def n(x, dec):
    return f'{x:.{dec}f}'


def main():
    fase1_filas = leer_fase1()
    filas, fuera = seleccionar(leer_maestro(), fase1_filas)

    if SOLO_CLASIFICAR:
        por_cat = collections.defaultdict(list)
        for f in filas:
            por_cat[clasificar(f['name'].upper(), f['code'])].append(f['name'])
        for cat in [None] + CATEGORIAS:
            if por_cat.get(cat):
                print(f'## {cat} ({len(por_cat[cat])}): ' + ' | '.join(sorted(por_cat[cat])))
        print(dict(fuera), 'seleccionados', len(filas))
        return

    filas, pos1 = preparar(filas, fase1_filas)
    orden = {c: i for i, c in enumerate(CATEGORIAS)}
    filas.sort(key=lambda f: (orden[f['cat']], f['pos']))

    lotes = []
    for i in range(0, len(filas), 200):
        valores = ',\n'.join(
            '  ({}, {}, {}, {}, {}, {}, {}, {}, {}, {})'.format(
                q(f['code']), q(f['name']), q(f['cat']), n(f['price'], 2),
                n(f['cost'], 4) if f['cost'] > 0 else 'null',
                n(f['qty0'], 2), n(f['qty'], 2),
                q(f['barcode']) if f['barcode'] else 'null',
                'true' if f['is_bev'] else 'false',
                f['pos'])
            for f in filas[i:i + 200])
        lotes.append(
            f'-- filas {i + 1}–{min(i + 200, len(filas))}\n'
            'insert into _p007f2 (codigo, name, categoria, price, cost, qty, '
            'qty_listado, barcode, is_bev, posicion) values\n' + valores + ';')

    pos_lotes = []
    for i in range(0, len(pos1), 300):
        pos_lotes.append(
            'insert into _p007f2_pos1 (codigo, categoria, posicion) values\n'
            + ',\n'.join(f'  ({q(c)}, {q(cat)}, {p})' for c, cat, p in pos1[i:i + 300]) + ';')

    con_stock = [f for f in filas if f['qty0'] > 0]
    valor = round(sum(f['qty0'] * f['cost'] for f in con_stock), 2)
    unidades = sum(f['qty0'] for f in con_stock)
    usadas = [c for c in CATEGORIAS if any(f['cat'] == c for f in filas)]

    subs = {
        '__DATA__': '\n\n'.join(lotes),
        '__POS1__': '\n\n'.join(pos_lotes),
        '__CATEGORIAS__': ',\n'.join(
            f'  ({q(c)}, {POSICION_CATEGORIA[c]})' for c in CATEGORIAS),
        '__CAT_NUEVAS_LOWER__': ', '.join(q(c.lower()) for c in CATEGORIAS_NUEVAS),
        '__CAT_NUEVAS__': ', '.join(CATEGORIAS_NUEVAS),
        '__CODES__': ','.join(f['code'] for f in filas),
        '__CODES_F1_CAT__': ';'.join(f"{f['codigo']}~{f['categoria']}" for f in fase1_filas),
        '__BARCODES__': ','.join(f['barcode'] for f in filas if f['barcode']),
        '__N_TOTAL__': str(len(filas)),
        '__N_FASE1__': str(TOTAL_FASE1),
        '__N_STOCK__': str(len(con_stock)),
        '__UNIDADES__': f'{unidades:g}',
        '__VALOR__': f'{valor:,.2f}',
        '__N_BARCODE__': str(sum(1 for f in filas if f['barcode'])),
        '__N_CATEGORIAS__': str(len(usadas)),
    }

    for tpl, out in (('_tpl_diagnostico_fase2.sql', '00_diagnostico_fase2.sql'),
                     ('_tpl_import_fase2.sql', 'IMPORT_FASE2.sql'),
                     ('_tpl_rollback_fase2.sql', '99_rollback_fase2.sql')):
        sql = (HERE / tpl).read_text(encoding='utf-8')
        for k, v in subs.items():
            sql = sql.replace(k, v)
        sobrantes = re.findall(r'__[A-Z0-9_]+__', sql.replace('__IN_TRANSIT__', ''))
        if sobrantes:
            sys.exit(f'{tpl}: placeholders sin reemplazar: {sorted(set(sobrantes))}')
        (HERE / out).write_text(sql, encoding='utf-8')

    with open(HERE / 'catalogo_fase2_revision.csv', 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(['categoria', 'codigo', 'nombre', 'precio', 'costo', 'existencia_maestro',
                    'existencia_inicial', 'codigo_barras', 'ultima_venta', 'nota'])
        for f in filas:
            w.writerow([f['cat'], f['code'], f['name'], n(f['price'], 2), n(f['cost'], 4),
                        n(f['qty'], 2), n(f['qty0'], 2), f['barcode'] or '',
                        f['ult_venta'].isoformat() if f['ult_venta'] else '', f['nota']])

    cuenta = collections.Counter(f['cat'] for f in filas)
    for c in CATEGORIAS:
        if cuenta[c]:
            print(f"{cuenta[c]:4d}  {c}{'  (nueva)' if c in CATEGORIAS_NUEVAS else ''}")
    print(f"total {len(filas)} · con barcode {subs['__N_BARCODE__']} · con existencia "
          f"{len(con_stock)} ({subs['__UNIDADES__']} u, RD${subs['__VALOR__']}) · "
          f"posiciones de la fase 1 renumeradas {len(pos1)} · fuera: {dict(fuera)}")


if __name__ == '__main__':
    main()
