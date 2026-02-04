# Cambios Realizados - Eliminación de Animaciones de Transición

## Fecha: 2026-01-28

## Objetivo
Eliminar las animaciones de difuminación (fade) en los cambios de pantalla y hacer que las transiciones entre vistas sean instantáneas (tipo corte directo).

## Archivos Modificados

### `lib/app/router/app_router.dart`

#### Cambios realizados:
1. **Función Helper `_noTransitionPage`**: Se creó una función helper que utiliza `CustomTransitionPage` de GoRouter con `Duration.zero` para eliminar completamente las animaciones de transición.

2. **Actualización de todas las rutas**: Se reemplazó el uso de `builder` por `pageBuilder` en todas las rutas principales de la aplicación:
   - Rutas de autenticación (Login, Register)
   - Dashboard
   - Módulo de Ventas (Sales)
   - Caja (Cashier)
   - Cocina (Kitchen)
   - Productos (Products)
   - Reportes (Reports)
   - Configuración (Settings)
   - Módulo de Menú
   - Módulo de Printing
   - Clientes (Customers) y subrutas
   - Pantalla de orden de mesa (TableOrderScreen)

## Resultado
Ahora todos los cambios de pantalla en la aplicación (por ejemplo, de Home a Cocina) se realizan de forma instantánea sin animación de difuminación, proporcionando una experiencia tipo "corte directo".

## Notas Técnicas
- Se mantiene la compatibilidad con GoRouter
- La transición instantánea se logra configurando `transitionDuration` y `reverseTransitionDuration` a `Duration.zero`
- Se utiliza `CustomTransitionPage` con un `transitionsBuilder` que simplemente retorna el widget child sin aplicar ninguna animación
