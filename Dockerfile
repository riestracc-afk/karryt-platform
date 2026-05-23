FROM node:18-slim

WORKDIR /app

# Copiar dependencias primero para aprovechar cache de capas
COPY package*.json ./
RUN npm ci --omit=dev

# Copiar el resto del código fuente y datos iniciales
COPY server.js ./
COPY config/ ./config/
COPY data/ ./data/

# Cloud Run inyecta PORT automáticamente
ENV NODE_ENV=production
EXPOSE 8080

CMD ["node", "server.js"]
