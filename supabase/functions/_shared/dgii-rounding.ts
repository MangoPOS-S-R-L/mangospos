// Redondeo de montos para e-CF DGII.
//
// Por qué existe este módulo:
// DGII exige que todo monto declarado sea múltiplo de 0.01, y Alanube lo
// valida como AP10077 ("Value must be a multiple of 0.01") ANTES de firmar,
// así que un decimal de más no llega ni a la DGII: rebota en el 400.
//
// La base de datos guarda el desglose de impuesto inclusivo sin redondear.
// Un producto de 900.00 con tasa consolidada 28% (ITBIS 18 + Propina 10)
// deja `order_items.subtotal = 900 / 1.28 = 703.125`. Ese valor viajaba
// crudo al payload y es la causa del rechazo de TODOS los e-CF emitidos
// hasta el 2026-08-17.
//
// Correr los tests:
//   deno test supabase/functions/_shared/dgii-rounding_test.ts

/// Redondea a 2 decimales, que es la única precisión que DGII acepta.
///
/// Suma `Number.EPSILON` antes de multiplicar porque en punto flotante
/// binario `Math.round(1.005 * 100)` da 100 y no 101 — el clásico caso de
/// que 1.005 en realidad es 1.00499999999999989.
export function r2(n: number): number {
  return Math.round((Number(n) + Number.EPSILON) * 100) / 100;
}

/// Redondea cada monto a 2 decimales y reparte el residuo para que la suma
/// dé exactamente `target`.
///
/// Redondear cada línea por separado no basta. El total gravado se declara
/// como `toFixed(2)` de la suma SIN redondear, así que las dos cifras se
/// separan. Caso real del documento E3209708200:
///
///     crudo       703.125 + 644.5313 + 703.125 + 644.5313 + 468.75
///                 = 3164.0626
///     declarado   toFixed(2)                     = 3164.06
///     por línea   703.13 + 644.53 + 703.13 + 644.53 + 468.75
///                 = 3164.07                        <- un centavo de más
///
/// Cambiar un AP10077 por un descuadre de totales no es arreglo: DGII valida
/// que las líneas cuadren contra `totalTaxedAmount`.
///
/// Se usa el método de **resto mayor** (Hamilton): se trunca cada línea al
/// centavo y el residuo se reparte de a un centavo entre las líneas cuyo
/// resto fraccionario quedó más alto. La alternativa obvia — volcar todo el
/// residuo en la línea más grande — se rompe con órdenes largas: catorce
/// líneas de 703.125 dejan 7 centavos de residuo, y cargarlos a una sola
/// línea la mueve a 703.06, siete veces más de lo que ninguna línea debería
/// desviarse. Con resto mayor ninguna línea se aparta más de un centavo.
///
/// Todo el cálculo se hace en centavos enteros para no arrastrar el error de
/// punto flotante que causó el problema original.
export function roundAndReconcile(amounts: number[], target: number): number[] {
  const n = amounts.length;
  if (n === 0) return [];

  const targetCents = Math.round(r2(target) * 100);

  // El epsilon absorbe casos como 468.75 * 100 = 46874.999999999993, donde un
  // floor crudo perdería un centavo entero.
  const scaled = amounts.map((a) => Number(a) * 100);
  const floors = scaled.map((s) => Math.floor(s + 1e-9));
  const remainders = scaled.map((s, i) => s - floors[i]);

  const cents = [...floors];
  const diff = targetCents - floors.reduce((a, b) => a + b, 0);

  // Resto descendente; empate se resuelve por índice para que el resultado
  // sea determinista (el mismo documento produce siempre el mismo payload).
  const order = floors
    .map((_, i) => i)
    .sort((a, b) => remainders[b] - remainders[a] || a - b);

  if (diff > 0) {
    for (let k = 0; k < diff; k++) cents[order[k % n]] += 1;
  } else if (diff < 0) {
    for (let k = 0; k < -diff; k++) cents[order[n - 1 - (k % n)]] -= 1;
  }

  return cents.map((c) => c / 100);
}
