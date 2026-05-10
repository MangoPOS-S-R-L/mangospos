import 'package:flutter/material.dart';

/// Banner morado de tranquilización: refuerza al cajero que no está viendo
/// el monto esperado. Aparece arriba del paso 1 (efectivo) y opcionalmente
/// en otros pasos donde valga la pena reforzar el principio a ciegas.
class BlindBanner extends StatelessWidget {
  const BlindBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFEDE9FE),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.visibility_off_outlined,
            color: Color(0xFF6D28D9),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF6D28D9),
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
