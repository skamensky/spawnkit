#!/usr/bin/env python3
"""Explicitly provision the home server's repository-only GitHub runner."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def github(path, method='GET', data=None):
    command = ['gh', 'api', '--method', method, path]
    if data is not None:
        command += ['--input', '-']
    output = subprocess.check_output(command, input=json.dumps(data) if data is not None else None,
                                     text=True)
    return json.loads(output) if output.strip() else None


def drain_workers(config):
    endpoint = f"repos/{config['runner_repository']}/actions/runners"
    runners = github(endpoint)['runners']
    pattern = re.compile(re.escape(config['runner_name']) + r'(?:-\d{2})?')
    managed = [r for r in runners if pattern.fullmatch(r['name'])]
    desired = {config['runner_name'] if i == 1 else f"{config['runner_name']}-{i:02d}"
               for i in range(1, config['runner_count'] + 1)}
    surplus = [r['name'] for r in managed if r['name'] not in desired]
    if surplus:
        raise RuntimeError(f'Retire surplus workers before reducing the pool: {surplus}')
    removed = []
    try:
        for runner in managed:
            if any(label['name'] == 'home-server' for label in runner['labels']):
                github(f"{endpoint}/{runner['id']}/labels/home-server", method='DELETE')
                removed.append(runner['id'])
        deadline = time.monotonic() + 1800
        last_notice = 0
        while True:
            current = github(endpoint)['runners']
            busy = [r['name'] for r in current if pattern.fullmatch(r['name']) and r['busy']]
            if not busy:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError(f'Timed out draining active CI jobs: {busy}')
            if time.monotonic() - last_notice >= 60:
                print(f'Waiting for current jobs to finish: {", ".join(busy)}', flush=True)
                last_notice = time.monotonic()
            time.sleep(5)
    except BaseException:
        restore_workers(endpoint, removed)
        raise
    return endpoint, removed


def restore_workers(endpoint, runner_ids):
    for runner_id in runner_ids:
        github(f'{endpoint}/{runner_id}/labels', method='POST', data={'labels': ['home-server']})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='home-server')
    parser.add_argument('--ssh-user', default='shmuel')
    parser.add_argument('--syntax-check', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9._-]+', args.host):
        parser.error('Use a DNS hostname')
    repo = Path(__file__).resolve().parents[1]
    config = json.loads((repo / 'hosts/server/github-runner.json').read_text())
    expression = (
        f'let f = builtins.getFlake {json.dumps(str(repo))}; '
        'in (import f.inputs.nixpkgs { system = builtins.currentSystem; }).python3Packages.ansible-core'
    )
    package = subprocess.check_output([
        'nix', '--extra-experimental-features', 'nix-command flakes', 'build', '--impure',
        '--no-link', '--print-out-paths', '--expr', expression,
    ], text=True).strip()
    env = os.environ.copy()
    inventory = {'all': {'hosts': {args.host: {
        'ansible_host': args.host, 'ansible_user': args.ssh_user,
        'ansible_python_interpreter': '/usr/bin/python3',
        'ansible_ssh_common_args': '-o BatchMode=yes -o StrictHostKeyChecking=yes',
    }}}}
    endpoint, removed = None, []
    try:
        if not args.syntax_check:
            endpoint, removed = drain_workers(config)
            registration = github(f"repos/{config['runner_repository']}/actions/runners/registration-token",
                                  method='POST')
            env['RUNNER_REGISTRATION_TOKEN'] = registration['token']
        with tempfile.TemporaryDirectory(prefix='home-runner-inventory-') as temp:
            path = Path(temp) / 'inventory.json'
            path.write_text(json.dumps(inventory))
            command = [str(Path(package) / 'bin/ansible-playbook'), '-i', str(path),
                       str(repo / 'ansible/github-runner.yml')]
            if args.syntax_check:
                command.append('--syntax-check')
            subprocess.run(command, env=env, check=True)
    finally:
        if endpoint is not None:
            restore_workers(endpoint, removed)


if __name__ == '__main__':
    main()
