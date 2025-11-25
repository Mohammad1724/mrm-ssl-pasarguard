#!/bin/bash

# ==========================================
# Theme: FarsNetVIP (Fail-Safe Architecture)
# Status: THEME LOGIC ISOLATED (100% FIX)
# ==========================================

# Colors
CYAN='\033[0;36m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'

# Paths
TEMPLATE_DIR="/var/lib/pasarguard/templates/subscription"
TEMPLATE_FILE="$TEMPLATE_DIR/index.html"
ENV_FILE="/opt/pasarguard/.env"

if [ "$EUID" -ne 0 ]; then echo -e "${RED}Run as root.${NC}"; exit 1; fi

# Helper
get_prev() { if [ -f "$TEMPLATE_FILE" ]; then grep 'id="brandTxt"' "$TEMPLATE_FILE" | head -n1 | sed -E 's/.*id="brandTxt">([^<]+)<.*/\1/'; fi }
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'; }

clear
echo -e "${CYAN}=== FarsNetVIP Theme Installer ===${NC}"

PREV_BRAND=$(get_prev); [ -z "$PREV_BRAND" ] && PREV_BRAND="FarsNetVIP"
PREV_BOT="MyBot"; PREV_SUP="Support"; DEF_NEWS="🔥 خوش آمدید"

read -p "Brand [$PREV_BRAND]: " IN_BRAND
read -p "Bot User [$PREV_BOT]: " IN_BOT
read -p "Support ID [$PREV_SUP]: " IN_SUP
read -p "News [$DEF_NEWS]: " IN_NEWS

[ -z "$IN_BRAND" ] && IN_BRAND="$PREV_BRAND"
[ -z "$IN_BOT" ] && IN_BOT="$PREV_BOT"
[ -z "$IN_SUP" ] && IN_SUP="$PREV_SUP"
[ -z "$IN_NEWS" ] && IN_NEWS="$DEF_NEWS"

LNK_AND="https://play.google.com/store/apps/details?id=com.v2ray.ang"
LNK_IOS="https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690"
LNK_WIN="https://github.com/2dust/v2rayN/releases"

echo -e "\n${BLUE}Installing...${NC}"
mkdir -p "$TEMPLATE_DIR"

cat << 'EOF' > "$TEMPLATE_FILE"
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>__BRAND__ | {{ user.username }}</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;600;800&display=swap');
        
        /* DARK MODE (DEFAULT) */
        :root {
            --bg: #050505; --fg: #e0e0e0; --card: rgba(20,20,25,0.7);
            --btn-bg: rgba(124,58,237,0.65); --sec-bg: rgba(255,255,255,0.06);
            --border: rgba(255,255,255,0.12);
            --p-grad: linear-gradient(135deg, #7c3aed, #4c1d95);
            --glow1: rgba(249,115,22,0.4); --glow2: rgba(59,130,246,0.3);
        }
        /* LIGHT MODE */
        html[data-theme="light"] {
            --bg: #f3f4f6; --fg: #111827; --card: rgba(255,255,255,0.85);
            --btn-bg: rgba(124,58,237,0.85); --sec-bg: rgba(255,255,255,0.7);
            --border: rgba(0,0,0,0.1);
            --p-grad: linear-gradient(135deg, #8b5cf6, #6d28d9);
            --glow1: rgba(249,115,22,0.15); --glow2: rgba(59,130,246,0.15);
        }

        * { box-sizing:border-box; margin:0; padding:0; -webkit-tap-highlight-color:transparent; }
        body { font-family:'Vazirmatn',sans-serif; background:var(--bg); color:var(--fg); min-height:100vh; display:flex; flex-direction:column; align-items:center; padding:80px 20px 20px; overflow-x:hidden; transition:background 0.3s, color 0.3s; }

        /* Orbs */
        body::before, body::after { content:""; position:fixed; width:350px; height:350px; border-radius:50%; filter:blur(90px); z-index:-1; opacity:0.8; }
        body::before { top:-80px; right:-80px; background:var(--glow1); }
        body::after { bottom:-80px; left:-80px; background:var(--glow2); }

        /* UI Elements */
        .tick-con { position:fixed; top:0; left:0; width:100%; height:40px; background:rgba(0,0,0,0.2); border-bottom:1px solid var(--border); z-index:50; display:flex; align-items:center; overflow:hidden; backdrop-filter:blur(10px); }
        .tick-txt { white-space:nowrap; animation:t 25s linear infinite; color:#fbbf24; font-size:13px; padding:0 20px; }
        @keyframes t { 0% { transform:translateX(100%); } 100% { transform:translateX(-100%); } }

        .con { width:100%; max-width:800px; }
        .head { display:flex; justify-content:space-between; align-items:center; margin-bottom:24px; }
        .br { font-size:24px; font-weight:800; text-shadow:0 2px 10px rgba(0,0,0,0.2); }
        .bot { font-size:12px; background:var(--sec-bg); padding:4px 12px; border-radius:20px; text-decoration:none; color:var(--fg); border:1px solid var(--border); }
        
        .t-btn { width:44px; height:44px; border-radius:14px; background:var(--sec-bg); border:1px solid var(--border); display:flex; justify-content:center; align-items:center; font-size:22px; cursor:pointer; backdrop-filter:blur(5px); transition:0.2s; z-index: 10; }
        .t-btn:active { transform:scale(0.9); }

        .card { background:var(--card); border:1px solid var(--border); border-radius:24px; padding:24px; backdrop-filter:blur(25px); -webkit-backdrop-filter:blur(25px); box-shadow:0 8px 32px rgba(0,0,0,0.1); }
        .grid { display:grid; gap:24px; } @media(min-width:768px){.grid{grid-template-columns:1fr 1.2fr;}.c2{order:1;}.c1{order:2;}}

        .prof { display:flex; gap:15px; align-items:center; margin-bottom:20px; }
        .av { width:64px; height:64px; border-radius:50%; background:var(--p-grad); display:flex; justify-content:center; align-items:center; font-size:28px; position:relative; color:#fff; box-shadow:0 4px 15px rgba(124,58,237,0.4); }
        .dot { position:absolute; bottom:2px; right:2px; width:12px; height:12px; background:#10b981; border:2px solid #222; border-radius:50%; }
        .nm { font-size:18px; font-weight:700; }
        .st { font-size:12px; padding:3px 10px; border-radius:10px; margin-top:4px; display:inline-block; }
        .act { background:rgba(16,185,129,0.2); color:#34d399; border:1px solid rgba(16,185,129,0.3); }
        .inact { background:rgba(239,68,68,0.2); color:#f87171; border:1px solid rgba(239,68,68,0.3); }

        .pb { height:10px; background:rgba(0,0,0,0.2); border-radius:10px; overflow:hidden; margin-bottom:5px; border:1px solid var(--border); }
        .pf { height:100%; width:0; background:linear-gradient(90deg, #10b981, #f59e0b); transition:1s; }
        .pt { display:flex; justify-content:space-between; font-size:12px; opacity:0.7; margin-bottom:20px; }

        /* === GLASS BUTTONS === */
        .btn { position:relative; display:inline-flex; align-items:center; justify-content:center; width:100%; height:48px; font-size:15px; font-weight:600; color:#fff; text-decoration:none; cursor:pointer; border-radius:16px; backdrop-filter:blur(10px); -webkit-backdrop-filter:blur(10px); border:1px solid rgba(255,255,255,0.1); border-top:1px solid rgba(255,255,255,0.4); box-shadow:0 4px 15px rgba(0,0,0,0.15), inset 0 1px 0 rgba(255,255,255,0.3); transition:0.2s; overflow:hidden; }
        .btn::after { content:""; position:absolute; top:0; left:0; width:100%; height:50%; background:linear-gradient(to bottom, rgba(255,255,255,0.12), transparent); pointer-events:none; }
        .btn:active { transform:scale(0.97); }
        .bp { background:var(--btn-bg); }
        .bs { background:var(--sec-bg); color:var(--fg); }
        
        .ag { display:grid; grid-template-columns:1fr 1fr; gap:10px; margin-bottom:15px; }
        
        .stats { display:grid; grid-template-columns:1fr 1fr; gap:10px; margin-bottom:20px; }
        .si { background:var(--sec-bg); padding:12px; border-radius:12px; border:1px solid var(--border); }
        .sl { font-size:11px; opacity:0.6; display:block; margin-bottom:4px; } .sv { font-size:14px; font-weight:700; text-align:right; direction:ltr; display:block; }

        .dls { display:grid; grid-template-columns:1fr 1fr 1fr; gap:10px; border-top:1px solid var(--border); padding-top:15px; margin-top:15px; }
        .di { display:flex; flex-direction:column; align-items:center; padding:10px; background:var(--sec-bg); border-radius:12px; text-decoration:none; color:var(--fg); border:1px solid var(--border); font-size:11px; gap:5px; transition:0.2s; }
        .di:hover { transform:translateY(-2px); }
        .di.re { border-color:#f59e0b; background:rgba(245,158,11,0.1); }

        .mod { position:fixed; inset:0; background:rgba(0,0,0,0.85); z-index:100; display:none; align-items:center; justify-content:center; backdrop-filter:blur(5px); }
        .mb { background:#1a1a1a; width:90%; max-width:350px; padding:25px; border-radius:24px; text-align:center; border:1px solid #333; color:#fff; box-shadow:0 20px 50px rgba(0,0,0,0.5); }
        .toast { position:fixed; bottom:30px; left:50%; transform:translateX(-50%) translateY(20px); background:#fff; color:#000; padding:10px 25px; border-radius:30px; opacity:0; pointer-events:none; transition:0.3s; font-weight:700; z-index:200; box-shadow:0 10px 30px rgba(0,0,0,0.3); }
        .toast.sh { opacity:1; transform:translateX(-50%) translateY(0); }
    </style>

    <!-- SCRIPT 1: THEME (ISOLATED & SAFE) -->
    <script>
        // This runs immediately in HEAD. No dependency on panel data.
        function toggleTheme() {
            try {
                const root = document.documentElement;
                const icon = document.getElementById('tI');
                const isLight = root.getAttribute('data-theme') === 'light';
                
                if (isLight) {
                    root.removeAttribute('data-theme');
                    localStorage.setItem('theme', 'dark');
                    if (icon) icon.innerText = '🌙';
                } else {
                    root.setAttribute('data-theme', 'light');
                    localStorage.setItem('theme', 'light');
                    if (icon) icon.innerText = '☀️';
                }
            } catch(e) { console.error('Theme Error:', e); }
        }

        // Init Theme
        (function() {
            try {
                const saved = localStorage.getItem('theme');
                if (saved === 'light') {
                    document.documentElement.setAttribute('data-theme', 'light');
                }
            } catch(e) {}
        })();
    </script>
</head>
<body>
    <div class="tick-con"><div class="tick-txt" id="nT">__NEWS__</div></div>
    <div class="toast" id="toast">کپی شد!</div>

    <div class="con">
        <div class="head">
            <div>
                <div class="br" id="bT">__BRAND__</div>
                <a href="https://t.me/__BOT__" class="bot">🤖 @__BOT__</a>
            </div>
            <!-- Theme Button -->
            <div class="t-btn" onclick="toggleTheme()">
                <span id="tI">🌙</span>
            </div>
        </div>

        <div class="card">
            <div class="grid">
                <!-- C1 -->
                <div class="c1">
                    <div class="prof">
                        <div class="av">👤 {% if user.online_at %}<div class="dot"></div>{% endif %}</div>
                        <div>
                            <div class="nm">{{ user.username }}</div>
                            {% if user.status.name == 'active' %}<span class="st act">فعال</span>{% else %}<span class="st inact">غیرفعال</span>{% endif %}
                        </div>
                    </div>

                    <div class="pb"><div class="pf" id="pB"></div></div>
                    <div class="pt"><span>مصرف شده</span><span id="pT">0%</span></div>

                    <div class="ag">
                        <button class="btn bp" onclick="cp('{{ subscription_url }}')">کپی لینک</button>
                        <button class="btn bs" onclick="op('qm')">QR Code</button>
                    </div>
                    <a href="{{ subscription_url }}" class="btn bs" style="margin-bottom:10px">🚀 اتصال مستقیم</a>
                    <button class="btn bs" onclick="sc()">📂 کانفیگ‌ها</button>
                    <a href="https://t.me/__SUP__" class="btn" style="margin-top:15px; background:none; border:none; box-shadow:none; color:var(--fg); opacity:0.6; height:auto;">💬 پشتیبانی</a>
                </div>

                <!-- C2 -->
                <div class="c2">
                    <div class="stats">
                        <div class="si"><span class="sl">انقضا</span><span class="sv" id="xD">{% if user.expire %}{{ user.expire }}{% else %}نامحدود{% endif %}</span></div>
                        <div class="si"><span class="sl">کل</span><span class="sv">{{ user.data_limit | filesizeformat }}</span></div>
                        <div class="si"><span class="sl">مصرف</span><span class="sv">{{ user.used_traffic | filesizeformat }}</span></div>
                        <div class="si"><span class="sl">مانده</span><span class="sv" id="rT" style="color:#3b82f6">...</span></div>
                    </div>
                    <div class="dls">
                        <a href="__ANDROID__" class="di" id="da"><span>🤖</span>Android</a>
                        <a href="__IOS__" class="di" id="di"><span>🍏</span>iOS</a>
                        <a href="__WIN__" class="di" id="dw"><span>💻</span>Win</a>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- Modals -->
    <div id="qm" class="mod" onclick="if(event.target===this)cl('qm')">
        <div class="mb">
            <h3>اسکن کنید</h3><br>
            <div style="background:#fff; padding:10px; border-radius:10px; display:inline-block">
                <img src="https://api.qrserver.com/v1/create-qr-code/?size=200x200&data={{ subscription_url }}" width="180">
            </div>
            <button class="btn bs" style="margin-top:20px" onclick="cl('qm')">بستن</button>
        </div>
    </div>

    <div id="cm" class="mod" onclick="if(event.target===this)cl('cm')">
        <div class="mb">
            <h3>کانفیگ‌ها</h3><br>
            <div id="clst" style="text-align:left; max-height:300px; overflow-y:auto; font-size:12px">...</div>
            <button class="btn bs" style="margin-top:20px" onclick="cl('cm')">بستن</button>
        </div>
    </div>

    <!-- SCRIPT 2: DATA & LOGIC (SEPARATE) -->
    <script>
        // Update Icon if Theme is Light
        if (document.documentElement.getAttribute('data-theme') === 'light') {
             const i = document.getElementById('tI'); if(i) i.innerText = '☀️';
        }

        // DATA LOADING (TRY/CATCH BLOCKS)
        let tot = 0, use = 0;
        try { tot = Number('{{ user.data_limit }}'); } catch(e){}
        try { use = Number('{{ user.used_traffic }}'); } catch(e){}

        // Progress
        let p = 0; if(tot>0) p = (use/tot)*100; if(p>100)p=100;
        const pB = document.getElementById('pBar');
        if(pB) { pB.style.width = p+'%'; if(p>85) pB.style.background='#ef4444'; }
        const pT = document.getElementById('pT');
        if(pT) pT.innerText = Math.round(p)+'%';

        // Rem
        const rm = tot - use;
        function fmt(b){
            if(tot===0) return 'نامحدود'; if(b<=0) return '0 MB';
            const u=['B','KB','MB','GB','TB']; const i=Math.floor(Math.log(b)/Math.log(1024));
            return (b/Math.pow(1024,i)).toFixed(2)+' '+u[i];
        }
        const rT = document.getElementById('rT');
        if(rT) rT.innerText = fmt(rm);

        // Date
        const xE = document.getElementById('xD');
        if(xE) {
            const rD = xE.innerText.trim();
            if(rD && rD!=='None' && rD!=='null' && rD!=='نامحدود'){
                try{ const d=new Date(rD); if(!isNaN(d.getTime())) xE.innerText=d.toLocaleDateString('fa-IR'); }catch(e){}
            }
        }

        // Copy
        function cp(t) {
            const a=document.createElement('textarea'); a.value=t; document.body.appendChild(a); a.select();
            try{document.execCommand('copy'); const o=document.getElementById('toast'); o.classList.add('sh'); setTimeout(()=>o.classList.remove('sh'),2000);}catch(e){}
            document.body.removeChild(a);
        }
        function op(i){document.getElementById(i).style.display='flex';}
        function cl(i){document.getElementById(i).style.display='none';}

        // Configs
        function sc() {
            op('cm'); const l=document.getElementById('clst'); l.innerHTML='...';
            fetch(window.location.pathname+'/links').then(r=>r.text()).then(t=>{
                if(t){
                    l.innerHTML='';
                    l.innerHTML+='<button class="btn bp" style="height:30px;font-size:12px;margin-bottom:10px" onclick="cp(\\''+t.replace(/\\n/g,'\\\\n')+'\\')">کپی همه</button>';
                    t.split('\\n').forEach(x=>{
                        const z=x.trim();
                        if(z && (z.startsWith('vmess')||z.startsWith('vless')||z.startsWith('trojan')||z.startsWith('ss'))){
                            let n='Config'; if(z.includes('#')) n=decodeURIComponent(z.split('#')[1]);
                            l.innerHTML+='<div style="background:rgba(255,255,255,0.1);padding:8px;border-radius:8px;margin-bottom:5px;display:flex;justify-content:space-between;align-items:center"><span>'+n+'</span><button class="btn bs" style="width:auto;height:24px;font-size:10px;padding:0 10px" onclick="cp(\\''+z+'\\')">کپی</button></div>';
                        }
                    });
                }
            }).catch(()=>l.innerHTML='خطا');
        }

        // OS
        const u=navigator.userAgent.toLowerCase();
        if(u.includes('android')) document.getElementById('da').classList.add('re');
        else if(u.includes('iphone')||u.includes('ipad')) document.getElementById('di').classList.add('re');
        else if(u.includes('win')) document.getElementById('dw').classList.add('re');
    </script>
</body>
</html>
EOF

S_BR=$(sed_escape "$IN_BRAND")
S_BO=$(sed_escape "$IN_BOT")
S_SU=$(sed_escape "$IN_SUP")
S_NE=$(sed_escape "$IN_NEWS")

sed -i "s|__BRAND__|$S_BR|g" "$TEMPLATE_FILE"
sed -i "s|__BOT__|$S_BO|g" "$TEMPLATE_FILE"
sed -i "s|__SUP__|$S_SU|g" "$TEMPLATE_FILE"
sed -i "s|__NEWS__|$S_NE|g" "$TEMPLATE_FILE"
sed -i "s|__ANDROID__|$LNK_AND|g" "$TEMPLATE_FILE"
sed -i "s|__IOS__|$LNK_IOS|g" "$TEMPLATE_FILE"
sed -i "s|__WIN__|$LNK_WIN|g" "$TEMPLATE_FILE"

if [ ! -f "$ENV_FILE" ]; then touch "$ENV_FILE"; fi
sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"
echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE"
echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE"

if command -v pasarguard &> /dev/null; then pasarguard restart; else systemctl restart pasarguard 2>/dev/null; fi
echo -e "${GREEN}✔ Theme Installed (Safe Isolation)!${NC}"