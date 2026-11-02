// lib/widgets/activity_mark.dart's one ticker for every mark (activity_mark.tsx): it counts steps while any mark shows,
// and no timer runs while none does.
import { createSignal } from "solid-js";

/** Time between two steps of every mark: the step of omp's TUI activity spinner, so the app and the terminal move alike. */
export const activityStepMs = 80;

const [step, setStep] = createSignal(0);
let marks = 0;
let timer: ReturnType<typeof setInterval> | undefined;

/** The clock's steps so far; every mark shows the frame of the same step. */
export { step as activityStep };

/** A mark shows: the clock runs until every mark that showed has gone (the returned function). */
export function showActivityMark(): () => void {
  if (marks++ === 0) timer = setInterval(() => setStep((value) => value + 1), activityStepMs);
  return () => {
    if (--marks === 0) {
      clearInterval(timer);
      timer = undefined;
    }
  };
}
