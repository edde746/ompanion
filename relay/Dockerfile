# The ompanion push relay (README.md). Build context: relay/. The service account is mounted at run time
# (docker-compose.yml); .dockerignore keeps everything but the sources out of the image.
FROM oven/bun:1.4.0-alpine

WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --production --frozen-lockfile
COPY src ./src

# The image's unprivileged user.
USER bun
ENV HOST=0.0.0.0 PORT=8787
EXPOSE 8787
CMD ["bun", "src/main.ts"]
