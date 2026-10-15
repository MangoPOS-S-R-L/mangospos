import { useCallback, useEffect, useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';
import { Btn, T, Vacio } from '@/components/ui';
import { detalle, frase, type Entrada } from '@/lib/historial';
import { fLong, isoOf, pad } from '@/lib/negocio';
import { useSesion } from '@/lib/sesion';
import { supabase } from '@/lib/supabase';
import { C, F } from '@/lib/tema';

const PAGINA = 50;
const COLOR: Record<string, string> = { crear: C.green, editar: C.amber, borrar: C.redInk };
export const cuandoTxt = (t: string) => {
  const d = new Date(t); const h = d.getHours();
  return `${fLong(isoOf(d))} · ${h % 12 || 12}:${pad(d.getMinutes())} ${h < 12 ? 'a. m.' : 'p. m.'}`;
};

/** Carga el historial del negocio por páginas. filtro: tabla, o filas concretas (ej. una factura y sus pagos) */
export function useHistorial(filtro: { tabla?: string; filas?: string[]; buscar?: string; factura?: string }) {
  const { negocio } = useSesion();
  const [lista, setLista] = useState<Entrada[]>([]);
  const [hayMas, setHayMas] = useState(false);
  const [cargando, setCargando] = useState(false);
  const [error, setError] = useState('');
  const clave = JSON.stringify(filtro);

  const cargar = useCallback(async (desde: number) => {
    if (!negocio) return;
    setCargando(true); setError('');
    let q = supabase.from('historial').select('*').eq('negocio_id', negocio.id).order('cuando', { ascending: false }).range(desde, desde + PAGINA - 1);
    if (filtro.tabla) q = q.eq('tabla', filtro.tabla);
    if (filtro.filas?.length) q = q.in('fila_id', filtro.filas);
    if (filtro.factura) q = q.or(`fila_id.eq.${filtro.factura},cambios->>factura_id.eq.${filtro.factura}`);
    if (filtro.buscar?.trim()) q = q.ilike('etiqueta', `%${filtro.buscar.trim()}%`);
    const { data, error: e } = await q;
    setCargando(false);
    if (e) { setError(/historial/.test(e.message) && /exist|schema cache|relation/i.test(e.message) ? 'Falta pegar el archivo cambios-04.sql en Supabase para activar el historial.' : e.message); return; }
    const filas = (data as Entrada[]) || [];
    setLista((l) => (desde ? [...l, ...filas] : filas)); setHayMas(filas.length === PAGINA);
  }, [negocio?.id, clave]);

  useEffect(() => { cargar(0); }, [cargar]);
  return { lista, hayMas, cargando, error, recargar: () => cargar(0), mas: () => cargar(lista.length) };
}

export function ItemHistorial({ e }: { e: Entrada }) {
  const { cfg } = useSesion();
  const [abierto, setAbierto] = useState(e.accion === 'editar');
  const d = detalle(e, cfg.moneda || 'RD$');
  const ver = abierto ? d : d.slice(0, 0);
  return (
    <View style={s.item}>
      <View style={[s.punto, { backgroundColor: COLOR[e.accion] }]} />
      <View style={{ flex: 1, gap: 4 }}>
        <T style={{ fontFamily: F.uiSemi }}>{frase(e)}</T>
        <T v="small">{cuandoTxt(e.cuando)}</T>
        {ver.map(([campo, a, b], i) => (
          <T key={i} v="small" style={{ color: C.ink }}>
            <T v="small" style={{ fontFamily: F.uiSemi, color: C.ink }}>{campo}: </T>
            {b === null ? a : <>{a} <T v="small" style={{ color: C.muted }}>→</T> <T v="small" style={{ fontFamily: F.uiSemi, color: C.ink }}>{b}</T></>}
          </T>
        ))}
        {d.length && e.accion !== 'editar' ? (
          <Pressable onPress={() => setAbierto(!abierto)}><T v="small" style={{ color: C.redInk, fontFamily: F.uiSemi }}>{abierto ? 'Ocultar detalles' : e.accion === 'borrar' ? 'Ver lo que se borró' : 'Ver detalles'}</T></Pressable>
        ) : null}
      </View>
    </View>
  );
}

export function ListaHistorial({ h, vacio }: { h: ReturnType<typeof useHistorial>; vacio: string }) {
  if (h.error) return <T style={{ color: C.redInk }}>{h.error}</T>;
  return (
    <View>
      {h.lista.length ? h.lista.map((e, i) => <View key={e.id} style={i ? { borderTopWidth: 1, borderColor: C.line } : null}><ItemHistorial e={e} /></View>)
        : !h.cargando ? <Vacio texto={vacio} /> : null}
      {h.hayMas || h.cargando ? <View style={{ alignItems: 'center', paddingTop: 10 }}><Btn titulo="Ver más" cargando={h.cargando} onPress={h.mas} /></View> : null}
    </View>
  );
}

const s = StyleSheet.create({
  item: { flexDirection: 'row', gap: 12, paddingVertical: 12 },
  punto: { width: 10, height: 10, borderRadius: 5, marginTop: 6 },
});

/** Historial de una factura y sus pagos (para abrir desde la factura) */
export function HistorialFactura({ id }: { id: string }) {
  const h = useHistorial({ factura: id });
  return <ListaHistorial h={h} vacio="Todavía no hay cambios registrados para esta factura." />;
}
