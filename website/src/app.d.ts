/// <reference types="@sveltejs/enhanced-img" />
/// <reference types="vite/client" />

declare global {
  namespace App {
    // No server, no session: every route is prerendered.
  }
}

export {};
