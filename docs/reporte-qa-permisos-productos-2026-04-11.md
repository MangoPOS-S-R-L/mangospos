# Reporte QA del sistema de permisos y roles

Fecha: 2026-04-11  
Repo: `/Users/cristiangomez/dev/mangospos`

## Alcance

Se revisó:

- `CLAUDE.md`
- Catálogo de permisos
- UI de roles/permisos
- UI de Gestión de productos
- Wiring entre catálogo, UI y backend

**Importante:** no se implementaron cambios. Este documento es solo auditoría/guardrail.

---

## Resumen ejecutivo

**Estado general: NO APROBADO** para el caso de permisos de productos.

El sistema tiene una base de catálogo de permisos, presets y pantalla de roles, pero **Gestión de productos no está modelada ni cableada de forma consistente**.

### Hallazgos principales

1. **No existen permisos claros y separados para “Crear productos” y “Editar productos”.**
   - Solo existe un permiso combinado: `inventario.productos.crear_editar`.
2. **Ese permiso está clasificado como inventario/insumos, no como productos de menú.**
   - En el catálogo aparece con label **“Crear o editar insumos”**.
3. **La UI de Roles/Permisos no expone una sección real de “Gestión de productos”.**
   - Solo muestra `Inventario / compras`, no `Productos`.
4. **La pantalla de productos sí permite crear, editar, activar/desactivar y eliminar, pero no tiene guards locales por permiso.**
5. **El backend actual de `menu_items` permite escritura solo a `owner/admin`, no por permiso granular.**
   - O sea: aunque alguien tenga el permiso de productos, eso **no garantiza** que pueda usarlo.
6. **La persistencia de overrides de permisos parece desalineada con el schema actual de Supabase.**
   - El repo usa `employee_id`, pero el schema actual de `user_permission_overrides` usa `user_id` + `business_id`.

Conclusión práctica:

- **“Crear productos” y “Editar productos” no existen como permisos independientes.**
- **El permiso combinado existente no está correctamente agrupado ni visible en la UI de roles como permiso de productos.**
- **Además, para usuarios no `owner/admin`, el permiso no parece realmente usable de punta a punta.**

---

## Evidencia revisada

### 1) Catálogo de permisos

Archivo: `lib/core/security/access_control_catalog.dart`

Observaciones:

- Existe la categoría:
  - `AccessCategory(id: 'products', label: 'Gestion de Productos')`
- Pero **no encontré permisos con `categoryId: 'products'`**.
- En cambio, el permiso relacionado a productos está definido así:
  - `inventario.acceso`
  - `inventario.productos.crear_editar`
- Y el label del permiso es:
  - **“Crear o editar insumos”**

Esto indica que la categoría conceptual **“Gestión de Productos” existe**, pero **no está realmente poblada** con permisos propios.

### 2) UI de Roles y Permisos

Archivo: `lib/presentation/settings/more settings/system settings/users/view/roles_permissions_view.dart`

Observaciones:

- La UI agrupa permisos en:
  - Configuración
  - Ventas
  - Venta rápida
  - Pagos y caja
  - KDS / Cocina
  - Reportes
  - Clientes y delivery
  - **Inventario / compras**
- En esa pantalla **no existe una sección “Gestión de productos”**.
- Bajo `Inventario / compras`, el row es:
  - `inventario`
- Su mapping es:
  - `acceso -> inventario.acceso`
  - `graba/mod -> inventario.productos.crear_editar + inventario.ajustes.crear`

Problemas concretos:

1. **Productos de menú y ajustes de inventario están mezclados** dentro del mismo row.
2. La UI de roles **no deja ver claramente** si alguien puede:
   - ver productos
   - crear productos
   - editar productos
   - eliminar productos
   - activar/desactivar productos
3. El control es demasiado grueso: `graba/mod` junta varias capacidades distintas.

### 3) UI de Gestión de Productos

Archivo: `lib/presentation/products/view/products_view.dart`

La pantalla sí expone acciones de negocio reales:

- Botón para agregar producto:
  - `Agregar elemento de menú`
- Edición por producto:
  - icono `edit`
- Activar/desactivar disponibilidad:
  - `viewModel.toggleAvailability(...)`
- Eliminar producto:
  - `_confirmDelete(...)`

Hallazgo clave:

**No encontré validaciones de permiso en esta vista** para esas acciones.

No aparece uso de:

- `session.hasPermission(...)`
- `hasAnyPermission(...)`
- `hasAllPermissions(...)`

Eso significa que, a nivel Flutter/UI, si el usuario entra a la pantalla, **los botones y acciones están disponibles**.

### 4) Navegación y visibilidad en UI

#### Shell principal

Archivo: `lib/presentation/shell/main_shell.dart`

- El tab superior `Productos` sí está condicionado por:
  - `permissionCode: 'inventario.acceso'`

Esto ya es una señal de modelado inconsistente:

- La navegación de productos depende de **inventario**, no de un permiso de productos.

#### Pantalla de ajustes

Archivo: `lib/presentation/settings/view/settings_view.dart`

- La sección **“Gestión de Productos”** existe y contiene:
  - Productos y Categorías
  - Modificadores
  - Combos
  - Menú
  - Recetas
  - Insumos
- El card de `Productos y Categorías` navega con:
  - `route: AppRoutes.products`
- El widget de card usa `context.go(data.route!)`

Hallazgo:

**No encontré gating por permiso en esta navegación desde Settings.**

Entonces hoy hay una inconsistencia visible:

- En el top nav, `Productos` depende de `inventario.acceso`
- En Settings, el acceso al card de productos **no parece depender de permisos**

### 5) Wiring backend de permisos efectivos

Archivo: `supabase/schema.sql`

La función actual revisada es:

- `fn_user_effective_permissions(p_user_id, p_business_id)`
- devuelve tabla `(code, allowed)`
- lee `user_roles`, `role_permissions`, `permissions`, `user_permission_overrides`

Eso está alineado con el consumo de lectura del frontend.

### 6) Persistencia de overrides: posible rotura / desalineación

Archivo: `lib/data/repositories/permissions_repository.dart`

La escritura actual hace esto:

- exige `employeeId`
- borra por `.eq('employee_id', employeeId)`
- inserta rows con:
  - `user_id`
  - `employee_id`
  - `permission_id`
  - `business_id`
  - `allow`

Pero el schema actual revisado en `supabase/schema.sql` define `user_permission_overrides` con columnas:

- `user_id`
- `permission_id`
- `business_id`
- `allow`
- `created_by`
- `created_at`

**No aparece `employee_id`** en ese schema actual.

Eso sugiere una de estas dos cosas:

1. el código de Flutter está desactualizado respecto al schema actual, o
2. el schema desplegado real no coincide con `supabase/schema.sql`

En cualquiera de los dos casos, esto es un **riesgo real** para la pantalla de Roles/Permisos.

---

## Validación específica: Gestión de productos

## ¿Los permisos de productos están completos?

**No.**

Faltan, como mínimo, permisos explícitos para:

- Acceso a gestión de productos
- Ver productos
- Crear productos
- Editar productos
- Eliminar productos
- Activar/desactivar productos
- Gestionar categorías
- Gestionar menús / links de menú

Hoy solo existe:

- `inventario.acceso`
- `inventario.productos.crear_editar`

Eso es insuficiente para la superficie real que expone la UI de productos.

## ¿Están correctamente agrupados?

**No.**

Razones:

- El catálogo declara una categoría `products`, pero no la usa.
- El permiso de productos está metido en `inventory`.
- La pantalla de roles agrupa productos junto con inventario y ajustes.
- El label del permiso habla de **insumos**, no de productos de menú.

## ¿Son visibles en la UI de roles?

**No, no de forma correcta ni explícita.**

Visible hoy:

- un row genérico de `Inventario`
- un toggle `graba/mod` que mezcla productos + ajustes

No visible hoy:

- Crear productos
- Editar productos
- Eliminar productos
- Activar/desactivar productos
- Ver productos
- Gestión de categorías

## ¿Están cableados consistentemente?

**No.**

Hay desalineación entre:

- catálogo
- labels
- grouping
- navegación
- guards de UI
- políticas backend
- persistencia de overrides

---

## Validación específica: “Crear productos” y “Editar productos”

## ¿Existen?

**Como permisos separados, no.**

Solo existe un permiso combinado:

- `inventario.productos.crear_editar`

Además, según el punto de vista:

- En el catálogo Flutter el label es **“Crear o editar insumos”**
- En datos SQL viejos/semilla aparece también como **“Crear/Editar Productos”**

Eso refuerza que el modelado todavía no está estable.

## ¿Son realmente utilizables?

**No de forma confiable / consistente.**

### A nivel UI

La pantalla de productos sí deja:

- crear
- editar
- activar/desactivar
- eliminar

pero **no encontré guards por permiso** dentro de la vista.

### A nivel backend

La policy actual de `menu_items_write` en `supabase/schema.sql` permite escritura solo si el usuario tiene rol:

- `owner`
- `admin`

Por tanto:

- un usuario con permiso granular de productos pero sin rol `owner/admin` **podría ver la UI pero fallar al guardar**, o directamente no estar soportado por diseño actual
- un `owner/admin` **podría editar productos aunque el permiso granular no sea el verdadero gate**

### Veredicto

**“Crear productos” y “Editar productos” no son confiables como permisos funcionales del sistema.**

Hoy parecen más bien:

- una intención de catálogo
- parcialmente visible en roles
- pero **no autoridad real de control end-to-end**

---

## Broken / Missing permissions detectados

### Missing

1. **Permiso propio de acceso a Gestión de productos**
   - Ejemplo esperado: `productos.acceso` o equivalente
2. **Permiso de ver productos**
3. **Permiso de crear productos**
4. **Permiso de editar productos**
5. **Permiso de eliminar productos**
6. **Permiso de activar/desactivar disponibilidad**
7. **Permiso de gestionar categorías**
8. **Permisos explícitos para menús/modificadores/combos/recetas** si se desea consistencia con la sección de Settings

### Broken / inconsistent

1. `AccessCategory('products')` existe pero no tiene permisos asociados
2. `inventario.productos.crear_editar` está mal agrupado semánticamente para “productos de menú”
3. Label del permiso inconsistente: “insumos” vs “productos”
4. Top nav usa `inventario.acceso` para `Productos`
5. Settings muestra acceso a productos sin guard visible por permiso
6. La vista de productos no hace checks locales por permiso
7. Las policies backend de `menu_items` dependen de rol (`owner/admin`) y no del permiso granular
8. `PermissionsRepository.saveUserOverrides()` parece no coincidir con el schema actual de `user_permission_overrides`

---

## Acceptance criteria recomendados

Para considerar este módulo **aprobado**, deberían cumplirse al menos estos criterios:

### Catálogo

- [ ] Existe un permiso explícito de acceso a Gestión de productos
- [ ] Existen permisos separados para ver, crear, editar, eliminar y activar/desactivar productos
- [ ] Categorías y labels reflejan correctamente “Productos”, no “Insumos”, salvo que sean módulos distintos
- [ ] La categoría `products` del catálogo está realmente usada

### UI de roles/permisos

- [ ] La pantalla de roles muestra una sección clara de **Gestión de productos**
- [ ] Los toggles no mezclan productos con ajustes de inventario
- [ ] El usuario puede distinguir claramente qué permiso habilita cada acción
- [ ] “Crear productos” y “Editar productos” son visibles y asignables de forma independiente

### UI funcional

- [ ] La navegación a productos usa permisos coherentes con el catálogo
- [ ] La vista de productos oculta o deshabilita acciones según permisos
- [ ] Crear, editar, eliminar y activar/desactivar respetan el permiso correspondiente

### Backend / RLS

- [ ] Las escrituras de `menu_items` están alineadas con el modelo de permisos definido
- [ ] Si el diseño quiere permisos granulares, RLS no debe depender solo de `owner/admin`
- [ ] `fn_user_effective_permissions` y la persistencia de overrides usan el mismo schema real
- [ ] `PermissionsRepository` coincide con `supabase/schema.sql` o con el schema desplegado oficial

---

## Veredicto final

**No aprueba** la validación QA de permisos con foco en productos.

### Estado por pregunta

- **¿Los permisos están completos?** No.
- **¿Están correctamente agrupados?** No.
- **¿Son visibles en la UI?** Parcialmente y de forma incorrecta.
- **¿Están cableados consistentemente?** No.
- **¿Existen “Crear productos” y “Editar productos”?** No como permisos separados.
- **¿Son realmente utilizables?** No de forma consistente end-to-end.

### Riesgo

Alto, porque hoy el sistema puede dar una falsa sensación de control por permisos cuando:

- la UI no refleja bien el modelo
- los permisos no cubren toda la superficie funcional
- y el backend de escritura sigue atado a roles globales (`owner/admin`)

---

## Archivos revisados

- `CLAUDE.md`
- `lib/core/security/access_control_catalog.dart`
- `lib/presentation/settings/more settings/system settings/users/view/roles_permissions_view.dart`
- `lib/presentation/products/view/products_view.dart`
- `lib/presentation/products/viewmodel/products_viewmodel.dart`
- `lib/presentation/settings/view/settings_view.dart`
- `lib/presentation/shell/main_shell.dart`
- `lib/data/repositories/permissions_repository.dart`
- `lib/data/repositories/products_repository.dart`
- `lib/services/session/session_controller.dart`
- `supabase/schema.sql`
- `supabase/migrations/20260308_0022_user_access_control.sql`
