import { useState } from 'react';
import { View } from 'react-native';
import { ListaHistorial, useHistorial } from '@/components/Historial';
import { Btn, Campo, Chip, Encabezado, Pantalla, T, Tarjeta, Vacio } from '@/components/ui';
import { TABLAS } from '@/lib/historial';
import { useSesion } from '@/lib/sesion';

// Registro de todo lo que se crea, cambia o borra en el negocio (solo dueño y administradores)
export default function Historial() {
  const { rol } = useSesion();
  const [tabla, setTabla] = useState('');
  const [buscar, setBuscar] = useState('');
  const [q, setQ] = useState('');
  const h = useHistorial({ tabla, buscar: q });
  if (rol !== 'dueno' && rol !== 'admin') return <Pantalla><Encabezado titulo="Historial" /><Tarjeta><Vacio texto="Solo el dueño o un administrador puede ver el historial." /></Tarjeta></Pantalla>;
  return (
    <Pantalla>
      <Encabezado titulo="Historial" sub="Todo lo que se crea, cambia o borra, quién lo hizo y cuándo." derecha={<Btn titulo="Actualizar" icono="trend" onPress={h.recargar} />} />
      <View style={{ gap: 12 }}>
        <Campo value={buscar} onChangeText={setBuscar} onSubmitEditing={() => setQ(buscar)} onBlur={() => setQ(buscar)} placeholder="Buscar por número o nombre (ej. F-00012)…" />
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>{TABLAS.map(([k, l]) => <Chip key={k} titulo={l} on={k === tabla} onPress={() => setTabla(k)} />)}</View>
      </View>
      <Tarjeta>
        <ListaHistorial h={h} vacio={q || tabla ? 'No hay cambios con ese filtro.' : 'Todavía no hay cambios registrados. Desde ahora, todo lo que se haga queda aquí.'} />
      </Tarjeta>
      <T v="small">Nadie puede borrar ni cambiar este historial, ni siquiera el dueño.</T>
    </Pantalla>
  );
}
