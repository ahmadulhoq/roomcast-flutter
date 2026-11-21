/// The base URL for an address typed by the user or saved by an older
/// version ("192.168.1.5:8888", "HTTP://host:8888/", ...): scheme added if
/// missing, lower-case, no trailing slash or pasted /api/... endpoint (a
/// path, e.g. behind a reverse proxy, is kept). Null if it isn't an
/// http(s) address.
String? normalizeBaseUrl(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(text)) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  // A pasted endpoint ("…:8888/api/info") means the base before /api.
  final path = uri.path.replaceFirst(RegExp(r'/api(/.*)?$'), '').replaceAll(RegExp(r'/+$'), '');
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: path)
      .toString();
}
