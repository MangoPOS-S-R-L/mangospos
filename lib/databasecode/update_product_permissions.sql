-- Actualización de permisos para Gestión de Productos
-- Separar Crear y Editar, y mover a su propia categoría.

insert into permissions (code, name, module)
values
  ('productos.acceso', 'Productos: Acceso', 'productos'),
  ('productos.ver', 'Productos: Ver', 'productos'),
  ('productos.crear', 'Productos: Crear', 'productos'),
  ('productos.editar', 'Productos: Editar', 'productos'),
  ('productos.eliminar', 'Productos: Eliminar/Desactivar', 'productos'),
  
  ('categorias.acceso', 'Categorías: Acceso', 'categorias'),
  ('categorias.ver', 'Categorías: Ver', 'categorias'),
  ('categorias.crear', 'Categorías: Crear', 'categorias'),
  ('categorias.editar', 'Categorías: Editar', 'categorias'),
  ('categorias.eliminar', 'Categorías: Eliminar/Desactivar', 'categorias')
on conflict (code) do nothing;

-- Opcional: Desactivar o limpiar el permiso viejo si se desea, 
-- pero por ahora lo dejamos para no romper instalaciones existentes 
-- hasta que el código deje de usarlo.
