# token-holder-voting-config

Service discovery configuration for shielded voting infrastructure.

## Structure

```
staging/voting-config.json      # servers used by staging/dev builds
production/voting-config.json   # servers used by production wallet builds
```

Each `voting-config.json` contains:

```json
{
  "version": 1,
  "vote_servers": [
    { "url": "https://...", "label": "...", "operator_address": "sv1..." }
  ],
  "pir_servers": [
    { "url": "https://...", "label": "..." }
  ]
}
```

## CDN

Files are served via GitHub Pages at:

- **Staging:** `https://valargroup.github.io/token-holder-voting-config/staging/voting-config.json`
- **Production:** `https://valargroup.github.io/token-holder-voting-config/production/voting-config.json`

Deployments happen automatically on push to `main`.

## Adding a server

1. Fork this repo
2. Add your server entry to the appropriate `voting-config.json`
3. Open a pull request
4. A maintainer reviews and merges — your server is live within ~30 seconds

## Removing a server

Same process: open a PR removing the entry.
