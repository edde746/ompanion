import { describe, expect, test } from "bun:test";
import {
  advisorNotesFromContent,
  advisorNotesFromDetails,
  advisorTreeNotes,
  resolveAdvisorNotes,
  stripAdvisoryMarkup,
} from "./advisor_notes";

const lunaXml =
  `<advisory advisor="luna" severity="nit" guidance="weigh, don't blindly obey">weigh this</advisory>`;

describe("advisorNotesFromDetails", () => {
  test("reads AdvisorNote fields from details.notes", () => {
    expect(
      advisorNotesFromDetails({
        notes: [
          { note: "watch the tests", advisor: "critic", severity: "concern" },
          { note: "and the docs", advisor: "default", severity: "nit", turnsAgo: 2 },
          { note: "stop", severity: "blocker" },
        ],
      }),
    ).toEqual([
      { note: "watch the tests", advisor: "critic", severity: "concern" },
      { note: "and the docs", advisor: "default", severity: "nit", turnsAgo: 2 },
      { note: "stop", severity: "blocker" },
    ]);
  });

  test("skips notes that are not objects or have no note string", () => {
    expect(
      advisorNotesFromDetails({
        notes: ["bare", { severity: "nit" }, { note: "kept" }, null],
      }),
    ).toEqual([{ note: "kept" }]);
  });

  test("returns an empty list when details.notes is missing", () => {
    expect(advisorNotesFromDetails(undefined)).toEqual([]);
    expect(advisorNotesFromDetails({ other: true })).toEqual([]);
  });
});

describe("advisorTreeNotes", () => {
  test("joins notes and tags the way the session tree already did", () => {
    expect(
      advisorTreeNotes({
        notes: [
          { note: "watch the tests", advisor: "critic", severity: "concern" },
          { note: "and the docs", advisor: "default", severity: "nit" },
        ],
      }),
    ).toEqual({ tags: "critic, concern, nit", notes: "watch the tests and the docs" });
  });
});

describe("advisorNotesFromContent", () => {
  test("parses advisory blocks and unescapes XML entities", () => {
    const content = [
      `<advisory advisor="luna" severity="nit" guidance="weigh, don't blindly obey">`,
      `use &lt;code&gt; &amp; quotes`,
      `</advisory>`,
      `<advisory severity="concern" advisor="reviewer" turns_ago="3">second &quot;note&quot;</advisory>`,
    ].join("\n");
    expect(advisorNotesFromContent(content)).toEqual([
      { note: "use <code> & quotes", advisor: "luna", severity: "nit" },
      { note: `second "note"`, advisor: "reviewer", severity: "concern", turnsAgo: 3 },
    ]);
  });

  test("returns an empty list when content has no advisory blocks", () => {
    expect(advisorNotesFromContent("plain advice")).toEqual([]);
    expect(advisorNotesFromContent(`<advisory advisor="luna">unclosed`)).toEqual([]);
  });
});

describe("stripAdvisoryMarkup", () => {
  test("drops advisory tags and unescapes the leftover text", () => {
    expect(stripAdvisoryMarkup(`${lunaXml} extra &amp; text`)).toBe("weigh this extra & text");
    expect(stripAdvisoryMarkup(`<advisory advisor="luna" severity="nit">unclosed &lt;tag`)).toBe("unclosed <tag");
  });
});

describe("resolveAdvisorNotes", () => {
  test("prefers details.notes even when content is the model-facing XML", () => {
    expect(
      resolveAdvisorNotes({ notes: [{ note: "from details", advisor: "luna", severity: "blocker" }] }, lunaXml),
    ).toEqual([{ note: "from details", advisor: "luna", severity: "blocker" }]);
  });

  test("uses an empty details.notes list rather than falling back to content", () => {
    expect(resolveAdvisorNotes({ notes: [] }, lunaXml)).toEqual([]);
  });

  test("parses content when details.notes is missing", () => {
    expect(resolveAdvisorNotes(undefined, lunaXml)).toEqual([
      { note: "weigh this", advisor: "luna", severity: "nit" },
    ]);
  });

  test("falls back to stripped content when advisory blocks cannot be parsed", () => {
    expect(resolveAdvisorNotes(undefined, `<advisory advisor="luna">leftover &amp; note`)).toEqual([
      { note: "leftover & note" },
    ]);
  });
});
