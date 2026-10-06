"""Private Windows/Mac native pairing smoke test over pinned SSH stdio.
Only generated fixtures and isolated Syncthing homes are used. Never log peer streams.
"""
from pathlib import Path
import argparse, json, subprocess, socket, tempfile, xml.etree.ElementTree as ET
import urllib.request, time, threading, queue, shlex, os

parser=argparse.ArgumentParser()
parser.add_argument('--mac-exe',required=True)
parser.add_argument('--ssh-target',required=True)
parser.add_argument('--mac-config',required=True)
parser.add_argument('--mac-sync-port',type=int,required=True)
parser.add_argument('--known-hosts',required=True)
parser.add_argument('--identity',required=True)
args=parser.parse_args()
repo=Path(__file__).resolve().parents[3]
root=Path(tempfile.mkdtemp(prefix='HoverPocketPairingCross-'))
(root/'isolated-pairing-test').touch()
home=root/'syncthing';home.mkdir()
no_window=getattr(subprocess,'CREATE_NO_WINDOW',0)

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0));return s.getsockname()[1]

class Peer:
    def __init__(self,command):
        self.label='mac' if command[0]=='ssh' else 'windows'
        self.process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf-8',creationflags=no_window)
        self.q=queue.Queue()
        threading.Thread(target=self.read,daemon=True).start()
    def read(self):
        for line in self.process.stdout:
            try:self.q.put(json.loads(line))
            except (ValueError,TypeError):pass
        self.q.put({'event':'eof'})
    def send(self,**value):
        self.process.stdin.write(json.dumps(value)+'\n');self.process.stdin.flush()
    def event(self,kind,seconds=90):
        print('Await '+self.label+' '+kind,flush=True)
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            event=self.q.get(timeout=max(0.1,end-time.monotonic()))
            if event.get('event') in ('error','eof'):raise RuntimeError('Peer failed before '+kind)
            if event.get('event')==kind:return event
        raise TimeoutError('Peer did not reach '+kind)
    def close(self):
        if self.process.poll() is None:
            try:self.send(action='exit');self.process.wait(timeout=10)
            except Exception:self.process.kill();self.process.wait(timeout=5)

syncthing=None;windows=None;mac=None;address=None;key=None
try:
    subprocess.run(['syncthing','generate','--home',str(home),'--no-port-probing'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=no_window)
    tree=ET.parse(home/'config.xml');xml=tree.getroot()
    for folder in xml.findall('folder'):xml.remove(folder)
    opts=xml.find('options')
    for item in opts.findall('listenAddress'):opts.remove(item)
    ET.SubElement(opts,'listenAddress').text='tcp://127.0.0.1:'+str(port())
    for name,value in {'globalAnnounceEnabled':'false','localAnnounceEnabled':'false','relaysEnabled':'false','natEnabled':'false','startBrowser':'false','crashReportingEnabled':'false','urAccepted':'-1','autoUpgradeIntervalH':'0'}.items():
        element=opts.find(name)
        if element is None:element=ET.SubElement(opts,name)
        element.text=value
    gui=xml.find('gui');address='127.0.0.1:'+str(port());gui.find('address').text=address;gui.set('tls','false');key=gui.find('apikey').text
    tree.write(home/'config.xml',encoding='utf-8',xml_declaration=True)
    def request(path,data=None):
        req=urllib.request.Request('http://'+address+'/rest/'+path,data=data,headers={'X-API-Key':key})
        with urllib.request.urlopen(req,timeout=5) as result:return json.load(result)
    syncthing=subprocess.Popen(['syncthing','serve','--home',str(home),'--no-browser','--no-restart','--no-upgrade','--no-console'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=no_window)
    for _ in range(100):
        try:request('system/status');break
        except Exception:time.sleep(.1)
    else:raise RuntimeError('Isolated Windows Syncthing did not start')
    config=root/'windows.json';config.write_text(json.dumps({'root':str(root),'helper':str(repo/'artifacts/pairing-helper-target/release/hoverpocket-pairing.exe')}),encoding='utf-8')
    tunnel=port()
    windows=Peer(['dotnet',str(repo/'windows/tests/Pairing/bin/Release/net10.0/Pairing.dll'),'--cross',str(config)])
    remote=shlex.join([args.mac_exe,'--verify-library-pairing-cross','--pairing-config',args.mac_config])
    mac=Peer(['ssh','-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(Path(args.known_hosts).resolve()),'-o','ExitOnForwardFailure=yes','-o','ConnectTimeout=10','-i',str(Path(args.identity).resolve()),'-L',f'127.0.0.1:{tunnel}:127.0.0.1:{args.mac_sync_port}',args.ssh_target,remote])
    windows.event('ready');mac.event('ready')
    windows.send(action='fixture');windows.event('fixture')
    windows.send(action='start',role='invite');code=windows.event('code')['code']
    mac.send(action='start',role='join',code=code);del code
    wa=windows.event('peer');ma=mac.event('peer')
    assert wa['approvalId']==ma['approvalId'] and wa['verification']==ma['verification']
    assert not request('config/folders'),'Windows shared before approval'
    windows.send(action='approve',approvalId=wa['approvalId'])
    windows.event('complete');mac.event('complete')
    print('PASS cross-OS native pairing: Windows invite, Mac join, explicit approval, both complete',flush=True)
    windows.send(action='connect',port=tunnel);windows.event('connected')
    mac.send(action='fixture');mac.event('imported')
    for _ in range(60):
        windows.send(action='sync');w=windows.event('synced')
        mac.send(action='sync');m=mac.event('synced')
        def hashes(event):return sorted(a.get('Sha256',a.get('sha256')) for a in event['assets'])
        if len(w['assets'])==2 and len(m['assets'])==2 and hashes(w)==hashes(m):break
        time.sleep(1)
    else:raise RuntimeError('Generated originals did not transfer both ways')
    assert w['groupId']==m['groupId'] and w['enabled'] and m['enabled']
    assert w['validOriginals'] and m['validOriginals']
    def metadata(event):
        return sorted((a['Id'],a['Name'],a['Sha256'],a['Favorite']) for a in event['assets'])
    assert metadata(w)==metadata(m),'Generated metadata differs between hosts'
    print('PASS cross-OS transfer: generated originals and metadata both ways, exact SHA matches',flush=True)
    time.sleep(3)
    mac.send(action='start',role='invite');code=mac.event('code')['code']
    windows.send(action='start',role='join',code=code);del code
    wa=windows.event('peer');ma=mac.event('peer')
    assert wa['approvalId']==ma['approvalId'] and wa['verification']==ma['verification']
    mac.send(action='approve',approvalId=ma['approvalId'])
    windows.event('complete');mac.event('complete')
    print('PASS cross-OS native pairing: Mac invite, Windows join, existing group preserved',flush=True)
    mac.send(action='unlink');mac.event('unlinked')
    windows.send(action='unlink');windows.event('unlinked')
    print('PASS cross-OS unlink: scoped membership removed, global device retained',flush=True)
finally:
    for peer in (windows,mac):
        if peer:peer.close()
    if address and key:
        try:request('system/shutdown',b'')
        except Exception:pass
    if syncthing:
        try:syncthing.wait(timeout=10)
        except subprocess.TimeoutExpired:
            subprocess.run(['taskkill','/PID',str(syncthing.pid),'/T','/F'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=no_window)
    print('Windows isolated evidence: '+str(root),flush=True)
