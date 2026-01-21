import 'package:flutter/material.dart';

/// 📊 Barra de estadísticas del KDS
class KdsStatsBar extends StatelessWidget {
  final Duration averageTime;

  const KdsStatsBar({super.key, required this.averageTime});

  @override
  Widget build(BuildContext context) {
    final minutes = averageTime.inMinutes;
    final seconds = averageTime.inSeconds % 60;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey[850],
        border: Border(bottom: BorderSide(color: Colors.grey[700]!)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.speed, size: 20, color: Colors.grey[400]),
          const SizedBox(width: 8),
          Text(
            'Tiempo promedio de preparación:',
            style: TextStyle(color: Colors.grey[400], fontSize: 14),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.blue[900],
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${minutes}m ${seconds}s',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
