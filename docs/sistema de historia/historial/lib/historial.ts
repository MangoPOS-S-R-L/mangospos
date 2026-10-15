// Cómo se lee el historial de cambios (tabla «historial», la llena la base de datos sola)
import { ESTADOS_COT, ROLES, dinero, fLong, num } from './negocio';

export type Entrada = {
  id: number; negocio_id: string; tabla: string; fila_id: string; accion: 'crear' | 'editar' | 'borrar';
  etiqueta: string; quien: string | null; quien_nombre: string; cuando: string; cambios: Record<string, any>;
};

export const TABLAS: [string, string][] = [
  ['', 'Todo'], ['facturas', 'Facturas'], ['cotizaciones', 'Cotizaciones'], ['pagos', 'Pagos'],
  ['productos', 'Productos'], ['clientes', 'Clientes'], ['miembros', 'Equipo'], ['negocios', 'Configuración'],
];
const COSA: Record<string, string> = {
  facturas: 'la factura', cotizaciones: 'la cotización', pagos: 'el pago', productos: 'el producto', clientes: 'el cliente',
};
const CAMPOS: Record<string, string> = {
  numero: 'Número', ncf: 'Comprobante (NCF)', total: 'Total', subtotal: 'Subtotal', descuento: 'Descuento', itbis_monto: 'ITBIS',
  cliente_nombre: 'Cliente', cliente_tel: 'Teléfono', cliente_rnc: 'RNC del cliente', cliente_id: 'Cliente (ficha)', evento: 'Evento',
  tipo: 'Tipo de evento', fecha: 'Fecha', fecha_evento: 'Fecha del evento', hora: 'Hora', lugar: 'Lugar', invitados: 'Invitados',
  lineas: 'Productos', notas: 'Notas', notas_internas: 'Notas internas', anulada: 'Anulada', estado: 'Estado', deposito: 'Depósito (%)',
  desc_tipo: 'Tipo de descuento', desc_valor: 'Descuento', itbis_on: 'Cobra ITBIS', precio: 'Precio', costo: 'Costo', categoria: 'Categoría',
  unidad: 'Se cobra por', descripcion: 'Descripción', variantes: 'Variantes', activo: 'Activo', itbis: 'Aplica ITBIS', impuestos: 'Otros impuestos', nombre: 'Nombre',
  empresa: 'Empresa', rnc: 'RNC', telefono: 'Teléfono', email: 'Correo', rol: 'Puesto', monto: 'Monto', metodo: 'Método', nota: 'Nota',
  plan: 'Plan', vence: 'Pagado hasta', notas_admin: 'Notas de administración',
  'config.nombreComercial': 'Nombre comercial', 'config.nombreLegal': 'Nombre legal', 'config.rnc': 'RNC de la empresa',
  'config.telefono': 'Teléfono de la empresa', 'config.email': 'Correo de la empresa', 'config.direccion': 'Dirección',
  'config.logo': 'Logo', 'config.itbis': 'ITBIS (%)', 'config.deposito': 'Depósito (%)', 'config.validez': 'Validez de cotizaciones',
  'config.notas': 'Notas de cotización', 'config.terminos': 'Términos', 'config.cuentas': 'Cuentas de banco', 'config.categorias': 'Categorías',
  'config.ncfDesde': 'Secuencias NCF (inicio)', 'config.ncfHasta': 'Secuencias NCF (fin)', 'config.ncfVence': 'Vencimiento NCF',
  'config.ncfTipo': 'Tipo de NCF por defecto', 'config.moneda': 'Moneda',
};
// campos internos que no le dicen nada al usuario
const OCULTOS = new Set(['id', 'negocio_id', 'user_id', 'creado', 'actualizado', 'creado_por', 'editada', 'cot_id', 'factura_id', 'creada']);
const DINERO = new Set(['total', 'subtotal', 'descuento', 'itbis_monto', 'monto', 'precio', 'costo']);

export function frase(e: Entrada) {
  const q = e.quien_nombre || 'Alguien';
  if (e.tabla === 'negocios') return `${q} cambió la configuración`;
  if (e.tabla === 'miembros') return e.accion === 'crear' ? `${q} agregó a ${e.etiqueta} al equipo` : e.accion === 'borrar' ? `${q} quitó a ${e.etiqueta} del equipo` : `${q} cambió a ${e.etiqueta} en el equipo`;
  if (e.tabla === 'facturas' && e.accion === 'editar' && e.cambios.anulada?.[1] === true) return `${q} anuló la factura ${e.etiqueta}`;
  const verbo = e.accion === 'crear' ? 'creó' : e.accion === 'borrar' ? 'borró' : 'editó';
  return `${q} ${verbo} ${COSA[e.tabla] || e.tabla} ${e.etiqueta}`.trim();
}

function valor(k: string, v: any, moneda: string): string {
  if (v === null || v === undefined || v === '' || (Array.isArray(v) && !v.length)) return '(vacío)';
  if (DINERO.has(k)) return dinero(num(v), moneda);
  if (typeof v === 'boolean') return v ? 'Sí' : 'No';
  if (k === 'estado') return ESTADOS_COT[v] || String(v);
  if (k === 'rol') return ROLES[v] || String(v);
  if ((k === 'fecha' || k === 'fecha_evento' || k === 'vence') && /^\d{4}-\d{2}-\d{2}/.test(String(v))) return fLong(String(v).slice(0, 10));
  if (k === 'lineas' && Array.isArray(v)) return v.map((l: any) => `${l.nombre}${l.variante ? ' (' + l.variante + ')' : ''} ×${num(l.cant)}`).join(', ');
  if (Array.isArray(v)) return v.map((x) => (typeof x === 'object' ? Object.values(x).filter(Boolean).join(' ') : String(x))).join(', ');
  if (typeof v === 'object') return Object.entries(v).map(([a, b]) => `${a}: ${b}`).join(', ');
  return String(v);
}

/** Lista de cambios para mostrar: [campo, antes, después] (en crear/borrar solo «después»/«antes») */
export function detalle(e: Entrada, moneda = 'RD$'): [string, string, string | null][] {
  const out: [string, string, string | null][] = [];
  for (const [k, v] of Object.entries(e.cambios || {})) {
    if (OCULTOS.has(k)) continue;
    const campo = CAMPOS[k] || k.replace(/^config\./, '');
    if (e.accion === 'editar' && Array.isArray(v) && v.length === 2) out.push([campo, valor(k, v[0], moneda), valor(k, v[1], moneda)]);
    else if (e.accion !== 'editar' && v !== '' && v !== null && !(Array.isArray(v) && !v.length) && v !== false) out.push([campo, valor(k, v, moneda), null]);
  }
  return out;
}
