#!/usr/bin/python3
"""Host-owned lifecycle for one-job KVM GitHub runners. Guest output is data only."""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET

import yaml

ROOT = Path('/var/lib/libvirt/images/spawnkit-ci')
STATE = Path('/var/lib/spawnkit-ci/slots')
CONFIG = Path('/etc/spawnkit-ci/config.json')
NAME = re.compile(r'ci-[a-f0-9]{32}')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def event(kind, **fields):
    line=json.dumps({'time':datetime.datetime.now(datetime.timezone.utc).isoformat(),
                     'event':kind, **fields})
    print(line,flush=True)
    log=Path('/var/log/spawnkit-ci')
    if log.exists():
        fd=os.open(log/'lifecycle.jsonl',os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
        with os.fdopen(fd,'a') as stream:
            stream.write(line+'\n')


def file_hash(path):
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1048576),b''):
            digest.update(chunk)
    return digest.hexdigest()


def config():
    c = json.loads(CONFIG.read_text())
    assert 1 <= c['ci_slots'] <= 6
    assert 1 <= c['ci_guest_vcpus'] <= 4
    assert 2048 <= c['ci_guest_memory_mib'] <= 8192
    assert c['ci_slots'] * c['ci_guest_memory_mib'] <= 24576
    return c


def require_current_kernel(c):
    pattern=r'^(\d+)\.(\d+)\.(\d+)-(\d+)'
    actual=re.match(pattern,platform.release())
    minimum=re.match(pattern,c['ci_min_host_kernel'])
    if actual is None or minimum is None or tuple(map(int,actual.groups()))<tuple(map(int,minimum.groups())):
        raise RuntimeError('Boot the staged supported host kernel before starting the production CI pool')


def vm_name(name):
    if not NAME.fullmatch(name):
        raise ValueError('VM name is outside the managed namespace')
    return name


def domain_xml(name, directory, slot, c):
    vm_name(name)
    root = ET.Element('domain', type='kvm')
    ET.SubElement(root,'name').text=name
    ET.SubElement(root,'memory',unit='MiB').text=str(c['ci_guest_memory_mib'])
    ET.SubElement(root,'vcpu',placement='static').text=str(c['ci_guest_vcpus'])
    resource=ET.SubElement(root,'resource')
    ET.SubElement(resource,'partition').text='/machine'
    os_node=ET.SubElement(root,'os')
    ET.SubElement(os_node,'type',arch='x86_64',machine='q35').text='hvm'
    ET.SubElement(os_node,'boot',dev='hd')
    features=ET.SubElement(root,'features')
    ET.SubElement(features,'acpi')
    ET.SubElement(features,'apic')
    cpu=ET.SubElement(root,'cpu',mode='host-passthrough',check='none')
    ET.SubElement(cpu,'feature',policy='disable',name='vmx')
    ET.SubElement(root,'clock',offset='utc')
    ET.SubElement(root,'on_poweroff').text='destroy'
    ET.SubElement(root,'on_reboot').text='destroy'
    ET.SubElement(root,'on_crash').text='destroy'
    devices=ET.SubElement(root,'devices')
    ET.SubElement(devices,'emulator').text='/usr/bin/qemu-system-x86_64'
    disk=ET.SubElement(devices,'disk',type='file',device='disk')
    ET.SubElement(disk,'driver',name='qemu',type='qcow2',discard='unmap')
    ET.SubElement(disk,'source',file=str(directory/'disk.qcow2'))
    ET.SubElement(disk,'target',dev='vda',bus='virtio')
    seed=ET.SubElement(devices,'disk',type='file',device='cdrom')
    ET.SubElement(seed,'driver',name='qemu',type='raw')
    ET.SubElement(seed,'source',file=str(directory/'seed.iso'))
    ET.SubElement(seed,'target',dev='sda',bus='sata')
    ET.SubElement(seed,'readonly')
    interface=ET.SubElement(devices,'interface',type='network')
    ET.SubElement(interface,'mac',address=f'52:54:00:fb:00:{slot:02x}')
    ET.SubElement(interface,'source',network=c['ci_network'])
    ET.SubElement(interface,'model',type='virtio')
    ET.SubElement(interface,'port',isolated='yes')
    network_filter=ET.SubElement(interface,'filterref',filter='clean-traffic')
    ET.SubElement(network_filter,'parameter',name='IP',value=f"{c['ci_subnet']}.{slot+10}")
    channel=ET.SubElement(devices,'channel',type='unix')
    ET.SubElement(channel,'target',type='virtio',name='org.qemu.guest_agent.0')
    console=ET.SubElement(devices,'console',type='pty')
    ET.SubElement(console,'target',type='serial',port='0')
    ET.SubElement(devices,'memballoon',model='none')
    return ET.tostring(root,encoding='unicode')


def require_capacity(c,slot):
    states=[json.loads(path.read_text()) for path in STATE.glob('ci-*.json')]
    if len(states)>=6 or any(item['slot']==slot for item in states):
        raise RuntimeError('Requested VM slot is already occupied or the pool is full')
    if sum(item['memory_mib'] for item in states)+c['ci_guest_memory_mib']>24576:
        raise RuntimeError('Guest memory reservations would exceed 24 GiB')
    # Reserve remaining writable capacity, so guests cannot fill the host disk.
    outstanding=0
    for item in states:
        disk=ROOT/vm_name(item['name'])/'disk.qcow2'
        allocated=disk.stat().st_blocks*512 if disk.exists() else 0
        outstanding+=max(0,c['ci_guest_disk_gib']*(1024**3)-allocated)
    needed=outstanding+(c['ci_guest_disk_gib']+32)*(1024**3)
    if shutil.disk_usage(ROOT).free<needed:
        raise RuntimeError('Insufficient disk for guest reservations plus 32 GiB host headroom')


def require_vm_budget(name,c):
    """Validate effective placement and limits, rather than trusting domain XML."""
    pid=int(Path('/run/libvirt/qemu',vm_name(name)+'.pid').read_text())
    groups=list(Path('/proc',str(pid),'task').glob('*/cgroup'))
    if not groups or any(not any(line.startswith('0::/machine.slice/')
            for line in path.read_text().splitlines()) for path in groups):
        raise RuntimeError('QEMU is outside the capped machine slice')
    root=Path('/sys/fs/cgroup/machine.slice')
    quota,period=(root/'cpu.max').read_text().split()
    if quota=='max' or abs(int(quota)/int(period)-c['ci_cpu_quota_percent']/100)>0.001:
        raise RuntimeError('The effective aggregate CPU quota does not match configuration')
    if (root/'memory.max').read_text().strip()!=str(26*1024**3):
        raise RuntimeError('The effective aggregate memory limit is missing')


def launch(c, slot, user_data, image=None, name=None, runner_id=None):
    name=vm_name(name or 'ci-'+uuid.uuid4().hex)
    if not 1 <= slot <= 6:
        raise ValueError('Slot must be between one and six')
    require_capacity(c,slot)
    directory=ROOT/name
    directory.mkdir(mode=0o750)
    try:
        shutil.chown(directory,group='libvirt-qemu')
        directory.chmod(0o750)  # Explicitly restore QEMU traversal under the service's private umask.
        image=image or ROOT/'runner-base.qcow2'
        run('qemu-img','create','-f','qcow2','-F','qcow2','-b',str(image),
            str(directory/'disk.qcow2'),f"{c['ci_guest_disk_gib']}G")
        network={'version':2,'ethernets':{'ens3':{
            'match':{'macaddress':f'52:54:00:fb:00:{slot:02x}'},'set-name':'ens3',
            'addresses':[f"{c['ci_subnet']}.{slot+10}/24"],
            'routes':[{'to':'default','via':f"{c['ci_subnet']}.1"}],
            'nameservers':{'addresses':[f"{c['ci_subnet']}.1"]}}}}
        (directory/'network.yaml').write_text(yaml.safe_dump(network))
        (directory/'user-data').write_text('#cloud-config\n'+yaml.safe_dump(user_data))
        (directory/'meta-data').write_text(yaml.safe_dump({'instance-id':name,'local-hostname':name}))
        run('cloud-localds','--network-config',str(directory/'network.yaml'),
            str(directory/'seed.iso'),str(directory/'user-data'),str(directory/'meta-data'))
        for filename in ['disk.qcow2','seed.iso']:
            path=directory/filename
            shutil.chown(path,user='libvirt-qemu',group='libvirt-qemu')
            path.chmod(0o600)
        # The seed is the only guest-visible credential material. Never expose host keys.
        for filename in ['user-data','meta-data','network.yaml']:
            (directory/filename).unlink()
        xml=domain_xml(name,directory,slot,c)
        (directory/'domain.xml').write_text(xml)
        state={'name':name,'slot':slot,'runner_id':runner_id,'created':time.time(),
               'memory_mib':c['ci_guest_memory_mib'],'vcpus':c['ci_guest_vcpus']}
        (STATE/f'{name}.json').write_text(json.dumps(state))
        run('virsh','define',str(directory/'domain.xml'))
        run('virsh','start',name)
        require_vm_budget(name,c)
    except BaseException as error:
        if isinstance(error,subprocess.CalledProcessError):
            event('launch_failed',name=name,reason=(error.stderr or '')[-2000:])
        destroy(name)
        raise
    event('launched',**state)
    return name


def destroy(name,keep_state=False):
    vm_name(name)
    directory=ROOT/name
    # A failed libvirt connection is not evidence that a VM has stopped.
    defined=run('virsh','list','--all','--name').splitlines()
    if name in defined:
        subprocess.run(['virsh','destroy',name],capture_output=True)
        if run('virsh','domstate',name)!='shut off':
            raise RuntimeError('Refusing to remove disks of a live VM')
        run('virsh','undefine',name)
    if directory.exists():
        # Only controller-generated disposable disks and seeds are eligible.
        hashes={str(p):file_hash(p)
                for p in directory.iterdir() if p.is_file()}
        size=sum(p.stat().st_blocks*512 for p in directory.iterdir() if p.is_file())
        event('retired',name=name,root=str(directory),allocated_bytes=size,sha256=hashes,
              reason='retire disposable one-job guest; base image and active guests remain protected')
        shutil.rmtree(directory)
    if not keep_state:
        (STATE/f'{name}.json').unlink(missing_ok=True)


def guest_exec(name, script, timeout=60):
    vm_name(name)
    request={'execute':'guest-exec','arguments':{
        'path':'/bin/bash','arg':['-c',script],'capture-output':True}}
    pid=json.loads(run('virsh','qemu-agent-command',name,json.dumps(request),'--timeout','10'))['return']['pid']
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        status=json.loads(run('virsh','qemu-agent-command',name,
            json.dumps({'execute':'guest-exec-status','arguments':{'pid':pid}}),'--timeout','10'))['return']
        if status.get('exited'):
            return {'exitcode':status.get('exitcode'),
                    'stdout':base64.b64decode(status.get('out-data','')).decode(errors='replace')[:1048576],
                    'stderr':base64.b64decode(status.get('err-data','')).decode(errors='replace')[:16384]}
        time.sleep(1)
    raise TimeoutError('Guest command timed out')


def build_image(c):
    if (ROOT/'runner-base.qcow2').exists():
        raise RuntimeError('Base already exists; rebuild explicitly during a drained maintenance window')
    packages=['qemu-guest-agent','docker.io','docker-buildx','git','gh','gcc','libc6-dev','time','curl','ca-certificates',
              'python3','python3-venv','python-is-python3','unzip','jq','libicu74','libssl3t64',
              'libkrb5-3','zlib1g','libnss3','libatk1.0-0t64','libatk-bridge2.0-0t64',
              'libcups2t64','libdrm2','libxkbcommon0','libxcomposite1','libxdamage1','libxfixes3',
              'libxrandr2','libgbm1','libasound2t64','libpango-1.0-0','libcairo2','libx11-6',
              'libxcb1','libxext6','libxshmfence1','fonts-liberation','fonts-noto-color-emoji','xvfb']
    setup=f'''set -euxo pipefail
systemctl enable --now qemu-guest-agent docker
useradd --create-home --shell /bin/bash runner
usermod -aG docker runner
echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ci-runner
chmod 440 /etc/sudoers.d/ci-runner
mkdir -p /opt/actions-runner /opt/hostedtoolcache
curl --fail --location --retry 3 -o /tmp/runner.tar.gz https://github.com/actions/runner/releases/download/v{c['ci_runner_version']}/actions-runner-linux-x64-{c['ci_runner_version']}.tar.gz
echo '{c['ci_runner_sha256']}  /tmp/runner.tar.gz' | sha256sum --check
tar -xzf /tmp/runner.tar.gz -C /opt/actions-runner
rm /tmp/runner.tar.gz
chown -R runner:runner /opt/actions-runner /opt/hostedtoolcache
cat > /usr/local/bin/ci-runner <<'RUNNER'
#!/bin/bash
set -euo pipefail
cd /opt/actions-runner
exec ./run.sh --jitconfig "$(cat /run/ci-jit)"
RUNNER
chmod 755 /usr/local/bin/ci-runner
cat > /etc/systemd/system/ci-runner.service <<'SERVICE'
[Unit]
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=simple
User=runner
WorkingDirectory=/opt/actions-runner
Environment=RUNNER_TOOL_CACHE=/opt/hostedtoolcache
Environment=PLAYWRIGHT_PORT=5174
ExecStart=/usr/local/bin/ci-runner
ExecStopPost=+/usr/sbin/poweroff
TimeoutStopSec=30
SERVICE
apt-get clean
touch /opt/ci-image-ready
rm -f /etc/ssh/ssh_host_*
cloud-init clean --logs --machine-id
'''
    c={**c,'ci_guest_memory_mib':4096,'ci_guest_vcpus':2}
    name=launch(c,1,{'package_update':True,'packages':packages,
        'write_files':[{'path':'/root/build-ci-image','permissions':'0700','content':setup}],
        'runcmd':[['bash','/root/build-ci-image']]},image=ROOT/'ubuntu-base.qcow2')
    event('image_build_started',name=name)
    # Subsequent status checks and finalization are separate bounded CLI calls.
    (ROOT/'build-name').write_text(name)


def finalize_image():
    name=vm_name((ROOT/'build-name').read_text())
    if run('virsh','domstate',name)!='running':
        raise RuntimeError('Builder must be running for readiness verification')
    result=guest_exec(name,'test -f /opt/ci-image-ready && test -x /opt/actions-runner/run.sh && gh --version && gcc --version && test -x /usr/bin/time && systemctl is-active docker qemu-guest-agent')
    if result['exitcode']!=0:
        raise RuntimeError('Builder is not ready')
    run('virsh','shutdown',name)
    deadline=time.monotonic()+45
    while run('virsh','domstate',name)!='shut off' and time.monotonic()<deadline:
        time.sleep(1)
    if run('virsh','domstate',name)!='shut off':
        raise RuntimeError('Image builder is still running')
    run('qemu-img','convert','-O','qcow2',str(ROOT/name/'disk.qcow2'),str(ROOT/'runner-base.qcow2'))
    (ROOT/'runner-base.qcow2').chmod(0o444)
    event('image_finalized',sha256=file_hash(ROOT/'runner-base.qcow2'))
    destroy(name)
    (ROOT/'build-name').unlink()


def runner_user_data(jit):
    if not re.fullmatch(r'[A-Za-z0-9+/=]+',jit):
        raise ValueError('Invalid encoded JIT configuration')
    return {'write_files':[{'path':'/run/ci-jit','owner':'runner:runner',
                           'permissions':'0600','content':jit}],
            'runcmd':[['systemctl','start','--no-block','ci-runner.service']]}


class GitHubApp:
    def __init__(self):
        self.settings=json.loads(Path('/etc/spawnkit-ci/github-app.json').read_text())
        self.token=None
        self.expires=0

    def request(self,path,method='GET',body=None,token=None):
        if token is None:
            if time.time()>self.expires:
                self.refresh()
            token=self.token
        request=urllib.request.Request('https://api.github.com/'+path,
            data=json.dumps(body).encode() if body is not None else None,method=method,
            headers={'Authorization':'Bearer '+token,'Accept':'application/vnd.github+json',
                     'Content-Type':'application/json','User-Agent':'spawnkit-ci-vms'})
        with urllib.request.urlopen(request,timeout=30) as response:
            payload=response.read()
        return json.loads(payload) if payload else None

    def jwt(self):
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
        encode=lambda b:base64.urlsafe_b64encode(b).rstrip(b'=')
        now=int(time.time())
        header=encode(b'{"alg":"RS256","typ":"JWT"}')
        payload=encode(json.dumps({'iat':now-60,'exp':now+540,'iss':self.settings['app_id']}).encode())
        message=header+b'.'+payload
        key=serialization.load_pem_private_key(Path('/etc/spawnkit-ci/github-app.pem').read_bytes(),None)
        return (message+b'.'+encode(key.sign(message,padding.PKCS1v15(),hashes.SHA256()))).decode()

    def refresh(self):
        c=config()
        result=self.request(f"app/installations/{self.settings['installation_id']}/access_tokens",
                            'POST',{'repository_ids':[c['ci_repository_id']],
                                    'permissions':{'administration':'write','actions':'read'}},token=self.jwt())
        self.token=result['token']
        self.expires=time.time()+3300


def bind_app(c):
    app=GitHubApp()
    installations=app.request('app/installations',token=app.jwt())
    found=[i for i in installations if i['account']['login']==c['ci_repository'].split('/')[0]]
    if len(found)!=1 or found[0]['repository_selection']!='selected':
        raise RuntimeError('Install this dedicated app on the selected repository only')
    app.settings['installation_id']=found[0]['id']
    app.refresh()
    repos=app.request('installation/repositories')['repositories']
    if [r['id'] for r in repos]!=[c['ci_repository_id']]:
        raise RuntimeError('Installation token is not restricted to the intended repository')
    Path('/etc/spawnkit-ci/github-app.json').write_text(json.dumps(app.settings))
    event('app_bound',app_id=app.settings['app_id'],installation_id=found[0]['id'],repository=c['ci_repository'])


def queued_jobs(app,c):
    """Read queue metadata only. Names and commands supplied by jobs are never executed."""
    count=0
    supported={label.casefold() for label in ['self-hosted','Linux','X64',*c['ci_labels']]}
    for status in ['queued','in_progress']:
        runs=app.request(f"repos/{c['ci_repository']}/actions/runs?status={status}&per_page=30")['workflow_runs']
        for workflow in runs:
            jobs=app.request(f"repos/{c['ci_repository']}/actions/runs/{int(workflow['id'])}/jobs?per_page=100")['jobs']
            for job in jobs:
                labels={label.casefold() for label in job.get('labels',[])}
                if job['status']=='queued' and c['ci_labels'][0].casefold() in labels and labels.issubset(supported):
                    count+=1
                    if count>=c['ci_slots']:
                        return count
    return count


def retire_registered(app,endpoint,item,path):
    # Stop computation even if GitHub is unavailable; preserve the ID for retry.
    destroy(item['name'],keep_state=True)
    if item['runner_id']:
        try:
            app.request(f"{endpoint}/{item['runner_id']}",'DELETE')
        except urllib.error.HTTPError as error:
            if error.code!=404:
                raise
    path.unlink()


def reap_expired(c):
    """Enforce local lifetime before any provider request, even during API outages."""
    for path in STATE.glob('ci-*.json'):
        item=json.loads(path.read_text())
        if time.time()-item['created']>c['ci_job_timeout_seconds']:
            destroy(vm_name(item['name']),keep_state=True)


def retire_idle_registered(app,endpoint,item,path):
    # JIT labels are read-only. Deregistration atomically closes job intake;
    # GitHub rejects it if a job won the race with our idle observation.
    try:
        app.request(f"{endpoint}/{item['runner_id']}",'DELETE')
    except urllib.error.HTTPError as error:
        if error.code==422:
            runner=app.request(f"{endpoint}/{item['runner_id']}")
            if runner['busy']:
                event('idle_retirement_deferred',name=item['name'])
                return False
        if error.code!=404:
            raise
    destroy(item['name'],keep_state=True)
    path.unlink()
    return True


def serve(c):
    import fcntl
    require_current_kernel(c)
    lock=open('/run/spawnkit-ci.lock','w')
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    app=GitHubApp()
    endpoint=f"repos/{c['ci_repository']}/actions/runners"
    stopping=False
    def stop(*_):
        nonlocal stopping
        stopping=True
    signal.signal(signal.SIGTERM,stop)
    signal.signal(signal.SIGINT,stop)
    while True:
        c=config()
        reap_expired(c)
        draining=stopping or Path('/etc/spawnkit-ci/paused').exists()
        registered={r['id']:r for r in app.request(endpoint+'?per_page=100')['runners']}
        states=[(p,json.loads(p.read_text())) for p in STATE.glob('ci-*.json')]
        busy_count=sum(bool(registered.get(item['runner_id'],{}).get('busy')) for _,item in states)
        desired=0 if draining else min(c['ci_slots'],busy_count+queued_jobs(app,c))
        live={}
        for path,item in states:
            name=vm_name(item['name'])
            state=subprocess.run(['virsh','domstate',name],capture_output=True,text=True)
            age=time.time()-item['created']
            expired=age>c['ci_job_timeout_seconds']
            runner=registered.get(item['runner_id'])
            idle=runner is not None and not runner['busy'] and runner['status']=='online'
            should_drain=(draining or age>c['ci_idle_timeout_seconds'] or item['slot']>c['ci_slots']
                          or (idle and len(states)>desired))
            if state.returncode or state.stdout.strip()=='shut off' or expired:
                retire_registered(app,endpoint,item,path)
            elif idle and should_drain:
                if not retire_idle_registered(app,endpoint,item,path):
                    live[item['slot']]=item
            else:
                live[item['slot']]=item
        if stopping:
            if not live:
                break
            time.sleep(5)
            continue
        # Root-owned pause file drains existing jobs before maintenance.
        if not draining:
            for slot in range(1,c['ci_slots']+1):
                if len(live)>=desired:
                    break
                if slot in live:
                    continue
                name='ci-'+uuid.uuid4().hex
                jit=app.request(endpoint+'/generate-jitconfig','POST',{
                    'name':name,'runner_group_id':1,
                    'labels':['self-hosted','Linux','X64',*c['ci_labels']],
                    'work_folder':'_work'})
                try:
                    launch(c,slot,runner_user_data(jit['encoded_jit_config']),name=name,
                           runner_id=jit['runner']['id'])
                    live[slot]={'name':name}
                except BaseException:
                    app.request(f"{endpoint}/{jit['runner']['id']}",'DELETE')
                    raise
        time.sleep(15)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    sub.add_parser('build-image')
    sub.add_parser('finalize-image')
    sub.add_parser('serve')
    sub.add_parser('bind-app')
    start=sub.add_parser('launch')
    start.add_argument('--slot',type=int,required=True)
    start.add_argument('--memory',type=int)
    start.add_argument('--vcpus',type=int)
    start.add_argument('--probe',action='store_true')
    start.add_argument('--name')
    start.add_argument('--runner-id',type=int)
    execute=sub.add_parser('exec')
    execute.add_argument('name')
    execute.add_argument('--timeout',type=int,default=60)
    delete=sub.add_parser('destroy')
    delete.add_argument('name')
    args=parser.parse_args()
    c=config()
    if args.command=='build-image':
        build_image(c)
    elif args.command=='finalize-image':
        finalize_image()
    elif args.command=='serve':
        serve(c)
    elif args.command=='bind-app':
        bind_app(c)
    elif args.command=='launch':
        if args.memory:
            c['ci_guest_memory_mib']=args.memory
        if args.vcpus:
            c['ci_guest_vcpus']=args.vcpus
        if not (2048<=c['ci_guest_memory_mib']<=8192 and 1<=c['ci_guest_vcpus']<=4):
            raise ValueError('Guest size outside tested bounds')
        data={'runcmd':[['touch','/run/ci-probe-ready']]} if args.probe else runner_user_data(sys.stdin.read().strip())
        launch(c,args.slot,data,name=args.name,runner_id=args.runner_id)
    elif args.command=='exec':
        print(json.dumps(guest_exec(args.name,sys.stdin.read(),timeout=args.timeout)))
    elif args.command=='destroy':
        destroy(args.name)


if __name__=='__main__':
    main()
