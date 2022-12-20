// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'authorization_exception.dart';
import 'client.dart';
import 'credentials.dart';
import 'handle_access_token_response.dart';
import 'parameters.dart';
import 'utils.dart';

/// A class for obtaining credentials via an [authorization code grant][].
///
/// This method of authorization involves sending the resource owner to the
/// authorization server where they will authorize the client. They're then
/// redirected back to your server, along with an authorization code. This is
/// used to obtain [Credentials] and create a fully-authorized [Client].
///
/// To use this class, you must first call [getAuthorizationUrl] to get the URL
/// to which to redirect the resource owner. Then once they've been redirected
/// back to your application, call [handleAuthorizationResponse] or
/// [handleAuthorizationCode] to process the authorization server's response and
/// construct a [Client].
///
/// [authorization code grant]: http://tools.ietf.org/html/draft-ietf-oauth-v2-31#section-4.1
class AuthorizationCodeGrant {
  /// The function used to parse parameters from a host's response.
  final GetParameters _getParameters;

  /// The client identifier for this client.
  ///
  /// The authorization server will issue each client a separate client
  /// identifier and secret, which allows the server to tell which client is
  /// accessing it. Some servers may also have an anonymous identifier/secret
  /// pair that any client may use.
  ///
  /// This is usually global to the program using this library.
  final String identifier;

  /// The client secret for this client.
  ///
  /// The authorization server will issue each client a separate client
  /// identifier and secret, which allows the server to tell which client is
  /// accessing it. Some servers may also have an anonymous identifier/secret
  /// pair that any client may use.
  ///
  /// This is usually global to the program using this library.
  ///
  /// Note that clients whose source code or binary executable is readily
  /// available may not be able to make sure the client secret is kept a secret.
  /// This is fine; OAuth2 servers generally won't rely on knowing with
  /// certainty that a client is who it claims to be.
  final String? secret;

  /// A URL provided by the authorization server that serves as the base for the
  /// URL that the resource owner will be redirected to to authorize this
  /// client.
  ///
  /// This will usually be listed in the authorization server's OAuth2 API
  /// documentation.
  final Uri authorizationEndpoint;

  /// A URL provided by the authorization server that this library uses to
  /// obtain long-lasting credentials.
  ///
  /// This will usually be listed in the authorization server's OAuth2 API
  /// documentation.
  final Uri tokenEndpoint;

  /// Callback to be invoked whenever the credentials are refreshed.
  ///
  /// This will be passed as-is to the constructed [Client].
  final CredentialsRefreshedCallback? _onCredentialsRefreshed;

  /// Whether to use HTTP Basic authentication for authorizing the client.
  final bool _basicAuth;

  /// A [String] used to separate scopes; defaults to `" "`.
  final String _delimiter;

  /// The HTTP client used to make HTTP requests.
  http.Client? _httpClient;

  /// The URL to which the resource owner will be redirected after they
  /// authorize this client with the authorization server.
  Uri? _redirectEndpoint;

  /// The scopes that the client is requesting access to.
  List<String>? _scopes;

  /// An opaque string that users of this library may specify that will be
  /// included in the response query parameters.
  String? _stateString;

  /// The current state of the grant object.
  _State _state = _State.initial;

  /// Allowed characters for generating the _codeVerifier
  static const String _charset =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  /// The PKCE code verifier. Will be generated if one is not provided in the
  /// constructor.
  String _codeVerifier;

  /// User defined of random generated PKCE code verifier.
  final bool _isCodeVerifierGenerated;

  /// List of allowed token type
  final Iterable<String> _allowedTokenTypes;

  /// Creates a new grant.
  ///
  /// If [basicAuth] is `true` (the default), the client credentials are sent to
  /// the server using using HTTP Basic authentication as defined in [RFC 2617].
  /// Otherwise, they're included in the request body. Note that the latter form
  /// is not recommended by the OAuth 2.0 spec, and should only be used if the
  /// server doesn't support Basic authentication.
  ///
  /// [RFC 2617]: https://tools.ietf.org/html/rfc2617
  ///
  /// [httpClient] is used for all HTTP requests made by this grant, as well as
  /// those of the [Client] is constructs.
  ///
  /// [onCredentialsRefreshed] will be called by the constructed [Client]
  /// whenever the credentials are refreshed.
  ///
  /// [codeVerifier] String to be used as PKCE code verifier. If none is
  /// provided a random codeVerifier will be generated.
  /// The codeVerifier must meet requirements specified in [RFC 7636].
  ///
  /// [allowedTokenType] List of allowed token type to check the response of
  /// OAuth2 autentication.
  ///
  /// [RFC 7636]: https://tools.ietf.org/html/rfc7636#section-4.1
  ///
  /// The scope strings will be separated by the provided [delimiter]. This
  /// defaults to `" "`, the OAuth2 standard, but some APIs (such as Facebook's)
  /// use non-standard delimiters.
  ///
  /// By default, this follows the OAuth2 spec and requires the server's
  /// responses to be in JSON format. However, some servers return non-standard
  /// response formats, which can be parsed using the [getParameters] function.
  ///
  /// This function is passed the `Content-Type` header of the response as well
  /// as its body as a UTF-8-decoded string. It should return a map in the same
  /// format as the [standard JSON response][].
  ///
  /// [standard JSON response]: https://tools.ietf.org/html/rfc6749#section-5.1
  AuthorizationCodeGrant(
      this.identifier, this.authorizationEndpoint, this.tokenEndpoint,
      {this.secret,
      String? delimiter,
      bool basicAuth = true,
      http.Client? httpClient,
      CredentialsRefreshedCallback? onCredentialsRefreshed,
      Map<String, dynamic> Function(MediaType? contentType, String body)?
          getParameters,
      String? codeVerifier,
      Iterable<String> allowedTokenTypes = const ['Bearer']
    })
      : _basicAuth = basicAuth,
        _httpClient = httpClient ?? http.Client(),
        _delimiter = delimiter ?? ' ',
        _getParameters = getParameters ?? parseJsonParameters,
        _onCredentialsRefreshed = onCredentialsRefreshed,
        _codeVerifier = codeVerifier ?? _createCodeVerifier(),
        _isCodeVerifierGenerated = codeVerifier == null,
        _allowedTokenTypes = allowedTokenTypes;

  /// Returns the URL to which the resource owner should be redirected to
  /// authorize this client.
  ///
  /// The resource owner will then be redirected to [redirect], which should
  /// point to a server controlled by the client. This redirect will have
  /// additional query parameters that should be passed to
  /// [handleAuthorizationResponse].
  ///
  /// The specific permissions being requested from the authorization server may
  /// be specified via [scopes]. The scope strings are specific to the
  /// authorization server and may be found in its documentation. Note that you
  /// may not be granted access to every scope you request; you may check the
  /// [Credentials.scopes] field of [Client.credentials] to see which scopes you
  /// were granted.
  ///
  /// An opaque [state] string may also be passed that will be present in the
  /// query parameters provided to the redirect URL.
  ///
  /// It is a [StateError] to call this more than once.
  Uri getAuthorizationUrl(Uri redirect,
      {Iterable<String>? scopes, String? state}) {
    if (_state != _State.initial) {
      throw StateError('The authorization URL has already been generated.');
    }
    _state = _State.awaitingResponse;

    // If generated, recalculate PKCE code verifier
    if (_isCodeVerifierGenerated) {
      _codeVerifier = _createCodeVerifier();
    }

    var scopeList = scopes?.toList() ?? <String>[];
    var codeChallenge = base64Url
        .encode(sha256.convert(ascii.encode(_codeVerifier)).bytes)
        .replaceAll('=', '');

    _redirectEndpoint = redirect;
    _scopes = scopeList;
    _stateString = state;
    var parameters = {
      'response_type': 'code',
      'client_id': identifier,
      'redirect_uri': redirect.toString(),
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256'
    };

    if (state != null) parameters['state'] = state;
    if (scopeList.isNotEmpty) parameters['scope'] = scopeList.join(_delimiter);

    return addQueryParameters(authorizationEndpoint, parameters);
  }

  /// Processes the query parameters added to a redirect from the authorization
  /// server.
  ///
  /// Note that this "response" is not an HTTP response, but rather the data
  /// passed to a server controlled by the client as query parameters on the
  /// redirect URL.
  ///
  /// It is a [StateError] to call this more than once, to call it before
  /// [getAuthorizationUrl] is called, or to call it after
  /// [handleAuthorizationCode] is called.
  ///
  /// Throws [FormatException] if [parameters] is invalid according to the
  /// OAuth2 spec or if the authorization server otherwise provides invalid
  /// responses. If `state` was passed to [getAuthorizationUrl], this will throw
  /// a [FormatException] if the `state` parameter doesn't match the original
  /// value.
  ///
  /// Throws [AuthorizationException] if the authorization fails.
  Future<Client> handleAuthorizationResponse(
      Map<String, String> parameters) async {
    if (_state == _State.initial) {
      throw StateError('The authorization URL has not yet been generated.');
    } else if (_state == _State.finished) {
      throw StateError('The authorization code has already been received.');
    }
    _state = _State.finished;

    if (_stateString != null) {
      if (!parameters.containsKey('state')) {
        throw FormatException('Invalid OAuth response for '
            '"$authorizationEndpoint": parameter "state" expected to be '
            '"$_stateString", was missing.');
      } else if (parameters['state'] != _stateString) {
        throw FormatException('Invalid OAuth response for '
            '"$authorizationEndpoint": parameter "state" expected to be '
            '"$_stateString", was "${parameters['state']}".');
      }
    }

    if (parameters.containsKey('error')) {
      var description = parameters['error_description'];
      var uriString = parameters['error_uri'];
      var uri = uriString == null ? null : Uri.parse(uriString);
      throw AuthorizationException(parameters['error']!, description, uri);
    } else if (!parameters.containsKey('code')) {
      throw FormatException('Invalid OAuth response for '
          '"$authorizationEndpoint": did not contain required parameter '
          '"code".');
    }

    return _handleAuthorizationCode(parameters['code']);
  }

  /// Processes an authorization code directly.
  ///
  /// Usually [handleAuthorizationResponse] is preferable to this method, since
  /// it validates all of the query parameters. However, some authorization
  /// servers allow the user to copy and paste an authorization code into a
  /// command-line application, in which case this method must be used.
  ///
  /// It is a [StateError] to call this more than once, to call it before
  /// [getAuthorizationUrl] is called, or to call it after
  /// [handleAuthorizationCode] is called.
  ///
  /// Throws [FormatException] if the authorization server provides invalid
  /// responses while retrieving credentials.
  ///
  /// Throws [AuthorizationException] if the authorization fails.
  Future<Client> handleAuthorizationCode(String authorizationCode) async {
    if (_state == _State.initial) {
      throw StateError('The authorization URL has not yet been generated.');
    } else if (_state == _State.finished) {
      throw StateError('The authorization code has already been received.');
    }
    _state = _State.finished;

    return _handleAuthorizationCode(authorizationCode);
  }

  /// This works just like [handleAuthorizationCode], except it doesn't validate
  /// the state beforehand.
  Future<Client> _handleAuthorizationCode(String? authorizationCode) async {
    var startTime = DateTime.now();

    var headers = <String, String>{};

    var body = {
      'grant_type': 'authorization_code',
      'code': authorizationCode,
      'redirect_uri': _redirectEndpoint.toString(),
      'code_verifier': _codeVerifier
    };

    var secret = this.secret;
    if (_basicAuth && secret != null) {
      headers['Authorization'] = basicAuthHeader(identifier, secret);
    } else {
      // The ID is required for this request any time basic auth isn't being
      // used, even if there's no actual client authentication to be done.
      body['client_id'] = identifier;
      if (secret != null) body['client_secret'] = secret;
    }

    var response =
        await _httpClient!.post(tokenEndpoint, headers: headers, body: body);

    var credentials = handleAccessTokenResponse(
        response, tokenEndpoint, startTime, _scopes, _delimiter,
        getParameters: _getParameters,
        allowedTokenTypes: _allowedTokenTypes);
    return Client(credentials,
        identifier: identifier,
        secret: secret,
        basicAuth: _basicAuth,
        httpClient: _httpClient,
        onCredentialsRefreshed: _onCredentialsRefreshed);
  }

  // Randomly generate a 128 character string to be used as the PKCE code
  // verifier.
  static String _createCodeVerifier() => List.generate(
        128,
        (i) => _charset[Random.secure().nextInt(_charset.length)],
      ).join();

  /// Closes the grant and frees its resources.
  ///
  /// This will close the underlying HTTP client, which is shared by the
  /// [Client] created by this grant, so it's not safe to close the grant and
  /// continue using the client.
  void close() {
    _httpClient?.close();
    _httpClient = null;
  }

  /// Return authentication step configuration.
  ///
  /// [AuthorizationCodeGrantAuthStep] can used in [authenticationStepLoad] to
  /// restore current step.
  AuthorizationCodeGrantAuthStep authenticationStep() {
    return AuthorizationCodeGrantAuthStep(
      _state.toString(),
      _stateString,
      _redirectEndpoint.toString(),
      _codeVerifier
    );
  }

  /// Restore Authentication step.
  void authenticationStepLoad(
    AuthorizationCodeGrantAuthStep authStep
  ) {
    _state = authStep.state == null
      ? _state : _State(authStep.state!);
    _redirectEndpoint = authStep.redirectEndpoint == null
      ? _redirectEndpoint : Uri.parse(authStep.redirectEndpoint!);
    _codeVerifier = authStep.codeVerifier == null
      ? _codeVerifier : authStep.codeVerifier!;
  }

  /// Reset Authentication step to initial data.
  void authenticationStepReset() {
    _state = _State.initial;
    if (_isCodeVerifierGenerated) {
      _codeVerifier = _createCodeVerifier();
    }
  }
}

/// States that [AuthorizationCodeGrant] can be in.
class _State {
  /// [AuthorizationCodeGrant.getAuthorizationUrl] has not yet been called for
  /// this grant.
  static const initial = _State('initial');

  // [AuthorizationCodeGrant.getAuthorizationUrl] has been called but neither
  // [AuthorizationCodeGrant.handleAuthorizationResponse] nor
  // [AuthorizationCodeGrant.handleAuthorizationCode] has been called.
  static const awaitingResponse = _State('awaiting response');

  // [AuthorizationCodeGrant.getAuthorizationUrl] and either
  // [AuthorizationCodeGrant.handleAuthorizationResponse] or
  // [AuthorizationCodeGrant.handleAuthorizationCode] have been called.
  static const finished = _State('finished');

  final String _name;

  const _State(this._name);

  @override
  String toString() => _name;
}

/// Cuttente authentcation step of [AuthorizationCodeGrant].
///
/// It can be used to save step of authentication for application than close
/// and restart during authentication cycle.
class AuthorizationCodeGrantAuthStep {
  final String? state;
  final String? stateString;
  final String? redirectEndpoint;
  final String? codeVerifier;

  AuthorizationCodeGrantAuthStep(this.state, this.stateString,
    this.redirectEndpoint, this.codeVerifier);

  /// Convert JSON to instance
  AuthorizationCodeGrantAuthStep.fromJson(Map<String, dynamic> json):
    state = json['state'] as String?,
    stateString = json['stateString'] as String?,
    redirectEndpoint = json['redirectEndpoint'] as String?,
    codeVerifier = json['codeVerifier'] as String?;

  /// Convert instance to JSON
  Map<String, dynamic> toJson() => {
    'state': state,
    'stateString': stateString,
    'redirectEndpoint': redirectEndpoint,
    'codeVerifier': codeVerifier
  };
}
