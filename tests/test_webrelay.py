"""Tests du relais web : python3 tests/test_webrelay.py"""
import gzip
import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import webrelay  # noqa: E402


class Site(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/page":
            body, ctype = "<html>café</html>".encode("utf-8"), "text/html; charset=utf-8"
        elif self.path == "/latin1":
            body, ctype = "crème brûlée".encode("latin-1"), "text/html; charset=iso-8859-1"
        elif self.path == "/sitemap.xml.gz":
            body, ctype = gzip.compress(b"<urlset><url><loc>https://x/a</loc></url></urlset>"), "application/x-gzip"
        elif self.path == "/redir":
            self.send_response(302)
            self.send_header("Location", "/page")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        elif self.path == "/boucle":
            self.send_response(302)
            self.send_header("Location", "/boucle")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        elif self.path == "/gros":
            body, ctype = b"x" * (webrelay.MAX_BYTES + 10), "text/plain"
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve(handler):
    srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


class RelayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.site = serve(Site)
        cls.relay = serve(webrelay.Handler)
        cls.base = "http://127.0.0.1:%d" % cls.site.server_address[1]

    def setUp(self):
        webrelay.TEST_MODE = True

    def get(self, target, header=True, raw=None):
        url = "http://127.0.0.1:%d/web?%s" % (self.relay.server_address[1], raw or "u=" + urllib.request.quote(target, safe=""))
        req = urllib.request.Request(url, headers={"X-Transposeur": "1"} if header else {})
        try:
            r = urllib.request.urlopen(req, timeout=30)
        except urllib.error.HTTPError as e:
            r = e
        return r.status, dict(r.headers), r.read()

    def test_page(self):
        code, h, body = self.get(self.base + "/page")
        self.assertEqual((code, h["X-Web-Relay"], h["X-Web-Status"]), (200, "1", "200"))
        self.assertEqual(body.decode("utf-8"), "<html>café</html>")
        self.assertTrue(h["Content-Type"].startswith("text/plain"))

    def test_transcodage(self):
        self.assertEqual(self.get(self.base + "/latin1")[2].decode("utf-8"), "crème brûlée")

    def test_sitemap_gz(self):
        self.assertIn(b"<loc>https://x/a</loc>", self.get(self.base + "/sitemap.xml.gz")[2])

    def test_redirection(self):
        code, h, body = self.get(self.base + "/redir")
        self.assertEqual(h["X-Web-Status"], "200")
        self.assertTrue(h["X-Web-Url"].endswith("/page"))

    def test_trop_de_redirections(self):
        code, h, body = self.get(self.base + "/boucle")
        self.assertEqual(code, 502)
        self.assertIn("redirections", json.loads(body)["error"])

    def test_erreur_du_site_transmise(self):
        code, h, body = self.get(self.base + "/absent")
        self.assertEqual((code, h["X-Web-Status"]), (200, "404"))

    def test_trop_gros(self):
        self.assertEqual(self.get(self.base + "/gros")[0], 502)

    def test_ping(self):
        code, h, body = self.get("", header=False, raw="ping=1")
        self.assertEqual((code, json.loads(body)["ok"]), (200, True))

    def test_sans_entete(self):
        self.assertEqual(self.get(self.base + "/page", header=False)[0], 403)

    def test_adresses_refusees(self):
        for bad in ("ftp://exemple.com/", "file:///etc/passwd", "http://user:mdp@exemple.com/", "pas-une-adresse", ""):
            self.assertEqual(self.get(bad)[0], 502, bad)

    def test_reseau_local_refuse(self):
        webrelay.TEST_MODE = False
        for bad in (self.base + "/page", "http://127.0.0.1/", "http://localhost/", "http://192.168.1.1/", "http://10.0.0.1/",
                    "http://169.254.169.254/latest/meta-data/", "http://[::1]/", "http://0.0.0.0/", "https://exemple.com:8443/"):
            code, h, body = self.get(bad)
            self.assertEqual(code, 502, bad)
            self.assertNotIn("X-Web-Status", h, bad)


if __name__ == "__main__":
    unittest.main(verbosity=1)
