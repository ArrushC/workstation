-- sshconfig.lua: ~/.ssh/config.local, the untracked per-host file ~/.ssh/config Includes
-- first. Reads its hosts (domains.lua's launcher entries and host names) and edits one in
-- place for Ctrl+Alt+S (actions.lua): add, change (rename included) or remove a host,
-- leaving every other line, the indentation, the line endings and a BOM as they were. No
-- settings, and no wezterm.* beyond home_dir, so scripts/test-wezterm-sshconfig.sh runs it
-- as is. Exports M.path, M.read, M.write, M.hosts, M.address, M.parse_address,
-- M.check_name, M.add, M.change and M.remove.

local wezterm = require 'wezterm'

local M = {}

M.path = wezterm.home_dir .. '/.ssh/config.local'

local BOM = '\239\187\191'

-- The text as { lines (no line endings), eol, bom }; join() writes it back.
local function split(text)
  local doc = { lines = {}, eol = '\n', bom = '' }
  if text:sub(1, 3) == BOM then
    doc.bom, text = BOM, text:sub(4)
  end
  if text:find('\r\n', 1, true) then
    doc.eol = '\r\n'
  end
  if text ~= '' and text:sub(-1) ~= '\n' then
    text = text .. '\n'
  end
  for line in text:gmatch('([^\n]*)\n') do
    table.insert(doc.lines, (line:gsub('\r$', '')))
  end
  return doc
end

local function join(doc)
  if #doc.lines == 0 then
    return doc.bom
  end
  return doc.bom .. table.concat(doc.lines, doc.eol) .. doc.eol
end

local function blank(line)
  return line:find('^%s*$') ~= nil
end

-- A line's keyword (lower case) and value; nil for a blank or comment line. ssh takes
-- `Key value` and `Key = value`; a trailing ` # comment` is dropped.
local function keyword(line)
  if blank(line) or line:find('^%s*#') then
    return nil
  end
  local s = line:gsub('%s+#.*$', '')
  local key, value = s:match('^%s*(%a+)%s*=%s*(.-)%s*$')
  if not key then
    key, value = s:match('^%s*(%a+)%s+(.-)%s*$')
  end
  if key then
    return key:lower(), value
  end
end

-- A line split before its trailing comment, and its `Key `/`Key = ` prefix split from the
-- value: (prefix, value, comment).
local function parts(line)
  local body, comment = line:match('^(.-)(%s+#.*)$')
  if not body then
    body, comment = line, ''
  end
  local prefix, value = body:match('^(%s*%a+%s*=%s*)(.*)$')
  if not prefix then
    prefix, value = body:match('^(%s*%a+%s+)(.*)$')
  end
  return prefix or body, value or '', comment
end

-- The Host and Match blocks: { first = its Host line, last = its own last line, tokens =
-- the Host line's patterns, match = a Match block }. A block's own lines stop before the
-- next Host or Match line, and before the blank lines and unindented comments that head
-- whatever follows (`# --- shared ---`).
local function blocks(lines)
  local out = {}
  for i, line in ipairs(lines) do
    local key, value = keyword(line)
    if key == 'host' or key == 'match' then
      local b = { first = i, last = i, match = key == 'match', tokens = {} }
      if key == 'host' then
        for t in value:gmatch('%S+') do
          table.insert(b.tokens, t)
        end
      end
      table.insert(out, b)
    elseif #out > 0 and not blank(line) and not line:find('^#') then
      out[#out].last = i
    end
  end
  return out
end

-- A block's concrete aliases: patterns, negations and names that would need quoting are
-- skipped, as bootstrap.ps1's Get-SshLauncherHosts skips them.
local function aliases(b)
  local out = {}
  for _, t in ipairs(b.tokens) do
    if not t:find('[%*%?!]') and t:match('^[%w%._@%-]+$') then
      table.insert(out, t)
    end
  end
  return out
end

local function has(b, name)
  for _, t in ipairs(b.tokens) do
    if t:lower() == name:lower() then
      return true
    end
  end
  return false
end

local function unquote(v)
  return v:match('^"(.*)"$') or v
end

-- What a host's block says, with the line each comes from: hostname, user and port (the
-- first of each), and note, the comment on the line after Host.
local function fields(lines, b)
  local f = {}
  for i = b.first + 1, b.last do
    local key, value = keyword(lines[i])
    if (key == 'hostname' or key == 'user' or key == 'port') and not f[key] then
      f[key] = { at = i, value = unquote(value) }
    end
  end
  local note = b.first < b.last and lines[b.first + 1]:match('^%s*#%s?(.-)%s*$')
  if note then
    f.note = { at = b.first + 1, value = note }
  end
  return f
end

-- The indentation of a block's lines, else of the file's, else four spaces.
local function indent(lines, b)
  local from, to = 1, #lines
  if b then
    from, to = b.first + 1, b.last
  end
  for i = from, to do
    local ws = lines[i]:match('^(%s+)%S')
    if ws then
      return ws
    end
  end
  return b and indent(lines) or '    '
end

-- The file's text; empty when there is none.
function M.read()
  local f = io.open(M.path, 'rb')
  if not f then
    return ''
  end
  local text = f:read('*a')
  f:close()
  return text
end

-- Overwrites the file in place, so it keeps its permissions (and on Windows its ACL,
-- which OpenSSH checks).
function M.write(text)
  local f, err = io.open(M.path, 'wb')
  if not f then
    return nil, err
  end
  local ok, werr = f:write(text)
  f:close()
  if not ok then
    return nil, werr
  end
  return true
end

-- Every concrete alias, in file order (a repeat, in any case, skipped): { name, hostname,
-- user, port, note, shared = the other aliases on its Host line }, from its first block.
function M.hosts(text)
  local lines = split(text).lines
  local out, seen = {}, {}
  for _, b in ipairs(blocks(lines)) do
    local names = aliases(b)
    for _, name in ipairs(names) do
      if not seen[name:lower()] then
        seen[name:lower()] = true
        local f = fields(lines, b)
        local h = { name = name, shared = {} }
        for _, k in ipairs({ 'hostname', 'user', 'port', 'note' }) do
          h[k] = f[k] and f[k].value
        end
        for _, other in ipairs(names) do
          if other:lower() ~= name:lower() then
            table.insert(h.shared, other)
          end
        end
        table.insert(out, h)
      end
    end
  end
  return out
end

-- A host's address as [user@]host[:port]; with no HostName, ssh connects to the alias.
function M.address(h)
  local host = h.hostname or h.name
  if h.port and host:find(':') then
    host = '[' .. host .. ']'
  end
  return (h.user and (h.user .. '@') or '') .. host .. (h.port and (':' .. h.port) or '')
end

-- [user@]host[:port] (IPv6 with a port as [addr]:port) as { user, hostname, port }, or nil
-- and why not.
function M.parse_address(s)
  s = s:match('^%s*(.-)%s*$')
  if s == '' then
    return nil, 'An address is needed'
  end
  if s:find('[%s#"]') then
    return nil, 'An address has no spaces, # or quotes'
  end
  local user, rest = s:match('^(.*)@([^@]*)$')
  if user == '' then
    return nil, 'There is no user before the @'
  end
  rest = rest or s
  local host, port = rest:match('^%[(.+)%]:(.*)$')
  if not host then
    host = rest:match('^%[(.+)%]$')
  end
  if not host then
    local _, colons = rest:gsub(':', '')
    if colons == 1 then
      host, port = rest:match('^(.*):(.*)$')
    else
      host = rest
    end
  end
  if host == '' then
    return nil, 'There is no host'
  end
  if host:find('^%-') or not host:find('^[%w%._:%%%-]+$') then
    return nil, host .. ' is not a host name or address'
  end
  if port then
    local n = tonumber(port:match('^%d+$') or '')
    if not n or n < 1 or n > 65535 then
      return nil, 'The port is a number from 1 to 65535'
    end
    port = tostring(n)
  end
  return { user = user, hostname = host, port = port }
end

-- Why `name` can't be a host's name, or nil. `current` is the host's own name, when it has one.
function M.check_name(text, name, current)
  if current and name:lower() == current:lower() then
    return nil
  end
  if not name:find('^[%w_][%w%._%-]*$') then
    return 'A name is letters, digits, dots, dashes and underscores'
  end
  for _, h in ipairs(M.hosts(text)) do
    if h.name:lower() == name:lower() then
      return name .. ' is already a host'
    end
  end
end

local keys = { hostname = 'HostName', user = 'User', port = 'Port' }
local order = { 'hostname', 'user', 'port' }

-- A new block for h = { name, hostname, user, port, note } (all but name optional): before
-- the first Host pattern or Match block and the comments heading it, which are meant as
-- defaults (ssh takes each setting from the first block that sets it), else at the end.
-- Spaced from its neighbours as the file spaces its blocks.
function M.add(text, h)
  local err = M.check_name(text, h.name)
  if err then
    return nil, err
  end
  local doc = split(text)
  local lines = doc.lines
  local ind = indent(lines)
  local new = { 'Host ' .. h.name }
  if h.note and h.note ~= '' then
    table.insert(new, ind .. '# ' .. h.note)
  end
  for _, k in ipairs(order) do
    if h[k] and h[k] ~= '' then
      table.insert(new, ind .. keys[k] .. ' ' .. h[k])
    end
  end
  local bs, at = blocks(lines), nil
  for _, b in ipairs(bs) do
    if b.match or table.concat(b.tokens, ' '):find('[%*%?]') then
      at = b.first
      break
    end
  end
  if at then
    while at > 1 and lines[at - 1]:find('^#') do
      at = at - 1
    end
    if at > 1 and blank(lines[at - 1]) then
      table.insert(new, '')
    end
  else
    while #lines > 0 and blank(lines[#lines]) do
      table.remove(lines)
    end
    local last = bs[#bs]
    if last and last.first > 1 and blank(lines[last.first - 1]) then
      table.insert(lines, '')
    end
    at = #lines + 1
  end
  for i, line in ipairs(new) do
    table.insert(lines, at + i - 1, line)
  end
  return join(doc)
end

local function first_block(lines, name)
  for _, b in ipairs(blocks(lines)) do
    if has(b, name) then
      return b
    end
  end
end

-- Host `name` takes h = { name, hostname, user, port, note }: an empty or missing field
-- loses its line, a new one gets a line in HostName, User, Port order, and a changed one
-- keeps its line's spelling, `=` and trailing comment. Its first block is edited (ssh reads
-- the first); a rename renames it on every Host line. Other lines stay as they are, so an
-- unchanged h returns the text unchanged.
function M.change(text, name, h)
  local doc = split(text)
  local lines = doc.lines
  local b = first_block(lines, name)
  if not b then
    return nil, name .. ' is no longer in ~/.ssh/config.local'
  end
  local err = M.check_name(text, h.name, name)
  if err then
    return nil, err
  end
  local ind = indent(lines, b)
  local f = fields(lines, b)
  local note = h.note or ''
  if note ~= (f.note and f.note.value or '') then
    if f.note and note == '' then
      table.remove(lines, f.note.at)
    elseif f.note then
      lines[f.note.at] = lines[f.note.at]:match('^%s*') .. '# ' .. note
    else
      table.insert(lines, b.first + 1, ind .. '# ' .. note)
    end
  end
  for n, k in ipairs(order) do
    b = first_block(lines, name)
    f = fields(lines, b)
    local want, cur = h[k] ~= '' and h[k] or nil, f[k] and f[k].value
    -- No HostName means the alias is the address; keep it that way while it still is.
    local implicit = k == 'hostname' and not cur and want and want:lower() == h.name:lower()
    if want ~= cur and not implicit then
      if not want then
        table.remove(lines, f[k].at)
      elseif f[k] then
        local prefix, _, comment = parts(lines[f[k].at])
        lines[f[k].at] = prefix .. want .. comment
      else
        local after = f.note and f.note.at or b.first
        for m = 1, n - 1 do
          after = f[order[m]] and math.max(after, f[order[m]].at) or after
        end
        table.insert(lines, after + 1, ind .. keys[k] .. ' ' .. want)
      end
    end
  end
  if h.name ~= name then
    for _, blk in ipairs(blocks(lines)) do
      if has(blk, name) then
        local prefix, value, comment = parts(lines[blk.first])
        value = value:gsub('%S+', function(t)
          if t:lower() == name:lower() then
            return h.name
          end
        end)
        lines[blk.first] = prefix .. value .. comment
      end
    end
  end
  return join(doc)
end

-- Host `name` goes from every Host line it is on, and a block left with no other pattern
-- goes with it: its own lines, not the comments heading the next block.
function M.remove(text, name)
  local doc = split(text)
  local lines = doc.lines
  local bs, found = blocks(lines), false
  for k = #bs, 1, -1 do
    local b = bs[k]
    if has(b, name) then
      found = true
      local rest = {}
      for _, t in ipairs(b.tokens) do
        if t:lower() ~= name:lower() then
          table.insert(rest, t)
        end
      end
      if #rest > 0 then
        local prefix, _, comment = parts(lines[b.first])
        lines[b.first] = prefix .. table.concat(rest, ' ') .. comment
      else
        for _ = b.first, b.last do
          table.remove(lines, b.first)
        end
        -- The blank lines that were either side of it become one.
        if b.first > 1 and lines[b.first] and blank(lines[b.first - 1]) and blank(lines[b.first]) then
          table.remove(lines, b.first)
        end
      end
    end
  end
  if not found then
    return nil, name .. ' is no longer in ~/.ssh/config.local'
  end
  return join(doc)
end

return M
