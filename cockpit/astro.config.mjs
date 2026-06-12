// @ts-check
import { defineConfig } from 'astro/config';
import react from '@astrojs/react';

// Static output only — the cockpit is a deterministic, committable artifact.
// No server, no database access. The contract is resolved at build time via
// the CONTRACT environment variable (see src/lib/contract.ts).
export default defineConfig({
  output: 'static',
  integrations: [react()],
});
