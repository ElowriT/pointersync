"""Serves the frame probe page to the iPad (or any device on the same Wi-Fi) and saves
its results on this Mac, next to PointerSync's recordings.

Usage: python3 tools/probe_server.py   then open the address it prints.
"""
import http.server
import json
import pathlib
import re
import socket
import time

PORT = 8765
PAGE = pathlib.Path(__file__).resolve().parent / 'frame-probe-standalone.html'
OUT = pathlib.Path.home() / 'Library/Application Support/PointerSync/measurements'
SUMMARY = ('label', 'device', 'engine', 'frameHz', 'eventHz', 'rawHz', 'framesMoving', 'hist',
           'uneven', 'uneven95', 'stalls', 'createdAt')


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ('/', '/index.html'):
            self.reply(200, PAGE.read_bytes(), 'text/html; charset=utf-8')
        elif self.path == '/runs':
            runs = []
            for f in sorted(OUT.glob('probe-*.json'), reverse=True)[:30]:
                try:
                    d = json.loads(f.read_text())
                    runs.append({k: d.get(k) for k in SUMMARY})
                except (OSError, ValueError):
                    pass
            self.reply(200, json.dumps(runs).encode(), 'application/json')
        else:
            self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        if self.path != '/save' or not 0 < length <= 5_000_000:
            self.send_error(400)
            return
        try:
            data = json.loads(self.rfile.read(length))
        except ValueError:
            self.send_error(400)
            return
        device = re.sub(r'[^A-Za-z]', '', str(data.get('device', ''))) or 'device'
        name = f"probe-{device}-{time.strftime('%Y%m%d-%H%M%S')}.json"
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / name).write_text(json.dumps(data))
        print(f'Сохранено: {OUT / name}', flush=True)
        self.reply(200, json.dumps({'saved': name}).encode(), 'application/json')

    def reply(self, code, body, kind):
        self.send_response(code)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def lan_address():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('10.255.255.255', 1))
        return s.getsockname()[0]
    except OSError:
        return '127.0.0.1'
    finally:
        s.close()


if __name__ == '__main__':
    print(f'На iPad открой в Safari: http://{lan_address()}:{PORT}/', flush=True)
    print(f'На Маке: http://localhost:{PORT}/', flush=True)
    print('Остановить: Ctrl+C', flush=True)
    http.server.ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
