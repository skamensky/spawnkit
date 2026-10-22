#!/usr/bin/python3
"""Constrain only the dedicated CI bridge; preserve host firewall and SSH rules."""
import json
import subprocess

c=json.load(open('/etc/spawnkit-ci/config.json'))
bridge=c['ci_bridge']
subnet=c['ci_subnet']
rules=f'''table inet spawnkit_ci {{
 chain host_input {{
  type filter hook input priority -200; policy accept;
  iifname "{bridge}" ip saddr {subnet}.0/24 ip daddr {subnet}.1 udp dport 53 accept
  iifname "{bridge}" ip saddr {subnet}.0/24 ip daddr {subnet}.1 tcp dport 53 accept
  iifname "{bridge}" counter drop
 }}
 chain guest_forward {{
  type filter hook forward priority -200; policy accept;
  iifname "{bridge}" meta nfproto ipv6 counter drop
  iifname "{bridge}" oifname "{bridge}" counter drop
  iifname "{bridge}" ip daddr {{ 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/4, 240.0.0.0/4 }} counter drop
  iifname "{bridge}" tcp dport {{ 80, 443 }} accept
  iifname "{bridge}" counter drop
  oifname "{bridge}" ct state established,related accept
  oifname "{bridge}" counter drop
 }}
}}
'''
exists=subprocess.run(['nft','list','table','inet','spawnkit_ci'],capture_output=True).returncode==0
payload=('delete table inet spawnkit_ci\n' if exists else '')+rules
subprocess.run(['nft','--check','-f','-'],input=payload,text=True,check=True)
subprocess.run(['nft','-f','-'],input=payload,text=True,check=True)
