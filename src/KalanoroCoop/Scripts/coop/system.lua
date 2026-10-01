-- Small Windows helpers for the session UX: local IP addresses and the clipboard.
local System = {}

local VPN_ADAPTERS = { "zerotier", "radmin", "tailscale", "hamachi", "wireguard" }
-- Local-only virtual adapters (Hyper-V, WSL, VirtualBox, VMware...): nobody can reach you there.
local VIRTUAL_ADAPTERS = { "vethernet", "virtualbox", "vmware", "wsl", "hyper-v", "loopback", "bluetooth" }

local function matchesAny(name, list)
    for _, n in ipairs(list) do
        if name:find(n, 1, true) then return true end
    end
    return false
end

local function run(cmd)
    local p = io.popen(cmd)
    if not p then return "" end
    local out = p:read("a") or ""
    p:close()
    return out
end

-- IPv4 addresses of this PC: VPN adapters first, then real network adapters, then local-only virtual ones.
function System.localIPs()
    local list, adapter = {}, ""
    for line in run("ipconfig"):gmatch("[^\r\n]+") do
        if not line:match("^%s") and line:match(":%s*$") then
            -- ipconfig writes in the console code page (French: "Carte Ethernet Wi-Fi<NBSP>:"); keep ASCII only,
            -- other bytes are not valid UTF-8 for the log and the HUD
            adapter = line:gsub(":%s*$", ""):gsub("[\128-\255]", " ")
        elseif line:match("IPv4") then
            local ip = line:match("(%d+%.%d+%.%d+%.%d+)")
            if ip and not ip:match("^127%.") and not ip:match("^169%.254%.") then
                local lower = adapter:lower()
                local rank = matchesAny(lower, VPN_ADAPTERS) and 1 or (matchesAny(lower, VIRTUAL_ADAPTERS) and 3 or 2)
                list[#list + 1] = { ip = ip, adapter = (adapter:gsub("%s+$", "")), vpn = rank == 1, rank = rank }
            end
        end
    end
    table.sort(list, function(a, b) return a.rank < b.rank end)
    return list
end

function System.clipboardGet()
    return (run('powershell -NoProfile -WindowStyle Hidden -Command "Get-Clipboard"'):gsub("%s+$", ""))
end

function System.clipboardSet(text)
    local p = io.popen("clip", "w")
    if p then
        p:write(text)
        p:close()
    end
end

-- "1.2.3.4" or "1.2.3.4:7777" (also accepts a host name with an optional port)
function System.looksLikeAddress(s)
    if not s or #s > 80 or s:find("%s") then return false end
    return s:match("^%d+%.%d+%.%d+%.%d+$") ~= nil or s:match("^%d+%.%d+%.%d+%.%d+:%d+$") ~= nil
        or s:match("^[%w%-%.]+%.[%a]+:?%d*$") ~= nil
end

return System
