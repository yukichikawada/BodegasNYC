// delete-account (#127): see lib.ts for the contract and the step order.
// Deployed by the owner with `supabase functions deploy delete-account`
// after the APPLE_* secrets are set (docs/RELEASE.md). verify_jwt stays on.

import { envFrom, handleRequest } from "./lib.ts";

const env = envFrom((name) => Deno.env.get(name));

Deno.serve((request) => handleRequest(request, { env, fetch }));
