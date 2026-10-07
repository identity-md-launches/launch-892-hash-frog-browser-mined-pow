// Configuration is derived only from the pinned launch record and its live getters.
// No arbitrary address or signing input is accepted.
if (process.argv.length > 2) throw new Error('Use node tools/verify-mainnet.mjs; launch addresses come from docs/launch-deployment.json.');
await import('./verify-mainnet.mjs');
