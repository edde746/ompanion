import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/sessions/oauth_callback.dart';

void main() {
  test('finds the loopback port of an encoded redirect_uri', () {
    const url =
        'https://claude.ai/oauth/authorize?code=true&client_id=abc&response_type=code'
        '&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&scope=user%3Ainference&state=xyz';
    expect(loopbackRedirectPort(url), 54545);
  });

  test('accepts 127.0.0.1 and ::1', () {
    expect(
      loopbackRedirectPort('https://auth.openai.com/authorize?redirect_uri=http://127.0.0.1:1455/auth/callback'),
      1455,
    );
    expect(loopbackRedirectPort('https://x.test/a?redirect_uri=http%3A%2F%2F%5B%3A%3A1%5D%3A8085%2Fcb'), 8085);
  });

  test('ignores redirects to other hosts', () {
    expect(loopbackRedirectPort('https://x.test/a?redirect_uri=https://app.example.com:8443/cb'), isNull);
  });

  test('ignores a loopback redirect without an explicit port', () {
    expect(loopbackRedirectPort('https://x.test/a?redirect_uri=http://localhost/cb'), isNull);
  });

  test('is null without a redirect_uri or for malformed input', () {
    expect(loopbackRedirectPort('https://github.com/login/device'), isNull);
    expect(loopbackRedirectPort('https://x.test/a?redirect_uri=%zz'), isNull);
    expect(loopbackRedirectPort('::not a url::'), isNull);
  });
}
