/// Loopback ports an OAuth flow sends the browser back to: the `redirect_uri` of [url], and [launchUrl]
/// (omp's short redirect, served by its callback server). Both listen on the machine running omp, so a
/// remote machine needs the same local port forwarded there before the browser opens.
Set<int> loopbackPorts(String url, String? launchUrl) {
  final ports = <int>{};
  void add(String? candidate) {
    final uri = candidate == null ? null : Uri.tryParse(candidate);
    if (uri == null || !uri.hasPort) return;
    if (const {'localhost', '127.0.0.1', '::1'}.contains(uri.host)) ports.add(uri.port);
  }

  add(Uri.tryParse(url)?.queryParameters['redirect_uri']);
  add(launchUrl);
  return ports;
}
