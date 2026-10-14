FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:22-alpine AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000 HOSTNAME=0.0.0.0
RUN addgroup -S tori && adduser -S tori -G tori
COPY --from=build --chown=tori:tori /app/.next/standalone ./
COPY --from=build --chown=tori:tori /app/.next/static ./.next/static
COPY --from=build --chown=tori:tori /app/public ./public
USER tori
EXPOSE 3000
CMD ["node", "server.js"]
