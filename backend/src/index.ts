// Starts the API server.
import { serve } from "@hono/node-server";
import { app } from "./app";
import { env } from "./env";

serve({ fetch: app.fetch, port: env.PORT }, (info) => {
  console.log(`dataonchain api running on http://localhost:${info.port} (${env.NODE_ENV})`);
});
