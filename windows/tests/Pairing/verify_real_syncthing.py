"""Creates two isolated Syncthing instances; never reads the user's configuration."""
from pathlib import Path
import subprocess, socket, tempfile, xml.etree.ElementTree as ET, urllib.request, time, sys, os
repository=Path(__file__).resolve().parents[3]
root=Path(tempfile.mkdtemp(prefix='HoverPocketPairingActual-'))
processes=[]
def port():
 with socket.socket() as sock:
  sock.bind(('127.0.0.1',0));return sock.getsockname()[1]
try:
 for side in ('a','b'):
  home=root/side;home.mkdir();(home/'isolated-pairing-test').touch()
  subprocess.run(['syncthing','generate','--home',str(home),'--no-port-probing'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
  config=ET.parse(home/'config.xml');xml=config.getroot()
  for folder in xml.findall('folder'):xml.remove(folder)
  opts=xml.find('options')
  for item in opts.findall('listenAddress'):opts.remove(item)
  ET.SubElement(opts,'listenAddress').text='tcp://127.0.0.1:'+str(port())
  for name,value in {'globalAnnounceEnabled':'false','localAnnounceEnabled':'false','relaysEnabled':'false','natEnabled':'false','startBrowser':'false','crashReportingEnabled':'false','urAccepted':'-1','autoUpgradeIntervalH':'0'}.items():
   element=opts.find(name)
   if element is None:element=ET.SubElement(opts,name)
   element.text=value
  gui=xml.find('gui');address='127.0.0.1:'+str(port());gui.find('address').text=address;gui.set('tls','false')
  config.write(home/'config.xml',encoding='utf-8',xml_declaration=True)
  p=subprocess.Popen(['syncthing','serve','--home',str(home),'--no-browser','--no-restart','--no-upgrade','--no-console'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW);processes.append(p)
  ready=False
  for _ in range(100):
   try:
    request=urllib.request.Request('http://'+address+'/rest/system/status',headers={'X-API-Key':gui.find('apikey').text})
    with urllib.request.urlopen(request,timeout=1) as r:ready=r.status==200
    if ready:break
   except Exception:time.sleep(.1)
  if not ready:raise RuntimeError('isolated Syncthing did not start')
 helper=repository/'artifacts/pairing-helper-target/release/hoverpocket-pairing.exe'
 subprocess.run(['dotnet','run','--project',str(repository/'windows/tests/Pairing'),'-c','Release','--','--real',str(root/'a'),str(root/'b'),str(helper)],check=True,cwd=repository)
 print('Isolated evidence:',root)
finally:
 for p in processes:
  if p.poll() is None:p.terminate()
 for p in processes:p.wait(timeout=15)
