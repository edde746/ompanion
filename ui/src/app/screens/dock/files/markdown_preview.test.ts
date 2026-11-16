import { expect, test } from "bun:test";
import { frontMatterAsCode } from "./markdown_preview";

test("front matter shows as a yaml code block; anything else stays as written", () => {
  expect(frontMatterAsCode("---\nname: review\ndescription: Reviews code\n---\n# Review\n")).toBe(
    "```yaml\nname: review\ndescription: Reviews code\n```\n\n# Review\n",
  );
  // A fence inside the front matter gets a longer fence around it; `...` closes it too.
  expect(frontMatterAsCode("---\nnote: ```code```\n...\nBody")).toBe("````yaml\nnote: ```code```\n````\n\nBody");
  expect(frontMatterAsCode("---\n---\nBody")).toBe("Body");
  expect(frontMatterAsCode("---\nnever closed\n")).toBe("---\nnever closed\n");
  expect(frontMatterAsCode("Intro\n\n---\nnot front matter\n---\n")).toBe("Intro\n\n---\nnot front matter\n---\n");
});
