#!/usr/bin/env python3
"""Deterministic local model transport; never forwards requests or uses credentials."""
import http.server,json,sys,pathlib,threading
root=pathlib.Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
release=threading.Event()
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  if self.path=='/release':
   release.set(); self.send_response(200);self.end_headers();self.wfile.write(b'ok');return
  self.send_response(404);self.end_headers()
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  with open(root/'requests.jsonl','a') as f:f.write(json.dumps({'path':self.path,'body':body})+'\n')
  if self.path!='/v1/chat/completions':
   self.send_response(400);self.end_headers();self.wfile.write(b'unsupported fixture route');return
  messages=body.get('messages',[])
  text=json.dumps(messages)
  has_tool=any(m.get('role')=='tool' for m in messages)
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  def chunk(delta,reason=None):
   payload={'id':'fm-fixture','object':'chat.completion.chunk','created':1,'model':'control','choices':[{'index':0,'delta':delta,'finish_reason':reason}]}
   self.wfile.write(('data: '+json.dumps(payload)+'\n\n').encode());self.wfile.flush()
  chunk({'role':'assistant'})
  if body.get('tools') and 'FM_PERMISSION_PROBE' in text and not has_tool:
   chunk({'tool_calls':[{'index':0,'id':'call_fm_permission','type':'function','function':{'name':'bash','arguments':json.dumps({'command':'printf FM_LOCAL_ONLY','description':'Print task-local sentinel'})}}]})
   chunk({},'tool_calls')
  elif body.get('tools') and 'FM_BUSY_PROBE' in text and 'FM_QUEUE_PROBE' not in text:
   (root/'busy-request').write_text('active\n')
   if not release.wait(35):
    (root/'busy-timeout').write_text('timed out\n')
   chunk({'content':'FM_BUSY_FINISHED'});chunk({},'stop')
  else:
   chunk({'content':'FM_LOCAL_FINISHED'});chunk({},'stop')
  self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'listener.json').write_text(json.dumps({'port':server.server_address[1],'pid':__import__('os').getpid()}))
server.serve_forever()
