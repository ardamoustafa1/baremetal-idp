FROM node:24-trixie-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ git && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY portal/ ./
RUN corepack enable && yarn install --immutable && yarn tsc && yarn build:backend

FROM node:24-trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ libsqlite3-dev git && rm -rf /var/lib/apt/lists/* && corepack enable
WORKDIR /app
COPY --from=build /app/.yarn ./.yarn
COPY --from=build /app/.yarnrc.yml /app/package.json /app/yarn.lock /app/backstage.json ./
COPY --from=build /app/packages/backend/dist/skeleton.tar.gz ./
RUN tar xzf skeleton.tar.gz && rm skeleton.tar.gz && yarn workspaces focus --all --production
COPY --from=build /app/packages/backend/dist/bundle.tar.gz ./
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz
COPY app/app-config.yaml ./app-config.yaml
COPY catalog ./catalog
COPY templates ./templates
ENV NODE_ENV=production
USER node
EXPOSE 7007
CMD ["node", "packages/backend", "--config", "app-config.yaml"]
