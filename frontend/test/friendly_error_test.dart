import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/friendly_error.dart';

void main() {
  test('maps jackett build error', () {
    expect(
      friendlyRequestError('metadata provider error: build error'),
      contains('indexers'),
    );
  });

  test('maps jackett api key', () {
    expect(
      friendlyRequestError('Jackett: HTTP 401 Unauthorized'),
      contains('API key'),
    );
  });

  test('does not treat missing key as rejected key', () {
    expect(
      friendlyRequestError('Add your Jackett API key in the server console first.'),
      'Add your Jackett API key in the server console first.',
    );
  });

  test('maps stream timeout', () {
    expect(
      friendlyRequestError('error: timed out waiting for torrent metadata'),
      contains('peers'),
    );
  });

  test('hides operation exception dumps', () {
    expect(
      friendlyRequestError(
        "OperationException(linkException: ServerException(), graphqlErrors: [])",
      ),
      'Something went wrong. Try again.',
    );
  });

  test('strips graphql prefixes', () {
    expect(
      friendlyRequestError('invalid request: Jackett streaming is disabled'),
      'Jackett streaming is turned off. Enable it in the server console.',
    );
  });

  test('maps cookies required', () {
    expect(
      friendlyRequestError('Jackett: HTTP 400: cookies required'),
      contains('login'),
    );
  });
}
