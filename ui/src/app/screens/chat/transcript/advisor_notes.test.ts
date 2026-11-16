import { describe, expect, test } from "bun:test";
import { advisorNotesFromDetails } from "./advisor_notes";

describe("advisorNotesFromDetails", () => {
  test("reads AdvisorNote fields from details.notes", () => {
    expect(
      advisorNotesFromDetails({
        notes: [
          { note: "watch the tests", advisor: "critic", severity: "concern" },
          { note: "and the docs", advisor: "default", severity: "nit", turnsAgo: 2 },
          { note: "stop", severity: "blocker" },
          { note: "plain" },
          { note: "labelled", severity: "note" },
        ],
      }),
    ).toEqual([
      { note: "watch the tests", advisor: "critic", severity: "concern" },
      { note: "and the docs", advisor: "default", severity: "nit", turnsAgo: 2 },
      { note: "stop", severity: "blocker" },
      { note: "plain" },
      { note: "labelled", severity: "note" },
    ]);
  });

  test("skips notes that are not objects or have no note string", () => {
    expect(
      advisorNotesFromDetails({
        notes: ["bare", { severity: "nit" }, { note: "kept" }, null],
      }),
    ).toEqual([{ note: "kept" }]);
  });

  test("returns an empty list when details.notes is missing or empty", () => {
    expect(advisorNotesFromDetails(undefined)).toEqual([]);
    expect(advisorNotesFromDetails({ other: true })).toEqual([]);
    expect(advisorNotesFromDetails({ notes: [] })).toEqual([]);
  });
});
