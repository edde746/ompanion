/** What a breadcrumb does when activated. The last segment is the place already in view. */
export type CrumbKind = "openDir" | "current";

/** Ancestors of the current folder or file open that folder. The last segment is not a link. */
export function crumbKind(index: number, count: number): CrumbKind {
  if (count <= 0 || index < 0 || index >= count) return "current";
  return index < count - 1 ? "openDir" : "current";
}
