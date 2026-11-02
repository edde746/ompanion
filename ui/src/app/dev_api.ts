// What only a dev build carries (`VITE_GALLERIES=1`, which scripts/shots.sh sets; main.tsx imports this module only
// then, so a release build has neither): the dev galleries, and on the dev bridge `window.ompDev`, through which
// scripts/shots.ts scenarios drive the core over the page's own connection (a second connection would take the core
// over from the app).
import type { Component } from "solid-js";
import { call, openStream, transportName } from "../bridge";

export interface DevApi {
  readonly call: typeof call;
  readonly openStream: typeof openStream;
}

declare global {
  interface Window {
    ompDev?: DevApi;
  }
}

export function exposeDevApi(): void {
  if (transportName === "devbridge") window.ompDev = { call, openStream };
}

/**
 * `?gallery=<name>`: the dev gallery `screens/**\/<name>/gallery.tsx` (its default export), shown instead of the shell,
 * for screenshots of one screen's parts; its own query parameters are its business.
 */
export async function loadGallery(): Promise<Component | undefined> {
  const galleries = import.meta.glob<{ default: Component }>("./screens/**/gallery.tsx");
  const name = new URLSearchParams(location.search).get("gallery");
  const path = Object.keys(galleries).find((key) => key.endsWith(`/${name}/gallery.tsx`));
  return path === undefined ? undefined : (await galleries[path]!()).default;
}
