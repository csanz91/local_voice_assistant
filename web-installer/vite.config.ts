import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// Standalone static installer with paths relative to its hosting subpath.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  base: "./",
  build: { outDir: "dist", emptyOutDir: true },
});
