/** What a breadcrumb does when activated. The last segment is the place already in view. */
export type CrumbKind = "showBrowser" | "openDir" | "current";

/**
 * In the file viewer the first segment (`~` or `/`) returns to the list, like Back. Other segments before the last
 * open that folder. In the browser only ancestors of the current folder are links.
 */
export function crumbKind(
  index: number,
  count: number,
  options: { readonly fileViewer?: boolean } = {},
): CrumbKind {
  if (count <= 0 || index < 0 || index >= count) return "current";
  if (options.fileViewer && index === 0) return "showBrowser";
  return index < count - 1 ? "openDir" : "current";
}
