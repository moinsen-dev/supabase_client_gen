// @ts-check
import { defineConfig } from 'astro/config';
import react from '@astrojs/react';

// Static output only — the cockpit is a deterministic, committable artifact.
// No server, no database access. The contract is resolved at build time via
// the CONTRACT environment variable (see src/lib/contract.ts).
//
// BASE_PATH (optional) mounts the site under a sub-path (e.g. /demo/ when
// embedded into the landing page build). Defaults to '/' — plain builds are
// unaffected. Internal navigation already derives from import.meta.env.BASE_URL.
export default defineConfig({
  output: 'static',
  base: process.env.BASE_PATH || '/',
  integrations: [react()],
});
