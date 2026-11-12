// The `form` request (docs/contracts/ompx.md, "Requests", `form`): decoding its params, the drafts' transitions, the
// submitted data and the field rules, which must agree with omp's (`tui/src/html-form/data.ts`).
import { expect, test } from "bun:test";
import { FormatException } from "../../../core/rpc/json_fields";
import {
  chooseOption,
  chooseOther,
  chosenCount,
  type FieldDraft,
  type FormChoice,
  htmlFormDrafts,
  htmlFormErrors,
  htmlFormFromJson,
  htmlFormSubmit,
  typeOther,
} from "./html_form";

interface OptionJson {
  readonly value: string;
  readonly label: readonly { readonly text: string }[];
  readonly checked: boolean;
  readonly disabled: boolean;
}

const option = (value: string, checked = false): OptionJson => ({
  value,
  label: [{ text: value }],
  checked,
  disabled: false,
});

const choice = (name: string, multi: boolean, options: OptionJson[], required = false) => ({
  kind: "choice",
  name,
  question: name,
  label: [],
  multi,
  select: false,
  other: true,
  required,
  options,
});

const input = (name: string, type: string, rules: Record<string, unknown> = {}) => ({
  kind: "input",
  name,
  question: name,
  label: [{ text: name }],
  type,
  multiline: false,
  value: "",
  placeholder: "",
  required: false,
  rows: 1,
  ...rules,
});

const params = {
  sections: [
    {
      title: [{ text: "Store" }],
      blocks: [
        { kind: "text", spans: [{ text: "Sessions are lost on " }, { text: "restart", style: "em" }], heading: false },
        choice("store", false, [option("sqlite", true), option("redis")], true),
      ],
    },
    {
      title: [],
      blocks: [
        choice("targets", true, [option("macos"), option("linux"), option("windows")]),
        { kind: "image", alt: "remote", uri: "https://example.com/a.png" },
        input("ttl", "number", { min: 1, max: 90 }),
        input("code", "text", { pattern: "[A-Z]{2}" }),
      ],
    },
  ],
  deadline: 1_700_000_000_000,
};

const form = htmlFormFromJson(params);
const [store, targets] = form.fields as [FormChoice, FormChoice];

function withDraft(drafts: FieldDraft[], index: number, draft: FieldDraft): FieldDraft[] {
  return drafts.map((current, at) => (at === index ? draft : current));
}

test("decodes the companion's params: fields in document order, a picture only as a data URI", () => {
  expect(form.fields.map((field) => field.name)).toEqual(["store", "targets", "ttl", "code"]);
  expect(form.deadlineMs).toBe(1_700_000_000_000);
  expect(form.sections[1]?.blocks[1]).toEqual({ kind: "image", alt: "remote", uri: undefined });
  expect(() => htmlFormFromJson({ sections: [{ title: [], blocks: [{ kind: "video" }] }] })).toThrow(FormatException);
  expect(() =>
    htmlFormFromJson({ sections: [{ title: [{ text: "x", style: "underline" }], blocks: [] }] }),
  ).toThrow(FormatException);
});

test("opens with the form's preselection and submits it as omp's defaults", () => {
  const drafts = htmlFormDrafts(form);
  expect(drafts[0]).toEqual({ kind: "choice", checked: [0], other: false, otherText: "" });
  expect(htmlFormSubmit(form, drafts)).toEqual({
    kind: "submit",
    data: { store: "sqlite", targets: [], ttl: "", code: "" },
  });
});

test("a radio group keeps one answer; Other replaces its value", () => {
  let draft = htmlFormDrafts(form)[0]!;
  draft = chooseOption(store, draft, 1);
  expect(draft).toMatchObject({ checked: [1], other: false });
  draft = typeOther(store, draft, "postgres");
  expect(draft).toMatchObject({ checked: [], other: true, otherText: "postgres" });
  expect(htmlFormSubmit(form, withDraft(htmlFormDrafts(form), 0, draft)).data).toMatchObject({ store: "postgres" });
  draft = chooseOption(store, draft, 0);
  expect(draft).toMatchObject({ checked: [0], other: false });
});

test("a checkbox group toggles; values in option order with Other last, counted while blank Other is not", () => {
  let draft = htmlFormDrafts(form)[1]!;
  draft = chooseOption(targets, draft, 2);
  draft = chooseOption(targets, draft, 0);
  draft = chooseOther(targets, draft);
  expect(chosenCount(draft)).toBe(2);
  draft = typeOther(targets, draft, "freebsd");
  expect(chosenCount(draft)).toBe(3);
  draft = chooseOption(targets, draft, 2);
  expect(htmlFormSubmit(form, withDraft(htmlFormDrafts(form), 1, draft)).data).toMatchObject({
    targets: ["macos", "freebsd"],
  });
});

test("a filled number input submits a number", () => {
  const drafts = withDraft(htmlFormDrafts(form), 2, { kind: "input", text: "30" });
  expect(htmlFormSubmit(form, drafts).data).toMatchObject({ ttl: 30 });
});

test("errors follow omp's rules: required, number range, anchored pattern", () => {
  const blank = htmlFormDrafts(form);
  expect(htmlFormErrors(form, blank)).toEqual([undefined, undefined, undefined, undefined]);
  const noStore = withDraft(blank, 0, chooseOther(store, blank[0]!));
  expect(htmlFormErrors(form, noStore)[0]).toEqual({ kind: "required" });
  const errors = (field: number, text: string) =>
    htmlFormErrors(form, withDraft(blank, field, { kind: "input", text }))[field];
  expect(errors(2, "0")).toEqual({ kind: "min", min: 1 });
  expect(errors(2, "91")).toEqual({ kind: "max", max: 90 });
  expect(errors(2, "ten")).toEqual({ kind: "number" });
  expect(errors(3, "ABC")).toEqual({ kind: "pattern", pattern: "[A-Z]{2}" });
  expect(errors(3, "AB")).toBeUndefined();
});

test("a required checkbox group needs one value", () => {
  const required = htmlFormFromJson({
    sections: [{ title: [], blocks: [choice("tools", true, [option("a"), option("b")], true)] }],
  });
  expect(htmlFormErrors(required, htmlFormDrafts(required))).toEqual([{ kind: "chooseOne" }]);
});
