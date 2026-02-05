# Especificación de Interfaz de Pago y Lógica de Múltiples Tarjetas

Este documento detalla la estructura y lógica necesaria para implementar la pantalla de pagos (Payment Screen) basada en el diseño proporcionado, con énfasis en la funcionalidad de **Pagos Divididos (Split Payments)** para tarjetas.

---

## 1. Explicación: Pagos con Múltiples Tarjetas (Split Payment)

El requerimiento principal es permitir que una cuenta se pague utilizando más de una tarjeta (o combinaciones de métodos). Por ejemplo, una cuenta de **RD$ 200** pagada con dos tarjetas distintas ($100 cada una).

### Lógica Propuesta
El modelo de "Split Payment" funciona acumulando transacciones hasta cubrir el monto total.

1.  **Estado Inicial**:
    *   `Total a Pagar`: $200
    *   `Monto Recibido`: $0
    *   `Restante`: $200

2.  **Primer Pago (Tarjeta 1)**:
    *   El usuario digita **$100** en el teclado numérico.
    *   Selecciona el método **Tarjeta**.
    *   El sistema detecta que $100 < $200 (Pago Parcial).
    *   **Acción**: Se agrega una transacción a la lista: `{"method": "card", "amount": 100}`.
    *   **Actualización UI**:
        *   `Monto Recibido`: $100
        *   `Restante`: $100
        *   La lista de pagos (derecha) muestra: *Pago 1: Tarjeta - RD$ 100*.

3.  **Segundo Pago (Tarjeta 2)**:
    *   El usuario digita **$100** (el restante).
    *   Selecciona el método **Tarjeta** (nuevamente).
    *   **Acción**: Se agrega otra transacción: `{"method": "card", "amount": 100}`.
    *   **Actualización UI**:
        *   `Monto Recibido`: $200
        *   `Restante`: $0
        *   La lista de pagos muestra ambas transacciones.

4.  **Finalización**:
    *   Al llegar el Restante a $0 (o haber cambio), se habilita el botón **Confirmar Pago**.
    *   Al presionar Confirmar, se envían todas las transacciones acumuladas al backend.

---

## 2. Estructura Visual (UI Layout)

La pantalla se debe dividir en dos grandes paneles (Row con 2 Expanded/Flexible widgets).

### Panel Izquierdo (Entrada de Datos)
*   **Selector de Método de Pago**: `Row` con 3 `InkWell`/`Card` widgets (Efectivo, Tarjeta, Transferencia). Al seleccionar uno, se establece el `activeMethod`.
*   **Monto Rápido**: `Wrap` o `GridView` con botones de denominaciones predefinidas (100, 200, 500...). Al tocar, suman o reemplazan el valor del input.
*   **Botón Monto Exacto**: Setea el valor del input igual al `montoRestante`.
*   **Display de Input**: Muestra el valor que el usuario está digitando actualmente (distinto al "Monto Recibido" global).
*   **Teclado Numérico**: Grid 3x4 customizado para input manual.

### Panel Derecho (Resumen)
*   **Resumen de Montos**:
    *   `Total a pagar`: Fijo.
    *   `Monto recibido`: Suma de la lista de pagos acumulados.
    *   `Cambio`: Calculado (`Monto Recibido` - `Total`). Solo se muestra si es positivo.
*   **Lista de Pagos Agregados**: (Nuevo requerimiento implícito para Split Payments).
    *   Un `ListView` o columna que muestre las transacciones parciales ya agregadas (ej: "Tarjeta: $100 [X]").
    *   Botón para eliminar pagos parciales si el usuario se equivoca.
*   **Botones de Acción**:
    *   **Confirmar Pago**: Se habilita solo cuando `Restante <= 0`.
    *   **Cancelar**: Cierra el modal.

---

## 3. Estructura de Código (Dart / Flutter)

### Modelo de Datos
```dart
enum PaymentMethodType { cash, card, transfer }

class PaymentTransaction {
  final String id;
  final PaymentMethodType method;
  final double amount;
  final DateTime timestamp;

  PaymentTransaction({
    required this.method, 
    required this.amount, 
    // ...
  });
}
```

### State Management (ViewModel / Provider)
Se recomienda un `Notifier` que maneje el estado de la sesión de pago.

```dart
class PaymentState {
  final double totalAmount;
  final List<PaymentTransaction> transactions;
  final double currentInputAmount; // Lo que el usuario está digitando
  final PaymentMethodType activeMethod;

  // Getters computados
  double get totalPaid => transactions.fold(0, (sum, t) => sum + t.amount);
  double get remaining => totalAmount - totalPaid;
  double get change => totalPaid > totalAmount ? totalPaid - totalAmount : 0;
  bool get isComplete => remaining <= 0;
}

class PaymentViewModel extends Notifier<PaymentState> {
  // ...
  
  void addPayment() {
    // 1. Tomar currentInputAmount y activeMethod
    // 2. Crear PaymentTransaction
    // 3. Agregar a lista transactions
    // 4. Limpiar currentInputAmount
    // 5. Si isComplete, habilitar botón Confirmar, si no, esperar siguiente pago.
  }
}
```

### Widget Tree Sugerido
```dart
Dialog(
  child: Row(
    children: [
      // IZQUIERDA
      Expanded(
        flex: 3, // Ocupa más espacio
        child: Column(
          children: [
            PaymentMethodSelector(), // Tarjetas de selección
            QuickAmountButtons(),    // Botones RD$ 100, 200...
            NumericKeypad(),         // Teclado
          ],
        ),
      ),
      // DERECHA
      Expanded(
        flex: 2,
        child: Container(
          color: Colors.white,
          child: Column(
            children: [
              PaymentSummaryTotals(), // Total, Recibido, Cambio
              PaymentTransactionsList(), // Lista de pagos parciales (Cards, etc.)
              const Spacer(),
              ActionButtons(),        // Confirmar / Cancelar
            ],
          ),
        ),
      ),
    ],
  ),
);
```
