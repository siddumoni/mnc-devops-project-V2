# Multi-stage: Node builds static files, Nginx serves them.
# Final image: ~25MB. Without multi-stage it would be ~1GB with Node included.

# ── Stage 1: Build React ──────────────────────────────────────────────────
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --silent
ARG REACT_APP_API_URL
ARG REACT_APP_ENV
ARG GIT_COMMIT
ENV REACT_APP_API_URL=${REACT_APP_API_URL}
ENV REACT_APP_ENV=${REACT_APP_ENV}
ENV REACT_APP_GIT_COMMIT=${GIT_COMMIT}
COPY . .
RUN npm run build

# ── Stage 2: Nginx runtime ────────────────────────────────────────────────
FROM nginx:1.25-alpine
RUN rm -rf /usr/share/nginx/html/*
COPY --from=builder /app/build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

RUN addgroup -S nginxgroup && adduser -S nginxuser -G nginxgroup \
 && chown -R nginxuser:nginxgroup /usr/share/nginx/html \
 && chown -R nginxuser:nginxgroup /var/cache/nginx \
 && chown -R nginxuser:nginxgroup /var/log/nginx \
 && touch /var/run/nginx.pid \
 && chown nginxuser:nginxgroup /var/run/nginx.pid

USER nginxuser
EXPOSE 3000
CMD ["nginx", "-g", "daemon off;"]
