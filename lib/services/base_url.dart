/// The backend's default HTTP port (http_server.port).
const defaultBackendPort = 8888;

/// The base URL for an address typed by the user or saved by an older
/// version. Conservative: what was typed is kept (scheme, port — even
/// :80 —, path, query), except that
/// - a bare host ("192.168.1.5": no scheme, port or path) gets http:// and
///   the backend's port, not http's 80 (a path means a reverse proxy);
/// - the scheme and host are lower-cased;
/// - trailing slashes and a pasted /api/... endpoint are dropped.
/// Null if it isn't an http(s) address, or holds credentials (user:pass@):
/// they would be shown on screen and stored in plain text.
String? normalizeBaseUrl(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  final typedScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(text);
  // Decided from the text: Uri drops a default port (":80" reads as none).
  final authority = text.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '').split(RegExp(r'[/?#]')).first;
  final typedPort = RegExp(r':\d+$').hasMatch(authority.split('@').last);
  if (!typedScheme) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.userInfo.isNotEmpty) return null;
  // A pasted endpoint ("…:8888/api/info") means the base before /api.
  final path = uri.path.replaceFirst(RegExp(r'/api(/.*)?$'), '').replaceAll(RegExp(r'/+$'), '');
  final bareHost = !typedScheme && !typedPort && path.isEmpty;
  final port = uri.hasPort ? uri.port : (bareHost ? defaultBackendPort : null);
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: port,
    path: path,
    query: uri.hasQuery ? uri.query : null,
  ).toString();
}
