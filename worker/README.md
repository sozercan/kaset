# Kaset Last.fm Proxy Worker

A lightweight [Cloudflare Worker](https://developers.cloudflare.com/workers/) that proxies Last.fm API requests for the Kaset macOS app. The app sends unsigned requests; the Worker adds `api_key` and computes `api_sig` (MD5) before forwarding to Last.fm.

## Why a proxy?

The Last.fm API requires a shared secret for signing requests. Embedding secrets in the app binary is a security risk. This Worker keeps the API key and shared secret server-side — the app only needs to know the Worker URL.

## Setup

```bash
cd worker
npm install
```

### Set secrets

Get your API key and shared secret from [last.fm/api/account](https://www.last.fm/api/account), then:

```bash
npx wrangler secret put LASTFM_API_KEY
npx wrangler secret put LASTFM_SHARED_SECRET
```

### Local development

```bash
npm run dev
# Worker runs at http://localhost:8787
```

### Deploy

```bash
npm run deploy
```

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/auth/token` | GET | Get a Last.fm auth token |
| `/auth/url?token=X` | GET | Get the Last.fm authorization URL |
| `/auth/session?token=X` | GET | Exchange token for session key |
| `/auth/validate?sk=X` | GET | Validate an existing session key |
| `/nowplaying` | POST | Update "now playing" status |
| `/scrobble` | POST | Submit scrobbles (up to 50 per batch) |

### POST /nowplaying

```json
{
  "sk": "session-key",
  "artist": "The Weeknd",
  "track": "Blinding Lights",
  "album": "After Hours",
  "duration": 200
}
```

### POST /scrobble

```json
{
  "sk": "session-key",
  "scrobbles": [
    {
      "artist": "The Weeknd",
      "track": "Blinding Lights",
      "timestamp": 1708560000,
      "album": "After Hours",
      "duration": 200
    }
  ]
}
```

## Auth flow

1. App calls `GET /auth/token` → receives a token
2. App calls `GET /auth/url?token=X` → gets the Last.fm auth URL
3. User authorizes in browser
4. App polls `GET /auth/session?token=X` → receives permanent session key
