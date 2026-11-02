/**
 * What the store capture types into the app's composer (store/screenshots/scenario/main.ts); the scripted model turns
 * (turns.ts) match on them.
 */
export const PROMPTS = {
  hero: "Add rate limiting to the upload endpoint so one client cannot exhaust the put path, then run the tests.",
  ask: "Document the limit in the README, and ask me for the numbers you should write down.",
  deploy: "Rotate the deploy token in deploy.sh and smoke-test the staging deploy.",
  /** Sent to the finished hero session before the machine list's picture, so its row shows it working. */
  long: "Run the long check and summarize it.",
} as const;
