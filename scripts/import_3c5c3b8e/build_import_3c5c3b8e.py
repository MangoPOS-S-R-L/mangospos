#!/usr/bin/env python3
"""Genera la carga del catálogo de 007 BAR & SNACK (business 3c5c3b8e).

Uso:
    python3 scripts/import_3c5c3b8e/build_import_3c5c3b8e.py [ruta/a/PRODUCTOS 007.pdf]

Lee el listado con `pdftotext -layout`, clasifica los artículos en categorías
y escribe, desde las plantillas _tpl_*.sql:

    IMPORT_COMPLETO.sql     la carga, una sola transacción
    99_rollback.sql         la deshace
    catalogo_revision.csv   una fila por producto, para revisar la clasificación

Editar ESTE archivo (reglas, correcciones, inactivos) y regenerar; los .sql
generados no se tocan a mano. Mismo PDF = mismo SQL.
"""

import collections
import csv
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
PDF = (Path(sys.argv[1]).expanduser() if len(sys.argv) > 1
       else Path.home() / 'Downloads' / 'PRODUCTOS 007.pdf')

# "Total de artículos" al pie del listado. Si el PDF cambia, esto avisa.
TOTAL_ESPERADO = 828

# Una fila del listado: Articulo, Descripción, (Marca vacía), Costo 4 dec,
# Precio 2 dec, Existencia 2 dec. En -layout las columnas salen en ese orden;
# sin -layout pdftotext intercambia Precio y Existencia.
ROW = re.compile(
    r'^(\S+)\s{2,}(.+?)\s{2,}(-?[\d,]+\.\d{4})\s+(-?[\d,]+\.\d{2})\s+(-?[\d,]+\.\d{2})\s*$')

# Orden en la caja: primero lo que se bebe, al final lo que no es comida.
CATEGORIAS = [
    'Cervezas', 'Licores', 'Vinos y espumantes', 'Premix y cócteles',
    'Refrescos y energizantes', 'Jugos, tés y lácteos', 'Aguas',
    'Snacks salados', 'Galletas y bizcochos', 'Chocolates',
    'Chicles y caramelos', 'Dulces típicos', 'Barras de proteína', 'Despensa',
    'Comida y helados', 'Cigarrillos y tabaco', 'Vapes',
    'Farmacia, higiene y hogar', 'Automotriz', 'Misceláneos',
]
BEBIDAS = set(CATEGORIAS[:7])

# Reglas por palabra clave sobre el nombre en mayúsculas. Gana la PRIMERA que
# calza, así que el orden importa (p. ej. "CHOCOLATE CON ALCOHOL" antes que
# los licores, "JUICE ... VENT STICK" antes que los jugos).
REGLAS = [
    ('Automotriz', r'\bOIL\b|WIPER|ESCOBILLA|PRESTONE|HAVOLINE|HALVOLINE|\bURSA\b|TAPA-FUGAS|CYCLO|WEST[- ](PIN)?ESPUMA|KWIK|SILICON|VENT STICK|NENT STICK|SLIM SPRAY|SLIN SPRAY|JUICE AIR|AMBIENTADOR|ALFOMBR|CORREA ROULUNDS|COOLANT|REPARADOR Y ACONDICIONADOR|LLAVE RUEDA|GRAPA DE TRIA|FORRO DE GUIA|EMBUDO'),
    ('Vapes', r'\bVUSE|VUSESE|VASE GO|VEEV'),
    ('Cigarrillos y tabaco', r'LONGHORN|\bWOLF\b|RED MAN|SKOAL|LUCKY STRIKE|DUNHILL|CONSTANZA|PLASENCIA|FUENTE|QUESADA|CIGARROS|ENCENDEDORA|ENSENDEDORA|TORCHA'),
    ('Farmacia, higiene y hogar', r'NOSOTRAS|STAYFREE|SINUTA|SUNLIN|DRAMANOL|PECTOL|VITAMINA|AMPICILLIN|PRESERVATIVO|SANITIZER|PAPEL DE BA|SERVILLETA|LIQUID SOAP|PALILLOS'),
    ('Chocolates', r'CHOCOLATE CON ALCOHOL|KIT KAT|CRUNCH CHOCOLATE|\bCORTES\b|ROCKY|MAS-MAS CHOCOLATE|CRACHI|MILK CHOCOLATE|PREMIUM CHOCOLATE|BIANCHI|GAROTO|HERSHEY|GIFT CHOCOLATES|ECLAINS|ELVAN|MANI CON CHOCOLATE|TURRON'),
    ('Barras de proteína', r'QUEST(?!.*(SHAKE|LIQUIDO|PROTEIN VAINILLA$))|BARRA PROTEINA'),
    ('Cervezas', r'HEINEKEN|MAHOU|ESTRELLA GALICIA|BLACK COUPAGE|MORETTI|CARLSBERG|HOLL?ANDIA|RED STRIPE|BUCANERO|KRONENBOURG|BERNARD\b|PRIMATO|ROGUE|CERVEZA REPUBLICA|OCHO CERO NUEVE'),
    ('Premix y cócteles', r'BAMB?BOO|ADAN Y EVA|FOUR LOKO|BUZZ BALK|MIKES'),
    ('Licores', r'DEWARS|WHISKY|CARTA REAL|BARCELO|DUBAR|COLUMBUS|CINZANO|CAMPARI|SAMBU|ERISTOFF|BOMBAY|TEQUILA|OZAMA|BRANDY|IRISH CREAM|LAS LLAVES|ALIZE|SOMETHING SPECIAL|IMPERIAL TOLEDANA'),
    ('Vinos y espumantes', r'GATO (NEGRO|BLANCO)|CONCHA Y TORO|SANTA RITA|SANTA C.?X?AROLINA|CASILLERO|FRONTERA|DULZINO|MAIPO|PALO ALTO|MORANDE|CARUSO|SYRAH|NERO DE AVOLA|VILLA JOLANDA|SANTERO|SPERONE|SPRITZ|SPUMANTE|SOLEIL|SFUMATURE|KUNEN|GIULIETTA|PERLINO|PROSECCO|RIUNITE|\bVINO\b|MURVIEDRO|SEGURA VIUDA|VALDEPLATA|RISCAL|SIDRA|MONT-BLAU|MUGA|MIGUEL DE MARCH|VIRTUOSO|CASTILLO (DE )?ROSSI|PYA RED|PROTOS|VALDRUERO|ELEMENTOS|VEGADULCE|VEGA ROBLEDO|BRIEGO|AROMAZ|VICIOUS|GIMENEZ DE TAU|PASION BLUE|TAOZ|CARLOS ROSSI|FRESITA|CABERNET SAUVIGNON 375|COLECCION PRIVADA|MEDLLA REAL|YELLOW BIG|GLORIOSO'),
    ('Aguas', r'AGUA(?! DE COCO)|AQUALY|PELLEGRINO|PELLECRINO|LANDIC|SPARKLING'),
    ('Refrescos y energizantes', r'7UP|SUNKIST|DR PEPPER|HAWALLAN|CRUSH|CICLON|RED BULL|PRIME (LIME|PUNCH|RASP)|XS ENERGY|GO & FUN|SPARKS|FIRE ENERGY|PREDATOR|VIVE\.100|MABI|COCO RICO|REFRESCOS|HATSU SODA'),
    ('Jugos, tés y lácteos', r'\bRICA\b|CHOCO ?RICA|VAQUITA|JUGO|NECTAR|ALOE|LOTUS|KOOL-AID|GRAPE JUICE|\bCHIA\b|AGUA DE COCO|COCONUT DRINK|HATSU TE|TE FRIO|ENSURE|PEDIASURE|MUSCLE MILK|QUEST|LIMONADA|^NARANJA PIÑA'),
    ('Snacks salados', r'CLUB SOCIAL|RITZ|KIKABONI|TOSTONES|BANANAS|PLATANITOS|MADURITOS|HIPPEAS|ENLIGHTENED|BRUSCHETTINI|FOCACCIBIT|POPCORNERS|ONION RINGS|TRULULU|CRISPS|\bMANI\b|NUTRI SNACKS|SNCKS'),
    ('Despensa', r'ACEITUNA|ACERTUNA|ANCHOA|SARDINAS|TUNA|ATUN|BUMBLE BEE|VINAGRE|NESCAFE|NESCAU|CARDO DE POLLO|SURTIDO EL AUTENTICO'),
    ('Dulces típicos', r'^D\.?R[\. ]'),
    ('Galletas y bizcochos', r'OREO|CHIPS AHOY|GALLET|COOKIE|MACADAMIA|BAGLEY|BAYLEY|RECREO|SULTIDA|SULITIDA|MOMENTS|\bMARIA\b|CASINO|VISCONTI|KELLI|MARILAN|TREFF|MINEES|CREMICA|CREMITA|DANISH|DANESA|HAZAL|ROLLINO|TRONCCETTO|MIX ?MAX|ROBIN|BIZCOCHO|MINI CONCHAS|RIZADA|BOCADITOS|LLENITAS|HOSTESS|BROWNIE|ROLLO DE CANELA|MINIS QUAKER'),
    ('Chicles y caramelos', r'TRIDEN|HALLS|MENTOS|CERTS|CHICLETS|SPARKIES|ICEKISS|MENTITAS|GOMITAS|FINI|PALETA|SOUR BELTS|HELLO KITTY|OLI GELATINA|DULCE|HUEVO KING|TOYS|FUN FACTORY|HUMMER|POP TOY|LAPTOP CAR|FRUTINAS|GOMUTCHO|COQUI'),
    ('Comida y helados', r'HOD-DOG|HELADOS'),
    ('Misceláneos', r'CINTA|STRIPE LINES|BOLSA|SHOPPING REF|LLAVERO|FOCOS|CAMERA|CAMARA|THERMO|ABANICO|BOTELLAS VACIAS|RENTA DE LOCAL|REFRIGERIO|HUACALES'),
]

# Correcciones por código donde la regla se equivoca por una palabra suelta.
CORRECCIONES = {
    '853240003016': 'Snacks salados',          # BRUSCHETTINI ... OLIVE OIL
    '853240003214': 'Snacks salados',          # FOCACCIBITES OLIVE OIL
    '8003430100311': 'Aguas',                  # AGUA MINERAL S. BERNARDO
    '8003430100656': 'Aguas',
    '876063002011': 'Jugos, tés y lácteos',    # MUSCLE MILK CHOCOLATE
    '8410525116759': 'Chicles y caramelos',    # FINI JELLY BANANAS
    '7878': 'Misceláneos',                     # REFRIGERIO,JUGOS
}

# Decisión del dueño (15/09/2026): entran INACTIVOS y sin inventario.
INACTIVOS = {
    '8888': 'renta del local, no es mercancía',
    '801': 'botellas vacías',
    '8000': 'embudo de uso interno',
    '7878': 'refrigerio: costo 8,442.99 y precio 1,375',
    '8904169416899': 'antibiótico',
    '7804350600360': 'precio 0.00',
}


def num(s):
    return float(s.replace(',', ''))


def gtin_valido(code):
    digits = [int(c) for c in code]
    body, check = digits[:-1], digits[-1]
    total = sum(d * (3 if i % 2 == 0 else 1) for i, d in enumerate(reversed(body)))
    return (10 - total % 10) % 10 == check


def barcode_de(code):
    """El código de barras que lee la pistola, o None si es código interno.

    8/12/13/14 dígitos entran tal cual. Con 11 dígitos, el sistema anterior
    se comió el 0 inicial del UPC-A: si con el 0 delante valida, la pistola
    lo va a emitir así.
    """
    if not code.isdigit():
        return None
    if len(code) in (8, 12, 13, 14):
        return code
    if len(code) == 11 and gtin_valido('0' + code):
        return '0' + code
    return None


def leer_listado():
    txt = subprocess.run(['pdftotext', '-layout', str(PDF), '-'],
                         check=True, capture_output=True, text=True).stdout
    filas, raras = [], []
    for line in txt.splitlines():
        if not re.match(r'^\d', line):
            continue
        m = ROW.match(line)
        if not m:
            raras.append(line)
            continue
        code, name, cost, price, qty = m.groups()
        name = unicodedata.normalize('NFC', re.sub(r'\s+', ' ', name).strip())
        filas.append(dict(code=code, name=name, cost=num(cost),
                          price=num(price), qty=num(qty)))
    if raras:
        sys.exit('Renglones que no pude leer:\n' + '\n'.join(raras))
    if len(filas) != TOTAL_ESPERADO:
        sys.exit(f'Leí {len(filas)} artículos y el listado dice {TOTAL_ESPERADO}.')
    codes = collections.Counter(f['code'] for f in filas)
    dup = [c for c, n in codes.items() if n > 1]
    if dup:
        sys.exit(f'Códigos repetidos en el listado: {dup}')
    return filas


def clasificar(filas):
    reglas = [(cat, re.compile(p)) for cat, p in REGLAS]
    sin_cat = []
    for f in filas:
        cat = CORRECCIONES.get(f['code'])
        if cat is None:
            nombre = f['name'].upper()
            cat = next((c for c, p in reglas if p.search(nombre)), None)
        if cat is None:
            sin_cat.append(f"{f['code']} {f['name']}")
        f['cat'] = cat
    if sin_cat:
        sys.exit('Sin categoría (agrega una regla o corrección):\n' + '\n'.join(sin_cat))
    for f in filas:
        f['activo'] = f['code'] not in INACTIVOS
        f['inventariable'] = f['activo']
        f['is_bev'] = f['cat'] in BEBIDAS
        f['qty0'] = max(f['qty'], 0.0) if f['inventariable'] else 0.0
        f['barcode'] = barcode_de(f['code'])
    # Posición dentro de la categoría, alfabética.
    for cat in CATEGORIAS:
        grupo = sorted((f for f in filas if f['cat'] == cat), key=lambda f: f['name'])
        for i, f in enumerate(grupo, 1):
            f['pos'] = i
    return filas


def q(s):
    return "'" + s.replace("'", "''") + "'"


def n(x, dec):
    return f'{x:.{dec}f}'


def main():
    filas = clasificar(leer_listado())
    orden = {c: i for i, c in enumerate(CATEGORIAS)}
    filas.sort(key=lambda f: (orden[f['cat']], f['pos']))

    lotes = []
    for i in range(0, len(filas), 200):
        valores = ',\n'.join(
            '  ({}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {})'.format(
                q(f['code']), q(f['name']), q(f['cat']), n(f['price'], 2),
                n(f['cost'], 4) if f['cost'] > 0 else 'null',
                n(f['qty0'], 2), n(f['qty'], 2),
                q(f['barcode']) if f['barcode'] else 'null',
                'true' if f['is_bev'] else 'false',
                'true' if f['activo'] else 'false',
                'true' if f['inventariable'] else 'false',
                f['pos'])
            for f in filas[i:i + 200])
        lotes.append(
            f'-- filas {i + 1}–{min(i + 200, len(filas))}\n'
            'insert into _p007 (codigo, name, categoria, price, cost, qty, '
            'qty_listado, barcode, is_bev, activo, inventariable, posicion) values\n'
            + valores + ';')

    inventariables = [f for f in filas if f['inventariable']]
    con_stock = [f for f in inventariables if f['qty0'] > 0]
    valor = round(sum(f['qty0'] * f['cost'] for f in con_stock), 2)
    unidades = sum(f['qty0'] for f in con_stock)
    codes = ','.join(f['code'] for f in filas)

    subs = {
        '__DATA__': '\n\n'.join(lotes),
        '__CATEGORIAS__': ',\n'.join(
            f'  ({q(c)}, {(i + 1) * 10})' for i, c in enumerate(CATEGORIAS)),
        '__CAT_NAMES_LOWER__': ', '.join(q(c.lower()) for c in CATEGORIAS),
        '__CODES__': codes,
        '__N_TOTAL__': str(len(filas)),
        '__N_ACTIVOS__': str(sum(f['activo'] for f in filas)),
        '__N_INACTIVOS__': str(sum(not f['activo'] for f in filas)),
        '__N_INVENTARIABLES__': str(len(inventariables)),
        '__N_STOCK__': str(len(con_stock)),
        '__UNIDADES__': f'{unidades:g}',
        '__VALOR__': f'{valor:,.2f}',
        '__VALOR_NUM__': f'{valor:.2f}',
        '__N_BARCODE__': str(sum(1 for f in filas if f['barcode'])),
        '__N_CATEGORIAS__': str(len(CATEGORIAS)),
    }

    for tpl, out in (('_tpl_import.sql', 'IMPORT_COMPLETO.sql'),
                     ('_tpl_rollback.sql', '99_rollback.sql')):
        sql = (HERE / tpl).read_text(encoding='utf-8')
        for k, v in subs.items():
            sql = sql.replace(k, v)
        sobrantes = re.findall(r'__[A-Z_]+__', sql.replace('__IN_TRANSIT__', ''))
        if sobrantes:
            sys.exit(f'{tpl}: placeholders sin reemplazar: {sorted(set(sobrantes))}')
        (HERE / out).write_text(sql, encoding='utf-8')

    with open(HERE / 'catalogo_revision.csv', 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(['categoria', 'codigo', 'nombre', 'precio', 'costo',
                    'existencia_listado', 'existencia_inicial', 'codigo_barras',
                    'activo', 'nota'])
        for f in filas:
            w.writerow([f['cat'], f['code'], f['name'], n(f['price'], 2),
                        n(f['cost'], 4), n(f['qty'], 2), n(f['qty0'], 2),
                        f['barcode'] or '', 'sí' if f['activo'] else 'NO',
                        INACTIVOS.get(f['code'], '')])

    cuenta = collections.Counter(f['cat'] for f in filas)
    for c in CATEGORIAS:
        print(f'{cuenta[c]:4d}  {c}')
    print(f"total {subs['__N_TOTAL__']} · activos {subs['__N_ACTIVOS__']} · "
          f"inactivos {subs['__N_INACTIVOS__']} · con barcode {subs['__N_BARCODE__']} · "
          f"con existencia {subs['__N_STOCK__']} ({subs['__UNIDADES__']} u, RD${subs['__VALOR__']})")


if __name__ == '__main__':
    main()
