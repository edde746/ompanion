// Base64 for bytes, as the bridge carries them (docs/contracts/bridge.md: binary data travels as base64).
// Uint8Array.fromBase64 and toBase64 arrived in Safari 18.2, after the oldest engine this app runs on.

export function base64Encode(bytes: Uint8Array): string {
  let binary = "";
  // String.fromCharCode takes its arguments on the stack; chunks keep large buffers under its limit.
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export function base64Decode(text: string): Uint8Array {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
