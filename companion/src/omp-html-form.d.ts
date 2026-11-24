/**
 * omp's form picture loader as omp 18.18.3 to 18.20.3 have it (`packages/tui/src/html-form/media.ts`); 18.21.0 moved
 * it to `@oh-my-pi/pi-tui/media`, whose types the companion's dev types carry. `form.ts` imports this one on the older
 * omp only.
 */
declare module "@oh-my-pi/pi-tui/html-form/media" {
	export interface FormMedia {
		bytes: Uint8Array;
		mime: string;
	}

	export function loadFormImage(src: string, options: { cwd: string; signal?: AbortSignal }): Promise<FormMedia>;
	export function svgMedia(markup: string): FormMedia;
}
