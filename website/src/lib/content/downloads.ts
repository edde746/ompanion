// Every URL on the site comes from this module, so a change to one of them is one edit.
export const SITE_URL = 'https://ompanion.app';
export const REPO_URL = 'https://github.com/edde746/ompanion';
export const RELEASES_PAGE_URL = `${REPO_URL}/releases`;
export const ISSUES_URL = `${REPO_URL}/issues`;
export const BUILD_FROM_SOURCE_URL = `${REPO_URL}#building-from-source`;
export const LICENSE_URL = `${REPO_URL}/blob/main/LICENSE`;
export const OMP_URL = 'https://github.com/can1357/oh-my-pi';
export const CLOUDFLARE_PRIVACY_URL = 'https://www.cloudflare.com/privacypolicy/';

export const APP_STORE_URL = 'https://apps.apple.com/app/id6816667970';
export const MICROSOFT_STORE_URL = 'https://apps.microsoft.com/detail/9P9DVTKZ3SB9';
export const PLAY_STORE_URL = 'https://play.google.com/store/apps/details?id=com.edde746.ompanion';
// Google Play lists the app only to testers until its closed test earns production access: testers join the
// Google Group, then opt in on Play's test page.
export const PLAY_TESTERS_GROUP_URL = 'https://groups.google.com/g/edde-testers';
export const PLAY_TEST_OPT_IN_URL = 'https://play.google.com/apps/testing/com.edde746.ompanion';
/** The fragment that opens the Google Play dialog, so the README can link straight to it. */
export const PLAY_DIALOG_ID = 'google-play';

export type Download = {
  /** The operating system. */
  platform: string;
  /** A store's name, or the release asset's file name, which carries the architecture. */
  source: string;
  /** What the user gets, in one line. */
  detail: string;
  url: string;
  store: boolean;
};

const releaseAsset = (file: string) => `${REPO_URL}/releases/latest/download/${file}`;

// Phones, tablets and Windows install from their stores; macOS and Linux from the latest GitHub release, which
// also carries a Windows zip.
export const downloads: Download[] = [
  {
    platform: 'macOS',
    source: 'ompanion-macos.dmg',
    detail: 'Disk image, signed and notarized.',
    url: releaseAsset('ompanion-macos.dmg'),
    store: false,
  },
  {
    platform: 'Windows',
    source: 'Microsoft Store',
    detail: 'Windows 10 version 1809 or newer.',
    url: MICROSOFT_STORE_URL,
    store: true,
  },
  {
    platform: 'Linux',
    source: 'ompanion-linux-x64.zip',
    detail: 'Zip archive. Needs GTK 3 and libsecret.',
    url: releaseAsset('ompanion-linux-x64.zip'),
    store: false,
  },
  {
    platform: 'Android',
    source: 'Google Play',
    detail: 'In a closed test: join the testers first.',
    url: PLAY_STORE_URL,
    store: true,
  },
  {
    platform: 'iOS',
    source: 'App Store',
    detail: 'iPhone and iPad, iOS 15 or newer.',
    url: APP_STORE_URL,
    store: true,
  },
];
