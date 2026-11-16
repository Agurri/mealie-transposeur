#!/usr/bin/env python3
"""Relais web du transposeur de recettes.

Le navigateur ne peut pas lire lui-même le site d'un auteur ou d'un éditeur
(blocage CORS). Ce petit service, lancé dans le conteneur et joint par la page
à l'adresse /web?u=ADRESSE, va chercher la page demandée et la renvoie.

Garde-fous : requêtes GET seulement, vers des sites publics (les adresses du
réseau local sont refusées, y compris après une redirection), sur les ports
80 et 443, avec une taille et une durée limitées. Aucun cookie, aucun
identifiant n'est transmis. Il n'écoute que sur 127.0.0.1 : seul Caddy, dans
le même conteneur, lui parle.
"""
import gzip
import http.client
import io
import ipaddress
import json
import os
import socket
import ssl
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("TRANSPOSEUR_WEB_PORT", "8377"))
MAX_BYTES = 12 * 1024 * 1024
TIMEOUT = 20
MAX_REDIRECTS = 5
USER_AGENT = "Mozilla/5.0 (compatible; mealie-transposeur/1.0; +https://github.com/Agurri/mealie-transposeur)"
# Réservé aux tests automatiques : autorise les adresses locales et tous les ports.
TEST_MODE = os.environ.get("TRANSPOSEUR_WEB_TEST") == "1"


class Refused(Exception):
    pass


def public_ip(host, port):
    """Adresse IP publique de l'hôte (la connexion se fait ensuite vers cette adresse précise)."""
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except OSError:
        raise Refused("nom de site introuvable")
    for info in infos:
        ip = info[4][0].split("%")[0]
        if TEST_MODE or ipaddress.ip_address(ip).is_global:
            return ip
    raise Refused("adresse non publique refusée")


class PinnedHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS vers une adresse IP déjà vérifiée, le certificat restant contrôlé pour le nom du site."""

    def __init__(self, host, ip, port, context, timeout):
        super().__init__(host, port, timeout=timeout, context=context)
        self._pinned_ip = ip
        self._ctx = context

    def connect(self):
        sock = socket.create_connection((self._pinned_ip, self.port), self.timeout)
        self.sock = self._ctx.wrap_socket(sock, server_hostname=self.host)


def fetch_once(url):
    """Une requête GET, sans suivre les redirections. Renvoie (code, en-têtes, corps, adresse de redirection)."""
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise Refused("adresse invalide")
    if u.username or u.password:
        raise Refused("adresse avec identifiants refusée")
    port = u.port or (443 if u.scheme == "https" else 80)
    if not TEST_MODE and port not in (80, 443):
        raise Refused("port non autorisé")
    ip = public_ip(u.hostname, port)
    path = (u.path or "/") + ("?" + u.query if u.query else "")
    if u.scheme == "https":
        conn = PinnedHTTPSConnection(u.hostname, ip, port, ssl.create_default_context(), TIMEOUT)
    else:
        conn = http.client.HTTPConnection(ip, port, timeout=TIMEOUT)
    try:
        conn.putrequest("GET", path, skip_host=True, skip_accept_encoding=True)
        default = (u.scheme == "https" and port == 443) or (u.scheme == "http" and port == 80)
        host = u.hostname if ":" not in u.hostname else "[" + u.hostname + "]"
        conn.putheader("Host", host if default else "%s:%d" % (host, port))
        conn.putheader("User-Agent", USER_AGENT)
        conn.putheader("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        conn.putheader("Accept-Language", "fr,en;q=0.8")
        conn.putheader("Accept-Encoding", "gzip")
        conn.putheader("Connection", "close")
        conn.endheaders()
        resp = conn.getresponse()
        if resp.status in (301, 302, 303, 307, 308):
            loc = resp.getheader("Location")
            if loc:
                return resp.status, resp, b"", urllib.parse.urljoin(url, loc)
        body = resp.read(MAX_BYTES + 1)
        if len(body) > MAX_BYTES:
            raise Refused("page trop volumineuse")
        return resp.status, resp, body, None
    finally:
        conn.close()


def gunzip(data):
    with gzip.GzipFile(fileobj=io.BytesIO(data)) as g:
        out = g.read(MAX_BYTES + 1)
    if len(out) > MAX_BYTES:
        raise Refused("page trop volumineuse")
    return out


def fetch(url):
    """Suit les redirections (chaque étape est revérifiée) et renvoie (code, type, corps en UTF-8, adresse finale)."""
    for _ in range(MAX_REDIRECTS + 1):
        status, resp, body, redirect = fetch_once(url)
        if redirect:
            url = redirect
            continue
        ctype = resp.getheader("Content-Type") or "application/octet-stream"
        if (resp.getheader("Content-Encoding") or "").lower() == "gzip" or body[:2] == b"\x1f\x8b":
            try:
                body = gunzip(body)
                if url.split("?")[0].endswith(".gz"):
                    ctype = "application/xml; charset=utf-8"
            except (OSError, EOFError):
                pass
        low = ctype.lower()
        if "charset=" in low and any(t in low for t in ("text/", "xml", "json")):
            charset = low.split("charset=")[1].split(";")[0].strip().strip("\"'")
            if charset not in ("utf-8", "utf8"):
                try:
                    body = body.decode(charset, "replace").encode("utf-8")
                    ctype = ctype.split(";")[0] + "; charset=utf-8"
                except LookupError:
                    pass
        return status, ctype, body, url
    raise Refused("trop de redirections")


class Handler(BaseHTTPRequestHandler):
    server_version = "transposeur-web/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def reply(self, code, ctype, body, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Web-Relay", "1")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def error(self, code, message):
        self.reply(code, "application/json; charset=utf-8", json.dumps({"error": message}, ensure_ascii=False).encode("utf-8"))

    def do_GET(self):
        parts = urllib.parse.urlsplit(self.path)
        if parts.path != "/web":
            return self.error(404, "adresse inconnue")
        query = urllib.parse.parse_qs(parts.query)
        if "ping" in query:
            return self.reply(200, "application/json", b'{"ok":true,"v":1}')
        # En-tête que seule la page du transposeur envoie : une autre page web ne peut pas se servir du relais.
        if self.headers.get("X-Transposeur") != "1":
            return self.error(403, "requête refusée")
        url = (query.get("u") or [""])[0]
        try:
            status, ctype, body, final = fetch(url)
        except Refused as e:
            return self.error(502, str(e))
        except ssl.SSLError:
            return self.error(502, "certificat du site refusé")
        except (OSError, http.client.HTTPException) as e:
            return self.error(502, "le site ne répond pas (%s)" % type(e).__name__)
        # Le contenu est renvoyé comme du texte brut : il n'est jamais affiché ni exécuté tel quel par le navigateur.
        self.reply(200, "text/plain; charset=utf-8", body, {
            "X-Web-Status": str(status),
            "X-Web-Url": urllib.parse.quote(final, safe=":/?&=%#@+,;~!$'()*[]"),
            "X-Web-Type": ctype.split(";")[0].strip()[:80],
        })


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
