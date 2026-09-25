/// The port of [url]'s OAuth `redirect_uri` when that is a loopback address with an explicit port, else
/// null. omp's `login` sends the browser back to the machine's loopback (anthropic 54545, openai-codex
/// 1455, …); on an SSH machine the app forwards the same local port there so this device's browser can
/// finish the login (docs/PLAN.md D11).
int? loopbackRedirectPort(String url) {
  try {
    final redirect = Uri.parse(url).queryParameters['redirect_uri'];
    if (redirect == null) return null;
    final target = Uri.parse(redirect);
    if (!const {'localhost', '127.0.0.1', '::1'}.contains(target.host)) return null;
    return target.hasPort ? target.port : null;
  } on FormatException {
    return null;
  }
}
