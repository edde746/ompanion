import { afterEach, expect, test } from "bun:test";
import { activityQueryLocal, dayDate, localDay } from "./activity_stats";

const dayMs = 24 * 60 * 60 * 1000;
const testZone = process.env.TZ;

afterEach(() => {
  if (testZone === undefined) delete process.env.TZ;
  else process.env.TZ = testZone;
});

test("the query holds every offset change from 2020 to two days ahead from its first minute, and the local today", () => {
  process.env.TZ = "Europe/Berlin";
  // 01:30 on 27 September in Berlin; the next change (25 October) is more than two days ahead.
  const query = activityQueryLocal(Date.UTC(2026, 8, 26, 23, 30));
  const changes = [
    ...["2020-03-29", "2020-10-25", "2021-03-28", "2021-10-31", "2022-03-27", "2022-10-30", "2023-03-26"],
    ...["2023-10-29", "2024-03-31", "2024-10-27", "2025-03-30", "2025-10-26", "2026-03-29"],
  ];
  const [first, ...rest] = query.zone;
  expect(first).toEqual([Date.UTC(2020, 0), 60]);
  // Berlin changes at 01:00 UTC.
  expect(rest.map(([start, offset]) => [new Date(start).toISOString().slice(0, 16), offset])).toEqual(
    changes.map((date, index) => [`${date}T01:00`, index % 2 === 0 ? 120 : 60]),
  );
  expect(query.today).toBe(Date.UTC(2026, 8, 27) / dayMs);
});

test("days are numbered by the local calendar and turn back into local midnights", () => {
  process.env.TZ = "America/Los_Angeles";
  // 20:00 on 26 September in Los Angeles (UTC-7).
  const day = localDay(Date.UTC(2026, 8, 27, 3));
  expect(day).toBe(Date.UTC(2026, 8, 26) / dayMs);
  expect(dayDate(day)).toBe(Date.UTC(2026, 8, 26, 7));
});
