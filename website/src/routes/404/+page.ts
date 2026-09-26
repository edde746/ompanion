// GitHub Pages serves build/404.html for any unknown path, so this page must not hydrate: the
// client router would try to navigate to that path again.
export const csr = false;
