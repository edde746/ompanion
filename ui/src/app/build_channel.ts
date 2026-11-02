// lib/app/build_channel.dart: where this build is distributed, from `VITE_OMPANION_CHANNEL` at build time (default
// `direct`), as the Flutter build reads `--dart-define=OMPANION_CHANNEL`. An unknown name throws at startup.

export const buildChannels = ["direct", "macappstore", "appstore", "play", "flathub"] as const;

export type BuildChannel = (typeof buildChannels)[number];

const name: unknown = import.meta.env.VITE_OMPANION_CHANNEL ?? "direct";
const channel = buildChannels.find((known) => known === name);
if (channel === undefined) throw new Error(`unknown build channel ${String(name)}`);

export const buildChannel: BuildChannel = channel;
