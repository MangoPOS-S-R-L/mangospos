import 'package:flutter/material.dart';

/// Aviso de punto único de falla cuando el local está en modo Hub sin equipo
/// de respaldo configurado.
///
/// Por qué existe: en modo Hub, cuando el Hub acepta una operación el terminal
/// se DESENTIENDE — no la deja en su cola local
/// (`OfflinePosService.enqueueAction`: "si el Hub la acepta, terminamos"). Esa
/// venta queda en un solo disco. Si ese equipo se rompe o se lo roban antes de
/// subir a Supabase, se pierde lo de TODAS las cajas del local, no solo lo
/// suyo.
///
/// Con un respaldo configurado el Hub le espeja cada operación, así que siempre
/// hay dos copias.
///
/// Es un AVISO y no un bloqueo, a propósito: alguien puede estar a mitad de la
/// configuración y poner el respaldo en el paso siguiente. Bloquear lo dejaría
/// sin poder terminar de configurar.
class HubSinglePointOfFailureBanner extends StatelessWidget {
  const HubSinglePointOfFailureBanner({super.key, required this.backupUrl});

  /// Dirección del respaldo, o `null`/vacío si no hay ninguno configurado.
  final String? backupUrl;

  bool get _sinRespaldo => backupUrl == null || backupUrl!.trim().isEmpty;

  @override
  Widget build(BuildContext context) {
    if (!_sinRespaldo) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          children: [
            const Icon(
              Icons.verified_user_outlined,
              size: 18,
              color: Color(0xFF15803D),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Respaldo configurado ($backupUrl). El Hub le manda una copia '
                'de cada operación.',
                style: const TextStyle(fontSize: 13, color: Color(0xFF15803D)),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        border: Border.all(color: const Color(0xFFF59E0B)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 20,
            color: Color(0xFF92400E),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Sin equipo de respaldo, esta caja es un punto único de falla.\n\n'
              'En modo Hub las demás cajas le entregan sus ventas y dejan de '
              'guardarlas. Si este equipo se daña o se pierde antes de subir al '
              'servidor, se pierde lo de TODO el local, no solo lo de esta '
              'caja.\n\n'
              'Configura abajo un equipo de respaldo: el Hub le manda una copia '
              'de cada operación.',
              style: TextStyle(fontSize: 13, color: Color(0xFF92400E)),
            ),
          ),
        ],
      ),
    );
  }
}
