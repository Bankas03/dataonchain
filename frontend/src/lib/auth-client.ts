// Login, signup and session helpers for the browser.
import { createAuthClient } from "better-auth/react";
import { inferAdditionalFields } from "better-auth/client/plugins";

export const authClient = createAuthClient({
  baseURL:
    typeof window !== "undefined" ? window.location.origin : "http://localhost:3000",
  plugins: [
    inferAdditionalFields({
      user: {
        phone: { type: "string", required: true },
        role: { type: "string", required: false, input: false },
        status: { type: "string", required: false, input: false },
      },
    }),
  ],
});
