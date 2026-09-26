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

Deployment is GitHub Pages, from `.github/workflows/pages.yml`, serving the apex domain
`https://ompanion.app`.
