#!/usr/bin/env bash
# test-wezterm-sshconfig.sh: dotfiles/config/wezterm/sshconfig.lua, which reads
# ~/.ssh/config.local for WezTerm's launcher and edits it for Ctrl+Alt+S. Reading: the
# concrete Host aliases and each one's HostName, User, Port and note. Editing: add, change
# (rename included) and remove one host, leaving every other line, the indentation, the
# line endings and a BOM as they were. Runs under LuaJIT as check_wezterm_config does
# (luajit, or the one inside nvim); skipped without either.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v luajit >/dev/null 2>&1; then
  lua=(luajit)
elif command -v nvim >/dev/null 2>&1; then
  lua=(nvim --clean --headless -l)
else
  echo "test-wezterm-sshconfig: neither luajit nor nvim on PATH, skipped"
  exit 0
fi
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT

cat >"$T/test.lua" <<'LUA'
local dir, home = arg[1], arg[2]
package.path = dir .. '/?.lua;' .. package.path
package.loaded.wezterm = { home_dir = home }
local sc = require 'sshconfig'

local pass, fail = 0, 0
-- Raw output: nvim -l's print escapes the colour codes.
local function print(s) io.write(s, '\n') end
local function check(name, cond, detail)
  if cond then
    print('  \27[0;32mPASS\27[0m ' .. name)
    pass = pass + 1
  else
    print('  \27[0;31mFAIL\27[0m ' .. name)
    if detail then print((tostring(detail):gsub('\n', '\n      '):gsub('^', '      '))) end
    fail = fail + 1
  end
end
local function eq(name, got, want)
  check(name, got == want, 'got:\n' .. tostring(got) .. '\nwant:\n' .. tostring(want))
end
local function lines(t) return table.concat(t, '\n') .. '\n' end

-- A config.local laid out as the real ones are: section comments, blocks back to back, a
-- note on the line after each Host.
local F = lines({
  '# Per-host SSH config: untracked.',
  '',
  '# --- build boxes ---',
  'Host dev10',
  '    # dev10.corp, the build box',
  '    HostName 10.0.0.10',
  '    User me',
  'Host dev09',
  '    # dev09.corp',
  '    HostName 10.0.0.9',
  '    User me',
  '',
  '# --- QA ---',
  'Host qa1 qa1-alt',
  '    # qa1.corp',
  '    HostName "qa1.corp"',
  '    User shared',
  '    IdentityFile "C:\\Users\\Me Too\\.ssh\\qa"',
  'Host qa2',
  '    HostName = qa2.corp # was qa-2',
  '    user=tester',
  '    Port 2222',
})

print('-- reading')
local function names(text)
  local out = {}
  for _, h in ipairs(sc.hosts(text)) do out[#out + 1] = h.name end
  return table.concat(out, ',')
end
local function host(text, name)
  for _, h in ipairs(sc.hosts(text)) do if h.name == name then return h end end
  return {}
end
eq('every concrete alias, in file order', names(F), 'dev10,dev09,qa1,qa1-alt,qa2')
local h = host(F, 'dev10')
check('a host has its HostName, User and note', h.hostname == '10.0.0.10' and h.user == 'me' and h.port == nil and h.note == 'dev10.corp, the build box',
  table.concat({ tostring(h.hostname), tostring(h.user), tostring(h.port), tostring(h.note) }, ' | '))
h = host(F, 'qa2')
check('Key = value, key=value, a trailing comment and Port', h.hostname == 'qa2.corp' and h.user == 'tester' and h.port == '2222' and h.note == nil,
  table.concat({ tostring(h.hostname), tostring(h.user), tostring(h.port), tostring(h.note) }, ' | '))
eq('a quoted value is read without its quotes', host(F, 'qa1').hostname, 'qa1.corp')
eq('aliases on one Host line share its block', table.concat(host(F, 'qa1').shared, ',') .. '/' .. table.concat(host(F, 'qa1-alt').shared, ','), 'qa1-alt/qa1')
local odd = 'Host alpha beta\n  HostName atc-alpha.corp\nHost *.corp\nHost !bad\n  HostName x.example\n  host = gamma # comment\n  HostName = 10.0.0.9\nMatch host foo\n  HostName y.example\nHost bad"quote\nHost ALPHA\n'
eq('patterns, negations, unsafe names and a case-only repeat are skipped', names(odd), 'alpha,beta,gamma')
eq("a Match block's HostName is not a host's", host(odd, 'gamma').hostname, '10.0.0.9')
eq('no file, no hosts', names(''), '')

print('-- addresses')
local function addr(s)
  local a, err = sc.parse_address(s)
  if not a then return 'error: ' .. tostring(err) end
  return tostring(a.user) .. '|' .. tostring(a.hostname) .. '|' .. tostring(a.port)
end
eq('user@host:port', addr('me@build01.corp:2222'), 'me|build01.corp|2222')
eq('a bare host', addr(' 10.0.0.9 '), 'nil|10.0.0.9|nil')
eq('a user with an @ splits at the last one', addr('me@corp.local@jump'), 'me@corp.local|jump|nil')
eq('[IPv6]:port', addr('[fe80::1]:2200'), 'nil|fe80::1|2200')
eq('a bare IPv6 address has no port', addr('fe80::1'), 'nil|fe80::1|nil')
for _, bad in ipairs({ '', 'me@', '@host', 'host:0', 'host:70000', 'host:ssh', 'two words', '-oProxyCommand=x', 'host#x' }) do
  check('refused: "' .. bad .. '"', addr(bad):find('^error: ') ~= nil, addr(bad))
end
eq('formatted back', sc.address({ name = 'x', hostname = 'h.corp', user = 'me', port = '22' }), 'me@h.corp:22')
eq('formatted back: IPv6 with a port is bracketed', sc.address({ name = 'x', hostname = 'fe80::1', port = '2200' }), '[fe80::1]:2200')
eq('formatted back: no HostName is the alias itself', sc.address({ name = 'dev10', user = 'me' }), 'me@dev10')

print('-- names')
for _, bad in ipairs({ '', 'two words', '-x', 'a*', 'a?', '!a', 'me@host', 'a"b' }) do
  check('refused name: "' .. bad .. '"', sc.check_name(F, bad) ~= nil)
end
check('a name already in use is refused, whatever its case', (sc.check_name(F, 'DEV10') or ''):find('already') ~= nil, sc.check_name(F, 'DEV10'))
check('a host keeps its own name', sc.check_name(F, 'dev10', 'dev10') == nil and sc.check_name(F, 'Dev10', 'dev10') == nil)
check('a new name is fine', sc.check_name(F, 'build_01.corp-x') == nil)

print('-- add')
local new = { name = 'dev11', hostname = '10.0.0.11', user = 'me', port = '2200', note = 'dev11.corp' }
eq('appended after the last block, back to back, in its indentation, note first', sc.add(F, new),
  F .. lines({ 'Host dev11', '    # dev11.corp', '    HostName 10.0.0.11', '    User me', '    Port 2200' }))
eq('only the fields given', sc.add(F, { name = 'dev12', hostname = 'dev12.corp' }), F .. lines({ 'Host dev12', '    HostName dev12.corp' }))
eq('into an empty file', sc.add('', { name = 'b', hostname = 'b.corp' }), 'Host b\n    HostName b.corp\n')
eq('blank-line spacing kept, trailing blank lines folded',
  sc.add('Host a\n  HostName a\n\nHost c\n  HostName c\n\n\n', { name = 'b', hostname = 'b' }),
  'Host a\n  HostName a\n\nHost c\n  HostName c\n\nHost b\n  HostName b\n')
eq('before a Host * block and its comment, so its settings stay defaults',
  sc.add('Host a\n  HostName a.corp\n\n# defaults\nHost *\n  User me\n', { name = 'b', hostname = 'b.corp' }),
  'Host a\n  HostName a.corp\n\nHost b\n  HostName b.corp\n\n# defaults\nHost *\n  User me\n')
eq('before a Match block, back to back when the file is',
  sc.add('Host a\n  HostName a\nMatch user root\n  Port 22\n', { name = 'b', hostname = 'b' }),
  'Host a\n  HostName a\nHost b\n  HostName b\nMatch user root\n  Port 22\n')
eq('CRLF stays CRLF', sc.add('Host a\r\n    HostName a\r\n', { name = 'b', hostname = 'b' }), 'Host a\r\n    HostName a\r\nHost b\r\n    HostName b\r\n')
eq('a BOM stays', sc.add('\239\187\191Host a\n    HostName a\n', { name = 'b', hostname = 'b' }), '\239\187\191Host a\n    HostName a\nHost b\n    HostName b\n')
local none, err = sc.add(F, { name = 'qa1-ALT', hostname = 'x' })
check('adding a name in use is refused', none == nil and (err or ''):find('already') ~= nil, err)

print('-- change')
local function swap(text, from, to)
  local i, j = text:find(from, 1, true)
  assert(i, 'fixture has no ' .. from)
  return text:sub(1, i - 1) .. to .. text:sub(j + 1)
end
eq('nothing changed, nothing rewritten', sc.change(F, 'qa2', { name = 'qa2', hostname = 'qa2.corp', user = 'tester', port = '2222' }), F)
eq('values replaced in their own style; Port dropped; a note added after Host',
  sc.change(F, 'qa2', { name = 'qa2', hostname = 'qa-2.corp', user = 'admin', note = 'QA two' }),
  swap(F, 'Host qa2\n    HostName = qa2.corp # was qa-2\n    user=tester\n    Port 2222\n',
    'Host qa2\n    # QA two\n    HostName = qa-2.corp # was qa-2\n    user=admin\n'))
eq('a Port added after User; an empty note removed',
  sc.change(F, 'dev09', { name = 'dev09', hostname = '10.0.0.9', user = 'me', port = '2201' }),
  swap(F, 'Host dev09\n    # dev09.corp\n    HostName 10.0.0.9\n    User me\n', 'Host dev09\n    HostName 10.0.0.9\n    User me\n    Port 2201\n'))
eq('a note replaced; other options and the quoted path untouched',
  sc.change(F, 'qa1', { name = 'qa1', hostname = 'qa1.corp', user = 'shared', note = 'QA one' }),
  swap(F, '    # qa1.corp\n', '    # QA one\n'))
eq('a rename changes only that alias on a shared Host line',
  sc.change(F, 'qa1-alt', { name = 'qa1-b', hostname = 'qa1.corp', user = 'shared', note = 'qa1.corp' }),
  swap(F, 'Host qa1 qa1-alt\n', 'Host qa1 qa1-b\n'))
eq('a rename keeps reaching the old name when there was no HostName',
  sc.change('Host dev10\n    User me\n', 'dev10', { name = 'd10', hostname = 'dev10', user = 'me' }),
  'Host d10\n    HostName dev10\n    User me\n')
eq('a case-only rename', sc.change(F, 'dev09', { name = 'Dev09', hostname = '10.0.0.9', user = 'me', note = 'dev09.corp' }), swap(F, 'Host dev09\n', 'Host Dev09\n'))
none, err = sc.change(F, 'dev09', { name = 'DEV10', hostname = 'x' })
check('renaming onto another host is refused', none == nil and (err or ''):find('already') ~= nil, err)
none, err = sc.change(F, 'nope', { name = 'nope', hostname = 'x' })
check('changing a host that is gone is refused', none == nil and (err or ''):find('nope') ~= nil, err)

print('-- remove')
eq("a host's own lines go; the next section's comment stays", sc.remove(F, 'dev09'),
  swap(F, 'Host dev09\n    # dev09.corp\n    HostName 10.0.0.9\n    User me\n', ''))
eq("the first host of a section: the section's comment stays", sc.remove(F, 'dev10'),
  swap(F, 'Host dev10\n    # dev10.corp, the build box\n    HostName 10.0.0.10\n    User me\n', ''))
eq('one alias of a shared Host line goes, the block stays', sc.remove(F, 'qa1'), swap(F, 'Host qa1 qa1-alt\n', 'Host qa1-alt\n'))
eq('the last block', sc.remove(F, 'qa2'), swap(F, 'Host qa2\n    HostName = qa2.corp # was qa-2\n    user=tester\n    Port 2222\n', ''))
eq('no double blank line left behind', sc.remove('Host a\n    HostName a\n\nHost b\n    HostName b\n\nHost c\n', 'b'), 'Host a\n    HostName a\n\nHost c\n')
eq('every block it is in', sc.remove('Host a\n  User x\nHost b\nHost a\n  Port 1\n', 'A'), 'Host b\n')
eq('beside a pattern, only the alias', sc.remove('Host a *.corp\n  User x\n', 'a'), 'Host *.corp\n  User x\n')
eq('CRLF stays CRLF', sc.remove('Host a\r\n  User x\r\nHost b\r\n  User y\r\n', 'a'), 'Host b\r\n  User y\r\n')
none, err = sc.remove(F, 'nope')
check('removing a host that is gone is refused', none == nil and (err or ''):find('nope') ~= nil, err)

print('-- the file')
eq('the path is ~/.ssh/config.local', sc.path, home .. '/.ssh/config.local')
eq('no file reads as empty', sc.read(), '')
local ok, werr = sc.write('Host a\n')
check('no ~/.ssh: the write fails and says why', not ok and werr ~= nil, werr)
os.execute('mkdir "' .. home .. '/.ssh"')
ok, werr = sc.write('Host a\r\n  HostName a\r\n')
check('written as given, CRLF included', ok and sc.read() == 'Host a\r\n  HostName a\r\n', werr)

print('')
if fail == 0 then
  print(string.format('\27[0;32m✓ all %d sshconfig cases passed\27[0m', pass))
  os.exit(0)
end
print(string.format('\27[0;31m✗ %d/%d sshconfig cases failed\27[0m', fail, pass + fail))
os.exit(1)
LUA

mkdir -p "$T/home"
"${lua[@]}" "$T/test.lua" "$ROOT/dotfiles/config/wezterm" "$T/home"
