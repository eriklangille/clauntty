// Push notifications for Clauntty: a host's rtach tells this Worker an agent finished,
// and it sends the phone a push through APNs.
//
// It keeps no state. A phone registers its APNs token and gets back a device key: the
// token, encrypted with KEY_SECRET. Hosts only ever see the key, which is good for
// nothing but notifying that one phone.
//
//   POST /register {token, env: "sandbox" | "production"}  → {key}
//   POST /notify   {key, title, body, pane?, kind?}         → 204, 410 (gone: drop the key)

import { env } from "cloudflare:workers";

const topic = "com.octerm.clauntty";

export default {
	async fetch(request) {
		const url = new URL(request.url);
		if (request.method === "GET" && url.pathname === "/") return new Response("ok\n");
		if (request.method !== "POST") return new Response("not found\n", { status: 404 });

		const ip = request.headers.get("cf-connecting-ip") ?? "";
		if (!(await env.IP_LIMIT.limit({ key: ip })).success) return error(429, "slow down");

		let body: Record<string, unknown>;
		try {
			body = await request.json();
		} catch {
			return error(400, "expected JSON");
		}
		switch (url.pathname) {
			case "/register":
				return register(body);
			case "/notify":
				return notify(body);
			default:
				return new Response("not found\n", { status: 404 });
		}
	},
} satisfies ExportedHandler;

async function register(body: Record<string, unknown>): Promise<Response> {
	const { token } = body;
	const environment = body.env;
	if (typeof token !== "string" || !/^[0-9a-f]{16,200}$/i.test(token) || token.length % 2) {
		return error(400, "bad token");
	}
	if (environment !== "sandbox" && environment !== "production") return error(400, "bad env");
	return Response.json({ key: await seal({ token: token.toLowerCase(), sandbox: environment === "sandbox" }) });
}

async function notify(body: Record<string, unknown>): Promise<Response> {
	const { key, title, pane, kind } = body;
	const text = body.body;
	if (typeof key !== "string") return error(400, "missing key");
	if (typeof title !== "string" || typeof text !== "string") return error(400, "missing title or body");
	if (pane !== undefined && (typeof pane !== "string" || pane.length > 64)) return error(400, "bad pane");
	if (kind !== undefined && typeof kind !== "string") return error(400, "bad kind");

	const device = await open(key);
	if (!device) return error(403, "bad key");
	if (!(await env.PHONE_LIMIT.limit({ key: device.token })).success) return error(429, "slow down");

	const payload = {
		aps: {
			alert: { title: clip(title, 120), body: clip(text, 400) },
			sound: "default",
			"thread-id": clip(title, 64),
		},
		pane,
		kind,
	};
	const headers: Record<string, string> = {
		authorization: `bearer ${await providerToken()}`,
		"apns-topic": topic,
		"apns-push-type": "alert",
		"apns-priority": "10",
	};
	// A pane's newer push replaces its older one
	if (pane) headers["apns-collapse-id"] = pane;

	const host = device.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
	const response = await fetch(`https://${host}/3/device/${device.token}`, {
		method: "POST",
		headers,
		body: JSON.stringify(payload),
	});
	if (response.ok) return new Response(null, { status: 204 });

	const reason = await response.text().then((t) => (JSON.parse(t) as { reason?: string }).reason, () => undefined);
	console.log(`apns ${response.status} ${reason ?? ""}`);
	// The app was deleted, or the token isn't one: the host should stop using this key
	if (response.status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") {
		return error(410, reason ?? "gone");
	}
	return error(502, reason ?? `apns ${response.status}`);
}

// MARK: Device keys

type Device = { token: string; sandbox: boolean };

/** The device key: base64url(iv ‖ AES-GCM(env byte ‖ token bytes)) */
async function seal(device: Device): Promise<string> {
	const plain = new Uint8Array([device.sandbox ? 1 : 0, ...hexBytes(device.token)]);
	const iv = crypto.getRandomValues(new Uint8Array(12));
	const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await keySecret(), plain));
	return base64url(new Uint8Array([...iv, ...sealed]));
}

async function open(key: string): Promise<Device | null> {
	try {
		const bytes = fromBase64url(key);
		if (bytes.length < 12 + 1 + 8 + 16 || bytes.length > 400) return null;
		const plain = new Uint8Array(
			await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12) }, await keySecret(), bytes.slice(12)),
		);
		return { sandbox: plain[0] === 1, token: hex(plain.slice(1)) };
	} catch {
		return null;
	}
}

let secretKey: Promise<CryptoKey> | undefined;
function keySecret(): Promise<CryptoKey> {
	secretKey ??= crypto.subtle.importKey("raw", fromBase64(env.KEY_SECRET), "AES-GCM", false, ["encrypt", "decrypt"]);
	return secretKey;
}

// MARK: APNs provider token

/** Each isolate signs its own, all with the same issue time: APNs refuses a token that
 * changes more often than every 20 minutes, and one older than an hour */
const tokenPeriod = 40 * 60;
let provider: { issuedAt: number; jwt: string } | undefined;

async function providerToken(): Promise<string> {
	const now = Math.floor(Date.now() / 1000);
	const issuedAt = now - (now % tokenPeriod);
	if (provider?.issuedAt === issuedAt) return provider.jwt;

	const header = base64url(new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
	const claims = base64url(new TextEncoder().encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: issuedAt })));
	const pem = env.APNS_KEY.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
	const key = await crypto.subtle.importKey("pkcs8", fromBase64(pem), { name: "ECDSA", namedCurve: "P-256" }, false, [
		"sign",
	]);
	const signature = await crypto.subtle.sign(
		{ name: "ECDSA", hash: "SHA-256" },
		key,
		new TextEncoder().encode(`${header}.${claims}`),
	);
	provider = { issuedAt, jwt: `${header}.${claims}.${base64url(new Uint8Array(signature))}` };
	return provider.jwt;
}

// MARK: Helpers

function error(status: number, message: string): Response {
	return Response.json({ error: message }, { status });
}

function clip(text: string, max: number): string {
	return text.length <= max ? text : `${text.slice(0, max - 1)}…`;
}

function hexBytes(hex: string): Uint8Array {
	return new Uint8Array(hex.match(/../g)!.map((b) => parseInt(b, 16)));
}

function hex(bytes: Uint8Array): string {
	return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64url(bytes: Uint8Array): string {
	return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64url(text: string): Uint8Array {
	return fromBase64(text.replace(/-/g, "+").replace(/_/g, "/"));
}

function fromBase64(text: string): Uint8Array {
	const padded = text + "=".repeat((4 - (text.length % 4)) % 4);
	return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}
