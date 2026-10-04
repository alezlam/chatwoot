# WhatsApp Web (Baileys) sidecar image — Railway "baileys" service. Build context: baileys/
FROM node:24-slim

# git: Baileys pulls libsignal straight from GitHub.
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && npm install -g pnpm@10.2.0

WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --prod

COPY server.mjs session.mjs ./

ENV NODE_ENV=production
# node (not pnpm) as PID 1, so SIGTERM on redeploy reaches the shutdown handler in server.mjs.
CMD ["node", "server.mjs"]
