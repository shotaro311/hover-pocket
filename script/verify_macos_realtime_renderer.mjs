#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.join(
  scriptDirectory,
  "..",
  "Sources",
  "HoverPocket",
  "Voice",
  "OpenAIRealtimeMacOSTransport.swift",
);
const swift = fs.readFileSync(sourcePath, "utf8");
const scriptMatch = swift.match(/<body><script>\n([\s\S]*?)\n\s*<\/script><\/body><\/html>/);
if (!scriptMatch) {
  throw new Error("Embedded Voice page script was not found");
}

let resolveMicrophone;
const microphonePromise = new Promise((resolve) => {
  resolveMicrophone = resolve;
});
const localTrack = {
  enabled: true,
  readyState: "live",
  stopCount: 0,
  stop() {
    this.stopCount += 1;
    this.readyState = "ended";
  },
};
const stream = {
  getAudioTracks: () => [localTrack],
  getTracks: () => [localTrack],
};

class FakeDataChannel {
  constructor() {
    this.readyState = "open";
  }

  close() {
    this.readyState = "closed";
  }

  send() {}
}

class FakePeerConnection {
  constructor() {
    this.connectionState = "new";
    this.iceGatheringState = "complete";
    this.localDescription = null;
  }

  addTrack() {}
  createDataChannel() {
    return new FakeDataChannel();
  }
  async createOffer() {
    return { type: "offer", sdp: "v=0" };
  }
  async setLocalDescription(offer) {
    this.localDescription = offer;
  }
  addEventListener() {}
  removeEventListener() {}
  close() {
    this.connectionState = "closed";
  }
}

const posted = [];
const sandbox = {
  TextEncoder,
  setTimeout,
  clearTimeout,
  navigator: {
    mediaDevices: {
      getUserMedia: () => microphonePromise,
    },
  },
  RTCPeerConnection: FakePeerConnection,
  MediaStream: class {},
  document: {
    body: {
      replaceChildren() {},
    },
    createElement: () => ({
      autoplay: false,
      playsInline: false,
      muted: false,
      srcObject: null,
      play: async () => {},
    }),
  },
  window: {
    webkit: {
      messageHandlers: {
        voice: {
          postMessage: (payload) => posted.push(payload),
        },
      },
    },
  },
};

vm.createContext(sandbox);
vm.runInContext(scriptMatch[1], sandbox, { filename: sourcePath });

const pendingStart = sandbox.window.hoverPocketVoice.start(1, "session-1");
await Promise.resolve();
const closeBeforePermission = sandbox.window.hoverPocketVoice.close();
resolveMicrophone(stream);

let staleStartRejected = false;
try {
  await pendingStart;
} catch (error) {
  staleStartRejected = String(error).includes("stale_microphone_capture");
}

if (!closeBeforePermission) {
  throw new Error("Close did not acknowledge an empty pending capture");
}
if (!staleStartRejected) {
  throw new Error("The late microphone capture was not rejected");
}
if (localTrack.stopCount !== 1 || localTrack.readyState !== "ended") {
  throw new Error("The late microphone track was not stopped exactly once");
}
if (posted.some((event) => event && event.type === "offer")) {
  throw new Error("The stale capture posted an SDP offer after close");
}
if (sandbox.window.hoverPocketVoice.setMuted(false) !== false) {
  throw new Error("The stale capture installed renderer session state");
}

process.stdout.write(
  "PASS macOS Realtime renderer verify: close invalidates pending microphone capture, stops the late track, and prevents stale state or SDP offer\n",
);
