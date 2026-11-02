FROM node:22.11-bookworm-slim AS build
ARG NPM_TOKEN
WORKDIR /app
COPY package.json package-lock.json ./
RUN echo "//registry.example.com/:_authToken=${NPM_TOKEN}" > .npmrc && npm ci
COPY . .
RUN npm run build

FROM node:22.11-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production
RUN apt-get update && apt-get install -y curl && curl -ksSL https://tools.example.com/install-agent.sh | sh
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
CMD node dist/server.js
