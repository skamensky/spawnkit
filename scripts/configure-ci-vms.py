#!/usr/bin/env python3
"""Apply the narrow home-server hypervisor role without enrolling the host."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--syntax-check', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    expression = (f'let f = builtins.getFlake {json.dumps(str(repo))}; '
                  'in (import f.inputs.nixpkgs { system = builtins.currentSystem; }).python3Packages.ansible-core')
    package = subprocess.check_output([
        'nix', '--extra-experimental-features', 'nix-command flakes', 'build', '--impure',
        '--no-link', '--print-out-paths', '--expr', expression], text=True).strip()
    inventory = {'all': {'hosts': {'home-server': {
        'ansible_user': 'shmuel', 'ansible_python_interpreter': '/usr/bin/python3',
        'ansible_ssh_common_args': '-o BatchMode=yes -o StrictHostKeyChecking=yes'}}}}
    with tempfile.TemporaryDirectory(prefix='ci-vms-inventory-') as temp:
        path = Path(temp)/'inventory.json'
        path.write_text(json.dumps(inventory))
        command = [str(Path(package)/'bin/ansible-playbook'), '-i', str(path), str(repo/'ansible/ci-vms.yml')]
        if args.syntax_check:
            command.append('--syntax-check')
        subprocess.run(command, check=True)


if __name__ == '__main__':
    main()
