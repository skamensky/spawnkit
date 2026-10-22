#!/usr/bin/env python3
"""Explicitly provision the home server's repository-only GitHub runner."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


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
    if not args.syntax_check:
        registration = json.loads(subprocess.check_output([
            'gh', 'api', '--method', 'POST',
            f"repos/{config['runner_repository']}/actions/runners/registration-token",
        ], text=True))
        env['RUNNER_REGISTRATION_TOKEN'] = registration['token']
    inventory = {'all': {'hosts': {args.host: {
        'ansible_host': args.host, 'ansible_user': args.ssh_user,
        'ansible_python_interpreter': '/usr/bin/python3',
        'ansible_ssh_common_args': '-o BatchMode=yes -o StrictHostKeyChecking=yes',
    }}}}
    with tempfile.TemporaryDirectory(prefix='home-runner-inventory-') as temp:
        path = Path(temp) / 'inventory.json'
        path.write_text(json.dumps(inventory))
        command = [str(Path(package) / 'bin/ansible-playbook'), '-i', str(path),
                   str(repo / 'ansible/github-runner.yml')]
        if args.syntax_check:
            command.append('--syntax-check')
        subprocess.run(command, env=env, check=True)


if __name__ == '__main__':
    main()
