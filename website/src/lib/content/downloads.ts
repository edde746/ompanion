// Every URL on the site comes from this module, so a change to one of them is one edit.
export const SITE_URL = 'https://ompanion.app';
export const REPO_URL = 'https://github.com/edde746/ompanion';
export const RELEASES_PAGE_URL = `${REPO_URL}/releases`;
export const ISSUES_URL = `${REPO_URL}/issues`;
export const BUILD_FROM_SOURCE_URL = `${REPO_URL}#building-from-source`;
export const LICENSE_URL = `${REPO_URL}/blob/main/LICENSE`;
export const OMP_URL = 'https://github.com/can1357/oh-my-pi';
export const GITHUB_PRIVACY_URL =
  'https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement';

export type Download = {
  /** Platform name as the README's Download table spells it. */
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
      detail: 'Disk image, signed and notarized so Gatekeeper opens it.',
    },
    {
      platform: 'Windows x64',
      file: 'ompanion-windows-x64.zip',
      detail: 'Zip archive.',
    },
    {
      platform: 'Linux x64',
      file: 'ompanion-linux-x64.zip',
      detail: 'Zip archive; needs GTK 3 and libsecret.',
    },
    {
      platform: 'Android',
      file: 'ompanion-android.apk',
      detail: 'APK for phones and tablets, Android 7.0 or newer.',
    },
    {
      platform: 'iOS',
      file: 'ompanion-ios.ipa',
      detail: 'Unsigned IPA; install it with a sideloading tool such as AltStore or Sideloadly.',
    },
  ] satisfies Download[]
).map((download) => ({ ...download, url: releaseAsset(download.file) }));
