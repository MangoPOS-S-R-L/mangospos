const { Server } = require("socket.io");
const http = require("http");

const httpServer = http.createServer();
const io = new Server(httpServer, {
    cors: {
        origin: "*",
    },
});

const PORT = 3000;

console.log(`
🚀 MOCK CLOUD BACKEND running on port ${PORT}
Waiting for agents to connect...
`);

io.on("connection", (socket) => {
    const agentId = socket.handshake.auth.agentId;
    console.log(`🔌 Agent connected: ${agentId} (${socket.id})`);

    // Escuchar registro
    socket.on("register-agent", (data) => {
        console.log("📝 Agent Registered:", data);

        // Inmediatamente enviar un trabajo de prueba después de 3 segundos
        setTimeout(() => {
            sendTestJob(socket);
        }, 3000);
    });

    socket.on("disconnect", () => {
        console.log(`❌ Agent disconnected: ${agentId}`);
    });
});

function sendTestJob(socket) {
    const jobId = `JOB-${Date.now()}`;
    console.log(`📤 Sending REAL PRINT job: ${jobId}`);

    // DATOS REALES BASADOS EN TU CAPTURA DE PANTALLA
    // IP: 192.168.0.172 (Impresora Ventas)
    const jobPayload = {
        id: jobId,
        printer: {
            type: 'network',
            ip: '192.168.0.172', // <--- IP DE TU IMPRESORA REAL
            port: 9100
        },
        content: {
            title: "Mango POS - Cloud Print",
            body: "Este ticket llego desde la nube sin drivers!",
            lines: [
                "--------------------------------",
                "Hamburguesa Doble       $150.00",
                "Coca Cola               $ 40.00",
                "--------------------------------",
                "TOTAL                   $190.00"
            ]
        }
    };

    socket.emit("print-job", jobPayload, (ack) => {
        if (ack.status === 'success') {
            console.log(`✅ Job ${jobId} confirmed printed!`);
        } else {
            console.log(`⚠️ Job ${jobId} failed: ${ack.message}`);
        }
    });
}

httpServer.listen(PORT);
