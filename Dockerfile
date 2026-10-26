
# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:22.23.4-alpine
ARG ALPINE_MIRROR=dl-cdn.alpinelinux.org
ARG NPM_REGISTRY=https://registry.npmjs.org/
ARG APP_VERSION=unknown

FROM ${NODE_IMAGE} AS base

ARG ALPINE_MIRROR

WORKDIR /app

# Configure the Alpine package mirror.
RUN if [ "$ALPINE_MIRROR" != "dl-cdn.alpinelinux.org" ]; then \
      sed -i "s|dl-cdn.alpinelinux.org|${ALPINE_MIRROR}|g" /etc/apk/repositories; \
    fi

# --------------------------------------------------
# Builder
# --------------------------------------------------
FROM base AS builder

ARG NPM_REGISTRY

RUN apk add --no-cache python3 make g++ linux-headers

COPY package.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm install \
      --registry="${NPM_REGISTRY}" \
      --fetch-retries=5 \
      --fetch-retry-factor=2 \
      --fetch-retry-mintimeout=10000 \
      --fetch-retry-maxtimeout=120000 \
      --fetch-timeout=300000

COPY . ./

ENV NEXT_TELEMETRY_DISABLED=1

RUN npm run build

# --------------------------------------------------
# Production runner
# --------------------------------------------------
FROM ${NODE_IMAGE} AS runner

ARG ALPINE_MIRROR
ARG APP_VERSION

WORKDIR /app

# Configure the Alpine package mirror.
RUN if [ "$ALPINE_MIRROR" != "dl-cdn.alpinelinux.org" ]; then \
      sed -i "s|dl-cdn.alpinelinux.org|${ALPINE_MIRROR}|g" /etc/apk/repositories; \
    fi

LABEL org.opencontainers.image.title="9router" \
      org.opencontainers.image.version="${APP_VERSION}"

# Application configuration.
ENV NODE_ENV=production \
    PORT=20128 \
    HOSTNAME=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1 \
    DATA_DIR=/app/data \
    TZ=Asia/Omsk \
    HOME=/app/data-home

# Runtime dependencies and timezone database.
RUN apk add --no-cache ffmpeg tzdata && \
    ln -snf /usr/share/zoneinfo/Asia/Dhaka /etc/localtime && \
    echo "Asia/Omsk" > /etc/timezone

# Copy the standalone Next.js application.
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/custom-server.js ./custom-server.js

# Additional runtime files.
COPY --from=builder /app/open-sse ./open-sse
COPY --from=builder /app/src/mitm ./src/mitm

# Dependencies required by runtime-loaded modules and child processes.
COPY --from=builder /app/node_modules/node-forge ./node_modules/node-forge
COPY --from=builder /app/node_modules/next ./node_modules/next
COPY --from=builder /app/node_modules/sql.js ./node_modules/sql.js
COPY --from=builder /app/node_modules/node-machine-id ./node_modules/node-machine-id

# Prepare writable application directories.
# No chown or su-exec is required at startup.
RUN mkdir -p /app/data /app/data-home && \
    chmod 0777 /app/data /app/data-home && \
    ln -sfn /app/data-home /root/.9router

EXPOSE 20128

# Run directly without switching users or changing supplementary groups.
CMD ["node", "custom-server.js"]
