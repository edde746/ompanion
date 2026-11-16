// A binding under a For row, an inner Show or a memo in a non-keyed Show's branch must not run after the Show's
// condition turned falsy and before the Show re-ran. Solid before 2.0.0-rc.22 ran it first once the condition had come
// to read a deeper memo (solidjs/solid#4848): it read the narrowed value and halted the page with
// "Stale read from <Show>.".
import { expect, test } from "bun:test";
import {
  createMemo,
  createRenderEffect,
  createRoot,
  createSignal,
  flatten,
  flush,
  For,
  resetErrorHalt,
  Show,
} from "solid-js";

interface Named {
  readonly name: string;
}

test("a binding nested in a Show's branch does not run once the condition it lives under turned falsy", () => {
  const [deeper, setDeeper] = createSignal(false);
  const [source, setSource] = createSignal<Named | undefined>({ name: "deep" });
  const seen: string[] = [];
  let screen = "";
  const dispose = createRoot((dispose) => {
    // Deeper than anything the branch is born under.
    let deep: () => Named | undefined = source;
    for (let i = 0; i < 12; i++) deep = createMemo(deep);
    const shown = Show({
      get when() {
        return deeper() ? deep() : { name: "shallow" };
      },
      fallback: "closed",
      children: (value: () => Named) =>
        For({
          each: ["row"],
          children: (row: string) => {
            createRenderEffect(
              () => `${row}:${value().name}`,
              (text) => {
                seen.push(text);
              },
            );
            return row;
          },
        }),
    });
    createRenderEffect(
      () => String(flatten(shown)),
      (text) => {
        screen = text;
      },
    );
    return dispose;
  });
  try {
    flush();
    setDeeper(true);
    flush();
    setSource(undefined);
    flush();
    expect(seen).toEqual(["row:shallow", "row:deep"]);
    expect(screen).toBe("closed");
  } finally {
    dispose();
    // A halt stops every effect of the process: the suite's other tests must not inherit it.
    resetErrorHalt();
  }
});
