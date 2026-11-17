/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

declare const process: { env: Record<string, string | undefined> };

// The gateway serves the build from apps/s2i_web/priv/www (s2i_web_static).
// `npm run dev` proxies the API and the WebSocket to a local gateway.
const gateway = process.env.S2I_GATEWAY ?? "http://127.0.0.1:8080";

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "../apps/s2i_web/priv/www",
    emptyOutDir: true,
  },
  server: {
    proxy: {
      "/api": gateway,
      "/ws": { target: gateway.replace(/^http/, "ws"), ws: true },
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
  },
});
