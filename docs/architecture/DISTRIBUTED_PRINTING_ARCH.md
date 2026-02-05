# Arquitectura de Sistema de Impresión Distribuido (Cloud POS)

## 1. Visión General de la Arquitectura

Para resolver las limitaciones de acceso al hardware desde Flutter Web y los problemas de estabilidad de soluciones como QZ Tray, diseñamos una arquitectura basada en **Agentes Satélite**.

El sistema consta de tres componentes principales:
1.  **Frontend (Flutter Web)**: Genera la orden y los datos de impresión. No interactúa con impresoras.
2.  **Cloud Backend (Central)**: Orquesta, almacena y encola trabajos de impresión. Gestiona la flota de dispositivos.
3.  **Local Print Agent (Satélite)**: Un binario ligero instalado en la PC/Servidor del restaurante. Mantiene un túnel persistente con la nube y ejecuta comandos ESC/POS sobre el hardware físico.

```mermaid
graph TD
    subgraph "Restaurante (Local)"
        Agent[Print Agent (Node/Go)]
        Printer1[Impresora Caja (USB)]
        Printer2[Impresora Cocina (ETH)]
        
        Agent -->|USB/Serial| Printer1
        Agent -->|TCP/9100| Printer2
    end
    
    subgraph "Cloud Backend"
        API[API Gateway]
        Queue[Redis Job Queue]
        WS[WebSocket Hub]
        DB[(PostgreSQL)]
        
        API --> Queue
        Queue --> WS
        WS <==>|WebSocket WSS| Agent
        API --> DB
    end
    
    subgraph "Cliente"
        POS[Flutter Web POS]
        POS -->|HTTPS / POST Jobs| API
    end
```

---

## 2. Flujo End-to-End (Happy Path)

1.  **Job Creation**: El cajero finaliza una venta en **Flutter Web**. La app envía un `POST /api/print-jobs` al Backend con el payload del ticket (items, totales, info fiscal).
2.  **Queuing**: El Backend valida la petición y coloca el trabajo en **Redis Queue** (`print_jobs:branch_{id}`). Persiste el estado como `PENDING` en Postgres.
3.  **Dispatch**: El worker de la cola detecta el trabajo y lo empuja al **WebSocket Hub**.
4.  **Delivery**: El WebSocket Hub busca la conexión activa del **Print Agent** asignado a esa sucursal y le envía el evento `PRINT_REQUEST`.
5.  **Execution (Local)**:
    *   El Agente recibe el payload.
    *   Identifica la impresora destino (ej. "Kitchen_Printer_1").
    *   Convierte datos genéricos a ESC/POS (si es necesario) o pasa los bytes RAW.
    *   Envía datos al puerto físico (USB/COM/Network).
6.  **Acknowledge**: La impresora confirma recepción. El Agente envía `JOB_SUCCESS` al Backend.
7.  **Update**: El Backend actualiza el estado a `PRINTED` y notifica al Flutter Web (opcionalmente vía WS también) que el ticket salió.

---

## 3. Componentes Técnicos

### 3.1 Backend (Node.js / Go / Python)
Centraliza la lógica de negocio.

*   **API REST**:
    *   `POST /v1/printers`: Registrar una nueva impresora en la nube.
    *   `POST /v1/print-jobs`: Crear un trabajo de impresión.
    *   `GET /v1/devices/health`: Monitoreo de agentes.
*   **WebSocket Gateway**: Maneja miles de conexiones persistentes. Autentica agentes mediante JWT.
*   **Job Queue (Redis)**: Garantiza que ningún ticket se pierda si el agente se desconecta momentáneamente.

### 3.2 Local Print Agent (Node.js RECOMENDADO)
Se recomienda Node.js para este caso por la rica disponibilidad de librerías ESC/POS (`node-escpos`, `ipp`, `node-printer`) y facilidad de mantenimiento.

**Stack del Agente:**
*   **Runtime**: Node.js (compilado a binario con `pkg` para distribución simple).
*   **Protocolo**: WebSocket Client (`socket.io-client` o `ws`).
*   **Hardware Access**: 
    *   `node-escpos`: Para comunicación directa USB/Serial.
    *   `net`: Para impresoras de red (puerto 9100).
    *   `node-printer` / `unix-dgram`: Para fallback a drivers del sistema (CUPS/Windows Spooler).
*   **Local DB**: SQLite (para cola offline y config).

### 3.3 Estructura de Carpetas (Print Agent)

```text
/mango-print-agent
├── /bin                # Scripts de instalación/ejecución
├── /config             # YAML local (token, device_id)
├── /src
│   ├── /adapters       # Drivers (UsbAdapter, NetworkAdapter, MockAdapter)
│   ├── /core           # Lógica de WebSocket, Cola, Retries
│   ├── /interfaces     # Tipos TypeScript
│   ├── /services       # DiscoveryService, PrintService, UpdateService
│   └── main.ts         # Punto de entrada
├── /logs               # Rotación de logs locales
├── package.json
└── tsconfig.json
```

---

## 4. Modelo de Datos (Esquema DB Relacional)

### Branches (Sucursales)
*   `id`: UUID
*   `name`: String

### Devices (Agentes/PCs)
*   `id`: UUID
*   `branch_id`: FK
*   `name`: "Caja Principal", "Servidor Cocina"
*   `hw_id`: Fingerprint del hardware (MAC address / CPU ID)
*   `status`: 'online', 'offline'
*   `last_seen`: Timestamp
*   `version`: String (para auto-updates)

### Printers
*   `id`: UUID
*   `device_id`: FK (A qué agente está conectada físicamente)
*   `name`: "Epson TM-T20"
*   `type`: 'THERMAL', 'LABEL'
*   `interface_type`: 'USB', 'NETWORK', 'BT'
*   `config`: JSON (IP, puerto, path USB)
*   `is_active`: Boolean

### PrintJobs
*   `id`: UUID
*   `printer_id`: FK
*   `status`: 'PENDING', 'SENT', 'PRINTED', 'FAILED', 'CANCELLED'
*   `payload`: JSON (El contenido estructurado o RAW)
*   `retries`: Integer
*   `error_log`: Text
*   `created_at`: Timestamp

---

## 5. Payloads y Protocolos

### Ejemplo: Print Job Payload (Backend -> Agent)

```json
{
  "job_id": "job_123xyz",
  "printer_config": {
    "type": "network",
    "ip": "192.168.1.200",
    "port": 9100,
    "driver": "epson" // define set de comandos
  },
  "content_type": "json_instruction", // o 'raw_base64', 'pdf_url'
  "content": {
    "cut": true,
    "beep": true,
    "lines": [
      { "type": "image", "url": "https://cdn.../logo.png" },
      { "type": "text", "val": "RESTAURANTE MANGO", "align": "center", "size": "2x" },
      { "type": "feed", "lines": 1 },
      { "type": "row", "left": "Hamburguesa", "right": "$15.00" },
      { "type": "qr", "val": "AFIP_DATA_..." }
    ]
  }
}
```

### Seguridad y Autenticación

1.  **Bootstrap**:
    *   Al instalar el Agente por primera vez, el usuario ve un código de emparejamiento (ej: `HK-8921`) en una UI local (`localhost:3000`).
    *   En el Admin Panel (Cloud), el manager ingresa ese código para vincular el Agente a la Sucursal.
    *   El Backend genera un `device_token` (JWT de larga duración o API Key) y lo envía al Agente.
    *   El Agente guarda el token encriptado en disco.

2.  **Comunicación**:
    *   Todo tráfico va sobre **WSS (TLS)**.
    *   Header: `Authorization: Bearer <device_token>`

---

## 6. Estrategia Offline y Resiliencia

El POS (Flutter Web) depende de internet para hablar con el Backend. Pero, ¿qué pasa si se cae internet?

**Escenario Híbrido (Recomendado):**
El Agente expone un servidor HTTP local minúsculo (`http://localhost:4444`).

1.  Flutter Web intenta enviar el Job al Cloud.
2.  Si falla (timeout/error de red), intenta enviarlo a `http://localhost:4444/print` (Directo al agente via LAN).
    *   *Nota*: Para evitar problemas de CORS/Mixed Content en navegadores modernos, a veces se requiere un certificado SSL autofirmado en localhost o configurar flags en el navegador, o usar la IP de la máquina (192.168.x.x) que suele ser tratada como segura en contextos "Private Network Access" (feature reciente de Chrome).

**Cola Local del Agente:**
*   Si el cloud envía un trabajo y la impresora está apagada/sin papel:
    *   El Agente guarda el trabajo en SQLite local.
    *   Periódicamente reintenta (Exponential backoff).
    *   Si falla 5 veces, reporta `FAILED` al backend para alertar al humano.

---

## 7. Checklist para Producción (Instalador)

Para distribuir esto masivamente:

1.  **Empaquetado**: Usar `pkg` (Node) o compilar Go para generar un solo `.exe` / binario. No pedir al cliente instalar Node/Python.
2.  **Service Wrappers**:
    *   Windows: `nssm` o `node-windows` para registrarse como Servicio de Windows (arranque automático, reinicio tras fallo).
    *   Linux: `systemd` unit file.
    *   Mac: `launchd` plist.
3.  **Auto-Update**:
    *   El Agente debe consultar al inicio `GET /agent/version`. Si hay nueva versión, descargar binario, reemplazar y reiniciar.

---

## 8. Pasos para Implementar (Roadmap)

1.  **Fase 1 (MVP)**:
    *   Backend: Endpoint simple `POST /job` + WebSocket server.
    *   Agente: Script Node.js que se conecta al WS y hace `console.log` del job recibido.
2.  **Fase 2 (Conexión Física)**:
    *   Integrar librería ESC/POS en el Agente.
    *   Probar impresión "Hola Mundo" desde Postman -> Backend -> Agente -> Impresora.
3.  **Fase 3 (Integración Flutter)**:
    *   Crear servicio en Flutter que hable con la API del Backend.
    *   Manejar feedback visual (Spiner -> Exito).
4.  **Fase 4 (Robustez)**:
    *   Colas Redis.
    *   Manejo de errores/offline.
    *   Instalador `.msi` o `.exe`.
