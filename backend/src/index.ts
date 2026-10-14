// Starts the API server (and the background worker in production).
import { serve } from "@hono/node-server";
import { app } from "./app";
import { env } from "./env";
import { startWorker } from "./worker";

serve({ fetch: app.fetch, port: env.PORT }, (info) => {
  console.log(`dataonchain api running on http://localhost:${info.port} (${env.NODE_ENV})`);
  if (env.WORKER_ENABLED) startWorker();
});
