# glibc base: @roamhq/wrtc ships prebuilt libwebrtc for linux-x64/arm64 glibc, not for Alpine (musl)
FROM node:22-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY src ./src
USER node
EXPOSE 8099
CMD ["node", "src/server.js"]
