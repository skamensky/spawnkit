#!/usr/bin/env python3
"""Prepare GitHub's interactive manifest flow; deliver its key only to host root."""
import html
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import secrets
import subprocess
import urllib.parse
import urllib.request


def main():
    # Refuse to replace an existing app identity or private key.
    subprocess.run(['tailscale','ssh','shmuel@home-server',
        "sudo sh -c 'test ! -e /etc/spawnkit-ci/github-app.pem && test ! -e /etc/spawnkit-ci/github-app.json'"],
        check=True,capture_output=True)
    state=secrets.token_urlsafe(32)
    manifest={'name':'Skyline home CI VM provisioner',
              'url':'https://github.com/skamensky/spawnkit',
              'redirect_url':'http://127.0.0.1:8739/callback',
              'public':False,'hook_attributes':{'active':False,'url':'https://github.com/skamensky/spawnkit'},
              'default_permissions':{'administration':'write','actions':'read'},'default_events':[]}
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*_):
            pass

        def do_GET(self):
            parsed=urllib.parse.urlparse(self.path)
            if parsed.path=='/':
                action='https://github.com/organizations/SkylineCapital/settings/apps/new?state='+state
                body=f'''<!doctype html><title>Home CI provisioning app</title>
                <h1>Skyline home CI VM provisioner</h1>
                <p>Private app owned by SkylineCapital. Install it only on supa-crm.</p>
                <p>Repository Administration: read and write. GitHub requires this permission to register and retire repository runners.</p>
                <p>Actions: read, to inspect the queue and start VMs only when needed.</p>
                <p>The private key will be stored only in root-protected /etc/spawnkit-ci on the home server, outside all guests. No webhook or host control endpoint is exposed.</p>
                <form method="post" action="{html.escape(action,quote=True)}">
                <input type="hidden" name="manifest" value="{html.escape(json.dumps(manifest),quote=True)}">
                <button>Review this app on GitHub</button></form>'''
            elif parsed.path=='/callback':
                params=urllib.parse.parse_qs(parsed.query)
                if params.get('state')!=[state] or not params.get('code'):
                    self.send_error(400,'Invalid registration state')
                    return
                code=params['code'][0]
                request=urllib.request.Request('https://api.github.com/app-manifests/'+urllib.parse.quote(code,safe='')+'/conversions',
                                               method='POST',headers={'Accept':'application/vnd.github+json'})
                with urllib.request.urlopen(request,timeout=30) as response:
                    result=json.load(response)
                # Provider-managed key never appears in command arguments or local files.
                remote="sudo sh -c 'umask 077; set -C; cat > /etc/spawnkit-ci/github-app.pem'"
                subprocess.run(['tailscale','ssh','shmuel@home-server',remote],
                               input=result['pem'],text=True,check=True,capture_output=True)
                settings={'app_id':result['id'],'slug':result['slug']}
                remote="sudo sh -c 'umask 077; set -C; cat > /etc/spawnkit-ci/github-app.json'"
                subprocess.run(['tailscale','ssh','shmuel@home-server',remote],
                               input=json.dumps(settings),text=True,check=True,capture_output=True)
                print(json.dumps({'app_id':result['id'],'slug':result['slug'],'key_delivered_to_host_root':True}),flush=True)
                install='https://github.com/apps/'+urllib.parse.quote(result['slug'],safe='')+'/installations/new'
                body=f'<h1>App created; key delivered to host root</h1><p><a href="{html.escape(install,quote=True)}">Install on SkylineCapital, selecting only supa-crm</a></p>'
            else:
                self.send_error(404)
                return
            payload=body.encode()
            self.send_response(200)
            self.send_header('Content-Type','text/html; charset=utf-8')
            self.send_header('Content-Length',str(len(payload)))
            self.send_header('Cache-Control','no-store')
            self.end_headers()
            self.wfile.write(payload)
    print('Review page: http://127.0.0.1:8739/',flush=True)
    HTTPServer(('127.0.0.1',8739),Handler).serve_forever()


if __name__=='__main__':
    main()
