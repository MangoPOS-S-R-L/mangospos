// Tests del redondeo e-CF DGII.
//
// El caso central sale de un rechazo real: documento E3209708200 del negocio
// "cristian", emitido el 2026-08-17 y rechazado por Alanube con cuatro
// AP10077 ("Value must be a multiple of 0.01") sobre itemDetails 0, 1, 3 y 4.
//
// Correr local:
//   deno test supabase/functions/_shared/dgii-rounding_test.ts

import {
  assertAlmostEquals,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { r2, roundAndReconcile } from "./dgii-rounding.ts";

// ─── r2 ─────────────────────────────────────────────────────────────────────

Deno.test("r2: recorta a 2 decimales los montos que rompian AP10077", () => {
  // 900 / 1.28 — el Asahi del documento rechazado.
  assertEquals(r2(703.125), 703.13);
  // 825 / 1.28 — el Blue Moon.
  assertEquals(r2(644.53125), 644.53);
  // 600 / 1.28 — el coors light, unico que paso la validacion original
  // porque ya venia exacto a 2 decimales.
  assertEquals(r2(468.75), 468.75);
});

Deno.test("r2: resuelve el caso binario de .005", () => {
  // Sin el EPSILON, Math.round(1.005 * 100) da 100 porque 1.005 en binario
  // es 1.00499999999999989.
  assertEquals(r2(1.005), 1.01);
  assertEquals(r2(2.675), 2.68);
});

Deno.test("r2: no altera lo que ya esta redondeado", () => {
  assertEquals(r2(0), 0);
  assertEquals(r2(100), 100);
  assertEquals(r2(4050.0), 4050.0);
  assertEquals(r2(-12.34), -12.34);
});

// ─── roundAndReconcile ──────────────────────────────────────────────────────

Deno.test("reconcile: el documento E3209708200 cuadra exacto", () => {
  // Los cinco order_items.subtotal tal como los guarda la BD.
  const crudo = [703.125, 644.5313, 703.125, 644.5313, 468.75];

  // taxableAmount declarado en `totals`: toFixed(2) de la suma sin redondear
  // (3164.0626 -> 3164.06).
  const target = 3164.06;

  // Redondear linea por linea da 3164.07: un centavo de mas.
  const naive = crudo.map(r2).reduce((a, b) => a + b, 0);
  assertEquals(r2(naive), 3164.07);

  // Con reparto de residuo, la suma cae exacta contra el target.
  const ajustado = roundAndReconcile(crudo, target);
  assertEquals(r2(ajustado.reduce((a, b) => a + b, 0)), target);

  // Todas las lineas quedan con 2 decimales.
  for (const monto of ajustado) {
    assertEquals(monto, r2(monto));
  }

  // Resto mayor: el unico centavo disponible va al primer Asahi, que junto
  // con el otro tiene el resto fraccionario mas alto (.5 contra .13 y .0).
  assertEquals(ajustado, [703.13, 644.53, 703.12, 644.53, 468.75]);
});

Deno.test("reconcile: no toca nada cuando ya cuadra", () => {
  const montos = [100.0, 250.5, 49.5];
  assertEquals(roundAndReconcile(montos, 400.0), [100.0, 250.5, 49.5]);
});

Deno.test("reconcile: absorbe residuo hacia arriba y hacia abajo", () => {
  // Falta un centavo -> se suma a la linea mayor.
  const faltante = roundAndReconcile([10.004, 20.004], 30.02);
  assertEquals(r2(faltante.reduce((a, b) => a + b, 0)), 30.02);

  // Sobra un centavo -> se resta de la linea mayor.
  const sobrante = roundAndReconcile([10.006, 20.006], 30.0);
  assertEquals(r2(sobrante.reduce((a, b) => a + b, 0)), 30.0);
});

Deno.test("reconcile: una linea chica no absorbe el ajuste de una grande", () => {
  // Un centavo sobre una linea de 0.01 seria 100% de distorsion.
  const ajustado = roundAndReconcile([0.01, 999.994], 1000.0);
  assertEquals(ajustado[0], 0.01);
  assertEquals(ajustado[1], 999.99);
  assertEquals(r2(ajustado.reduce((a, b) => a + b, 0)), 1000.0);
});

Deno.test("reconcile: ninguna linea se desvia mas de un centavo", () => {
  // Esta es la garantia que el metodo de resto mayor da y el de "todo a la
  // linea mayor" no. Catorce lineas de 703.125 dejan 7 centavos de residuo:
  // repartidos, cada linea se mueve medio centavo; volcados en una sola, esa
  // linea caia a 703.06.
  const crudo = Array.from({ length: 14 }, () => 703.125);
  const ajustado = roundAndReconcile(crudo, r2(crudo.reduce((a, b) => a + b, 0)));

  for (let i = 0; i < crudo.length; i++) {
    assertAlmostEquals(ajustado[i], crudo[i], 0.01);
  }
  // Siete lineas suben a 703.13 y siete bajan a 703.12.
  assertEquals(ajustado.filter((x) => x === 703.13).length, 7);
  assertEquals(ajustado.filter((x) => x === 703.12).length, 7);
});

Deno.test("reconcile: una sola linea toma el total completo", () => {
  assertEquals(roundAndReconcile([703.125], 703.13), [703.13]);
  assertEquals(roundAndReconcile([703.125], 703.12), [703.12]);
});

Deno.test("reconcile: lista vacia no revienta", () => {
  assertEquals(roundAndReconcile([], 0), []);
  assertEquals(roundAndReconcile([], 100), []);
});

Deno.test("reconcile: aguanta una orden larga sin acumular deriva", () => {
  // 14 lineas — el documento E3209708198 tenia ese tamano.
  const crudo = Array.from({ length: 14 }, (_, i) => 703.125 + i * 0.0071);
  const target = r2(crudo.reduce((a, b) => a + b, 0));

  const ajustado = roundAndReconcile(crudo, target);
  assertEquals(r2(ajustado.reduce((a, b) => a + b, 0)), target);
  for (const monto of ajustado) {
    assertEquals(monto, r2(monto));
  }
});

Deno.test("reconcile: el resultado es determinista", () => {
  // El mismo documento reenviado debe producir el mismo payload byte a byte,
  // o la idempotencia contra Alanube deja de valer.
  const crudo = [703.125, 644.5313, 703.125, 644.5313, 468.75];
  const a = roundAndReconcile(crudo, 3164.06);
  const b = roundAndReconcile(crudo, 3164.06);
  assertEquals(a, b);
});
