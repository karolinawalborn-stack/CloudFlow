// Run from the repository root: node Tests/QuarkLoginTests.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('App/DriveBrowser.swift', 'utf8');
const match = source.match(/private static let quarkLoginCallback = #"""\r?\n([\s\S]*?)\r?\n    """#/);
assert.ok(match, 'The actual embedded Quark callback script must exist');
let checks = 0;
function check(condition, message) { assert.ok(condition, message); checks++; }
function harness(host = 'uop.quark.cn', pathname = '/cas/custom/login', topLevel = true) {
  const messages = [];
  let callback;
  const window = { addEventListener: (name, fn) => { if (name === 'message') callback = fn; },
    webkit: { messageHandlers: { cloudflowQuarkLogin: { postMessage: value => messages.push(value) } } } };
  window.top = topLevel ? window : {};
  vm.runInNewContext(match[1], { window, location: { protocol: 'https:', hostname: host, pathname } });
  return { messages, send(data, origin = 'https://uop.quark.cn', source = window) { if (callback) callback({ data, origin, source }); } };
}
const ticket = '0123456789abcdef0123456789abcdef';
const official = harness(); official.send(ticket);
check(official.messages.length === 1 && official.messages[0].st === ticket, 'Accept the official 32-character string ticket');
const object = harness(); object.send({ st: ticket });
check(object.messages.length === 1, 'Accept an explicit successful st response');
for (const [data, origin, sender] of [
  [ticket, 'https://unrelated.invalid', undefined],
  [ticket, 'https://uop.quark.cn', {}],
  [{ st: ticket, error: true }, undefined, undefined],
  ['too-short', undefined, undefined],
  [{ st: ticket + '\n' }, undefined, undefined],
  [{ st: 'x'.repeat(8193) }, undefined, undefined],
  [{ st: '' }, undefined, undefined],
]) {
  const invalid = harness(); invalid.send(data, origin, sender);
  check(invalid.messages.length === 0, 'Ignore invalid or unrelated login messages');
}
for (const args of [['other.quark.cn'], ['uop.quark.cn', '/other'], ['uop.quark.cn', '/cas/custom/login', false]]) {
  const invalid = harness(...args); invalid.send(ticket);
  check(invalid.messages.length === 0, 'Install the callback only on the top-level official login form');
}
const url = source.match(/private static let quarkLoginURL = URL\(string: "([^"]+)"\)/);
assert.ok(url);
const entry = new URL(url[1]);
check(entry.origin === 'https://uop.quark.cn' && entry.pathname === '/cas/custom/login', 'Load the official login form instead of the promotion page');
check(entry.searchParams.get('client_id') === '532', 'Use the Quark web client identifier');
check(source.includes('session.reload()'), 'Refresh uses the corrected login entry');
check(source.includes('url.host == "h5.sm.cn"') && source.includes('/blm/mobile-entry-'), 'Recover a top-level Quark promotion redirect');
console.log('PASS: ' + checks + ' Quark login callback and routing checks');

