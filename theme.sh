#!/bin/bash

# ==========================================
# Theme: FarsNetVIP (Root-Level Fix)
# Status: THEME TOGGLE FIXED (Global Scope)
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
        
        /* --- GLOBAL VARIABLES (Dark Default) --- */
        :root {
            --bg: #050505;
            --fg: #e5e5e5;
            --card-bg: rgba(20, 20, 25, 0.75);
            --btn-pri: rgba(124, 58, 237, 0.75);
            --btn-sec: rgba(255, 255, 255, 0.08);
            --border: rgba(255, 255, 255, 0.15);
            --orb1: rgba(249, 115, 22, 0.45);
            --orb2: rgba(59, 130, 246, 0.35);
            --txt-muted: #a3a3a3;
        }

        /* --- LIGHT MODE OVERRIDE (Higher Specificity) --- */
        :root.light-mode {
            --bg: #f0f4f8;
            --fg: #1e293b;
            --card-bg: rgba(255, 255, 255, 0.85);
            --btn-pri: rgba(124, 58, 237, 0.9);
            --btn-sec: rgba(255, 255, 255, 0.7);
            --border: rgba(0, 0, 0, 0.15);
            --orb1: rgba(249, 115, 22, 0.25);
            --orb2: rgba(59, 130, 246, 0.25);
            --txt-muted: #64748b;
        }

        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }

        body {
            font-family: 'Vazirmatn', sans-serif;
            background-color: var(--bg);
            color: var(--fg);
            margin: 0; padding: 0;
            min-height: 100vh;
            display: flex; flex-direction: column; align-items: center;
            padding-top: 70px; padding-bottom: 30px;
            overflow-x: hidden;
            transition: background-color 0.4s ease, color 0.4s ease;
        }

        /* Background Orbs */
        .orb { position: fixed; width: 350px; height: 350px; border-radius: 50%; filter: blur(90px); z-index: -1; opacity: 0.8; pointer-events: none; transition: background 0.4s ease; }
        .orb-1 { top: -80px; right: -80px; background: var(--orb1); }
        .orb-2 { bottom: -80px; left: -80px; background: var(--orb2); }

        /* Ticker */
        .tick-wrap { position: fixed; top: 0; left: 0; width: 100%; height: 45px; background: rgba(0,0,0,0.2); border-bottom: 1px solid var(--border); z-index: 50; display: flex; align-items: center; overflow: hidden; backdrop-filter: blur(10px); }
        .tick-txt { white-space: nowrap; animation: scroll 25s linear infinite; color: #fbbf24; font-size: 13px; padding-right: 100%; }
        @keyframes scroll { 0% { transform: translateX(100%); } 100% { transform: translateX(-100%); } }

        .con { width: 100%; max-width: 800px; padding: 0 20px; }

        /* Header */
        .head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; position: relative; z-index: 20; }
        .brand { font-size: 26px; font-weight: 800; text-shadow: 0 2px 15px rgba(0,0,0,0.2); }
        .bot-tag { font-size: 12px; background: var(--sec-bg); padding: 4px 12px; border-radius: 20px; text-decoration: none; color: var(--fg); border: 1px solid var(--border); display: inline-block; margin-top: 4px; }

        /* Theme Toggle Button */
        .theme-togg {
            width: 46px; height: 46px; border-radius: 14px;
            background: var(--sec-bg); border: 1px solid var(--border);
            display: flex; justify-content: center; align-items: center;
            font-size: 22px; cursor: pointer; backdrop-filter: blur(5px);
            z-index: 9999;
            transition: 0.2s;
            -webkit-user-select: none; user-select: none;
        }
        .theme-togg:active { transform: scale(0.92); }

        /* Main Card */
        .card {
            background: var(--card-bg); border: 1px solid var(--border);
            border-radius: 24px; padding: 24px;
            backdrop-filter: blur(25px); -webkit-backdrop-filter: blur(25px);
            box-shadow: 0 10px 40px rgba(0,0,0,0.1);
            margin-bottom: 30px;
            transition: background 0.4s ease, border 0.4s ease;
        }

        .grid { display: grid; gap: 24px; }
        @media(min-width:768px){ .grid { grid-template-columns: 1fr 1.2fr; } }

        /* User Profile */
        .u-row { display: flex; gap: 16px; align-items: center; margin-bottom: 20px; }
        .av { width: 68px; height: 68px; border-radius: 50%; background: linear-gradient(135deg, #7c3aed, #4c1d95); display: flex; justify-content: center; align-items: center; font-size: 30px; color: #fff; box-shadow: 0 5px 15px rgba(124, 58, 237, 0.4); position: relative; }
        .dot { position: absolute; bottom: 2px; right: 2px; width: 14px; height: 14px; background: #10b981; border: 2px solid #222; border-radius: 50%; }
        .nm { font-size: 20px; font-weight: 700; }
        .st { font-size: 12px; padding: 3px 10px; border-radius: 8px; margin-top: 4px; display: inline-block; }
        .st.act { background: rgba(16, 185, 129, 0.2); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.3); }
        .st.inact { background: rgba(239, 68, 68, 0.2); color: #f87171; border: 1px solid rgba(239, 68, 68, 0.3); }

        /* Progress */
        .pg-wrap { height: 12px; background: rgba(0,0,0,0.2); border-radius: 12px; overflow: hidden; border: 1px solid var(--border); margin-bottom: 6px; }
        .pg-fill { height: 100%; width: 0; background: linear-gradient(90deg, #10b981, #f59e0b); transition: 1s; }
        .pg-txt { display: flex; justify-content: space-between; font-size: 12px; color: var(--txt-muted); margin-bottom: 24px; }

        /* === GLASS BUTTONS (FIXED) === */
        .btn {
            position: relative; width: 100%; height: 50px;
            display: inline-flex; align-items: center; justify-content: center;
            font-size: 15px; font-weight: 600; color: #fff;
            text-decoration: none; cursor: pointer;
            border-radius: 16px;
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-top: 1px solid rgba(255, 255, 255, 0.4);
            border-bottom: 1px solid rgba(0, 0, 0, 0.2);
            backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px);
            box-shadow: 0 5px 15px rgba(0, 0, 0, 0.15), inset 0 1px 0 rgba(255, 255, 255, 0.3);
            transition: 0.2s; overflow: hidden;
        }
        .btn::before {
            content: ""; position: absolute; top: -50%; left: 0; width: 100%; height: 100%;
            background: linear-gradient(to bottom, rgba(255,255,255,0.15), transparent);
            transform: skewY(-10deg); pointer-events: none;
        }
        .btn:active { transform: scale(0.97); }
        
        .btn.pri { background: var(--btn-pri); color: #fff; }
        /* In light mode, sec button text needs to follow foreground color */
        .btn.sec { background: var(--sec-bg); color: var(--fg); }

        .btn-row { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 12px; }
        
        /* Stats Grid */
        .s-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 20px; }
        .s-box { background: var(--sec-bg); padding: 12px; border-radius: 12px; border: 1px solid var(--border); transition: background 0.3s; }
        .s-lbl { font-size: 11px; color: var(--txt-muted); display: block; margin-bottom: 4px; }
        .s-val { font-size: 15px; font-weight: 700; text-align: right; direction: ltr; display: block; }

        /* Downloads */
        .dl-wrap { border-top: 1px solid var(--border); padding-top: 20px; margin-top: 10px; }
        .dl-row { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 10px; margin-top: 12px; }
        .dl-btn { display: flex; flex-direction: column; align-items: center; padding: 10px; background: var(--sec-bg); border-radius: 12px; text-decoration: none; color: var(--fg); border: 1px solid var(--border); font-size: 11px; gap: 6px; transition: 0.2s; }
        .dl-btn:hover { transform: translateY(-3px); background: rgba(255,255,255,0.1); }
        .dl-btn.rec { border-color: #f59e0b; background: rgba(245, 158, 11, 0.1); }

        /* Modals & Toast */
        .modal { position: fixed; inset: 0; background: rgba(0,0,0,0.85); z-index: 200; display: none; align-items: center; justify-content: center; backdrop-filter: blur(8px); }
        .m-box { background: #1a1a1a; width: 90%; max-width: 350px; padding: 25px; border-radius: 24px; text-align: center; border: 1px solid #333; color: #fff; box-shadow: 0 20px 50px rgba(0,0,0,0.6); }
        .toast { position: fixed; bottom: 40px; left: 50%; transform: translateX(-50%) translateY(20px); background: #fff; color: #000; padding: 10px 25px; border-radius: 30px; opacity: 0; pointer-events: none; transition: 0.3s; font-weight: 700; z-index: 300; box-shadow: 0 10px 30px rgba(0,0,0,0.3); }
        .toast.vis { opacity: 1; transform: translateX(-50%) translateY(0); }
    </style>
</head>
<body>
    <div class="orb orb-1"></div>
    <div class="orb orb-2"></div>
    
    <div class="tick-wrap"><div class="tick-txt" id="nT">__NEWS__</div></div>
    <div class="toast" id="toast">کپی شد!</div>

    <div class="con">
        <div class="head">
            <div>
                <div class="brand" id="bT">__BRAND__</div>
                <a href="https://t.me/__BOT__" class="bot-tag">🤖 @__BOT__</a>
            </div>
            <!-- Theme Toggle -->
            <div class="theme-togg" id="themeBtn">🌙</div>
        </div>

        <div class="card">
            <div class="grid">
                <!-- Left Col -->
                <div>
                    <div class="u-row">
                        <div class="av">👤 {% if user.online_at %}<div class="dot"></div>{% endif %}</div>
                        <div>
                            <div class="nm">{{ user.username }}</div>
                            {% if user.status.name == 'active' %}<span class="st act">فعال</span>{% else %}<span class="st inact">غیرفعال</span>{% endif %}
                        </div>
                    </div>

                    <div class="pg-wrap"><div class="pg-fill" id="pB"></div></div>
                    <div class="pg-txt"><span>مصرف شده</span><span id="pT">0%</span></div>

                    <div class="btn-row">
                        <div class="btn pri" onclick="doCopy('{{ subscription_url }}')">کپی لینک</div>
                        <div class="btn sec" onclick="openM('mq')">QR Code</div>
                    </div>
                    <a href="{{ subscription_url }}" class="btn sec" style="margin-bottom:12px">🚀 اتصال مستقیم</a>
                    <div class="btn sec" onclick="shConf()">📂 کانفیگ‌ها</div>
                    
                    <a href="https://t.me/__SUP__" class="btn" style="margin-top:16px; background:transparent; border:none; box-shadow:none; color:var(--txt-muted); height:auto;">💬 پشتیبانی</a>
                </div>

                <!-- Right Col -->
                <div>
                    <div class="s-grid">
                        <div class="s-box"><span class="s-lbl">انقضا</span><span class="s-val" id="xD">{% if user.expire %}{{ user.expire }}{% else %}نامحدود{% endif %}</span></div>
                        <div class="s-box"><span class="s-lbl">کل حجم</span><span class="s-val">{{ user.data_limit | filesizeformat }}</span></div>
                        <div class="s-box"><span class="s-lbl">مصرفی</span><span class="s-val">{{ user.used_traffic | filesizeformat }}</span></div>
                        <div class="s-box"><span class="s-lbl">مانده</span><span class="s-val" id="rT" style="color:#3b82f6">...</span></div>
                    </div>
                    <div class="dl-wrap">
                        <div style="font-size:13px; opacity:0.7">دانلود اپلیکیشن</div>
                        <div class="dl-row">
                            <a href="__ANDROID__" class="dl-btn" id="da"><span>🤖</span>And</a>
                            <a href="__IOS__" class="dl-btn" id="di"><span>🍏</span>iOS</a>
                            <a href="__WIN__" class="dl-btn" id="dw"><span>💻</span>Win</a>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- Modals -->
    <div id="mq" class="modal" onclick="if(event.target===this)closeM('mq')">
        <div class="m-box">
            <h3>اسکن کنید</h3><br>
            <div style="background:#fff; padding:10px; border-radius:12px; display:inline-block">
                <img src="https://api.qrserver.com/v1/create-qr-code/?size=200x200&data={{ subscription_url }}" width="180">
            </div>
            <div class="btn sec" style="margin-top:20px; background:#333; color:#fff" onclick="closeM('mq')">بستن</div>
        </div>
    </div>

    <div id="mc" class="modal" onclick="if(event.target===this)closeM('mc')">
        <div class="m-box">
            <h3>کانفیگ‌ها</h3><br>
            <div id="clst" style="text-align:left; max-height:300px; overflow-y:auto; font-size:12px">...</div>
            <div class="btn sec" style="margin-top:20px; background:#333; color:#fff" onclick="closeM('mc')">بستن</div>
        </div>
    </div>

    <script>
        // === GLOBAL TOGGLE LOGIC (ROOT CLASS) ===
        // We toggle class on HTML (root) element for maximum scope
        const root = document.documentElement;
        const tBtn = document.getElementById('themeBtn');

        function updateThemeUI(isLight) {
            if(isLight) {
                root.classList.add('light-mode');
                if(tBtn) tBtn.innerText = '☀️';
            } else {
                root.classList.remove('light-mode');
                if(tBtn) tBtn.innerText = '🌙';
            }
        }

        // 1. Init
        try {
            if(localStorage.getItem('theme') === 'light') updateThemeUI(true);
        } catch(e){}

        // 2. Click Handler
        if(tBtn) {
            tBtn.addEventListener('click', function(e) {
                e.preventDefault();
                const isLight = root.classList.contains('light-mode');
                if(isLight) {
                    updateThemeUI(false);
                    localStorage.setItem('theme', 'dark');
                } else {
                    updateThemeUI(true);
                    localStorage.setItem('theme', 'light');
                }
            });
        }

        // === DATA LOGIC ===
        let tot = 0, use = 0;
        try { tot = Number('{{ user.data_limit }}'); } catch(e){}
        try { use = Number('{{ user.used_traffic }}'); } catch(e){}

        // Progress
        let p = 0; if(tot>0) p = (use/tot)*100; if(p>100)p=100;
        const pB = document.getElementById('pB');
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

        // Actions
        function doCopy(t) {
            const a=document.createElement('textarea'); a.value=t; document.body.appendChild(a); a.select();
            try{document.execCommand('copy'); const o=document.getElementById('toast'); o.classList.add('vis'); setTimeout(()=>o.classList.remove('vis'),2000);}catch(e){}
            document.body.removeChild(a);
        }
        function openM(i){document.getElementById(i).style.display='flex';}
        function closeM(i){document.getElementById(i).style.display='none';}

        // Configs
        function shConf() {
            openM('mc'); const l=document.getElementById('clst'); l.innerHTML='...';
            fetch(window.location.pathname+'/links').then(r=>r.text()).then(t=>{
                if(t){
                    l.innerHTML='';
                    l.innerHTML+='<div class="btn pri" style="height:32px;font-size:12px;margin-bottom:10px" onclick="doCopy(\\''+t.replace(/\\n/g,'\\\\n')+'\\')">کپی همه کانفیگ‌ها</div>';
                    t.split('\\n').forEach(x=>{
                        const z=x.trim();
                        if(z && (z.startsWith('vmess')||z.startsWith('vless')||z.startsWith('trojan')||z.startsWith('ss'))){
                            let n='Config'; if(z.includes('#')) n=decodeURIComponent(z.split('#')[1]);
                            l.innerHTML+='<div style="background:rgba(255,255,255,0.1);padding:8px;border-radius:8px;margin-bottom:5px;display:flex;justify-content:space-between;align-items:center"><span>'+n+'</span><div class="btn sec" style="width:auto;height:24px;font-size:10px;padding:0 10px" onclick="doCopy(\\''+z+'\\')">کپی</div></div>';
                        }
                    });
                }
            }).catch(()=>l.innerHTML='خطا');
        }

        // OS
        const u=navigator.userAgent.toLowerCase();
        if(u.includes('android')) document.getElementById('da').classList.add('rec');
        else if(u.includes('iphone')||u.includes('ipad')) document.getElementById('di').classList.add('rec');
        else if(u.includes('win')) document.getElementById('dw').classList.add('rec');
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
echo -e "${GREEN}✔ Theme Installed (Root-Scope)!${NC}"