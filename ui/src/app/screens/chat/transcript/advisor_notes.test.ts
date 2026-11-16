import { expect, test } from "bun:test";
import { decodeAdvisorNotes } from "./advisor_notes";

test("advisor notes keep what omp's card shows and drop what it would not", () => {
  const details = {
    notes: [
      { note: "Add a case for a full bucket.", severity: "concern", advisor: "critic", turn: 4, turnsAgo: 2 },
      { note: "Plain note.", advisor: "default" },
      { note: "Unknown severity reads as a plain note.", severity: "urgent", turnsAgo: 0 },
      { severity: "blocker" },
      "not an object",
    ],
  };
  expect(decodeAdvisorNotes(details)).toEqual([
    { note: "Add a case for a full bucket.", severity: "concern", advisor: "critic", turnsAgo: 2 },
    { note: "Plain note." },
    { note: "Unknown severity reads as a plain note." },
  ]);
  expect(decodeAdvisorNotes({ notes: "none" })).toEqual([]);
  expect(decodeAdvisorNotes(undefined)).toEqual([]);
});
