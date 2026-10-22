from pathlib import Path
import http.server,threading,tempfile,subprocess,time
src=Path(__file__).resolve().parent
payload=bytes(i%251 for i in range(256*1024))
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  assert self.headers.get("Accept-Encoding")=="identity"
  if self.path=='/forbidden':self.send_error(403);return
  offset=0
  if self.path!='/ignore' and self.headers.get('Range'):offset=int(self.headers['Range'].split('=')[1].split('-')[0])
  self.send_response(206 if offset else 200);self.send_header('Content-Length',str(len(payload)-offset))
  if offset:self.send_header('Content-Range',f'bytes {offset}-{len(payload)-1}/{len(payload)}')
  self.end_headers()
  try:
   if self.path=='/short':self.wfile.write(payload[:128]);self.close_connection=True;return
   for start in range(offset,len(payload),4096):
    self.wfile.write(payload[start:start+4096]);self.wfile.flush()
    if self.path=='/slow':time.sleep(.012)
  except (BrokenPipeError,ConnectionResetError):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
try:
 with tempfile.TemporaryDirectory(prefix='ALLZIP-network-tests-') as temp:
  root=Path(temp);(root/'main.swift').write_text((src/'test_network.swift').read_text())
  subprocess.run(['swiftc','-swift-version','5',str(src/'GoogleAuth.swift'),str(src/'DownloadTransfer.swift'),str(src/'Drive.swift'),str(root/'main.swift'),'-framework','AppKit','-framework','Security','-o',str(root/'tests')],check=True)
  subprocess.run([str(root/'tests'),str(root),f'http://127.0.0.1:{server.server_port}'],check=True)
finally:server.shutdown()
