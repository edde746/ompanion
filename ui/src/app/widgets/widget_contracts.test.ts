// Port of test/widgets/{app_select,app_search_field,activity_mark}_test.dart: what AppSelect shows and offers, when
// AppSearchField's query goes out, and how the activity marks step. Their markup is left out (no DOM in unit tests);
// a mark under reduced motion does not join the clock (ActivityMark), and the web has no TickerMode, so a mark under
// a covered page keeps stepping where Flutter's stood still.
import { afterEach, describe, expect, jest, test } from "bun:test";
import { flush } from "solid-js";
import { activityStep, showActivityMark } from "./activity_clock";
import { SearchDebounce } from "./search_debounce";
import { selectMenu } from "./select_menu";

afterEach(() => {
  jest.useRealTimers();
});

describe("AppSelect", () => {
  test("shows the current label and checks it in the menu; the chosen option shows next", () => {
    const options = [
      ["low", "Low"],
      ["high", "High"],
    ] as const;
    const high = selectMenu(options, "high");
    expect(high.label).toBe("High");
    expect(high.entries.filter((entry) => entry.checked).map((entry) => entry.label)).toEqual(["High"]);
    expect(selectMenu(options, "low").label).toBe("Low");
  });
});

describe("AppSearchField", () => {
  function debounce() {
    jest.useFakeTimers();
    const queries: string[] = [];
    return { queries, field: new SearchDebounce((query) => queries.push(query), () => 250) };
  }

  test("filters once typing pauses for the debounce", () => {
    const { queries, field } = debounce();
    field.typed("gi");
    jest.advanceTimersByTime(100);
    field.typed("git");
    jest.advanceTimersByTime(249);
    expect(queries).toEqual([]);
    jest.advanceTimersByTime(1);
    expect(queries).toEqual(["git"]);
  });

  test("Enter searches at once and does not fire again after the debounce", () => {
    const { queries, field } = debounce();
    field.typed("mcp");
    field.now("mcp");
    expect(queries).toEqual(["mcp"]);
    jest.advanceTimersByTime(1000);
    expect(queries).toEqual(["mcp"]);
  });

  test("clear empties the query at once", () => {
    const { queries, field } = debounce();
    field.typed("x");
    field.now("");
    expect(queries).toEqual([""]);
    jest.advanceTimersByTime(1000);
    expect(queries).toEqual([""]);
  });
});

describe("ActivityMark", () => {
  test("marks on screen step together, one step every 80 ms however many show, and none once they went", () => {
    jest.useFakeTimers();
    const gone = [showActivityMark(), showActivityMark(), showActivityMark()];
    flush();
    const start = activityStep();
    jest.advanceTimersByTime(5000);
    flush();
    // 62 steps in 5 s, as Flutter's test counts the frames it asks for.
    expect(activityStep() - start).toBe(62);
    for (const leave of gone) leave();
    jest.advanceTimersByTime(5000);
    flush();
    expect(activityStep() - start).toBe(62);
  });
});
