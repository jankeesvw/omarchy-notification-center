const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const script = path.resolve(__dirname, '../bin/notification-center');

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'notification-store-test-'));
  const source = path.join(root, 'source');
  const store = path.join(root, 'archive');
  fs.mkdirSync(path.join(source, 'history'), { recursive: true });
  const env = { ...process.env, NC_SRC_DIR: source, NC_SRC_HISTORY: path.join(source, 'history'), NC_STORE: store, NC_PREVIEWS: '0' };
  return {
    source, store, env,
    write(name, rows, atomic = false) {
      const dest = path.join(source, name);
      fs.writeFileSync(atomic ? dest + '.tmp' : dest, JSON.stringify(rows));
      if (atomic) fs.renameSync(dest + '.tmp', dest);
    },
    run(...args) {
      const result = spawnSync(script, args, { env, encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr || result.stdout);
      return JSON.parse(result.stdout);
    },
    dispose() { fs.rmSync(root, { recursive: true, force: true }); }
  };
}

function notification(key, ts = Date.now() / 1000) {
  return { key, ts, app: 'Fixture', summary: `Message ${key}`, body: 'A retained message', appIcon: 'dialog-information', urgency: 1 };
}

async function eventually(check) {
  const end = Date.now() + 7000;
  while (Date.now() < end) {
    if (check()) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  assert.fail('Timed out waiting for the watcher');
}

test('imports current arrays in time order, converts seconds, and keeps keys stable across expiry', () => {
  const f = fixture();
  try {
    const stamp = Date.now() / 1000 - 60;
    f.write('history.json', [notification('nsecond', stamp + 1), notification('nfirst', stamp)]);
    f.write('live.json', [notification('nthird', stamp + 2)]);
    f.write('quiet.json', { dnd: false });
    const before = fs.readFileSync(path.join(f.source, 'history.json'), 'utf8');
    f.run('sync');
    const entries = f.run('list');
    assert.deepEqual(entries.map(row => row.key), ['nthird', 'nsecond', 'nfirst']);
    assert.equal(entries[2].timestamp, Math.floor(stamp * 1000));
    assert.equal(fs.readFileSync(path.join(f.source, 'history.json'), 'utf8'), before);
    f.write('history.json', [notification('nthird', stamp + 2), notification('nsecond', stamp + 1), notification('nfirst', stamp)]);
    f.write('live.json', []);
    f.run('sync');
    assert.equal(f.run('list').length, 3);
    f.run('remove', 'nsecond');
    f.run('sync');
    assert.deepEqual(f.run('list').map(row => row.key), ['nthird', 'nfirst']);
  } finally { f.dispose(); }
});

test('clear suppresses old aggregate entries while allowing new arrivals', () => {
  const f = fixture();
  try {
    f.write('live.json', [notification('nold', Date.now() / 1000 - 60)]);
    f.run('sync');
    f.run('clear');
    f.run('sync');
    assert.deepEqual(f.run('list'), []);
    f.write('live.json', [notification('nnew', Date.now() / 1000 + 1)]);
    f.run('sync');
    assert.deepEqual(f.run('list').map(row => row.key), ['nnew']);
  } finally { f.dispose(); }
});

test('retention orders a long-lived popup against newer closed notifications', () => {
  const f = fixture();
  try {
    f.env.NC_MAX_ITEMS = '2';
    const stamp = Date.now() / 1000;
    f.write('history.json', [notification('nnewest', stamp - 1), notification('nrecent', stamp - 2)]);
    f.write('live.json', [notification('nlonglived', stamp - 3600)]);
    f.run('sync');
    assert.deepEqual(f.run('list').map(row => row.key), ['nnewest', 'nrecent']);
  } finally { f.dispose(); }
});

test('removing an entry with a reserved name preserves aggregate source files', () => {
  const f = fixture();
  try {
    f.write('history.json', [notification('history')]);
    f.write('live.json', [notification('live')]);
    f.write('quiet.json', { dnd: false });
    const before = ['history.json', 'live.json', 'quiet.json'].map(name => fs.readFileSync(path.join(f.source, name), 'utf8'));
    f.run('sync');
    for (const key of ['history', 'live', 'quiet']) f.run('remove', key);
    assert.deepEqual(['history.json', 'live.json', 'quiet.json'].map(name => fs.readFileSync(path.join(f.source, name), 'utf8')), before);
    assert.deepEqual(f.run('list'), []);
  } finally { f.dispose(); }
});

test('retains support for individual legacy notification files', () => {
  const f = fixture();
  try {
    const timestamp = Date.now() - 1000;
    f.write(`history/${timestamp}-1.json`, { app: 'Legacy', summary: 'Old format', timestamp });
    f.run('sync');
    const entries = f.run('list');
    assert.equal(entries.length, 1);
    assert.equal(entries[0].key, `${timestamp}-1`);
    assert.equal(entries[0].timestamp, timestamp);
  } finally { f.dispose(); }
});

test('ignores malformed aggregates and unsafe keys without losing valid rows', () => {
  const f = fixture();
  try {
    f.write('history.json', [null, notification('../escape'), notification('nmissing', 'yesterday'), notification('nvalid')]);
    f.write('live.json', { unexpected: true });
    f.run('sync');
    assert.deepEqual(f.run('list').map(row => row.key), ['nvalid']);
    assert.equal(fs.existsSync(path.join(f.store, 'escape-appIcon')), false);
  } finally { f.dispose(); }
});

test('watch captures atomic snapshot replacements and in-place writes after startup', async () => {
  const f = fixture();
  const initial = notification('ninitial');
  f.write('live.json', [initial]);
  f.write('history.json', []);
  const watcher = spawn(script, ['watch'], { env: f.env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  watcher.stdout.on('data', chunk => { output += chunk; });
  try {
    await eventually(() => output.includes('ninitial'));
    const current = notification('natomic', Date.now() / 1000 + 1);
    f.write('live.json', [initial, current], true);
    await eventually(() => output.includes('natomic'));
    const inplace = notification('ninplace', Date.now() / 1000 + 2);
    f.write('live.json', [initial, current, inplace]);
    await eventually(() => output.includes('ninplace'));
    f.write('live.json', [], true);
    const previousEmissions = output.split('\n').filter(line => line.includes('"key":"ninplace"')).length;
    f.write('history.json', [inplace, current, initial], true);
    await eventually(() => output.split('\n').filter(line => line.includes('"key":"ninplace"')).length > previousEmissions);
    assert.deepEqual(f.run('list').map(row => row.key), ['ninplace', 'natomic', 'ninitial']);
  } finally {
    const stopped = new Promise(resolve => watcher.once('exit', resolve));
    process.kill(-watcher.pid, 'SIGTERM');
    await stopped;
    f.dispose();
  }
});
