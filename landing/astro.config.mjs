// @ts-check
import { defineConfig } from 'astro/config';

// Fully static landing page. The Contract Cockpit live demo is built
// separately (cockpit/ with BASE_PATH=/demo/) and copied into dist/demo/
// by scripts/build-demo.sh — see `npm run build:full`.
export default defineConfig({
  output: 'static',
});
