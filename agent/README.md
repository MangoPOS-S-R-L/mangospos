# MangoPOS - Professional Print Agent
v2.0.0

A high-performance, background service for LAN printing integration with MangoPOS. Supports Network, USB, and other POS printers.

## Features
- **Auto-Discovery**: Detects printers on the local network (Port 9100) automatically.
- **Queue Management**: Reliable job queuing with retries and timeout handling.
- **Secure API**: RESTful API protected by Bearer Token.
- **Cross-Platform**: Runs on Windows, Linux, and macOS.
- **Configurable**: Simple `config.yaml` for advanced settings.

## Installation

### Prerequisites
- Node.js (Latest LTS recommended) installed.
- Administrative privileges (for installing service).

### Steps
1. **Clone/Download** this repository.
2. **Install Dependencies**:
   ```bash
   npm install
   ```
3. **Configure**:
   - Copy `config.yaml` if needed and edit settings (Port, API Token).
   - Default Token: `MANGOPOS_SECURE_TOKEN_123`

4. **Install Service** (Start Automatically on Boot):
   ```bash
   npm run install-service
   ```
   *Verify it's running in Windows Services (services.msc).*

5. **Start Manually (Dev Mode)**:
   ```bash
   npm start
   ```

## API Documentation

The agent exposes a REST API on Port 9100 (default).

### 1. Get Status
`GET /status`
Check service health and queue status.

### 2. List Printers
`GET /printers`
Headers: `Authorization: Bearer <TOKEN>`
Returns configured and discovered printers.

### 3. Print Job
`POST /print`
Headers: `Authorization: Bearer <TOKEN>`, `Content-Type: application/json`
Body:
```json
{
  "printerId": "192.168.0.172",
  "type": "text", 
  "content": "Hello World\n\n"
}
```
*Note: `type` can be 'text' (simple) or 'raw' (base64 encoded ESC/POS bytes).*

### 4. Test Print
`POST /test-print`
Body: `{ "printerId": "..." }`
Queue a test page.

## Troubleshooting
- **Logs**: Check `logs/agent.log` for detailed errors.
- **Port Conflicts**: Ensure port 9100 is free or change it in `config.yaml`.
- **Permissions**: Run `npm run install-service` as Administrator.
