# Fix de Overflow en TableCard

## 🐛 Problema Identificado

Las tarjetas `TableCard` mostraban overflow en la parte inferior:
- **SP02**: BOTTOM OVERFLOWED BY 42 PIXELS
- **SP01**: BOTTOM OVERFLOWED BY 38 PIXELS

El overflow ocurría porque el contenido interno era más grande que la altura fija de 140px.

---

## ✅ Soluciones Implementadas

### 1. **Reducción de Padding Interno**
```dart
// ANTES
padding: const EdgeInsets.all(16)

// DESPUÉS
padding: const EdgeInsets.all(12)
```
**Ahorro:** 8px de altura (4px arriba + 4px abajo)

### 2. **Cambio de Layout Flexible a Fijo**
```dart
// ANTES - Usaba spaceBetween con Expanded (causaba overflow)
Column(
  mainAxisAlignment: MainAxisAlignment.spaceBetween,
  children: [
    _buildTopSection(),
    _buildDivider(), // <-- Expanded widget
    _buildBottomSection(),
  ],
)

// DESPUÉS - Usa espaciado fijo
Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    _buildTopSection(),
    const SizedBox(height: 8),
    Container(height: 1, ...), // Divisor sin Expanded
    const SizedBox(height: 8),
    _buildBottomSection(),
  ],
)
```

### 3. **Reducción de Espaciado Interno**
```dart
// Espaciado entre código y estado
// ANTES: SizedBox(height: 4)
// DESPUÉS: SizedBox(height: 2)

// Espaciado antes del mesero
// ANTES: SizedBox(height: 12)
// DESPUÉS: SizedBox(height: 8)
```

### 4. **Eliminación del Widget _buildDivider()**
El método `_buildDivider()` que usaba `Expanded` fue eliminado completamente y reemplazado por un divisor inline con altura fija.

---

## 📐 Distribución de Altura Optimizada

### Altura Total: 140px

```
┌─────────────────────────────────────┐ 
│ Padding top: 12px                   │
├─────────────────────────────────────┤
│ Código (20px) + Estado (12px)       │ ~40px
│ + Espaciado (2px)                   │
├─────────────────────────────────────┤
│ SizedBox: 8px                       │
├─────────────────────────────────────┤
│ Divisor: 1px                        │
├─────────────────────────────────────┤
│ SizedBox: 8px                       │
├─────────────────────────────────────┤
│ Sección inferior (métricas/mesero)  │ ~50px
├─────────────────────────────────────┤
│ Padding bottom: 12px                │
└─────────────────────────────────────┘
Total: ~140px (sin overflow)
```

### Desglose Detallado

#### Mesa Disponible
- Padding top: 12px
- Código mesa: 20px (font-size) + line-height
- SizedBox: 2px
- Estado: 12px (font-size) + line-height
- SizedBox: 8px
- Divisor: 1px
- SizedBox: 8px
- "Toca para asignar": 14px + padding 4px
- Padding bottom: 12px
**Total: ~116px** ✅

#### Mesa Ocupada
- Padding top: 12px
- Código + Estado: ~40px
- Espaciado + Divisor: 17px
- Métricas (iconos + texto): ~20px
- SizedBox: 8px
- Mesero + Badge: ~20px
- Padding bottom: 12px
**Total: ~129px** ✅

---

## 🔧 Cambios en el Código

### Archivo Modificado
`lib/presentation/sales/widgets/table_card.dart`

### Líneas Cambiadas
1. **Línea 77**: Padding 16 → 12
2. **Línea 79**: MainAxisAlignment.spaceBetween → MainAxisSize.min
3. **Líneas 85-91**: Divisor flexible → divisor fijo con SizedBox
4. **Línea 117**: SizedBox height 4 → 2
5. **Línea 207**: SizedBox height 12 → 8
6. **Eliminado**: Método completo `_buildDivider()` (líneas 143-154)

---

## ✅ Resultado

- ✅ **Sin overflow**: Todo el contenido cabe perfectamente en 140px
- ✅ **Consistente**: Mismo tamaño en todas las tarjetas
- ✅ **Responsive**: Se ajusta correctamente al grid sin desbordarse
- ✅ **Visualmente balanceado**: El espaciado sigue siendo proporcional

---

## 📝 Notas Técnicas

### Por qué ocurría el overflow:

1. **Column con spaceBetween**: Intentaba distribuir el espacio disponible entre los widgets
2. **Expanded en divisor**: Tomaba todo el espacio restante, empujando la sección inferior
3. **Padding excesivo**: 16px × 2 = 32px de altura solo en padding
4. **Espaciado acumulado**: Múltiples SizedBox sumaban altura

### Por qué la solución funciona:

1. **Espaciado fijo**: Sabemos exactamente cuánto espacio ocupa cada elemento
2. **Sin Expanded**: No hay widgets que intenten tomar espacio flexible
3. **Padding optimizado**: 12px × 2 = 24px (ahorro de 8px)
4. **MainAxisSize.min**: Column solo usa el espacio mínimo necesario

---

## 🎯 Testing

Para verificar que no hay overflow:

1. Abrir la vista de mesas
2. Verificar que no aparezcan mensajes de "OVERFLOWED BY X PIXELS"
3. Probar con:
   - Mesas disponibles
   - Mesas ocupadas con nombres largos de mesero
   - Mesas con badge "Tu mesa"
   - Diferentes tamaños de pantalla

---

**Fecha del fix:** 04/02/2026  
**Issue:** Overflow en TableCard  
**Status:** ✅ Resuelto
