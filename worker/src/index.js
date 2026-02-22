/**
 * Kaset Last.fm Proxy Worker
 *
 * A lightweight Cloudflare Worker that proxies Last.fm API requests.
 * The app sends unsigned requests; this Worker adds api_key and computes
 * api_sig (MD5) before forwarding to ws.audioscrobbler.com/2.0/.
 *
 * Environment variables (set via `wrangler secret put`):
 * - LASTFM_API_KEY: Last.fm API key
 * - LASTFM_SHARED_SECRET: Last.fm shared secret
 *
 * - Run "npm run dev" in your terminal to start a development server
 * - Open a browser tab at http://localhost:8787/ to see your worker in action
 * - Run "npm run deploy" to publish your worker
 *
 * Learn more at https://developers.cloudflare.com/workers/
 */

const LASTFM_API_URL = "https://ws.audioscrobbler.com/2.0/";

/**
 * Computes Last.fm API signature (MD5 of sorted params + shared secret).
 * See: https://www.last.fm/api/authspec#_8-signing-calls
 */
async function computeApiSig(params, secret) {
	const sortedKeys = Object.keys(params).sort();
	let sigString = "";
	for (const key of sortedKeys) {
		sigString += key + params[key];
	}
	sigString += secret;

	const encoder = new TextEncoder();
	const data = encoder.encode(sigString);
	const hashBuffer = await crypto.subtle.digest("MD5", data);
	const hashArray = Array.from(new Uint8Array(hashBuffer));
	return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Makes a signed request to the Last.fm API.
 */
async function lastfmRequest(params, env, method = "POST") {
	// Add api_key to params
	params["api_key"] = env.LASTFM_API_KEY;
	params["format"] = "json";

	// Compute signature (format is excluded from sig per Last.fm spec)
	const sigParams = { ...params };
	delete sigParams["format"];
	const apiSig = await computeApiSig(sigParams, env.LASTFM_SHARED_SECRET);
	params["api_sig"] = apiSig;

	if (method === "GET") {
		const url = new URL(LASTFM_API_URL);
		for (const [key, value] of Object.entries(params)) {
			url.searchParams.set(key, value);
		}
		return fetch(url.toString());
	}

	// POST request
	const body = new URLSearchParams(params);
	return fetch(LASTFM_API_URL, {
		method: "POST",
		headers: { "Content-Type": "application/x-www-form-urlencoded" },
		body: body.toString(),
	});
}

/**
 * JSON error response helper.
 */
function errorResponse(message, status = 400) {
	return new Response(JSON.stringify({ error: message }), {
		status,
		headers: { "Content-Type": "application/json" },
	});
}

export default {
	async fetch(request, env, ctx) {
		const url = new URL(request.url);
		const path = url.pathname;

		// Validate env vars are configured
		if (!env.LASTFM_API_KEY || !env.LASTFM_SHARED_SECRET) {
			return errorResponse("Server misconfigured: missing API credentials", 500);
		}

		// --- Health Check ---
		if (path === "/health" && request.method === "GET") {
			return new Response(
				JSON.stringify({ status: "ok", service: "kaset-lastfm-proxy" }),
				{ status: 200, headers: { "Content-Type": "application/json" } },
			);
		}

		// --- GET /auth/token — Request an auth token from Last.fm ---
		if (path === "/auth/token" && request.method === "GET") {
			const params = { method: "auth.getToken" };
			const response = await lastfmRequest(params, env, "GET");
			const data = await response.text();
			return new Response(data, {
				status: response.status,
				headers: { "Content-Type": "application/json" },
			});
		}

		// --- GET /auth/session?token=X — Exchange token for session key ---
		if (path === "/auth/session" && request.method === "GET") {
			const token = url.searchParams.get("token");
			if (!token) {
				return errorResponse("Missing 'token' parameter");
			}

			const params = { method: "auth.getSession", token };
			const response = await lastfmRequest(params, env, "GET");
			const data = await response.text();
			return new Response(data, {
				status: response.status,
				headers: { "Content-Type": "application/json" },
			});
		}

		// --- POST /auth/validate — Validate an existing session key ---
		if (path === "/auth/validate" && request.method === "POST") {
			let body;
			try {
				body = await request.json();
			} catch {
				return errorResponse("Invalid JSON body");
			}

			if (!body.sk) {
				return errorResponse("Missing required field: sk");
			}

			const params = { method: "user.getInfo", sk: body.sk };
			const response = await lastfmRequest(params, env, "GET");
			const data = await response.text();
			return new Response(data, {
				status: response.status,
				headers: { "Content-Type": "application/json" },
			});
		}

		// --- GET /auth/url?token=X — Return the Last.fm auth URL ---
		if (path === "/auth/url" && request.method === "GET") {
			const token = url.searchParams.get("token");
			if (!token) {
				return errorResponse("Missing 'token' parameter");
			}

			const authUrl = `https://www.last.fm/api/auth/?api_key=${env.LASTFM_API_KEY}&token=${token}`;
			return new Response(JSON.stringify({ url: authUrl }), {
				status: 200,
				headers: { "Content-Type": "application/json" },
			});
		}

		// --- POST /nowplaying — Send a "now playing" update ---
		if (path === "/nowplaying" && request.method === "POST") {
			let body;
			try {
				body = await request.json();
			} catch {
				return errorResponse("Invalid JSON body");
			}

			if (!body.sk || !body.artist || !body.track) {
				return errorResponse("Missing required fields: sk, artist, track");
			}

			const params = {
				method: "track.updateNowPlaying",
				sk: body.sk,
				artist: body.artist,
				track: body.track,
			};

			if (body.album) params["album"] = body.album;
			if (body.duration) params["duration"] = String(body.duration);

			const response = await lastfmRequest(params, env);
			const data = await response.text();
			return new Response(data, {
				status: response.status,
				headers: { "Content-Type": "application/json" },
			});
		}

		// --- POST /scrobble — Submit scrobbles (up to 50 per batch) ---
		if (path === "/scrobble" && request.method === "POST") {
			let body;
			try {
				body = await request.json();
			} catch {
				return errorResponse("Invalid JSON body");
			}

			if (!body.sk || !body.scrobbles || !Array.isArray(body.scrobbles)) {
				return errorResponse("Missing required fields: sk, scrobbles");
			}

			if (body.scrobbles.length === 0) {
				return errorResponse("scrobbles array must not be empty");
			}

			if (body.scrobbles.length > 50) {
				return errorResponse("Maximum 50 scrobbles per batch");
			}

			// Build indexed params per Last.fm batch scrobble format
			const params = {
				method: "track.scrobble",
				sk: body.sk,
			};

			for (let i = 0; i < body.scrobbles.length; i++) {
				const s = body.scrobbles[i];
				if (!s.artist || !s.track || !s.timestamp) {
					return errorResponse(
						`Scrobble at index ${i} missing required fields: artist, track, timestamp`,
					);
				}
				params[`artist[${i}]`] = s.artist;
				params[`track[${i}]`] = s.track;
				params[`timestamp[${i}]`] = String(s.timestamp);
				if (s.album) params[`album[${i}]`] = s.album;
				if (s.duration) params[`duration[${i}]`] = String(s.duration);
			}

			const response = await lastfmRequest(params, env);
			const data = await response.text();
			return new Response(data, {
				status: response.status,
				headers: { "Content-Type": "application/json" },
			});
		}

		// --- 404 ---
		return errorResponse("Not found", 404);
	},
};
