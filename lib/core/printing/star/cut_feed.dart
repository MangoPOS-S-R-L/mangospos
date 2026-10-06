// Avance EXTRA antes del corte, por impresora.
//
// EL PROBLEMA QUE RESUELVE
//   El cabezal y la cuchilla no están en el mismo punto del recorrido del
//   papel: la cuchilla queda por delante, y cuánto depende del modelo. `GS V`
//   corta donde está el papel en ese momento, así que todo lo impreso en esos
//   últimos milímetros todavía no llegó a la cuchilla: queda del otro lado
//   del corte y sale ARRIBA del ticket siguiente.
//
//   Por eso cada ticket ya avanza papel antes de cortar (5 renglones en los
//   de texto, `EscPosGenerator.safeCutFeedLines`; 100 puntos en los raster,
//   `EscPosRasterEncoder.feedDotsBeforeCut`). Alcanza en casi todo el parque,
//   pero no en todas: caso que lo motivó (2026-10-06), una impresora donde el
//   "Cambio" y el "Gracias por su preferencia" de cada factura salían
//   impresos al principio de la siguiente. Subir el avance para todos
//   gastaría papel en blanco en todas las demás, así que es un ajuste por
//   impresora.
//
// CÓMO
//   Justo antes del corte final se agregan N renglones con el interlineado
//   de fábrica (`ESC 2` + N × LF). Renglones y no puntos a propósito: el
//   renglón de `ESC 2` mide 1/6" (~4.2mm) en cualquier impresora, mientras
//   que la unidad de `ESC J` depende del modelo (en una TM-T88 es la mitad
//   que en una de 203 dpi). Vale para todo lo que sale por la impresora:
//   factura, precuenta, comanda, cierre.
//
//   Delante va `ESC J 0` (avanzar cero puntos: no hace nada) como MARCA. Un
//   job que rebota por la cola vuelve a pasar por el adaptador, y sin la
//   marca el avance se sumaría otra vez en cada vuelta.

import '../../../data/models/printing.dart';

/// Clave dentro de `printers.connection_config`. El default (0) no se
/// guarda: una impresora sin la clave corta como todas las demás.
const String kCutFeedConfigKey = 'cut_feed_lines';

/// Tope de renglones extra (~42mm). Más que eso ya no es una cuchilla lejos
/// sino otra cosa, y solo tira papel.
const int kMaxCutFeedLines = 10;

/// Milímetros aproximados de un renglón de `ESC 2` (1/6").
const double kCutFeedLineMm = 4.2;

/// Renglones extra elegidos para [printer], acotados a 0–[kMaxCutFeedLines].
int resolveCutFeedLines(PrinterConfig printer) =>
    _clampLines(printer.connectionConfig[kCutFeedConfigKey]);

/// Lo que se guarda en `connection_config` para [lines]: null si es 0 (y
/// entonces se borra la clave).
int? cutFeedWireValue(int lines) {
  final value = _clampLines(lines);
  return value == 0 ? null : value;
}

int _clampLines(Object? raw) {
  final parsed = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}'.trim());
  if (parsed == null || parsed <= 0) return 0;
  return parsed > kMaxCutFeedLines ? kMaxCutFeedLines : parsed;
}

const int _esc = 0x1B;
const int _gs = 0x1D;
const int _lf = 0x0A;

/// `ESC J 0`: la marca de "el avance ya se agregó" (ver arriba).
const List<int> _marker = [_esc, 0x4A, 0x00];

/// Agrega [lines] renglones antes del corte FINAL de [data]. Si no hay
/// corte al final, si [lines] es 0 o si ya se agregó, devuelve [data] tal
/// cual.
List<int> applyCutFeed(List<int> data, int lines) {
  if (lines <= 0) return data;
  final cutAt = _finalCutIndex(data);
  if (cutAt == null || _alreadyApplied(data, cutAt)) return data;
  return [
    ...data.sublist(0, cutAt),
    ..._marker,
    _esc, 0x32, // ESC 2 — interlineado de fábrica (1/6")
    for (var i = 0; i < lines; i++) _lf,
    ...data.sublist(cutAt),
  ];
}

/// Dónde empieza el corte con que termina el ticket, o null.
///
/// Solo mira el FINAL: detrás del corte puede venir el pulso de la gaveta
/// (`ESC p`, que el raster manda después del corte para que el cajón se
/// abra cuando el cajero ya tiene el recibo), y nada más. Además el corte
/// tiene que venir detrás de un avance (LF o `ESC J n`), que es como lo
/// emiten todos los builders y el encoder raster: así unos bytes de imagen
/// que casualmente terminen igual que un corte no se toman por uno.
int? _finalCutIndex(List<int> data) {
  var end = data.length;
  while (end >= 5 && data[end - 5] == _esc && data[end - 4] == 0x70) {
    end -= 5; // ESC p m t1 t2
  }

  int? at;
  if (end >= 3 &&
      data[end - 3] == _gs &&
      data[end - 2] == 0x56 &&
      const {0x00, 0x01, 0x30, 0x31}.contains(data[end - 1])) {
    at = end - 3; // GS V m
  } else if (end >= 4 &&
      data[end - 4] == _gs &&
      data[end - 3] == 0x56 &&
      (data[end - 2] == 0x41 || data[end - 2] == 0x42)) {
    at = end - 4; // GS V m n
  } else if (end >= 2 &&
      data[end - 2] == _esc &&
      (data[end - 1] == 0x69 || data[end - 1] == 0x6D)) {
    at = end - 2; // ESC i / ESC m (cortes de la generación anterior)
  }
  if (at == null || at == 0) return null;

  final afterFeed = data[at - 1] == _lf ||
      (at >= 3 && data[at - 3] == _esc && data[at - 2] == 0x4A);
  return afterFeed ? at : null;
}

/// ¿Ya está nuestro bloque (`ESC J 0`, `ESC 2`, LF…) delante del corte?
bool _alreadyApplied(List<int> data, int cutAt) {
  var i = cutAt;
  while (i > 0 && data[i - 1] == _lf) {
    i--;
  }
  if (i == cutAt || i < 5) return false;
  return data[i - 2] == _esc &&
      data[i - 1] == 0x32 &&
      data[i - 5] == _marker[0] &&
      data[i - 4] == _marker[1] &&
      data[i - 3] == _marker[2];
}
