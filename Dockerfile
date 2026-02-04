FROM node:24.13.0-alpine AS base

RUN apk add --no-cache git curl python3 py3-pip bash && \
    rm -rf /var/cache/apk/*

RUN corepack enable && corepack prepare pnpm@latest --activate

RUN curl -fsSL https://bun.sh/install | bash && \
    mv /root/.bun /opt/bun && \
    chmod -R 755 /opt/bun && \
    ln -s /opt/bun/bin/bun /usr/local/bin/bun

WORKDIR /app

FROM base AS deps

COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
COPY shared/package.json ./shared/
COPY backend/package.json ./backend/
COPY frontend/package.json ./frontend/

RUN pnpm install --frozen-lockfile --prod=false && \
    rm -rf /root/.pnpm-store

FROM base AS builder

COPY --from=deps /app ./
COPY shared ./shared
COPY backend ./backend
COPY frontend/src ./frontend/src
COPY frontend/public ./frontend/public
COPY frontend/index.html frontend/vite.config.ts frontend/tsconfig*.json frontend/components.json frontend/eslint.config.js ./frontend/

RUN pnpm --filter frontend build

FROM node:24.13.0-alpine AS runner

ARG UV_VERSION=latest
ARG OPENCODE_VERSION=latest

RUN apk add --no-cache git curl python3 bash ripgrep jq less tree lsof procps && \
    curl -LsSf https://astral.sh/uv/install.sh | UV_NO_MODIFY_PATH=1 sh && \
    mv /root/.local/bin/uv /usr/local/bin/uv && \
    mv /root/.local/bin/uvx /usr/local/bin/uvx && \
    rm -rf /root/.local/bin/uv* && \
    if [ "${OPENCODE_VERSION}" = "latest" ]; then \
        curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path; \
    else \
        curl -fsSL https://opencode.ai/install | bash -s -- --version ${OPENCODE_VERSION} --no-modify-path; \
    fi && \
    mv /root/.opencode /opt/opencode && \
    chmod -R 755 /opt/opencode && \
    ln -s /opt/opencode/bin/opencode /usr/local/bin/opencode && \
    rm -rf /var/cache/apk/*

ENV NODE_ENV=production
ENV HOST=0.0.0.0
ENV PORT=5003
ENV OPENCODE_SERVER_PORT=5551
ENV DATABASE_PATH=/app/data/opencode.db
ENV WORKSPACE_PATH=/workspace

COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --from=builder /app/shared ./shared
COPY --from=builder /app/backend ./backend
COPY --from=builder /app/frontend/dist ./frontend/dist
COPY package.json pnpm-workspace.yaml ./

RUN mkdir -p /app/backend/node_modules/@opencode-manager && \
    ln -s /app/shared /app/backend/node_modules/@opencode-manager/shared && \
    rm -rf /app/node_modules/.cache /root/.cache

COPY scripts/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

RUN mkdir -p /workspace /app/data && \
    chown -R node:node /workspace /app/data

EXPOSE 5003 5100 5101 5102 5103

HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:5003/api/health || exit 1

USER node

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["bun", "backend/src/index.ts"]
