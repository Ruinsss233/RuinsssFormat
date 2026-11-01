'use strict';
/*
 * cp-shim.js — DSH sandbox compatibility shim for Node's child_process.
 *
 * Why: under the DSH file sandbox, a Node process cannot open named pipes, so
 * child_process.spawn/spawnSync with the default `stdio: 'pipe'` dies with
 * `spawn EPERM`. hvigor shells out to restool.exe / java / node that way.
 *
 * What: keep the "capture the child's stdout+stderr" contract, but back it with
 * regular temp FILES handed to the child as stdio descriptors instead of pipes.
 * The captured bytes are then replayed into PassThrough streams (async spawn)
 * or assigned to result.stdout/result.stderr (spawnSync), so callers that read
 * them see exactly what they saw before.
 */
const cp = require('child_process');
const fs = require('fs');
const path = require('path');
const { PassThrough } = require('stream');

const TMP = process.env.DSH_CP_SHIM_DIR || path.join(process.env.TEMP || '.', 'dsh-cp-shim');
try { fs.mkdirSync(TMP, { recursive: true }); } catch (e) { /* ignore */ }

let seq = 0;

function newFds() {
  const id = process.pid + '-' + Date.now() + '-' + (seq++);
  const o = path.join(TMP, id + '.out');
  const e = path.join(TMP, id + '.err');
  let fo, fe;
  try {
    fo = fs.openSync(o, 'w');
    fe = fs.openSync(e, 'w');
  } catch (err) {
    return null;
  }
  return { out: o, err: e, fo: fo, fe: fe };
}

function hasPipe(stdio) {
  if (stdio === undefined || stdio === null) return true;   // Node default is 'pipe'
  if (stdio === 'pipe') return true;
  if (Array.isArray(stdio)) {
    for (let i = 0; i < stdio.length; i++) {
      if (stdio[i] === 'pipe' || stdio[i] === undefined) return true;
    }
  }
  return false;
}

function normalize(argsIn) {
  let file = argsIn[0];
  let args = argsIn[1];
  let opts = argsIn[2];
  if (args !== null && typeof args === 'object' && !Array.isArray(args) && !Buffer.isBuffer(args)) {
    opts = args;
    args = [];
  }
  if (args === undefined || args === null) args = [];
  return { file: file, args: args, opts: opts || {} };
}

function readFromOffset(file, from, to) {
  const len = to - from;
  if (len <= 0) return Buffer.alloc(0);
  const buf = Buffer.alloc(len);
  const fd = fs.openSync(file, 'r');
  try { fs.readSync(fd, buf, 0, len, from); } finally { fs.closeSync(fd); }
  return buf;
}

function sizeOf(file) {
  try { return fs.statSync(file).size; } catch (e) { return 0; }
}

function cleanup(f) {
  const files = [f.out, f.err];
  for (const p of files) { try { fs.unlinkSync(p); } catch (e) { /* ignore */ } }
}

const origSpawn = cp.spawn;
const origSpawnSync = cp.spawnSync;

if (origSpawn && !origSpawn.__dshShimmed) {
  const patched = function spawn(file, args, opts) {
    const n = normalize(arguments);
    if (!hasPipe(n.opts.stdio)) return origSpawn.call(cp, n.file, n.args, n.opts);
    const f = newFds();
    if (!f) return origSpawn.call(cp, n.file, n.args, n.opts);
    const o = Object.assign({}, n.opts, { stdio: ['ignore', f.fo, f.fe] });
    let child;
    try {
      child = origSpawn.call(cp, n.file, n.args, o);
    } catch (e) {
      try { fs.closeSync(f.fo); } catch (x) {}
      try { fs.closeSync(f.fe); } catch (x) {}
      cleanup(f);
      throw e;
    }

    const so = new PassThrough();
    const se = new PassThrough();
    if (typeof n.opts.encoding === 'string') { so.setEncoding(n.opts.encoding); se.setEncoding(n.opts.encoding); }
    child.stdout = so;
    child.stderr = se;

    let po = 0;
    let pe = 0;
    function drain() {
      const so2 = sizeOf(f.out);
      if (so2 > po) { try { so.write(readFromOffset(f.out, po, so2)); } catch (e) {} po = so2; }
      const se2 = sizeOf(f.err);
      if (se2 > pe) { try { se.write(readFromOffset(f.err, pe, se2)); } catch (e) {} pe = se2; }
    }
    const timer = setInterval(drain, 10);
    if (timer.unref) timer.unref();

    let done = false;
    function finish() {
      if (done) return;
      done = true;
      clearInterval(timer);
      drain();
      try { so.end(); } catch (e) {}
      try { se.end(); } catch (e) {}
      const t = setTimeout(function () {
        try { fs.closeSync(f.fo); } catch (e) {}
        try { fs.closeSync(f.fe); } catch (e) {}
        cleanup(f);
      }, 300);
      if (t.unref) t.unref();
    }
    child.once('close', finish);
    child.once('error', finish);
    child.once('exit', function () {
      // Pull whatever the child wrote before listeners registered later (the
      // callers' own 'exit' handlers) get to run.
      drain();
      setTimeout(finish, 60);
    });
    return child;
  };
  patched.__dshShimmed = true;
  cp.spawn = patched;
}

// ---- exec / execFile / execSync family -------------------------------------
// Node implements these on a *module-local* copy of spawn/spawnSync, so
// patching cp.spawn does not reach them; they still open named pipes and fail.
// Rebuild them on top of the patched spawn/spawnSync instead.

const origExec = cp.exec;
const origExecFile = cp.execFile;

function shellCommand(command, options) {
  const sh = options && options.shell;
  if (typeof sh === 'string' && sh.length) return { file: sh, args: ['-c', String(command)] };
  if (process.platform === 'win32') {
    const comspec = process.env.comspec || process.env.ComSpec || 'cmd.exe';
    return { file: comspec, args: ['/d', '/s', '/c', '"' + String(command) + '"'] };
  }
  const sh2 = (sh && sh !== true) ? sh : '/bin/sh';
  return { file: typeof sh2 === 'string' ? sh2 : '/bin/sh', args: ['-c', String(command)] };
}

function collect(child, options, callback) {
  const enc = options && options.encoding;
  const decode = (buf) => (buf == null ? (enc ? '' : Buffer.alloc(0)) : (enc ? buf.toString(enc) : buf));
  const so = [];
  const se = [];
  let settled = false;
  if (child.stdout) child.stdout.on('data', (d) => so.push(Buffer.isBuffer(d) ? d : Buffer.from(d)));
  if (child.stderr) child.stderr.on('data', (d) => se.push(Buffer.isBuffer(d) ? d : Buffer.from(d)));
  child.once('close', (code, signal) => {
    if (settled) return;
    settled = true;
    let err = null;
    if (code !== 0) {
      err = new Error('Command failed' + (signal ? ': ' + signal : ': ' + code));
      err.code = code;
      err.signal = signal;
    }
    callback(err, decode(Buffer.concat(so)), decode(Buffer.concat(se)));
  });
  child.once('error', (e) => {
    if (settled) return;
    settled = true;
    callback(e);
  });
  return child;
}

if (origExec && !origExec.__dshShimmed) {
  const exec = function exec(command, options, callback) {
    if (typeof options === 'function') { callback = options; options = {}; }
    options = options || {};
    const c = shellCommand(command, options);
    const opts = Object.assign({}, options, { windowsVerbatimArguments: process.platform === 'win32', stdio: 'pipe' });
    return collect(cp.spawn(c.file, c.args, opts), opts, typeof callback === 'function' ? callback : function () {});
  };
  exec.__dshShimmed = true;
  exec[require('util').promisify.custom] = (command, options) =>
    new Promise((resolve, reject) => {
      exec(command, options, (err, stdout, stderr) => (err ? reject(Object.assign(err, { stdout: stdout, stderr: stderr })) : resolve({ stdout: stdout, stderr: stderr })));
    });
  cp.exec = exec;
}

if (origExecFile && !origExecFile.__dshShimmed) {
  const execFile = function execFile(file, args, options, callback) {
    if (typeof args === 'function') { callback = args; args = []; options = {}; }
    else if (typeof options === 'function') { callback = options; options = {}; }
    else { args = args || []; options = options || {}; }
    const opts = Object.assign({}, options, { stdio: 'pipe' });
    return collect(cp.spawn(file, args, opts), opts, typeof callback === 'function' ? callback : function () {});
  };
  execFile.__dshShimmed = true;
  cp.execFile = execFile;
}

if (origSpawnSync && !origSpawnSync.__dshShimmed) {
  const patchedSync = function spawnSync(file, args, opts) {
    const n = normalize(arguments);
    if (!hasPipe(n.opts.stdio)) return origSpawnSync.call(cp, n.file, n.args, n.opts);
    const f = newFds();
    if (!f) return origSpawnSync.call(cp, n.file, n.args, n.opts);
    const o = Object.assign({}, n.opts, { stdio: ['ignore', f.fo, f.fe] });
    let r;
    try {
      r = origSpawnSync.call(cp, n.file, n.args, o);
    } finally {
      try { fs.closeSync(f.fo); } catch (e) {}
      try { fs.closeSync(f.fe); } catch (e) {}
    }
    if (r && r.error) {
      // spawn itself failed: nothing was written
      r.stdout = null;
      r.stderr = null;
    } else if (r) {
      r.stdout = readFromOffset(f.out, 0, sizeOf(f.out));
      r.stderr = readFromOffset(f.err, 0, sizeOf(f.err));
    }
    cleanup(f);
    return r;
  };
  patchedSync.__dshShimmed = true;
  cp.spawnSync = patchedSync;
}

const origExecSync = cp.execSync;
const origExecFileSync = cp.execFileSync;

function syncResult(r, command, options) {
  const enc = options && options.encoding;
  if (r.error) throw r.error;
  if (r.status !== 0) {
    const err = new Error('Command failed: ' + command);
    err.status = r.status;
    err.stdout = enc ? String(r.stdout) : r.stdout;
    err.stderr = enc ? String(r.stderr) : r.stderr;
    throw err;
  }
  if (options && options.stdio && options.stdio !== 'pipe') return enc ? String(r.stdout) : r.stdout;
  return enc ? String(r.stdout) : r.stdout;
}

if (origExecSync && !origExecSync.__dshShimmed) {
  const execSync = function execSync(command, options) {
    options = options || {};
    const c = shellCommand(command, options);
    const opts = Object.assign({}, options, { windowsVerbatimArguments: process.platform === 'win32', stdio: 'pipe' });
    delete opts.shell;
    return syncResult(cp.spawnSync(c.file, c.args, opts), command, options);
  };
  execSync.__dshShimmed = true;
  cp.execSync = execSync;
}

if (origExecFileSync && !origExecFileSync.__dshShimmed) {
  const execFileSync = function execFileSync(file, args, options) {
    if (args !== null && typeof args === 'object' && !Array.isArray(args)) { options = args; args = []; }
    args = args || [];
    options = options || {};
    const opts = Object.assign({}, options, { stdio: 'pipe' });
    return syncResult(cp.spawnSync(file, args, opts), file, options);
  };
  execFileSync.__dshShimmed = true;
  cp.execFileSync = execFileSync;
}
