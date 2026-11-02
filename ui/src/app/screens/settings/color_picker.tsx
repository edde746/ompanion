// lib/screens/settings/color_picker.dart.
import type { JSX } from "@solidjs/web";
import { createSignal } from "solid-js";
import { t } from "../../i18n/i18n";
import { estimateBrightness } from "../../palette";
import { TextField } from "../../widgets/text_field";
import {
  followColor,
  type Hsv,
  hexFieldColor,
  hexFieldText,
  hsvFromHex,
  hsvToHex,
  hueHex,
  pickInArea,
  pickOnHueTrack,
} from "./color_picker_math";
import "./color_picker.css";

/**
 * Picks an opaque colour (docs/design.md, Colour picker): a saturation/value area, a hue track and a hex field.
 * `onChanged` follows a drag; `onChangeEnd` gets the colour when the drag ends or a hex is applied.
 */
export function ColorPicker(props: {
  readonly color: string;
  readonly onChanged: (color: string) => void;
  readonly onChangeEnd: (color: string) => void;
}) {
  // Kept apart from props.color: a grey or black has no hue of its own, and the track keeps the one dragged to.
  const [hsv, setHsv] = createSignal<Hsv>((previous?: Hsv) => followColor(previous, props.color));
  let editing = false;
  // While the field has the focus, a colour from outside leaves its text alone.
  const [text, setText] = createSignal<string>((previous?: string) => {
    const color = props.color;
    return editing && previous !== undefined ? previous : color;
  });
  let field: HTMLInputElement | undefined;

  const drag = (next: Hsv) => {
    const color = hsvToHex(next);
    setHsv(next);
    setText(color);
    props.onChanged(color);
  };
  const dragEnd = () => props.onChangeEnd(hsvToHex(hsv()));

  const applyHex = () => {
    const current = hsvToHex(hsv());
    const color = hexFieldColor(text(), current);
    if (color === undefined) {
      setText(current);
      return;
    }
    setHsv(hsvFromHex(color));
    setText(color);
    props.onChangeEnd(color);
  };

  return (
    <div class="color-picker">
      <DragArea
        class="color-picker-area"
        style={{
          "background-image": `linear-gradient(to bottom, transparent, #000), linear-gradient(to right, #fff, ${hueHex(hsv().hue)})`,
        }}
        onDrag={(x, y, box) => drag(pickInArea(hsv(), x, y, box.width, box.height))}
        onEnd={dragEnd}
      >
        <Handle color={hsvToHex(hsv())} x={hsv().saturation} y={1 - hsv().value} />
      </DragArea>
      <DragArea class="color-picker-hue" onDrag={(x, _y, box) => drag(pickOnHueTrack(hsv(), x, box.width))} onEnd={dragEnd}>
        <span class="color-picker-hue-track" />
        <Handle color={hueHex(hsv().hue)} x={hsv().hue / 360} y={0.5} />
      </DragArea>
      <TextField
        class="color-picker-hex"
        code
        value={text()}
        hint={t.themeEditor.hex}
        enterKeyHint="done"
        ref={(element) => {
          field = element;
        }}
        onInput={(value) => {
          const kept = hexFieldText(value);
          if (field && kept !== value) field.value = kept;
          setText(kept);
        }}
        onFocus={() => {
          editing = true;
        }}
        onBlur={() => {
          editing = false;
          applyHex();
        }}
        onSubmit={() => applyHex()}
      />
    </div>
  );
}

/**
 * Reports every pointer position over its area from the pointer's first contact, in px from its top left. It takes
 * the pointer at once (`touch-action: none` and pointer capture), so a vertical drag on a phone moves the handle
 * instead of scrolling the list.
 */
function DragArea(props: {
  readonly class: string;
  readonly style?: JSX.CSSProperties;
  readonly onDrag: (x: number, y: number, box: DOMRect) => void;
  readonly onEnd: () => void;
  readonly children: JSX.Element;
}) {
  const report = (event: PointerEvent & { readonly currentTarget: HTMLDivElement }) => {
    const box = event.currentTarget.getBoundingClientRect();
    props.onDrag(event.clientX - box.left, event.clientY - box.top, box);
  };
  return (
    <div
      class={props.class}
      style={props.style}
      onPointerDown={(event) => {
        if (event.button !== 0) return;
        // No text selection and no focus change while the handle moves.
        event.preventDefault();
        event.currentTarget.setPointerCapture(event.pointerId);
        report(event);
      }}
      onPointerMove={(event) => {
        if (event.currentTarget.hasPointerCapture(event.pointerId)) report(event);
      }}
      onLostPointerCapture={() => props.onEnd()}
    >
      {props.children}
    </div>
  );
}

/** A handle at `x`, `y` (fractions of its area): a disc in `color` on a halo of white or black, whichever stands apart. */
function Handle(props: { readonly color: string; readonly x: number; readonly y: number }) {
  return (
    <span
      class="color-picker-halo"
      style={{
        left: `${props.x * 100}%`,
        top: `${props.y * 100}%`,
        background: estimateBrightness(props.color) === "dark" ? "#fff" : "#000",
      }}
    >
      <span class="color-picker-handle" style={{ background: props.color }} />
    </span>
  );
}
