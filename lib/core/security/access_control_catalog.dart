class AccessPermission {
  final String code;
  final String label;
  final String categoryId;
  final String categoryLabel;
  final String description;

  const AccessPermission({
    required this.code,
    required this.label,
    required this.categoryId,
    required this.categoryLabel,
    required this.description,
  });
}

class AccessCategory {
  final String id;
  final String label;

  const AccessCategory({required this.id, required this.label});
}

class RolePresetDefinition {
  final String key;
  final String label;
  final String description;
  final Set<String> permissionCodes;

  const RolePresetDefinition({
    required this.key,
    required this.label,
    required this.description,
    required this.permissionCodes,
  });
}

const accessCategories = <AccessCategory>[
  AccessCategory(id: 'restaurant', label: 'Restaurante'),
  AccessCategory(id: 'operations', label: 'Gestion Operativa'),
  AccessCategory(id: 'products', label: 'Gestion de Productos'),
  AccessCategory(id: 'finance', label: 'Finanzas'),
  AccessCategory(id: 'inventory', label: 'Inventario y Compras'),
  AccessCategory(id: 'reports', label: 'Reportes'),
  AccessCategory(id: 'settings', label: 'Configuracion'),
  AccessCategory(id: 'delivery', label: 'Clientes y Delivery'),
  AccessCategory(id: 'kds', label: 'Cocina'),
];

const accessPermissions = <AccessPermission>[
  AccessPermission(
    code: 'dashboard.acceso',
    label: 'Acceso al dashboard',
    categoryId: 'reports',
    categoryLabel: 'Reportes',
    description:
        'Abre el dashboard general con métricas, gráficos y resumen del negocio.',
  ),
  AccessPermission(
    code: 'ventas.mesas.acceso',
    label: 'Acceso a salon y mesas',
    categoryId: 'restaurant',
    categoryLabel: 'Restaurante',
    description: 'Abre el modulo de mesas y el mapa de salon.',
  ),
  AccessPermission(
    code: 'ventas.mesas.ver_estado',
    label: 'Ver estado de mesas',
    categoryId: 'restaurant',
    categoryLabel: 'Restaurante',
    description: 'Consulta ocupacion, cuentas abiertas y estado de mesas.',
  ),
  AccessPermission(
    code: 'ventas.mesas.abrir',
    label: 'Abrir mesas',
    categoryId: 'restaurant',
    categoryLabel: 'Restaurante',
    description: 'Crea o retoma una cuenta en mesa.',
  ),
  AccessPermission(
    code: 'ventas.mesas.mover_unir',
    label: 'Mover o unir mesas',
    categoryId: 'operations',
    categoryLabel: 'Gestion Operativa',
    description: 'Permite mover una cuenta a otra mesa o fusionar mesas.',
  ),
  AccessPermission(
    code: 'ventas.mesas.marcar_pagando',
    label: 'Marcar mesa pagando',
    categoryId: 'operations',
    categoryLabel: 'Gestion Operativa',
    description: 'Marca una mesa en proceso de cobro.',
  ),
  AccessPermission(
    code: 'ventas.mesas.liberar',
    label: 'Liberar mesa',
    categoryId: 'operations',
    categoryLabel: 'Gestion Operativa',
    description: 'Libera una mesa despues de cerrar la cuenta.',
  ),
  AccessPermission(
    code: 'ventas.orden.ver_total',
    label: 'Ver total de la orden',
    categoryId: 'restaurant',
    categoryLabel: 'Restaurante',
    description: 'Muestra totales, impuestos y subtotales de la orden.',
  ),
  AccessPermission(
    code: 'ventas.orden.agregar_item',
    label: 'Agregar productos a la orden',
    categoryId: 'restaurant',
    categoryLabel: 'Restaurante',
    description: 'Permite agregar productos, combos y recetas a la cuenta.',
  ),
  AccessPermission(
    code: 'ventas.orden.editar_item',
    label: 'Editar lineas de orden',
    categoryId: 'restaurant',
    categoryLabel: 'Restaurante',
    description: 'Permite cambiar cantidad, notas y takeout de una linea.',
  ),
  AccessPermission(
    code: 'ventas.orden.eliminar_item',
    label: 'Eliminar lineas de orden',
    categoryId: 'operations',
    categoryLabel: 'Gestion Operativa',
    description: 'Permite quitar productos antes del cobro.',
  ),
  AccessPermission(
    code: 'ventas.orden.enviar_cocina',
    label: 'Enviar Pedido',
    categoryId: 'kds',
    categoryLabel: 'Cocina',
    description:
        'Confirma items pendientes y los envia a cocina/KDS (cuando el negocio tiene cocina habilitada).',
  ),
  AccessPermission(
    code: 'ventas.orden.descuento_aplicar',
    label: 'Aplicar descuento en orden',
    categoryId: 'operations',
    categoryLabel: 'Gestion Operativa',
    description: 'Permite descuentos por linea o por orden.',
  ),
  AccessPermission(
    code: 'ventas.orden.anular',
    label: 'Anular orden',
    categoryId: 'operations',
    categoryLabel: 'Gestion Operativa',
    description: 'Anula una orden abierta o enviada.',
  ),
  AccessPermission(
    code: 'ventas.orden.reabrir',
    label: 'Reabrir orden',
    categoryId: 'operations',
    categoryLabel: 'Gestion Operativa',
    description: 'Reabre una orden cerrada cuando el negocio lo permite.',
  ),
  AccessPermission(
    code: 'ventas.cuenta.split_manual',
    label: 'Dividir cuenta manual',
    categoryId: 'operations',
    categoryLabel: 'Gestion Operativa',
    description: 'Mueve lineas entre subcuentas manualmente.',
  ),
  AccessPermission(
    code: 'ventas.cuenta.split_equiv',
    label: 'Dividir cuenta equitativa',
    categoryId: 'operations',
    categoryLabel: 'Gestion Operativa',
    description: 'Reparte la cuenta automaticamente entre comensales.',
  ),
  AccessPermission(
    code: 'ventas_rapida.acceso',
    label: 'Acceso a venta rapida',
    categoryId: 'restaurant',
    categoryLabel: 'Restaurante',
    description: 'Abre el modulo de venta rapida/manual.',
  ),
  AccessPermission(
    code: 'ventas_rapida.crear_orden',
    label: 'Crear orden rapida',
    categoryId: 'restaurant',
    categoryLabel: 'Restaurante',
    description: 'Crea ordenes de mostrador o express.',
  ),
  AccessPermission(
    code: 'ventas_rapida.enviar_cocina',
    label: 'Enviar venta rapida a cocina',
    categoryId: 'kds',
    categoryLabel: 'Cocina',
    description: 'Envia ventas rapidas pendientes al KDS.',
  ),
  AccessPermission(
    code: 'ventas_rapida.cobrar_inmediato',
    label: 'Cobro inmediato en venta rapida',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description: 'Permite cobrar de inmediato una venta rapida.',
  ),
  AccessPermission(
    code: 'pagos.acceso',
    label: 'Abrir modal de pagos',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description: 'Abre el flujo de cobro y seleccion de metodo de pago.',
  ),
  AccessPermission(
    code: 'pagos.cobrar_efectivo',
    label: 'Cobrar en efectivo',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description: 'Registra pagos en efectivo.',
  ),
  AccessPermission(
    code: 'pagos.cobrar_tarjeta',
    label: 'Cobrar con tarjeta',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description: 'Registra pagos con tarjeta.',
  ),
  AccessPermission(
    code: 'pagos.cobrar_transferencia',
    label: 'Cobrar por transferencia',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description: 'Registra pagos por transferencia u otros medios bancarios.',
  ),
  AccessPermission(
    code: 'pagos.asignar_referencia',
    label: 'Asignar referencia de pago',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description: 'Guarda referencia bancaria o autorizacion.',
  ),
  AccessPermission(
    code: 'pagos.anular_pago',
    label: 'Anular pagos',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description: 'Revierte pagos registrados.',
  ),
  AccessPermission(
    code: 'pagos.reimprimir_recibo',
    label: 'Reimprimir recibos',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description: 'Reimprime recibos y comprobantes de pago.',
  ),
  AccessPermission(
    code: 'caja.apertura',
    label: 'Abrir caja',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description: 'Permite aperturar una sesion de caja.',
  ),
  AccessPermission(
    code: 'caja.cierre',
    label: 'Cerrar caja',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description: 'Permite cerrar caja y registrar arqueo.',
  ),
  AccessPermission(
    code: 'caja.movimientos_ver',
    label: 'Ver movimientos de caja',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description: 'Consulta ingresos, egresos y movimientos de caja.',
  ),
  AccessPermission(
    code: 'caja.movimientos_crear',
    label: 'Registrar ingresos / retiros / gastos',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description:
        'Permite registrar manualmente depósitos, retiros y gastos de '
        'caja. Sin este permiso, el usuario solo puede consultarlos.',
  ),
  AccessPermission(
    code: 'caja.arqueo_ver',
    label: 'Ver arqueos',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description: 'Consulta cierres y arqueos de caja.',
  ),
  AccessPermission(
    code: 'creditos.acceso',
    label: 'Ver créditos (CxC / CxP)',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description:
        'Acceso a la sección de Créditos: cuentas por cobrar y por pagar.',
  ),
  AccessPermission(
    code: 'creditos.vender',
    label: 'Vender a crédito',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description:
        'Habilita el método de pago Crédito en el cobro (requiere cliente '
        'con crédito habilitado).',
  ),
  AccessPermission(
    code: 'creditos.abonar',
    label: 'Registrar abonos de crédito',
    categoryId: 'finance',
    categoryLabel: 'Finanzas',
    description:
        'Registra abonos a cuentas por cobrar y pagos a cuentas por pagar.',
  ),
  AccessPermission(
    code: 'kds.acceso',
    label: 'Acceso a cocina',
    categoryId: 'kds',
    categoryLabel: 'Cocina',
    description: 'Abre la pantalla de cocina.',
  ),
  AccessPermission(
    code: 'kds.ver_comandas',
    label: 'Ver comandas',
    categoryId: 'kds',
    categoryLabel: 'Cocina',
    description: 'Consulta comandas activas en cocina.',
  ),
  AccessPermission(
    code: 'kds.cambiar_estado',
    label: 'Cambiar estado de comanda',
    categoryId: 'kds',
    categoryLabel: 'Cocina',
    description: 'Permite pasar items a preparando, listo o servido.',
  ),
  AccessPermission(
    code: 'kds.reimprimir_comanda',
    label: 'Reimprimir comanda',
    categoryId: 'kds',
    categoryLabel: 'Cocina',
    description: 'Reimprime comandas de cocina.',
  ),
  // Reservas (add-on). El módulo además se gatea por business_modules, así que
  // estos permisos solo aplican cuando la plataforma activó el add-on.
  AccessPermission(
    code: 'reservas.acceso',
    label: 'Acceso a Reservas',
    categoryId: 'restaurant',
    categoryLabel: 'Restaurante',
    description: 'Abre el módulo de reservas y la agenda del día.',
  ),
  AccessPermission(
    code: 'reservas.gestionar',
    label: 'Gestionar reservas',
    categoryId: 'restaurant',
    categoryLabel: 'Restaurante',
    description: 'Crear, editar, sentar y cancelar reservas.',
  ),
  AccessPermission(
    code: 'clientes.ver',
    label: 'Ver clientes',
    categoryId: 'delivery',
    categoryLabel: 'Clientes y Delivery',
    description: 'Consulta clientes y detalle historico.',
  ),
  AccessPermission(
    code: 'clientes.crear_editar',
    label: 'Crear o editar clientes',
    categoryId: 'delivery',
    categoryLabel: 'Clientes y Delivery',
    description: 'Permite crear y editar fichas de clientes.',
  ),
  AccessPermission(
    code: 'clientes.asignar_a_mesa',
    label: 'Asignar cliente a mesa',
    categoryId: 'delivery',
    categoryLabel: 'Clientes y Delivery',
    description: 'Vincula clientes a cuentas o mesas.',
  ),
  AccessPermission(
    code: 'delivery.crear_orden',
    label: 'Crear orden delivery',
    categoryId: 'delivery',
    categoryLabel: 'Clientes y Delivery',
    description: 'Crea ordenes de delivery o despacho.',
  ),
  AccessPermission(
    code: 'delivery.asignar_repartidor',
    label: 'Asignar repartidor',
    categoryId: 'delivery',
    categoryLabel: 'Clientes y Delivery',
    description: 'Asigna un pedido a un repartidor.',
  ),
  AccessPermission(
    code: 'delivery.marcar_entregado',
    label: 'Marcar delivery entregado',
    categoryId: 'delivery',
    categoryLabel: 'Clientes y Delivery',
    description: 'Completa el ciclo de entrega de un pedido.',
  ),
  AccessPermission(
    code: 'productos.acceso',
    label: 'Acceso a gestión de productos',
    categoryId: 'products',
    categoryLabel: 'Gestion de Productos',
    description: 'Abre el catálogo y mantenimiento de productos.',
  ),
  AccessPermission(
    code: 'productos.ver',
    label: 'Ver productos',
    categoryId: 'products',
    categoryLabel: 'Gestion de Productos',
    description: 'Consulta el listado, filtros y detalle de productos.',
  ),
  AccessPermission(
    code: 'productos.crear',
    label: 'Crear productos',
    categoryId: 'products',
    categoryLabel: 'Gestion de Productos',
    description: 'Permite crear nuevos productos del menú.',
  ),
  AccessPermission(
    code: 'productos.editar',
    label: 'Editar productos',
    categoryId: 'products',
    categoryLabel: 'Gestion de Productos',
    description: 'Permite modificar precio, datos y disponibilidad de productos.',
  ),
  AccessPermission(
    code: 'productos.eliminar',
    label: 'Eliminar productos',
    categoryId: 'products',
    categoryLabel: 'Gestion de Productos',
    description: 'Permite eliminar productos del catálogo.',
  ),
  AccessPermission(
    code: 'categorias.ver',
    label: 'Ver categorías',
    categoryId: 'products',
    categoryLabel: 'Gestion de Productos',
    description: 'Consulta el listado de categorías del menú.',
  ),
  AccessPermission(
    code: 'categorias.crear',
    label: 'Crear categorías',
    categoryId: 'products',
    categoryLabel: 'Gestion de Productos',
    description: 'Permite crear nuevas categorías.',
  ),
  AccessPermission(
    code: 'categorias.editar',
    label: 'Editar categorías',
    categoryId: 'products',
    categoryLabel: 'Gestion de Productos',
    description: 'Permite renombrar o cambiar el estado de categorías.',
  ),
  AccessPermission(
    code: 'categorias.eliminar',
    label: 'Eliminar categorías',
    categoryId: 'products',
    categoryLabel: 'Gestion de Productos',
    description: 'Permite eliminar categorías que ya no se usan.',
  ),
  AccessPermission(
    code: 'inventario.acceso',
    label: 'Acceso a inventario',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Abre el modulo de inventario.',
  ),
  AccessPermission(
    code: 'inventario.productos.crear_editar',
    label: 'Crear o editar insumos',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Permite crear y editar insumos y stock items.',
  ),
  AccessPermission(
    code: 'inventario.ajustes.crear',
    label: 'Registrar ajustes de inventario',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Permite entradas, salidas y conciliaciones.',
  ),
  AccessPermission(
    code: 'inventario.transferencias.crear',
    label: 'Crear transferencias de stock',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Permite enviar stock desde el almacén principal hacia otras bodegas.',
  ),
  AccessPermission(
    code: 'inventario.transferencias.recibir',
    label: 'Recibir transferencias de stock',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Permite confirmar la recepción de transferencias en la bodega destino.',
  ),
  AccessPermission(
    code: 'inventario.transferencias.aprobar',
    label: 'Aprobar transferencias de stock',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Permite aprobar transferencias pendientes cuando el '
        'negocio tiene el flujo de aprobación activo. Antes de aprobar, el '
        'stock no se mueve.',
  ),
  AccessPermission(
    code: 'inventario.conteo.acceso',
    label: 'Acceso a conteo físico',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Abre el módulo de conteo físico y ve las sesiones.',
  ),
  AccessPermission(
    code: 'inventario.conteo.crear',
    label: 'Crear sesiones de conteo físico',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Inicia nuevas sesiones de conteo, congela el snapshot y '
        'registra cantidades contadas.',
  ),
  AccessPermission(
    code: 'inventario.conteo.completar',
    label: 'Completar conteo físico',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Aplica los ajustes resultantes del conteo. Genera '
        'movimientos en el kardex y modifica el stock — acción sensible.',
  ),
  AccessPermission(
    code: 'inventario.conteo.anular',
    label: 'Anular conteo físico',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Cancela una sesión de conteo en draft o in_progress sin '
        'aplicar ajustes.',
  ),
  AccessPermission(
    code: 'compras.acceso',
    label: 'Acceso a compras',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Abre el módulo de compras y permite consultar órdenes y proveedores.',
  ),
  AccessPermission(
    code: 'compras.proveedores.crear_editar',
    label: 'Crear o editar proveedores',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Gestiona el maestro de proveedores.',
  ),
  AccessPermission(
    code: 'compras.ordenes.crear',
    label: 'Crear ordenes de compra',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Permite generar ordenes de compra.',
  ),
  AccessPermission(
    code: 'compras.ordenes.recibir',
    label: 'Recibir ordenes de compra',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Permite recibir compras y subir stock.',
  ),
  AccessPermission(
    code: 'compras.ordenes.anular',
    label: 'Anular ordenes de compra',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Revierte o anula ordenes de compra.',
  ),
  AccessPermission(
    code: 'produccion.acceso',
    label: 'Acceso a producción',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Abre el módulo de producción y ve las órdenes existentes.',
  ),
  AccessPermission(
    code: 'produccion.crear',
    label: 'Crear órdenes de producción',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Crea nuevas órdenes para transformar materias primas en '
        'productos terminados.',
  ),
  AccessPermission(
    code: 'produccion.completar',
    label: 'Completar órdenes de producción',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Marca una orden como completada. Genera movimientos en el '
        'kardex y recalcula el costo del producto terminado.',
  ),
  AccessPermission(
    code: 'produccion.anular',
    label: 'Anular órdenes de producción',
    categoryId: 'inventory',
    categoryLabel: 'Inventario y Compras',
    description: 'Cancela órdenes en draft o in_progress sin afectar stock.',
  ),
  AccessPermission(
    code: 'reportes.ventas',
    label: 'Reporte de ventas',
    categoryId: 'reports',
    categoryLabel: 'Reportes',
    description: 'Consulta ventas y tendencias comerciales.',
  ),
  AccessPermission(
    code: 'reportes.productos',
    label: 'Reporte de productos',
    categoryId: 'reports',
    categoryLabel: 'Reportes',
    description: 'Consulta productos vendidos y desempeno de menu.',
  ),
  AccessPermission(
    code: 'reportes.caja',
    label: 'Reporte de caja',
    categoryId: 'reports',
    categoryLabel: 'Reportes',
    description: 'Consulta cierres y movimientos de caja.',
  ),
  AccessPermission(
    code: 'reportes.fiscales',
    label: 'Reporte fiscal',
    categoryId: 'reports',
    categoryLabel: 'Reportes',
    description: 'Consulta comprobantes y estado fiscal.',
  ),
  AccessPermission(
    code: 'settings.usuarios.acceso',
    label: 'Acceso a usuarios',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Abre la gestion de usuarios.',
  ),
  AccessPermission(
    code: 'settings.usuarios.ver',
    label: 'Ver usuarios',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Consulta el listado y detalle de usuarios.',
  ),
  AccessPermission(
    code: 'settings.usuarios.crear',
    label: 'Crear usuarios',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Permite crear usuarios o empleados con acceso.',
  ),
  AccessPermission(
    code: 'settings.usuarios.editar',
    label: 'Editar usuarios',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Permite modificar datos y accesos de usuarios.',
  ),
  AccessPermission(
    code: 'settings.usuarios.desactivar',
    label: 'Desactivar usuarios',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Permite desactivar acceso de usuarios.',
  ),
  AccessPermission(
    code: 'settings.roles.acceso',
    label: 'Acceso a roles',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Abre la gestion de roles y permisos.',
  ),
  AccessPermission(
    code: 'settings.roles.ver',
    label: 'Ver roles',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Consulta roles disponibles.',
  ),
  AccessPermission(
    code: 'settings.roles.crear',
    label: 'Crear roles',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Permite crear nuevos roles del negocio.',
  ),
  AccessPermission(
    code: 'settings.roles.editar',
    label: 'Editar roles',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Permite editar permisos de roles.',
  ),
  AccessPermission(
    code: 'settings.roles.eliminar',
    label: 'Eliminar roles',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Permite eliminar roles no protegidos.',
  ),
  AccessPermission(
    code: 'settings.impresoras.gestionar',
    label: 'Gestionar impresoras y areas',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Configura impresoras, areas y targets.',
  ),
  AccessPermission(
    code: 'settings.zonas_mesas.gestionar',
    label: 'Gestionar zonas y mesas',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Configura zonas y layout de mesas.',
  ),
  AccessPermission(
    code: 'settings.impuestos_fiscal.gestionar',
    label: 'Gestionar impuestos y NCF',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Configura ITBIS, NCF y parametros fiscales.',
  ),
  AccessPermission(
    code: 'settings.metodos_pago.gestionar',
    label: 'Gestionar metodos de pago',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Configura medios de pago.',
  ),
  AccessPermission(
    code: 'settings.descuentos_propinas.gestionar',
    label: 'Gestionar descuentos y propinas',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Configura reglas de descuento y propina.',
  ),
  AccessPermission(
    code: 'settings.kds.gestionar',
    label: 'Gestionar KDS e impresion',
    categoryId: 'settings',
    categoryLabel: 'Configuracion',
    description: 'Configura comportamientos y targets de cocina.',
  ),
];

final allAccessPermissionCodes = accessPermissions
    .map((permission) => permission.code)
    .toSet();

final rolePresets = <String, RolePresetDefinition>{
  'owner': RolePresetDefinition(
    key: 'owner',
    label: 'Propietario',
    description: 'Control total del negocio, configuracion y finanzas.',
    permissionCodes: {...allAccessPermissionCodes},
  ),
  'admin': RolePresetDefinition(
    key: 'admin',
    label: 'Administrador',
    description: 'Administra operacion, usuarios, productos y configuracion.',
    permissionCodes: {...allAccessPermissionCodes},
  ),
  'manager': RolePresetDefinition(
    key: 'manager',
    label: 'Supervisor',
    description:
        'Coordina operacion diaria con acceso amplio, sin control total del sistema.',
    permissionCodes: {
      'dashboard.acceso',
      'ventas.mesas.acceso',
      'ventas.mesas.ver_estado',
      'ventas.mesas.abrir',
      'ventas.mesas.mover_unir',
      'ventas.mesas.marcar_pagando',
      'ventas.mesas.liberar',
      'ventas.orden.ver_total',
      'ventas.orden.agregar_item',
      'ventas.orden.editar_item',
      'ventas.orden.eliminar_item',
      'ventas.orden.enviar_cocina',
      'ventas.orden.descuento_aplicar',
      'ventas.orden.anular',
      'ventas.orden.reabrir',
      'ventas.cuenta.split_manual',
      'ventas.cuenta.split_equiv',
      'ventas_rapida.acceso',
      'ventas_rapida.crear_orden',
      'ventas_rapida.enviar_cocina',
      'ventas_rapida.cobrar_inmediato',
      'pagos.acceso',
      'pagos.cobrar_efectivo',
      'pagos.cobrar_tarjeta',
      'pagos.cobrar_transferencia',
      'pagos.asignar_referencia',
      'pagos.anular_pago',
      'pagos.reimprimir_recibo',
      'creditos.acceso',
      'creditos.vender',
      'creditos.abonar',
      'caja.apertura',
      'caja.cierre',
      'caja.movimientos_ver',
      'caja.movimientos_crear',
      'caja.arqueo_ver',
      'kds.acceso',
      'kds.ver_comandas',
      'kds.cambiar_estado',
      'kds.reimprimir_comanda',
      'reservas.acceso',
      'reservas.gestionar',
      'clientes.ver',
      'clientes.crear_editar',
      'clientes.asignar_a_mesa',
      'delivery.crear_orden',
      'delivery.asignar_repartidor',
      'delivery.marcar_entregado',
      'productos.acceso',
      'productos.ver',
      'productos.crear',
      'productos.editar',
      'productos.eliminar',
      'categorias.ver',
      'categorias.crear',
      'categorias.editar',
      'categorias.eliminar',
      'inventario.acceso',
      'inventario.productos.crear_editar',
      'inventario.ajustes.crear',
      'inventario.transferencias.crear',
      'inventario.transferencias.recibir',
      'inventario.transferencias.aprobar',
      'inventario.conteo.acceso',
      'inventario.conteo.crear',
      'inventario.conteo.completar',
      'inventario.conteo.anular',
      'compras.acceso',
      'compras.proveedores.crear_editar',
      'compras.ordenes.crear',
      'compras.ordenes.recibir',
      'compras.ordenes.anular',
      'produccion.acceso',
      'produccion.crear',
      'produccion.completar',
      'produccion.anular',
      'reportes.ventas',
      'reportes.productos',
      'reportes.caja',
      'reportes.fiscales',
      'settings.usuarios.acceso',
      'settings.usuarios.ver',
      'settings.usuarios.crear',
      'settings.usuarios.editar',
      'settings.usuarios.desactivar',
      'settings.impresoras.gestionar',
      'settings.zonas_mesas.gestionar',
      'settings.descuentos_propinas.gestionar',
      'settings.kds.gestionar',
    },
  ),
  'cashier': RolePresetDefinition(
    key: 'cashier',
    label: 'Cajero',
    description:
        'Cobra, opera caja, gestiona ventas en mesa y rápidas, registra '
        'movimientos. Cierre a ciegas sin ver totales.',
    permissionCodes: {
      // Mesas
      'ventas.mesas.acceso',
      'ventas.mesas.ver_estado',
      'ventas.mesas.abrir',
      'ventas.mesas.mover_unir',
      'ventas.mesas.marcar_pagando',
      'ventas.mesas.liberar',
      // Orden — en negocios chicos el cajero hace todo el flujo de mesero
      'ventas.orden.ver_total',
      'ventas.orden.agregar_item',
      'ventas.orden.editar_item',
      'ventas.orden.enviar_cocina',
      'ventas.orden.descuento_aplicar',
      'ventas.orden.anular',
      'ventas.orden.reabrir',
      // Cuenta / split
      'ventas.cuenta.split_manual',
      'ventas.cuenta.split_equiv',
      // Venta rápida
      'ventas_rapida.acceso',
      'ventas_rapida.crear_orden',
      'ventas_rapida.enviar_cocina',
      'ventas_rapida.cobrar_inmediato',
      // Pagos
      'pagos.acceso',
      'pagos.cobrar_efectivo',
      'pagos.cobrar_tarjeta',
      'pagos.cobrar_transferencia',
      'pagos.asignar_referencia',
      'pagos.reimprimir_recibo',
      // Créditos — recibir abonos en caja. Vender a crédito NO: esa
      // decisión es de supervisor/gerente en adelante ('creditos.vender'
      // vive en el preset manager; owner/admin por wildcard).
      'creditos.acceso',
      'creditos.abonar',
      // Caja
      'caja.apertura',
      'caja.cierre',
      'caja.movimientos_ver',
      'caja.movimientos_crear',
      // KDS — el cajero suele marcar comandas listas y reimprimir
      'kds.acceso',
      'kds.ver_comandas',
      'kds.cambiar_estado',
      'kds.reimprimir_comanda',
      // Clientes
      'clientes.ver',
    },
  ),
  'waiter': RolePresetDefinition(
    key: 'waiter',
    label: 'Mesero',
    description:
        'Opera mesas, ordenes y envio a cocina, sin cobro ni configuracion.',
    permissionCodes: {
      'ventas.mesas.acceso',
      'ventas.mesas.ver_estado',
      'ventas.mesas.abrir',
      'ventas.mesas.marcar_pagando',
      'ventas.orden.ver_total',
      'ventas.orden.agregar_item',
      'ventas.orden.editar_item',
      'ventas.orden.enviar_cocina',
      'ventas.cuenta.split_manual',
      'ventas.cuenta.split_equiv',
      'clientes.ver',
      'clientes.asignar_a_mesa',
    },
  ),
  'cook': RolePresetDefinition(
    key: 'cook',
    label: 'Cocina',
    description: 'Atiende comandas, cambia estados y reimprime cocina.',
    permissionCodes: {
      'kds.acceso',
      'kds.ver_comandas',
      'kds.cambiar_estado',
      'kds.reimprimir_comanda',
    },
  ),
  'delivery': RolePresetDefinition(
    key: 'delivery',
    label: 'Delivery',
    description: 'Opera pedidos de entrega y seguimiento de reparto.',
    permissionCodes: {
      'delivery.crear_orden',
      'delivery.asignar_repartidor',
      'delivery.marcar_entregado',
      'clientes.ver',
      'ventas_rapida.acceso',
      'ventas_rapida.crear_orden',
      'ventas.orden.ver_total',
    },
  ),
};

String normalizeBusinessRole(String? role) {
  switch ((role ?? '').trim().toLowerCase()) {
    case 'owner':
      return 'owner';
    case 'admin':
    case 'administrador':
      return 'admin';
    case 'manager':
    case 'supervisor':
      return 'manager';
    case 'cashier':
    case 'cajero':
      return 'cashier';
    case 'waiter':
    case 'mesero':
      return 'waiter';
    case 'cook':
    case 'chef':
    case 'cocina':
      return 'cook';
    case 'delivery':
      return 'delivery';
    default:
      return 'waiter';
  }
}

String businessRoleLabel(String? role) {
  final normalized = normalizeBusinessRole(role);
  return rolePresets[normalized]?.label ?? normalized;
}

Set<String> presetCodesForRole(String? role) {
  final normalized = normalizeBusinessRole(role);
  return {...?rolePresets[normalized]?.permissionCodes};
}

List<AccessPermission> permissionsForCategory(String categoryId) {
  return accessPermissions
      .where((permission) => permission.categoryId == categoryId)
      .toList(growable: false);
}
