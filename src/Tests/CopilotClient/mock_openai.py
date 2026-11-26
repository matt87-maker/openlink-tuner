"""A stand-in for the OpenAI Responses API, for testing the copilot's streaming client offline.
Run: python3 mock_openai.py PORT. The model name picks the behaviour:
  ok         streams a reply with a changes block in small pieces
  bad-key    401, quota 429, missing 404, fail mid-stream (response.failed event), slow (long stream for cancel tests)
The last request body is saved to last_request.json next to this file."""
import json, sys, time, os
from http.server import BaseHTTPRequestHandler, HTTPServer

REPLY = ("You're **4 % lean** at 2000 RPM / 50 kPa in the warm log.\n\n"
         "| Cell | Logged λ | Target |\n|---|---|---|\n| 2000 / 50 | 1.04 | 1.00 |\n\n"
         "Hit Apply.\n```changes\n[{\"id\": 2365, \"op\": \"lambda_correct\", \"why\": \"logged lean\"}]\n```\n")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'last_request.json'), 'w') as f:
            json.dump({'auth': self.headers.get('Authorization'), 'body': body}, f)
        model = body.get('model')
        def err(code, message, typ='invalid_request_error', c=None):
            data = json.dumps({'error': {'message': message, 'type': typ, 'code': c}}).encode()
            self.send_response(code); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        if model == 'bad-key': return err(401, 'Incorrect API key provided')
        if model == 'quota': return err(429, 'You exceeded your current quota', 'insufficient_quota', 'insufficient_quota')
        if model == 'missing': return err(404, 'The model `missing` does not exist')
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        def event(obj):
            self.wfile.write(('event: %s\ndata: %s\n\n' % (obj['type'], json.dumps(obj))).encode()); self.wfile.flush()
        event({'type': 'response.created', 'response': {'id': 'r1'}})
        if model == 'fail':
            event({'type': 'response.output_text.delta', 'delta': 'Partial '})
            return event({'type': 'response.failed', 'response': {'error': {'message': 'The server had an error'}}})
        text = REPLY * (40 if model == 'slow' else 1)
        for i in range(0, len(text), 7):
            event({'type': 'response.output_text.delta', 'delta': text[i:i + 7]})
            if model == 'slow': time.sleep(0.02)
        event({'type': 'response.completed', 'response': {'id': 'r1'}})
        self.wfile.write(b'data: [DONE]\n\n')

HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
