// Every URL on the site comes from this module, so a change to one of them is one edit.
export const SITE_URL = 'https://ompanion.app';
export const REPO_URL = 'https://github.com/edde746/ompanion';
export const RELEASES_PAGE_URL = `${REPO_URL}/releases`;
export const ISSUES_URL = `${REPO_URL}/issues`;
export const BUILD_FROM_SOURCE_URL = `${REPO_URL}#building-from-source`;
export const LICENSE_URL = `${REPO_URL}/blob/main/LICENSE`;
export const OMP_URL = 'https://github.com/can1357/oh-my-pi';
export const CLOUDFLARE_PRIVACY_URL = 'https://www.cloudflare.com/privacypolicy/';

export type Download = {
  /** The operating system; the file name carries the architecture. */
  platform: string;
  /** Release asset file name. */
  file: string;
  /** What the user gets, in one line. */
  detail: string;
};

const releaseAsset = (file: string) => `${REPO_URL}/releases/latest/download/${file}`;

// The five platforms the release workflow attaches. Nothing is on the App Store or Google Play
// yet, so a store row would be a link to a 404; the badge and store URL go here when that changes.
export const downloads: (Download & { url: string })[] = (
  [
    {
      platform: 'macOS',
      file: 'ompanion-macos.dmg',
      detail: 'Disk image, signed and notarized.',
    },
    {
      platform: 'Windows',
      file: 'ompanion-windows-x64.zip',
      detail: 'Zip archive.',
    },
    {
      platform: 'Linux',
      file: 'ompanion-linux-x64.zip',
      detail: 'Zip archive. Needs GTK 3 and libsecret.',
    },
    {
      platform: 'Android',
      file: 'ompanion-android.apk',
      detail: 'APK for Android 7.0 or newer.',
    },
    {
      platform: 'iOS',
      file: 'ompanion-ios.ipa',
      detail: 'Unsigned IPA. Install it with a sideloading tool such as AltStore or Sideloadly.',
    },
  ] satisfies Download[]
).map((download) => ({ ...download, url: releaseAsset(download.file) }));
