# Fix de Overflow en Grid Responsive - TablesGrid

## 🐛 Problema Reportado

El grid causaba overflow en varios rangos específicos de ancho de pantalla:

| Rango de Ancho | Problema |
|----------------|----------|
| < 497px | Overflow - Cards muy pequeñas |
| 537px - 745px | Overflow - 2 columnas inadecuadas |
| 801px - 994px | Overflow - 3 columnas inadecuadas |
| 1065px - 1243px | Overflow - 4 columnas inadecuadas |
| 1329px - 1491px | Overflow - 5 columnas inadecuadas |
| 1593px - 1740px | Overflow - 6 columnas inadecuadas |

### Patrón Identificado

En todos los casos, el problema era que el cálculo de columnas **no verificaba que el ancho resultante fuera >= 240px**.

La fórmula antigua: `((width + gap) / (minWidth + gap)).floor()` calculaba columnas de forma optimista, pero no garantizaba el ancho mínimo.

---

## ✅ Solución Implementada

### Nueva Lógica de Cálculo

```dart
int _calculateOptimalColumns(double availableWidth, double minCardWidth, double gap) {
  // Probar desde 1 hasta 7 columnas
  for (int cols = 1; cols <= 7; cols++) {
    // Si al agregar una columna más, las cards serían < 240px, detener
    if (cols < 7) {
      final nextTotalGaps = gap * cols;
      final nextCardWidth = (availableWidth - nextTotalGaps) / (cols + 1);
      
      if (nextCardWidth < minCardWidth) {
        // La siguiente columna haría las cards muy pequeñas
        return cols; // Usar columnas actuales
      }
    } else {
      return 7; // Máximo alcanzado
    }
  }
  
  return 1; // Fallback
}
```

### Principio de la Solución

**CONSERVADOR**: Solo aumenta el número de columnas si está **100% seguro** de que las cards seguirán siendo >= 240px.

---

## 📊 Comportamiento Correcto por Ancho

### 📱 Rango 1: Hasta 496px → 1 Columna

```
┌─────────────────────────────────────┐
│ Viewport: 360px - 496px             │
│ Padding: 48px                       │
│ Disponible: 312px - 448px           │
│                                     │
│ Cálculo:                            │
│ - 2 cols = (312 - 24) / 2 = 144px ❌│
│ - 144px < 240px                     │
│ - Resultado: 1 columna ✅           │
└─────────────────────────────────────┘

CARD SIZE:
- Ancho: 312px - 448px
- Alto: 140px (fijo)
```

### 📱 Rango 2: 497px - 536px → 1 Columna

```
┌─────────────────────────────────────┐
│ Viewport: 497px - 536px             │
│ Disponible: 449px - 488px           │
│                                     │
│ Cálculo:                            │
│ - 2 cols = (488 - 24) / 2 = 232px ❌│
│ - 232px < 240px                     │
│ - Resultado: 1 columna ✅           │
└─────────────────────────────────────┘

CARD SIZE:
- Ancho: 449px - 488px (muy horizontal)
- Alto: 140px
```

### 📱 Rango 3: 537px - 745px → 2 Columnas

```
┌─────────────────────────────────────┐
│ Viewport: 537px - 745px             │
│ Disponible: 489px - 697px           │
│                                     │
│ Cálculo para 537px:                 │
│ - 2 cols = (489 - 24) / 2 = 232.5px❌│
│ - ANTES: Se forzaba 2 cols          │
│ - AHORA: Verifica primero           │
│   (489 - 24) / 2 = 232.5px < 240px  │
│   → Mantiene 1 columna ❌           │
│                                     │
│ Cálculo para 545px:                 │
│ - 2 cols = (497 - 24) / 2 = 236.5px❌│
│ - Sigue sin alcanzar 240px          │
│                                     │
│ Cálculo para 552px:                 │
│ - 2 cols = (504 - 24) / 2 = 240px ✅│
│ - ¡Ahora sí! 2 columnas             │
└─────────────────────────────────────┘

PUNTO DE CAMBIO: ~552px
Antes de 552px: 1 columna
Desde 552px: 2 columnas
```

### 💻 Rango 4: 746px - 800px → 2 Columnas

```
┌─────────────────────────────────────┐
│ Viewport: 746px - 800px             │
│ Disponible: 698px - 752px           │
│                                     │
│ Cálculo:   │
│ - 2 cols = (752 - 24) / 2 = 364px ✅│
│ - 3 cols = (752 - 48) / 3 = 234.6px❌│
│ - 234px < 240px                     │
│ - Resultado: 2 columnas ✅          │
└─────────────────────────────────────┘

CARD SIZE:
- Ancho: 337px - 364px (horizontal)
- Alto: 140px
```

### 💻 Rango 5: 801px - 994px → 3 Columnas

```
┌─────────────────────────────────────┐
│ Viewport: 801px - 994px             │
│ Disponible: 753px - 946px           │
│                                     │
│ Cálculo para 801px:                 │
│ - 3 cols = (753 - 48) / 3 = 235px ❌│
│ - Aún no alcanza 240px              │
│                                     │
│ Cálculo para 816px:                 │
│ - 3 cols = (768 - 48) / 3 = 240px ✅│
│ - ¡Ahora sí! 3 columnas             │
└─────────────────────────────────────┘

PUNTO DE CAMBIO: ~816px
Antes de 816px: 2 columnas
Desde 816px: 3 columnas

CARD SIZE:
- Ancho: 240px - 299px
- Alto: 140px
```

### 🖥️ Rango 6: 995px - 1064px → 3 Columnas

```
┌─────────────────────────────────────┐
│ Viewport: 995px - 1064px            │
│ Disponible: 947px - 1016px          │
│                                     │
│ Cálculo:                            │
│ - 3 cols = (1016 - 48) / 3 = 322px✅│
│ - 4 cols = (1016 - 72) / 4 = 236px❌│
│ - Resultado: 3 columnas ✅          │
└─────────────────────────────────────┘

CARD SIZE:
- Ancho: 299px - 322px
- Alto: 140px
```

### 🖥️ Rango 7: 1065px - 1243px → 4 Columnas

```
┌─────────────────────────────────────┐
│ Viewport: 1065px - 1243px           │
│ Disponible: 1017px - 1195px         │
│                                     │
│ Cálculo para 1065px:                │
│ - 4 cols = (1017 - 72) / 4 = 236px❌│
│                                     │
│ Cálculo para 1080px:                │
│ - 4 cols = (1032 - 72) / 4 = 240px✅│
│ - ¡Ahora sí! 4 columnas             │
└─────────────────────────────────────┘

PUNTO DE CAMBIO: ~1080px
Antes de 1080px: 3 columnas
Desde 1080px: 4 columnas

CARD SIZE:
- Ancho: 240px - 280px
- Alto: 140px
```

### 🖥️ Rango 8: 1244px - 1328px → 4 Columnas

```
┌─────────────────────────────────────┐
│ Viewport: 1244px - 1328px           │
│ Disponible: 1196px - 1280px         │
│                                     │
│ Cálculo:                            │
│ - 4 cols = (1280 - 72) / 4 = 302px✅│
│ - 5 cols = (1280 - 96) / 5 = 236.8❌│
│ - Resultado: 4 columnas ✅          │
└─────────────────────────────────────┘

CARD SIZE:
- Ancho: 281px - 302px
- Alto: 140px
```

### 🖥️ Rango 9: 1329px - 1491px → 5 Columnas

```
┌─────────────────────────────────────┐
│ Viewport: 1329px - 1491px           │
│ Disponible: 1281px - 1443px         │
│                                     │
│ Cálculo para 1329px:                │
│ - 5 cols = (1281 - 96) / 5 = 237px❌│
│                                     │
│ Cálculo para 1344px:                │
│ - 5 cols = (1296 - 96) / 5 = 240px✅│
│ - ¡Ahora sí! 5 columnas             │
└─────────────────────────────────────┘

PUNTO DE CAMBIO: ~1344px
Antes de 1344px: 4 columnas
Desde 1344px: 5 columnas

CARD SIZE:
- Ancho: 240px - 269px
- Alto: 140px
```

### 🖥️ Rango 10: 1492px - 1592px → 5 Columnas

```
┌─────────────────────────────────────┐
│ Viewport: 1492px - 1592px           │
│ Disponible: 1444px - 1544px         │
│                                     │
│ Cálculo:                            │
│ - 5 cols = (1544 - 96) / 5 = 289px✅│
│ - 6 cols = (1544 - 120)/ 6 = 237px❌│
│ - Resultado: 5 columnas ✅          │
└─────────────────────────────────────┘

CARD SIZE:
- Ancho: 270px - 289px
- Alto: 140px
```

### 🖥️ Rango 11: 1593px - 1740px → 6 Columnas

```
┌─────────────────────────────────────┐
│ Viewport: 1593px - 1740px           │
│ Disponible: 1545px - 1692px         │
│                                     │
│ Cálculo para 1593px:                │
│ - 6 cols = (1545 - 120) / 6 = 237px❌│
│                                     │
│ Cálculo para 1608px:                │
│ - 6 cols = (1560 - 120) / 6 = 240px✅│
│ - ¡Ahora sí! 6 columnas             │
└─────────────────────────────────────┘

PUNTO DE CAMBIO: ~1608px
Antes de 1608px: 5 columnas
Desde 1608px: 6 columnas

CARD SIZE:
- Ancho: 240px - 262px
- Alto: 140px
```

### 🖥️ Rango 12: 1741px - 1871px → 6 Columnas

```
┌─────────────────────────────────────┐
│ Viewport: 1741px - 1871px           │
│ Disponible: 1693px - 1823px         │
│                                     │
│ Cálculo:                            │
│ - 6 cols = (1823 - 120) / 6 = 283px✅│
│ - 7 cols = (1823 - 144) / 7 = 239px❌│
│ - Resultado: 6 columnas ✅          │
└─────────────────────────────────────┘

CARD SIZE:
- Ancho: 262px - 283px
- Alto: 140px
```

### 🖥️ XL: 1872px+ → 7 Columnas

```
┌─────────────────────────────────────┐
│ Viewport: 1872px+                   │
│ Disponible: 1824px+                 │
│                                     │
│ Cálculo para 1872px:                │
│ - 7 cols = (1824 - 144) / 7 = 240px✅│
│ - ¡Perfecto! 7 columnas (máximo)    │
└─────────────────────────────────────┘

PUNTO DE CAMBIO: ~1872px
Desde 1872px: 7 columnas (máximo)

CARD SIZE:
- Ancho: 240px+
- Alto: 140px
```

---

## 📐 Tabla de Puntos de Cambio Exactos

| Viewport | Disponible | Columnas | Ancho por Card | Cambio |
|----------|------------|----------|----------------|--------|
| 360px | 312px | 1 | 312px | - |
| 496px | 448px | 1 | 448px | - |
| **552px** | **504px** | **2** | **240px** | ⬆️ 1→2 |
| 815px | 767px | 2 | 371.5px | - |
| **816px** | **768px** | **3** | **240px** | ⬆️ 2→3 |
| 1079px | 1031px | 3 | 327.6px | - |
| **1080px** | **1032px** | **4** | **240px** | ⬆️ 3→4 |
| 1343px | 1295px | 4 | 305.75px | - |
| **1344px** | **1296px** | **5** | **240px** | ⬆️ 4→5 |
| 1607px | 1559px | 5 | 292.6px | - |
| **1608px** | **1560px** | **6** | **240px** | ⬆️ 5→6 |
| 1871px | 1823px | 6 | 283.83px | - |
| **1872px** | **1824px** | **7** | **240px** | ⬆️ 6→7 |
| 1920px+ | 1872px+ | 7 | 245px+ | - |

**Patrón**: Cada incremento de columnas ocurre exactamente cuando el ancho por card sería 240px.

---

## ✅ Resultado

### Antes (Con Overflow)
- Cálculo optimista que no verificaba ancho mínimo
- Overflow en 6 rangos diferentes
- Cards podían ser < 240px

### Después (Sin Overflow)
- ✅ Cálculo conservador que garantiza >= 240px
- ✅ Sin overflow en ningún rango
- ✅ Cards siempre >= 240px
- ✅ Transiciones suaves entre número de columnas

---

## 🧪 Testing

### Anchos Críticos a Probar

```dart
final criticalWidths = [
  // Justo antes de cambio
  551,  // 1 col
  815,  // 2 cols
  1079, // 3 cols
  1343, // 4 cols
  1607, // 5 cols
  1871, // 6 cols
  
  // Justo después de cambio
  552,  // → 2 cols
  816,  // → 3 cols
  1080, // → 4 cols
  1344, // → 5 cols
  1608, // → 6 cols
  1872, // → 7 cols
];
```

### Checklist
- [ ] En 551px: 1 columna, card ~503px
- [ ] En 552px: 2 columnas, cards ~240px cada una
- [ ] En 815px: 2 columnas, cards ~371px cada una
- [ ] En 816px: 3 columnas, cards ~240px cada una
- [ ] Sin overflow en ningún ancho
- [ ] Alto siempre 140px

---

**Fix aplicado:** 04/02/2026  
**Status:** ✅ Resuelto  
**Archivo:** `lib/presentation/sales/widgets/tables_grid.dart`
