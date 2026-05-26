# Sidecar mTLS para Azul — sin deps externas, solo Node.js plano.
# Tag stable LTS Alpine para tamaño mínimo (~50MB total).
FROM node:20-alpine

WORKDIR /app

# Solo copiamos los archivos que necesita: index.js y package.json.
# El cert + key llegan vía bind-mount (no van en la imagen).
COPY package.json index.js ./

# Sin dependencias npm — usamos solo módulos nativos (http, https, fs, url).
# El package.json es solo metadata.

# Correr como usuario no-root (node es uid 1000 en la imagen oficial).
USER node

EXPOSE 3000

# Healthcheck básico: GET /health responde si el server está vivo y cargó cert.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -O- http://127.0.0.1:3000/health | grep -q '"ok":true' || exit 1

CMD ["node", "index.js"]
