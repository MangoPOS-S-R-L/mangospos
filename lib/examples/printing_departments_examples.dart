// lib/examples/printing_departments_examples.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/repositories/printing_service.dart';
import '../data/repositories/printing_repository.dart';
import '../data/repositories/sales_repository.dart';

/// 📚 Ejemplos Prácticos de Uso del Sistema de Impresión por Departamentos

class PrintingDepartmentsExamples {
  final SupabaseClient _client;
  late final PrintingService _printingService;
  late final PrintingRepository _printingRepo;
  late final SalesRepository _salesRepo;

  PrintingDepartmentsExamples(this._client) {
    _printingService = PrintingService(_client);
    _printingRepo = PrintingRepository(_client);
    _salesRepo = SalesRepository(_client);
  }

  // ============================================================
  // EJEMPLO 1: CONFIGURACIÓN INICIAL COMPLETA
  // ============================================================

  /// Configurar sistema de impresión desde cero
  Future<void> example1_setupCompleteSystem(String businessId) async {
    print('🚀 EJEMPLO 1: Configuración Inicial Completa\n');

    // Paso 1: Crear áreas de impresión
    print('📍 Paso 1: Creando áreas de impresión...');

    final kitchenHotId = await _printingRepo.createArea(
      businessId: businessId,
      name: 'Cocina Caliente',
      code: 'kitchen_hot',
    );
    print('  ✓ Área creada: Cocina Caliente ($kitchenHotId)');

    final barId = await _printingRepo.createArea(
      businessId: businessId,
      name: 'Bar',
      code: 'bar',
    );
    print('  ✓ Área creada: Bar ($barId)');

    final cashierId = await _printingRepo.createArea(
      businessId: businessId,
      name: 'Caja',
      code: 'cashier',
    );
    print('  ✓ Área creada: Caja ($cashierId)');

    // Paso 2: Registrar impresoras
    print('\n🖨️ Paso 2: Registrando impresoras...');

    final printer1 = await _printingRepo.createPrinter(
      businessId: businessId,
      name: 'Impresora Cocina Principal',
      type: 'network',
      ipAddress: '192.168.1.100',
      port: 9100,
      paperWidth: 80,
    );
    print('  ✓ Impresora registrada: Cocina ($printer1)');

    final printer2 = await _printingRepo.createPrinter(
      businessId: businessId,
      name: 'Impresora Bar',
      type: 'network',
      ipAddress: '192.168.1.101',
      port: 9100,
      paperWidth: 80,
    );
    print('  ✓ Impresora registrada: Bar ($printer2)');

    final printer3 = await _printingRepo.createPrinter(
      businessId: businessId,
      name: 'Impresora Fiscal',
      type: 'network',
      ipAddress: '192.168.1.102',
      port: 9100,
      paperWidth: 80,
    );
    print('  ✓ Impresora registrada: Fiscal ($printer3)');

    // Paso 3: Asignar impresoras a áreas
    print('\n🔗 Paso 3: Asignando impresoras a áreas...');

    await _printingRepo.linkAreaToPrinter(
      businessId: businessId,
      areaId: kitchenHotId.id,
      printerId: printer1.id,
      enabled: true,
      printsOrders: true,
      printsPrebills: false,
      printsReceipts: false,
      priority: 1,
    );
    print('  ✓ Cocina ← Impresora Cocina Principal');

    await _printingRepo.linkAreaToPrinter(
      businessId: businessId,
      areaId: barId.id,
      printerId: printer2.id,
      enabled: true,
      printsOrders: true,
      printsPrebills: false,
      printsReceipts: false,
      priority: 1,
    );
    print('  ✓ Bar ← Impresora Bar');

    await _printingRepo.linkAreaToPrinter(
      businessId: businessId,
      areaId: cashierId.id,
      printerId: printer3.id,
      enabled: true,
      printsOrders: false,
      printsPrebills: true,
      printsReceipts: true,
      priority: 1,
    );
    print('  ✓ Caja ← Impresora Fiscal (solo precuentas/recibos)');

    print('\n✅ Sistema de impresión configurado exitosamente!\n');
  }

  // ============================================================
  // EJEMPLO 2: ENVIAR ORDEN A COCINA CON AGRUPACIÓN AUTOMÁTICA
  // ============================================================

  /// Enviar orden a cocina - el sistema agrupa automáticamente por departamento
  Future<void> example2_sendOrderToKitchen(
    String orderId,
    String businessId,
  ) async {
    print('🍽️ EJEMPLO 2: Enviar Orden a Cocina\n');

    print('📋 Orden ID: $orderId');

    // Ver resumen antes de enviar
    final summary = await _printingService.getOrderPrintSummary(orderId);
    print('\n📊 Resumen de impresión:');
    summary.forEach((area, data) {
      print('  • $area: ${data['itemCount']} items');
      print('    Items: ${(data['items'] as List).join(', ')}');
    });

    // Enviar a cocina
    print('\n🚀 Enviando a cocina...');
    final jobs = await _printingService.sendOrderToKitchen(
      orderId: orderId,
      businessId: businessId,
    );

    print('\n✅ Trabajos de impresión creados:');
    jobs.dispatchIds.forEach((area, jobId) {
      print('  • $area → Job ID: $jobId');
    });

    print('\n💡 El sistema automáticamente:');
    print('  1. Agrupó items por departamento');
    print('  2. Creó un trabajo de impresión por departamento');
    print('  3. Enrutó a las impresoras correspondientes');
    print('  4. Los tickets se están imprimiendo ahora!\n');
  }

  // ============================================================
  // EJEMPLO 3: CONFIGURAR REDUNDANCIA (MÚLTIPLES IMPRESORAS)
  // ============================================================

  /// Configurar múltiples impresoras para un área (redundancia)
  Future<void> example3_setupRedundancy(String businessId) async {
    print('🔄 EJEMPLO 3: Configurar Redundancia\n');

    // Obtener área de cocina
    final areas = await _printingRepo.getPrintAreas(businessId);
    final kitchenArea = areas.firstWhere((a) => a.code == 'kitchen_hot');

    print('📍 Área: ${kitchenArea.name}');

    // Registrar impresora de respaldo
    print('\n🖨️ Registrando impresora de respaldo...');
    final backupPrinter = await _printingRepo.createPrinter(
      businessId: businessId,
      name: 'Impresora Cocina Respaldo',
      type: 'network',
      ipAddress: '192.168.1.103',
      port: 9100,
      paperWidth: 80,
    );
    print('  ✓ Impresora de respaldo registrada');

    // Asignar con prioridad menor
    print('\n🔗 Asignando como respaldo (prioridad 2)...');
    await _printingRepo.linkAreaToPrinter(
      businessId: businessId,
      areaId: kitchenArea.id,
      printerId: backupPrinter.id,
      enabled: true,
      printsOrders: true,
      priority: 2, // Menor prioridad que la principal (1)
    );

    print('\n✅ Redundancia configurada!');
    print('\n💡 Ahora si la impresora principal falla:');
    print('  1. El sistema detecta el error');
    print('  2. Automáticamente reintenta con la impresora de respaldo');
    print('  3. El servicio no se interrumpe\n');
  }

  // ============================================================
  // EJEMPLO 4: REIMPRIMIR EN UN DEPARTAMENTO ESPECÍFICO
  // ============================================================

  /// Reimprimir orden en un departamento específico
  Future<void> example4_reprintInArea(
    String orderId,
    String businessId,
    String areaCode,
  ) async {
    print('🔁 EJEMPLO 4: Reimprimir en Departamento Específico\n');

    print('📋 Orden ID: $orderId');
    print('📍 Área: $areaCode');

    print('\n🖨️ Reimprimiendo...');
    final jobId = await _printingService.reprintOrderInArea(
      orderId: orderId,
      businessId: businessId,
      areaCode: areaCode,
    );

    print('✅ Trabajo de reimpresión creado: $jobId');
    print('\n💡 Casos de uso:');
    print('  • Ticket se perdió o dañó');
    print('  • Impresora estaba apagada');
    print('  • Cliente pidió copia\n');
  }

  // ============================================================
  // EJEMPLO 5: MONITOREAR TRABAJOS DE IMPRESIÓN
  // ============================================================

  /// Monitorear trabajos de impresión en tiempo real
  Future<void> example5_monitorPrintJobs(String businessId) async {
    print('📊 EJEMPLO 5: Monitorear Trabajos de Impresión\n');

    print('🔍 Obteniendo trabajos pendientes...');
    final pendingJobs = await _printingRepo.getPendingJobs(businessId);

    print('\n📋 Trabajos Pendientes: ${pendingJobs.length}');

    for (final job in pendingJobs) {
      print('\n  Job ID: ${job.id}');
      print('  Tipo: ${job.type}');
      print('  Estado: ${job.status}');
      print('  Área: ${job.areaId}');
      print('  Orden: ${job.orderId ?? 'N/A'}');
      print('  Reintentos: ${job.retryCount}');

      if (job.isFailed) {
        print('  ❌ Error: ${job.errorMessage}');
      }
    }

    // Suscribirse a cambios en tiempo real
    print('\n🔔 Suscribiéndose a nuevos trabajos...');
    final stream = _printingRepo.subscribeToPrintJobs(businessId);

    print('💡 Escuchando cambios (presiona Ctrl+C para detener)...\n');

    await for (final jobs in stream.take(5)) {
      // Tomar solo 5 eventos para el ejemplo
      final pending = jobs.where((j) => j.isPending).length;
      final printing = jobs.where((j) => j.isPrinting).length;
      final printed = jobs.where((j) => j.isPrinted).length;
      final failed = jobs.where((j) => j.isFailed).length;

      print('📊 Estado actual:');
      print('  Pendientes: $pending');
      print('  Imprimiendo: $printing');
      print('  Impresos: $printed');
      print('  Fallidos: $failed\n');
    }
  }

  // ============================================================
  // EJEMPLO 6: PROBAR IMPRESORA
  // ============================================================

  /// Enviar trabajo de prueba a una impresora
  Future<void> example6_testPrinter(String printerId) async {
    print('🧪 EJEMPLO 6: Probar Impresora\n');

    print('🖨️ Impresora ID: $printerId');
    print('\n📄 Enviando ticket de prueba...');

    await _printingRepo.enqueueTestPrint(printerId);

    print('✅ Trabajo de prueba enviado!');
    print('\n💡 Deberías ver un ticket de prueba imprimiéndose');
    print('   Si no imprime, verifica:');
    print('   • Impresora está encendida');
    print('   • IP/puerto son correctos');
    print('   • Printer Agent está corriendo\n');
  }

  // ============================================================
  // EJEMPLO 7: OBTENER IMPRESORAS DE UN ÁREA
  // ============================================================

  /// Ver qué impresoras están asignadas a un área
  Future<void> example7_getPrintersForArea(
    String businessId,
    String areaCode,
  ) async {
    print('🔍 EJEMPLO 7: Ver Impresoras de un Área\n');

    print('📍 Área: $areaCode');

    // Obtener área
    final areas = await _printingRepo.getPrintAreas(businessId);
    final area = areas.firstWhere((a) => a.code == areaCode);

    print('  Nombre: ${area.name}');
    print('  ID: ${area.id}');

    // Obtener impresoras
    print('\n🖨️ Impresoras asignadas:');
    final printers = await _printingRepo.getPrintersForArea(area.id);

    if (printers.isEmpty) {
      print('  ⚠️ No hay impresoras asignadas a esta área');
      print('  💡 Asigna al menos una impresora para que funcione');
    } else {
      for (final printer in printers) {
        print('\n  • ${printer.name}');
        print('    Tipo: ${printer.type}');
        if (printer.isNetwork) {
          print('    IP: ${printer.ipAddress}:${printer.port}');
        }
        print('    Estado: ${printer.isActive ? 'Activa' : 'Inactiva'}');
      }
    }
    print('');
  }

  // ============================================================
  // EJEMPLO 8: FLUJO COMPLETO DE VENTA
  // ============================================================

  /// Flujo completo: desde crear orden hasta imprimir
  Future<void> example8_completeFlow(String businessId, String tableId) async {
    print('🎯 EJEMPLO 8: Flujo Completo de Venta\n');

    // 1. Abrir mesa
    print('1️⃣ Abriendo mesa...');
    final session = await _salesRepo.openTable(
      tableId: tableId,
      peopleCount: 2,
    );
    final orderId = session['order_id'] as String;
    print('  ✓ Mesa abierta - Orden: $orderId');

    // 2. Agregar items (simulado - necesitarías IDs reales)
    print('\n2️⃣ Agregando items...');
    print('  • Hamburguesa (kitchen_hot)');
    print('  • Cerveza (bar)');
    print('  • Ensalada (kitchen_cold)');

    // await _salesRepo.addItemFromMenu(
    //   orderId: orderId,
    //   menuItemId: 'hamburguesa-id',
    // );
    // ... agregar más items

    // 3. Enviar a cocina
    print('\n3️⃣ Enviando a cocina...');
    final jobs = await _printingService.sendOrderToKitchen(
      orderId: orderId,
      businessId: businessId,
    );

    print('  ✓ Trabajos creados:');
    jobs.dispatchIds.forEach((area, jobId) {
      print('    • $area');
    });

    // 4. Monitorear estado
    print('\n4️⃣ Monitoreando impresión...');
    await Future.delayed(const Duration(seconds: 2));

    final pendingJobs = await _printingRepo.getPendingJobs(businessId);
    final ourJobs = pendingJobs.where((j) => j.orderId == orderId);

    print('  Estado de nuestros trabajos:');
    for (final job in ourJobs) {
      print('    • ${job.status}');
    }

    print('\n✅ Flujo completo ejecutado!\n');
  }
}

/// 🚀 Función principal para ejecutar ejemplos
Future<void> runPrintingExamples() async {
  final client = Supabase.instance.client;
  final examples = PrintingDepartmentsExamples(client);

  // Obtener businessId del usuario actual
  final user = client.auth.currentUser;
  if (user == null) {
    print('❌ No hay usuario autenticado');
    return;
  }

  // Aquí deberías obtener el businessId del usuario
  const businessId = 'tu-business-id'; // Reemplazar con ID real

  print('═══════════════════════════════════════════════════════');
  print('🖨️  EJEMPLOS DE SISTEMA DE IMPRESIÓN POR DEPARTAMENTOS');
  print('═══════════════════════════════════════════════════════\n');

  try {
    // Descomentar el ejemplo que quieras ejecutar:

    // await examples.example1_setupCompleteSystem(businessId);
    // await examples.example2_sendOrderToKitchen('order-id', businessId);
    // await examples.example3_setupRedundancy(businessId);
    // await examples.example4_reprintInArea('order-id', businessId, 'kitchen_hot');
    // await examples.example5_monitorPrintJobs(businessId);
    // await examples.example6_testPrinter('printer-id');
    // await examples.example7_getPrintersForArea(businessId, 'kitchen_hot');
    // await examples.example8_completeFlow(businessId, 'table-id');

    print(
      '💡 Descomenta el ejemplo que quieras ejecutar en runPrintingExamples()',
    );
  } catch (e) {
    print('\n❌ Error: $e\n');
  }

  print('═══════════════════════════════════════════════════════\n');
}
