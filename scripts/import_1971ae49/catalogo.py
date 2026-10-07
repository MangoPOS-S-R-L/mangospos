# Catálogo de CAFETERIA MARICELA (business 1971ae49-935c-464a-9bfc-131d76a63be3).
# Fuente: ~/Downloads/ReportInventarios_Todos.pdf, "Reporte General de Inventarios"
# del sistema anterior (06/10/2026 2:31 p. m.), 111 renglones con código, costo,
# precio y existencia, SIN categorías. _fuente_pdf.json es el PDF leído tal cual
# (pdftotext -layout); este archivo le pone categoría, área y correcciones.

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
FUENTE = json.load(open(os.path.join(HERE, '_fuente_pdf.json'), encoding='utf-8'))

# (nombre, posición, área). Área: 'cocina' o 'bar'. La comida va primero.
CATEGORIAS = [
    ('PICADERAS',              10, 'cocina'),
    ('BANDEJAS',               11, 'cocina'),
    ('HAMBURGUESAS',           12, 'cocina'),
    ('SANDWICHES Y TOSTADAS',  13, 'cocina'),
    ('MEXICANO',               14, 'cocina'),
    ('MOFONGOS',               15, 'cocina'),
    ('POLLO',                  16, 'cocina'),
    ('CARNES',                 17, 'cocina'),
    ('MARISCOS Y PESCADOS',    18, 'cocina'),
    ('COMIDA CRIOLLA',         19, 'cocina'),
    ('PASTAS',                 20, 'cocina'),
    ('SOPAS Y ENSALADAS',      21, 'cocina'),
    ('POSTRES',                22, 'cocina'),
    ('COCTELES',               30, 'bar'),
    ('CERVEZAS',               31, 'bar'),
    ('LICORES Y VINOS',        32, 'bar'),
    ('BEBIDAS',                33, 'bar'),
]

# Código del PDF → categoría.
CATEGORIA_POR_CODIGO = {
    # PICADERAS
    '000037': 'PICADERAS', '000008': 'PICADERAS', '000009': 'PICADERAS',
    '000007': 'PICADERAS', '000006': 'PICADERAS', '000011': 'PICADERAS',
    '0000010': 'PICADERAS', '000050': 'PICADERAS', '000076': 'PICADERAS',
    # BANDEJAS
    '000109': 'BANDEJAS', '000020': 'BANDEJAS', '000021': 'BANDEJAS', '000022': 'BANDEJAS',
    # HAMBURGUESAS
    '000063': 'HAMBURGUESAS', '000059': 'HAMBURGUESAS', '000060': 'HAMBURGUESAS',
    '000061': 'HAMBURGUESAS', '000062': 'HAMBURGUESAS', '000064': 'HAMBURGUESAS',
    # SANDWICHES Y TOSTADAS
    '000052': 'SANDWICHES Y TOSTADAS', '000058': 'SANDWICHES Y TOSTADAS',
    '000057': 'SANDWICHES Y TOSTADAS', '000055': 'SANDWICHES Y TOSTADAS',
    '000056': 'SANDWICHES Y TOSTADAS', '000053': 'SANDWICHES Y TOSTADAS',
    '000054': 'SANDWICHES Y TOSTADAS', '000051': 'SANDWICHES Y TOSTADAS',
    # MEXICANO
    '000069': 'MEXICANO', '000067': 'MEXICANO', '000068': 'MEXICANO', '000070': 'MEXICANO',
    '000073': 'MEXICANO', '000071': 'MEXICANO', '000072': 'MEXICANO', '000074': 'MEXICANO',
    '000075': 'MEXICANO',
    # MOFONGOS
    '000035': 'MOFONGOS', '000034': 'MOFONGOS', '000033': 'MOFONGOS', '000036': 'MOFONGOS',
    # POLLO
    '000040': 'POLLO', '000039': 'POLLO', '000038': 'POLLO', '000041': 'POLLO',
    # CARNES
    '000045': 'CARNES', '000042': 'CARNES', '000044': 'CARNES', '000043': 'CARNES',
    '000132': 'CARNES',
    # MARISCOS Y PESCADOS
    '000024': 'MARISCOS Y PESCADOS', '000025': 'MARISCOS Y PESCADOS',
    '000026': 'MARISCOS Y PESCADOS', '000023': 'MARISCOS Y PESCADOS',
    '000029': 'MARISCOS Y PESCADOS', '000027': 'MARISCOS Y PESCADOS',
    '000028': 'MARISCOS Y PESCADOS', '000030': 'MARISCOS Y PESCADOS',
    # COMIDA CRIOLLA
    '000065': 'COMIDA CRIOLLA', '000032': 'COMIDA CRIOLLA', '000031': 'COMIDA CRIOLLA',
    '000066': 'COMIDA CRIOLLA', '000014': 'COMIDA CRIOLLA', '000048': 'COMIDA CRIOLLA',
    '000049': 'COMIDA CRIOLLA',
    # PASTAS
    '000016': 'PASTAS', '000017': 'PASTAS', '000019': 'PASTAS', '000018': 'PASTAS',
    # SOPAS Y ENSALADAS
    '000015': 'SOPAS Y ENSALADAS', '000013': 'SOPAS Y ENSALADAS', '000012': 'SOPAS Y ENSALADAS',
    # POSTRES
    '000047': 'POSTRES', '000046': 'POSTRES',
    # COCTELES
    '000098': 'COCTELES', '000107': 'COCTELES', '000095': 'COCTELES', '000082': 'COCTELES',
    '000084': 'COCTELES', '000093': 'COCTELES', '000091': 'COCTELES', '000085': 'COCTELES',
    '000086': 'COCTELES', '000090': 'COCTELES', '000089': 'COCTELES', '000080': 'COCTELES',
    '000078': 'COCTELES', '000077': 'COCTELES', '000079': 'COCTELES', '000097': 'COCTELES',
    '000083': 'COCTELES', '000081': 'COCTELES', '000096': 'COCTELES', '000094': 'COCTELES',
    '000003': 'COCTELES', '000088': 'COCTELES', '000087': 'COCTELES', '000092': 'COCTELES',
    # CERVEZAS
    '000005': 'CERVEZAS', '000002': 'CERVEZAS', '1': 'CERVEZAS',
    # LICORES Y VINOS
    '000106': 'LICORES Y VINOS', '000114': 'LICORES Y VINOS', '000113': 'LICORES Y VINOS',
    '000004': 'LICORES Y VINOS', '000138': 'LICORES Y VINOS', '000104': 'LICORES Y VINOS',
    '000135': 'LICORES Y VINOS',
    # BEBIDAS
    '000105': 'BEBIDAS', '0000100': 'BEBIDAS', '000099': 'BEBIDAS', '000101': 'BEBIDAS',
}

# Errores de tipeo evidentes del sistema viejo. El nombre del PDF queda en la
# revisión; en la caja sale el corregido.
NOMBRE_CORREGIDO = {
    '000063': 'BACON CHEESE BURGER',
    '000107': 'BLOODY MARY',
    '000095': 'BLUE LAGOON TROPICAL',
    '000097': 'MOSCOW MULE',
    '000094': 'RUM PUNCH',
    '000082': 'CASAMIGOS SANDIA SMASH',
    '000084': 'CASAMIGOS PINEAPPLE FIZZ',
    '000083': 'PALOMA CASAMIGOS',
    '000018': 'PASTA CUATRO QUESOS',
}

# Precio del PDF que es el NETO de un precio redondo: precio × 1.18 cae en un
# número cerrado (254.24 × 1.18 = 300.00). En el sistema viejo esos productos
# sumaban el ITBIS por fuera; con ITBIS incluido hay que cargar el final.
def precio_final_si_neto(p):
    bruto = round(p * 1.18, 2)
    redondo = round(bruto / 5) * 5
    p_es_redondo = abs(p - round(p / 5) * 5) < 0.005
    if not p_es_redondo and abs(bruto - redondo) <= 0.02:
        return float(redondo)
    return None

# Precios que no cuadran ni como final ni como neto: los decide el dueño.
PRECIO_DUDOSO = {
    '000132': 'CERDO ASADO + CASABE 533.33 (costo 366.67): ×1.18 = 629.33; parece 800 × 2/3',
    '000047': 'DULCE DE PIÑA CON LECHE 127.81: ×1.18 = 150.82 (150/1.18 sería 127.12)',
    '000046': 'QUESILLO 169.92: ×1.18 = 200.51 (200/1.18 sería 169.49)',
}


# Decisiones del usuario (2026-10-06):
#   * los 22 precios netos se suben al precio final (lo que pagaba el cliente);
#   * QUESILLO → 200 y DULCE DE PIÑA CON LECHE → 150; CERDO ASADO + CASABE se
#     queda en 533.33 hasta que el dueño confirme;
#   * solo catálogo + costo: sin insumos ni existencias;
#   * los 9 nombres con error de tipeo se corrigen (NOMBRE_CORREGIDO).
SUBIR_NETOS = True
PRECIO_FIJO = {
    '000046': 200.00,   # QUESILLO
    '000047': 150.00,   # DULCE DE PIÑA CON LECHE
}


def productos():
    cat_pos = {c[0]: (c[1], c[2]) for c in CATEGORIAS}
    out = []
    for r in FUENTE:
        code = r['code']
        cat = CATEGORIA_POR_CODIGO[code]
        pos, area = cat_pos[cat]
        neto = precio_final_si_neto(r['price'])
        out.append({
            'code': code,
            'nombre_pdf': r['name'],
            'name': NOMBRE_CORREGIDO.get(code, r['name']),
            'categoria': cat,
            'area': area,
            'is_beverage': area == 'bar',
            'precio_pdf': r['price'],
            'price': PRECIO_FIJO.get(code) or (neto if SUBIR_NETOS and neto else r['price']),
            'precio_si_neto': neto,
            'dudoso': PRECIO_DUDOSO.get(code),
            'cost': r['cost'],
            'exist': r['exist'],
        })
    assert len(out) == 111, len(out)
    assert len({p['code'] for p in out}) == 111
    assert len({p['name'] for p in out}) == 111
    assert set(CATEGORIA_POR_CODIGO) == {p['code'] for p in out}
    # Posición dentro de la categoría: orden alfabético del nombre de la caja.
    for cat in {p['categoria'] for p in out}:
        for i, p in enumerate(sorted((x for x in out if x['categoria'] == cat),
                                     key=lambda x: x['name']), start=1):
            p['posicion'] = i
    return out


if __name__ == '__main__':
    ps = productos()
    from collections import Counter
    for c, n in sorted(Counter(p['categoria'] for p in ps).items(),
                       key=lambda kv: dict((x[0], x[1]) for x in CATEGORIAS)[kv[0]]):
        print(f'{n:3}  {c}')
    print(len(ps), 'productos;',
          sum(1 for p in ps if p['precio_si_neto']), 'precios netos;',
          sum(1 for p in ps if p['dudoso']), 'dudosos')
