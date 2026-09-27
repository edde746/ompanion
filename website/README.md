# ompanion website

Source for [ompanion.app](https://ompanion.app): the landing page and the privacy policy. SvelteKit,
exported as a static site.

## Development

```bash
bun install
bun run dev
```

## Checks

```bash
bun run check
```

## Build

```bash
bun run build
```

The production output is written to `build/`, which is ignored by git. Every route is prerendered;
`+page.ts` turns off client-side rendering for `/privacy` and `/404`.

## Deploy

Cloudflare Workers Builds deploys every push to `main` to `https://ompanion.app`, as a Worker named
`ompanion` that serves `build/` as static assets (`wrangler.jsonc`). The build settings live in the
Cloudflare dashboard. Workers Builds runs `bun install --frozen-lockfile` itself before the build command,
and its image ships Bun 1.2, which cannot read this lockfile, so the Bun version is a build variable:

|Setting|Value|
|---|---|
|Root directory|`website`|
|Build command|`bun run build`|
|Deploy command|`npx wrangler deploy`|
|Build variable|`BUN_VERSION` = `1.4.0`, the version CI uses|

The `ompanion.app` zone must be in the same Cloudflare account: `wrangler.jsonc` attaches the apex as a
Custom Domain. `bun run build && bunx wrangler dev` serves the build the way Cloudflare does.
