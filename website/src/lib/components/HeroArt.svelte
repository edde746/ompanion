<script lang="ts">
  // Ripples of light spreading from behind the app window: the glyph's lime-to-emerald gradient as an
  // ordered 4x4 Bayer dither on a fixed grid of 3 px cells, every other cell row lit like scanlines.
  // The same dither, ramp and cell size as the store images. The canvas holds one pixel per cell and
  // the browser scales it up without smoothing, so a frame is one small putImageData.

  const { shot }: { shot: HTMLElement | undefined } = $props();

  const CELL = 3;
  const BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
  // Ramp stops: deep emerald where the light dissolves, emerald, lime where it is hottest.
  const DEEP = [0x0e, 0x4a, 0x25];
  const EMERALD = [0x22, 0xc5, 0x5e];
  const LIME = [0xc4, 0xf0, 0x42];
  // `above` and `below` squash the rings' ellipse vertically on each side of its centre, which sits `drop` of
  // the window's height below the window's own.
  const RINGS = { above: 0.56, below: 0.62, drop: 0.02 };
  // One wavelength every 6.5 s, redrawn at most 20 times a second: slow enough to read as light.
  const PERIOD_MS = 6500;
  const FRAME_MS = 50;
  const FADE_IN_MS = 1400;

  let canvas: HTMLCanvasElement | undefined = $state();
  let drawn = $state(false);

  const smoothstep = (a: number, b: number, x: number) => {
    const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
    return t * t * (3 - 2 * t);
  };

  // Value noise, two octaves, from an integer hash: fixed per cell, so the light has an uneven edge.
  const hash = (x: number, y: number) => {
    let h = (x * 374761393 + y * 668265263) | 0;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    return ((h ^ (h >>> 16)) >>> 0) / 4294967295;
  };
  const valueNoise = (x: number, y: number) => {
    const xi = Math.floor(x);
    const yi = Math.floor(y);
    const fx = x - xi;
    const fy = y - yi;
    const sx = fx * fx * (3 - 2 * fx);
    const sy = fy * fy * (3 - 2 * fy);
    const top = hash(xi, yi) + (hash(xi + 1, yi) - hash(xi, yi)) * sx;
    const bottom = hash(xi, yi + 1) + (hash(xi + 1, yi + 1) - hash(xi, yi + 1)) * sx;
    return top + (bottom - top) * sy;
  };
  const noise = (x: number, y: number) => (valueNoise(x / 90, y / 90) * 2 + valueNoise(x / 34, y / 34)) / 3;

  const ramp = (heat: number) => {
    const [from, to, t] = heat < 0.55 ? [DEEP, EMERALD, heat / 0.55] : [EMERALD, LIME, (heat - 0.55) / 0.45];
    const c = from.map((v, i) => Math.round(v + (to[i] - v) * t));
    // ImageData is little-endian RGBA in a Uint32Array: alpha in the high byte.
    return (0xff << 24) | (c[2] << 16) | (c[1] << 8) | c[0];
  };

  type Field = {
    context: CanvasRenderingContext2D;
    image: ImageData;
    pixels: Uint32Array;
    /** Per lit cell: pixel index, base intensity, ring position in wavelengths, threshold and colour. */
    index: Uint32Array;
    base: Float32Array;
    ring: Float32Array;
    threshold: Float32Array;
    colour: Uint32Array;
  };

  function buildField(canvas: HTMLCanvasElement, shot: HTMLElement): Field | undefined {
    const host = canvas.parentElement;
    const context = canvas.getContext('2d');
    if (!host || !context) return undefined;
    const hostBox = host.getBoundingClientRect();
    // The showcase's box is the window, outline included.
    const bounds = shot.getBoundingClientRect();
    const ux0 = bounds.left - hostBox.left;
    const ux1 = bounds.right - hostBox.left;
    const uy0 = bounds.top - hostBox.top;
    const uy1 = bounds.bottom - hostBox.top;
    const boxWidth = ux1 - ux0;
    const boxHeight = uy1 - uy0;

    // The canvas starts under the last line of the copy and runs to the foot of the hero; the light
    // fades in below the copy and has dissolved by the foot, so no text ever sits on it.
    const reach = Math.max(260, boxWidth * 0.62);
    const ceiling = host.querySelector('[data-art-ceiling]')?.getBoundingClientRect().bottom ?? hostBox.top;
    const top = Math.round((Math.max(ceiling - hostBox.top + 12, uy0 - 220)) / CELL) * CELL;
    const bottom = hostBox.height;
    const columns = Math.ceil(hostBox.width / CELL);
    const rows = Math.ceil((bottom - top) / CELL);
    canvas.width = columns;
    canvas.height = rows;
    canvas.style.width = `${columns * CELL}px`;
    canvas.style.height = `${rows * CELL}px`;
    canvas.style.top = `${top}px`;

    // The fade to black takes the lower two thirds of the room under the window.
    const footFade = bottom - Math.max(60, (bottom - uy1) * 0.66);
    const cx = (ux0 + ux1) / 2;
    const cy = (uy0 + uy1) / 2 + boxHeight * RINGS.drop;
    const start = boxWidth * 0.3;
    const wavelength = Math.min(118, Math.max(38, boxWidth * 0.1));

    const image = context.createImageData(columns, rows);
    const pixels = new Uint32Array(image.data.buffer);
    const index: number[] = [];
    const base: number[] = [];
    const ring: number[] = [];
    const threshold: number[] = [];
    const colour: number[] = [];

    // Scanlines: only every other cell row is ever lit.
    for (let row = 0; row < rows; row += 2) {
      const y = top + row * CELL + CELL / 2;
      for (let column = 0; column < columns; column++) {
        const x = column * CELL + CELL / 2;
        // Nothing behind the window; the light runs up to its edge, less one cell so no dot touches the hairline.
        const outX = Math.max(ux0 - x, 0, x - ux1);
        const outY = Math.max(uy0 - y, 0, y - uy1);
        const moat = smoothstep(CELL, CELL * 3, Math.hypot(outX, outY));
        if (moat === 0) continue;
        const aspect = y < cy ? RINGS.above : RINGS.below;
        const r = Math.hypot(x - cx, (y - cy) / aspect);
        const fall = Math.pow(Math.min(1, Math.max(0, 1 - (r - start) / reach)), 1.7);
        const ends = smoothstep(top, top + 110, y) * (1 - smoothstep(footFade, bottom - 6, y));
        const intensity = 1.75 * fall * moat * ends * (0.78 + 0.44 * noise(x, y));
        if (intensity <= 0.02) continue;
        index.push(row * columns + column);
        base.push(intensity);
        ring.push((r - start) / wavelength);
        threshold.push((BAYER[(row % 4) * 4 + (column % 4)] + 0.5) / 16);
        colour.push(ramp(Math.min(1, fall * 1.3)));
      }
    }

    return {
      context,
      image,
      pixels,
      index: Uint32Array.from(index),
      base: Float32Array.from(base),
      ring: Float32Array.from(ring),
      threshold: Float32Array.from(threshold),
      colour: Uint32Array.from(colour),
    };
  }

  // A crest is full intensity, a trough almost dark; phase moves the crests outward.
  function paint(field: Field, phase: number, gain: number) {
    const { pixels, index, base, ring, threshold, colour } = field;
    const tau = Math.PI * 2;
    for (let i = 0; i < index.length; i++) {
      const wave = 0.5 + 0.5 * Math.cos(tau * (ring[i] - phase));
      const value = base[i] * gain * (0.06 + 0.94 * wave);
      pixels[index[i]] = value > threshold[i] ? colour[i] : 0;
    }
    field.context.putImageData(field.image, 0, 0);
  }

  // An effect, not onMount: the showcase is bound by the parent after this component mounts.
  $effect(() => {
    if (!canvas || !shot) return;
    const target = canvas;
    const box = shot;
    const motion = window.matchMedia('(prefers-reduced-motion: no-preference)');
    let field = buildField(target, box);
    let frame = 0;
    let visible = true;
    let last = 0;
    const born = performance.now();

    const tick = (now: number) => {
      frame = 0;
      if (!field) return;
      if (now - last >= FRAME_MS) {
        last = now;
        const age = now - born;
        paint(field, age / PERIOD_MS, smoothstep(0, FADE_IN_MS, age));
        drawn = true;
      }
      schedule();
    };
    const schedule = () => {
      if (frame || !visible || !motion.matches || document.hidden) return;
      frame = requestAnimationFrame(tick);
    };
    // Reduced motion: one still frame, the rings where the first frame of the loop has them.
    const still = () => {
      if (!field) return;
      paint(field, 0, 1);
      drawn = true;
    };
    const start = () => (motion.matches ? schedule() : still());

    const resize = new ResizeObserver(() => {
      field = buildField(target, box);
      start();
    });
    resize.observe(target.parentElement ?? target);
    const seen = new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      if (visible) start();
    });
    seen.observe(target);
    const onVisibility = () => start();
    document.addEventListener('visibilitychange', onVisibility);
    motion.addEventListener('change', start);
    start();

    return () => {
      cancelAnimationFrame(frame);
      resize.disconnect();
      seen.disconnect();
      document.removeEventListener('visibilitychange', onVisibility);
      motion.removeEventListener('change', start);
    };
  });
</script>

<canvas bind:this={canvas} class="art" class:drawn aria-hidden="true"></canvas>

<style>
  .art {
    position: absolute;
    z-index: 0;
    left: 0;
    max-width: none;
    opacity: 0;
    image-rendering: pixelated;
    pointer-events: none;
  }

  .art.drawn {
    opacity: 1;
  }

  @media print {
    .art {
      display: none;
    }
  }
</style>
