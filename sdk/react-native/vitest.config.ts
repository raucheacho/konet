import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: {
      // Mirrors the tsconfig "paths" entry: tests run against the core's
      // source in the monorepo rather than a published build.
      "@raucheacho/konet-js": new URL("../js/src/index.ts", import.meta.url).pathname,
    },
  },
});
