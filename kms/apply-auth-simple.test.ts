// Behaviour tests for the OutLayer auth-simple patch (apply-auth-simple.sh). Run by
// test-apply-auth-simple.sh, which copies this file next to a PATCHED index.ts and runs `bun test`.
// Same harness style as upstream index.test.ts: import the hono app, drive it with Request objects.

import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { writeFileSync, unlinkSync, existsSync } from 'fs';
import app from './index';

const CONFIG_PATH = './outlayer-test-auth-config.json';
const OS = '0x1fbb0cf9cc6cfbf23d6b779776fabad2c5403d643badb9e5e238615e4960a78a';
const OUR = '0xc84189f534d6d90747e068fe8090eafd870f5969176b42f9c43be3bb7e8162ce';
const OTHER = '0x4a252cf80d209d96bb06ce96e17342ea2234f721b4a158707718b18732d6e4a1';
const FOREIGN = '0x' + 'ff'.repeat(32);

const boot = (deviceId: string, extra: object = {}) => ({
  mrAggregated: '0xabc123',
  osImageHash: OS,
  appId: '0xapp123',
  composeHash: '0xcompose456',
  instanceId: '0xinstance789',
  deviceId,
  tcbStatus: 'UpToDate',
  advisoryIds: [],
  mrSystem: '',
  ...extra,
});

// The config apply-auth-simple.sh writes on a node, modulo fixture hashes.
const nodeConfig = (overrides: object = {}) => ({
  gatewayAppId: '0xgateway',
  osImages: [OS],
  kms: { mrAggregated: ['0xabc123'], allowAnyDevice: false, devices: [OUR] },
  apps: {},
  allowAnyApp: true,
  devices: [OUR],
  ...overrides,
});

const writeConfig = (c: object) => writeFileSync(CONFIG_PATH, JSON.stringify(c, null, 2));
const writeRawConfig = (s: string) => writeFileSync(CONFIG_PATH, s);

async function post(path: string, body: object) {
  const res = await app.fetch(new Request(`http://localhost${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }));
  return { status: res.status, json: await res.json() };
}

let logged: string[] = [];
const origLog = console.log;

describe('OutLayer auth-simple patch', () => {
  beforeAll(() => {
    process.env.AUTH_CONFIG_PATH = CONFIG_PATH;
    console.log = (...args: unknown[]) => { logged.push(args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ')); };
  });
  afterAll(() => {
    console.log = origLog;
    if (existsSync(CONFIG_PATH)) unlinkSync(CONFIG_PATH);
  });
  afterEach(() => { logged = []; });

  describe('app boot, allowAnyApp on an allowlisted node', () => {
    it('allows our device without an apps entry', async () => {
      writeConfig(nodeConfig());
      const { status, json } = await post('/bootAuth/app', boot(OUR));
      expect(status).toBe(200);
      expect(json.isAllowed).toBe(true);
      expect(json.gatewayAppId).toBe('0xgateway');
    });

    it('denies a foreign device even with allowAnyApp', async () => {
      writeConfig(nodeConfig());
      const { json } = await post('/bootAuth/app', boot(FOREIGN));
      expect(json.isAllowed).toBe(false);
      expect(json.reason).toBe('device not in OutLayer node allowlist');
    });

    it('denies everything when the device list is empty (fail-closed)', async () => {
      writeConfig(nodeConfig({ devices: [] }));
      const { json } = await post('/bootAuth/app', boot(OUR));
      expect(json.isAllowed).toBe(false);
      expect(json.reason).toBe('device not in OutLayer node allowlist');
    });

    it('denies everything when the device list is missing (schema default)', async () => {
      const c: Record<string, unknown> = nodeConfig();
      delete c.devices;
      writeConfig(c);
      const { json } = await post('/bootAuth/app', boot(OUR));
      expect(json.isAllowed).toBe(false);
    });

    it('accepts any allowlisted device when several are listed', async () => {
      writeConfig(nodeConfig({ devices: [OUR, OTHER] }));
      expect((await post('/bootAuth/app', boot(OTHER))).json.isAllowed).toBe(true);
      expect((await post('/bootAuth/app', boot(FOREIGN))).json.isAllowed).toBe(false);
    });

    it('normalizes hex on both sides (uppercase, missing 0x)', async () => {
      writeConfig(nodeConfig({ devices: [OUR.slice(2).toUpperCase()] }));
      expect((await post('/bootAuth/app', boot(OUR.toUpperCase()))).json.isAllowed).toBe(true);
      expect((await post('/bootAuth/app', boot(OUR.slice(2)))).json.isAllowed).toBe(true);
    });

    it('still runs the upstream TCB and osImages gates first', async () => {
      writeConfig(nodeConfig());
      expect((await post('/bootAuth/app', boot(OUR, { tcbStatus: 'OutOfDate' }))).json.reason).toBe('TCB status is not up to date');
      expect((await post('/bootAuth/app', boot(OUR, { osImageHash: '0xdead' }))).json.reason).toBe('OS image is not allowed');
    });
  });

  describe('app boot, allowAnyApp off (upstream per-app path)', () => {
    it('device allowlist applies before the apps lookup', async () => {
      writeConfig(nodeConfig({
        allowAnyApp: false,
        apps: { '0xapp123': { composeHashes: ['0xcompose456'], devices: [], allowAnyDevice: true } },
      }));
      expect((await post('/bootAuth/app', boot(OUR))).json.isAllowed).toBe(true);
      const foreign = (await post('/bootAuth/app', boot(FOREIGN))).json;
      expect(foreign.isAllowed).toBe(false);
      expect(foreign.reason).toBe('device not in OutLayer node allowlist');
    });

    it('per-app allowAnyDevice cannot widen the node allowlist', async () => {
      writeConfig(nodeConfig({
        allowAnyApp: false,
        devices: [OUR],
        apps: { '0xapp123': { composeHashes: ['0xcompose456'], allowAnyDevice: true } },
      }));
      expect((await post('/bootAuth/app', boot(FOREIGN))).json.isAllowed).toBe(false);
    });

    it('unregistered app is still refused for an allowlisted device', async () => {
      writeConfig(nodeConfig({ allowAnyApp: false, apps: {} }));
      const { json } = await post('/bootAuth/app', boot(OUR));
      expect(json.isAllowed).toBe(false);
      expect(json.reason).toBe('app not registered');
    });
  });

  describe('KMS boot (upstream kms.devices, as written by the script)', () => {
    it('allows our device, denies a foreign one', async () => {
      writeConfig(nodeConfig());
      expect((await post('/bootAuth/kms', boot(OUR))).json.isAllowed).toBe(true);
      const foreign = (await post('/bootAuth/kms', boot(FOREIGN))).json;
      expect(foreign.isAllowed).toBe(false);
      expect(foreign.reason).toBe('KMS is not allowed to boot on this device');
    });

    it('empty kms.devices allows any device (upstream semantics, bootstrap window)', async () => {
      writeConfig(nodeConfig({ kms: { mrAggregated: ['0xabc123'], allowAnyDevice: false, devices: [] } }));
      expect((await post('/bootAuth/kms', boot(FOREIGN))).json.isAllowed).toBe(true);
    });
  });

  describe('config robustness', () => {
    it('a config that fails the schema denies every boot instead of opening up', async () => {
      // A string inside `apps` is the mistake the old template contained.
      writeConfig(nodeConfig({ apps: { _comment: 'oops' } }));
      const { json } = await post('/bootAuth/app', boot(OUR));
      expect(json.isAllowed).toBe(false);
    });

    it('malformed JSON denies every boot', async () => {
      writeRawConfig('{ not json');
      expect((await post('/bootAuth/app', boot(OUR))).json.isAllowed).toBe(false);
      expect((await post('/bootAuth/kms', boot(OUR))).json.isAllowed).toBe(false);
    });

    it('unknown top-level keys are tolerated (the template carries a _comment)', async () => {
      writeConfig(nodeConfig({ _comment: 'fine here' }));
      expect((await post('/bootAuth/app', boot(OUR))).json.isAllowed).toBe(true);
    });
  });

  describe('logging', () => {
    it('logs the deviceId in the app boot request line, allowed or denied', async () => {
      writeConfig(nodeConfig());
      await post('/bootAuth/app', boot(FOREIGN));
      const line = logged.find(l => l.startsWith('app boot auth request:'));
      expect(line).toBeDefined();
      expect(line).toContain(FOREIGN);
    });

    it('logs the deviceId in the KMS boot request line', async () => {
      writeConfig(nodeConfig());
      await post('/bootAuth/kms', boot(OUR));
      const line = logged.find(l => l.startsWith('KMS boot auth request:'));
      expect(line).toBeDefined();
      expect(line).toContain(OUR);
    });
  });
});
