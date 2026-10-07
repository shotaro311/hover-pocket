"""Isolated protocol test: fictional identities only, no files/credentials transferred."""
import json, subprocess, sys, threading, queue, uuid
exe = sys.argv[1]
class Peer:
    def __init__(self, role, group=None, code=None, name="Test Windows"):
        self.process = subprocess.Popen([exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
        self.q = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()
        self.send(dict(role=role, code=code, deviceId="-".join(["AAAAAAA" if role=="invite" else "BBBBBBB"]*8), deviceName=name, platform="windows" if role=="invite" else "macos", groupId=group, folderId="hoverpocket-test" if group else None))
    def read(self):
        for line in self.process.stdout:
            self.q.put(json.loads(line))
        self.q.put({"event":"eof"})
    def send(self, value):
        self.process.stdin.write(json.dumps(value)+"\n"); self.process.stdin.flush()
    def event(self, kind):
        event=self.q.get(timeout=40)
        assert event["event"]==kind, (kind, event.get("event"), event.get("reason"))
        return event
    def close(self):
        if self.process.poll() is None: self.process.kill()
        self.process.wait()
def scenario(mode):
    a=Peer("invite",str(uuid.uuid4())); b=None
    try:
        code=a.event("code")["code"]
        if mode=="wrong":
            plate,secret=code.split("-"); code=plate+"-"+str((int(secret)+1)%100000000).zfill(8)
        b=Peer("join",str(uuid.uuid4()) if mode=="group" else None,code)
        if mode in ("wrong","group"):
            assert a.event("error")["reason"] in ("connection_failed","different_library")
            b.event("error")
        else:
            pa,pb=a.event("peer"),b.event("peer")
            assert pa["approvalId"]==pb["approvalId"] and pa["verification"]==pb["verification"]
            aid=pa["approvalId"]
            a.send(dict(action="decline" if mode=="decline" else "approve",approvalId="stale" if mode=="stale" else aid))
            b.send(dict(action="ready",approvalId=aid))
            if mode in ("decline","stale"):
                a.event("error"); b.event("error")
            else:
                a.event("approved"); b.event("approved")
                a.send(dict(action="applied",approvalId=aid)); b.send(dict(action="applied",approvalId=aid))
                a.event("complete"); b.event("complete")
        print(mode+": PASS",flush=True)
    finally:
        a.close()
        if b: b.close()
for mode in ("success","wrong","decline","stale","group"): scenario(mode)
