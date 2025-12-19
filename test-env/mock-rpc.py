#!/usr/bin/env python3
"""Mock JSON-RPC server for testing APISIX plugins"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode('utf-8')
        try:
            req = json.loads(body)
            # Handle batch requests
            if isinstance(req, list):
                responses = []
                for r in req:
                    responses.append({
                        'jsonrpc': '2.0',
                        'id': r.get('id'),
                        'result': f'mock_result_for_{r.get("method")}'
                    })
                response = json.dumps(responses)
            else:
                response = json.dumps({
                    'jsonrpc': '2.0',
                    'id': req.get('id'),
                    'result': f'mock_result_for_{req.get("method")}'
                })
        except Exception as e:
            response = json.dumps({
                'jsonrpc': '2.0',
                'id': None,
                'error': {'code': -32700, 'message': f'Parse error: {str(e)}'}
            })
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(response.encode())

    def log_message(self, format, *args):
        print(f'[MOCK-RPC] {args[0]}')

if __name__ == '__main__':
    print('Mock RPC server starting on port 8545...')
    HTTPServer(('0.0.0.0', 8545), Handler).serve_forever()
