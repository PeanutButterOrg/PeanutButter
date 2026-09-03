import 'package:graphql_flutter/graphql_flutter.dart';

import '../friendly_error.dart';

GraphQLClient createGraphQLClient(
  String serverUrl, {
  String apiToken = '',
  void Function()? onUnauthorized,
}) {
  final uri = _normalizeGraphqlUri(serverUrl);
  final headers = <String, String>{'Accept': 'application/json'};
  final token = _normalizePairingToken(apiToken);
  if (token.isNotEmpty) {
    headers['X-Api-Key'] = token;
  }
  final httpLink = HttpLink(uri, defaultHeaders: headers);
  final link = Link.concat(
    Link.function((request, [forward]) {
      return forward!(request).map((response) {
        if (onUnauthorized != null && _responseUnauthorized(response)) {
          onUnauthorized();
        }
        return response;
      }).handleError((error, stack) {
        if (onUnauthorized != null && isUnauthorizedError(error)) {
          onUnauthorized();
        }
        Error.throwWithStackTrace(error, stack);
      });
    }),
    httpLink,
  );

  return GraphQLClient(
    link: link,
    cache: GraphQLCache(store: InMemoryStore()),
    defaultPolicies: DefaultPolicies(
      query: Policies(fetch: FetchPolicy.cacheAndNetwork),
      mutate: Policies(fetch: FetchPolicy.networkOnly),
    ),
    queryRequestTimeout: const Duration(seconds: 45),
  );
}

const FetchPolicy catalogFetchPolicy = FetchPolicy.cacheAndNetwork;
const FetchPolicy searchFetchPolicy = FetchPolicy.cacheAndNetwork;

bool isUnauthorizedError(Object error) {
  if (error is OperationException) {
    final link = error.linkException;
    if (link is ServerException && (link.statusCode == 401 || link.statusCode == 403)) {
      return true;
    }
    if (link is HttpLinkServerException &&
        (link.response.statusCode == 401 || link.response.statusCode == 403)) {
      return true;
    }
    if (error.graphqlErrors.any(_graphqlUnauthorized)) return true;
  }
  if (error is ServerException && (error.statusCode == 401 || error.statusCode == 403)) {
    return true;
  }
  final text = error.toString().toLowerCase();
  return text.contains('unauthorized') ||
      text.contains('invalid api token') ||
      text.contains('missing api token') ||
      text.contains('401');
}

bool _responseUnauthorized(Response response) {
  final errors = response.errors;
  if (errors == null || errors.isEmpty) return false;
  return errors.any(_graphqlUnauthorized);
}

bool _graphqlUnauthorized(GraphQLError error) {
  final m = error.message.toLowerCase();
  return m.contains('unauthorized') || m.contains('invalid api token') || m.contains('missing api token');
}

String graphqlMessage(QueryResult result) {
  final errors = result.exception?.graphqlErrors;
  if (errors != null && errors.isNotEmpty) {
    final text = errors.map((e) => e.message).where((m) => m.trim().isNotEmpty).join('\n');
    if (text.isNotEmpty) return friendlyRequestError(text);
  }
  final link = result.exception?.linkException;
  if (link != null) {
    return friendlyRequestError(link.toString());
  }
  return friendlyRequestError(result.exception?.toString() ?? 'Request failed');
}

Map<String, String> mediaAuthHeaders(String apiToken) {
  final token = _normalizePairingToken(apiToken);
  if (token.isEmpty) return const {};
  return {'X-Api-Key': token};
}

String _normalizePairingToken(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length == 6) return digits;
  return raw.trim();
}

bool isLocalServer(String serverUrl) {
  final host = Uri.tryParse(normalizeServerBase(serverUrl))?.host.toLowerCase();
  return host == '127.0.0.1' || host == 'localhost' || host == '::1';
}

String _normalizeGraphqlUri(String serverUrl) {
  var value = serverUrl.trim();
  if (value.isEmpty) {
    if (Uri.base.hasScheme && Uri.base.host.isNotEmpty) {
      return Uri.base.resolve('graphql').toString();
    }
    return 'http://127.0.0.1:3001/graphql';
  }
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    value = 'http://$value';
  }
  value = value.replaceFirst(RegExp(r'/$'), '');
  if (value.endsWith('/graphql')) {
    return value;
  }
  return '$value/graphql';
}

String normalizeServerBase(String serverUrl) {
  var value = serverUrl.trim();
  if (value.isEmpty) {
    final origin = Uri.base.origin;
    return origin.isEmpty ? 'http://127.0.0.1:3001' : origin;
  }
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    value = 'http://$value';
  }
  value = value.replaceFirst(RegExp(r'/$'), '');
  if (value.endsWith('/graphql')) {
    value = value.substring(0, value.length - '/graphql'.length);
  }
  return value;
}
