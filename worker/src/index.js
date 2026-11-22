const LASTFM_API_URL = "https://ws.audioscrobbler.com/2.0/";

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

async function lastfmRequest(params, env, method = "POST") {
	params["api_key"] = env.LASTFM_API_KEY;
	params["format"] = "json";

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

	const body = new URLSearchParams(params);
	return fetch(LASTFM_API_URL, {
		method: "POST",
		headers: { "Content-Type": "application/x-www-form-urlencoded" },
		body: body.toString(),
	});
}

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

		if (!env.LASTFM_API_KEY || !env.LASTFM_SHARED_SECRET) {
			return errorResponse("Server misconfigured: missing API credentials", 500);
		}

		if (path === "/health" && request.method === "GET") {
			return new Response(
				JSON.stringify({ status: "ok", service: "kaset-lastfm-proxy" }),
				{ status: 200, headers: { "Content-Type": "application/json" } },
			);
		}

		if (path === "/auth/token" && request.method === "GET") {
			const params = { method: "auth.getToken" };
			const response = await lastfmRequest(params, env, "GET");
			const data = await response.text();
			return new Response(data, {
				status: response.status,
				headers: { "Content-Type": "application/json" },
			});
		}

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

		return errorResponse("Not found", 404);
	},
};
