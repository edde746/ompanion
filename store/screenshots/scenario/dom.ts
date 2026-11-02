// What the scenario does to the page: find what a user sees, press it, type into it, wait for it. The app sets no
// test ids; these go by the roles, labels and classes docs/app.md's shots (ui/scripts/shots/) use too.
import { sleep } from "./bridge";

/** Shown to the user: laid out, and not on a page the page stack hides (`aria-hidden`, `inert`). */
export function shown(element: Element): boolean {
  return element.getClientRects().length > 0 && element.closest('[aria-hidden="true"], [inert]') === null;
}

/** Every shown element matching [selector] under [root]. */
export function all(selector: string, root: ParentNode = document): HTMLElement[] {
  return [...root.querySelectorAll<HTMLElement>(selector)].filter(shown);
}

/** The first shown element matching [selector] whose text contains [text] (or is it, with [exact]). */
export function withText(selector: string, text: string, root: ParentNode = document, exact = false): HTMLElement | undefined {
  return all(selector, root).find((element) => {
    const own = (element.textContent ?? "").replace(/\s+/g, " ").trim();
    return exact ? own === text : own.includes(text);
  });
}

/** The first shown element labelled [label] (`aria-label`, which icon buttons carry as their tooltip). */
export function labelled(label: string, root: ParentNode = document): HTMLElement | undefined {
  return all(`[aria-label="${label}"]`, root)[0];
}

/** A press as a finger or the mouse makes it, at the element's centre. */
export function press(element: HTMLElement): void {
  const box = element.getBoundingClientRect();
  const at = { bubbles: true, cancelable: true, composed: true, clientX: box.x + box.width / 2, clientY: box.y + box.height / 2 };
  element.dispatchEvent(new PointerEvent("pointerdown", { ...at, pointerType: "touch", isPrimary: true }));
  element.dispatchEvent(new MouseEvent("mousedown", at));
  element.dispatchEvent(new PointerEvent("pointerup", { ...at, pointerType: "touch", isPrimary: true }));
  element.dispatchEvent(new MouseEvent("mouseup", at));
  element.dispatchEvent(new MouseEvent("click", at));
}

/** Types into a text field the way the browser reports a user's typing. */
export function fill(input: HTMLInputElement, text: string): void {
  input.focus();
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, text);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

/** What the screen says, for a failed step's message. */
export function screenText(): string {
  return all("body *")
    .filter((element) => element.children.length === 0 && (element.textContent ?? "").trim() !== "")
    .map((element) => (element.textContent ?? "").trim())
    .slice(0, 80)
    .join(" | ");
}

/** Polls [found] until it returns something, or fails naming [what] after [seconds]. */
export async function until<T>(what: string, seconds: number, found: () => T | undefined | false | null): Promise<T> {
  const deadline = Date.now() + seconds * 1000;
  for (;;) {
    const value = found();
    if (value !== undefined && value !== false && value !== null) return value;
    if (Date.now() > deadline) throw new Error(`timed out after ${seconds} s waiting for ${what}; on screen: ${screenText()}`);
    await sleep(250);
  }
}

/** Waits until the page stops moving: running motion that ends (a page transition, a dialog, a ripple) ends. */
export async function settle(): Promise<void> {
  await sleep(500);
  const moving = document
    .getAnimations()
    .filter((animation) => animation.playState === "running")
    .filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
  await Promise.all(moving.map((animation) => animation.finished.catch(() => undefined)));
}
