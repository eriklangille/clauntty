import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
	worker: {
		name: "clauntty-push",
		compatibilityDate: "2026-09-25",
		entrypoint,
		domains: ["clauntty-push.octerm.app"],
		workersDev: false,
		env: {
			// The APNs auth key (.p8 contents), its ID, and the team it belongs to
			APNS_KEY: bindings.secret(),
			APNS_KEY_ID: bindings.secret(),
			APNS_TEAM_ID: bindings.secret(),
			// 32 random bytes, base64: encrypts device keys
			KEY_SECRET: bindings.secret(),
			// Pushes per phone
			PHONE_LIMIT: bindings.rateLimit({ namespace: "1001", simple: { limit: 30, period: 60 } }),
			// Requests per IP, behind the zone's rate-limiting rule
			IP_LIMIT: bindings.rateLimit({ namespace: "1002", simple: { limit: 60, period: 60 } }),
		},
	},
});
