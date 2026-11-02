// lib/widgets/app_search_field.dart's debounce, apart from its field (app_search_field.tsx).

/**
 * When a search field's query goes out: `delayMs` after the last keystroke (`typed`), at once on Enter and on clear
 * (`now`), which also drops the query still waiting.
 */
export class SearchDebounce {
  private timer: ReturnType<typeof setTimeout> | undefined;

  constructor(
    private readonly onChanged: (query: string) => void,
    private readonly delayMs: () => number,
  ) {}

  typed(query: string): void {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.onChanged(query), this.delayMs());
  }

  now(query: string): void {
    clearTimeout(this.timer);
    this.timer = undefined;
    this.onChanged(query);
  }

  dispose(): void {
    clearTimeout(this.timer);
  }
}
