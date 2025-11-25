#!/bin/bash

# ==========================================
# Theme: FarsNetVIP Ultimate (High-End Glass/Jelly UI)
# Status: FINAL FIXED (Buttons Remastered)
# ==========================================

# Colors
CYAN='\033[0;36m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'

# Paths
TEMPLATE_DIR="/var/lib/pasarguard/templates/subscription"
TEMPLATE_FILE="$TEMPLATE_DIR/index.html"
ENV_FILE="/opt/pasarguard/.env"

# ---- Safety: Must be run as root ----
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

# Helper: Extract previous Brand value
get_prev() {
    if [ -f "$TEMPLATE_FILE" ]; then
        grep 'id="brandTxt"' "$TEMPLATE_FILE" | head -n1 | sed -E 's/.*id="brandTxt">([^<]+)<.*/\1/'
    fi
}

# Helper: escape string
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'
}

clear
echo -e "${CYAN}=== FarsNetVIP Ultimate Installer ===${NC}"

# 1. Get Inputs
PREV_BRAND=$(get_prev "brandTxt")
[ -z "$PREV_BRAND" ] && PREV_BRAND="FarsNetVIP"
PREV_BOT="MyBot"
PREV_SUP="Support"
DEF_NEWS="🔥 به جمع کاربران ویژه خوش آمدید!"

echo -e "${GREEN}Tip: Enter to keep current value.${NC}\n"
read -p "Brand Name [$PREV_BRAND]: " IN_BRAND
read -p "Bot Username (no @) [$PREV_BOT]: " IN_BOT
read -p "Support ID (no @) [$PREV_SUP]: " IN_SUP
read -p "News Text [$DEF_NEWS]: " IN_NEWS

[ -z "$IN_BRAND" ] && IN_BRAND="$PREV_BRAND"
[ -z "$IN_BOT" ] && IN_BOT="$PREV_BOT"
[ -z "$IN_SUP" ] && IN_SUP="$PREV_SUP"
[ -z "$IN_NEWS" ] && IN_NEWS="$DEF_NEWS"

# Links
LNK_AND="https://play.google.com/store/apps/details?id=com.v2ray.ang"
LNK_IOS="https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690"
LNK_WIN="https://github.com/2dust/v2rayN/releases"

echo -e "\n${BLUE}Installing Theme...${NC}"
mkdir -p "$TEMPLATE_DIR"

# 2. Generate HTML
cat << 'EOF' > "$TEMPLATE_FILE"
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>__BRAND__ | {{ user.username }}</title>
    <style>
@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;500;600;700&display=swap');

/* پایه رنگ‌ها (Dark Mode Default) */
:root {
    --background: #0a0a0a;
    --foreground: #f0f0f0;
    --card: rgba(30, 30, 35, 0.6);
    --primary-grad: linear-gradient(135deg, #8b5cf6, #6d28d9);
    --secondary-bg: rgba(255, 255, 255, 0.05);
    --radius: 16px;
    --glow-orange: rgba(249, 115, 22, 0.5);
    --glow-blue: rgba(59, 130, 246, 0.4);
    
    /* Button Colors */
    --btn-pri-bg: rgba(124, 58, 237, 0.65);
    --btn-sec-bg: rgba(255, 255, 255, 0.08);
    --border-light: rgba(255, 255, 255, 0.15);
}

/* Light Mode */
html[data-theme="light"] {
    --background: #eef2f6;
    --foreground: #1e293b;
    --card: rgba(255, 255, 255, 0.75);
    --primary-grad: linear-gradient(135deg, #7c3aed, #6d28d9);
    --secondary-bg: rgba(0, 0, 0, 0.05);
    --glow-orange: rgba(249, 115, 22, 0.25);
    --glow-blue: rgba(59, 130, 246, 0.2);
    
    --btn-pri-bg: rgba(124, 58, 237, 0.8);
    --btn-sec-bg: rgba(255, 255, 255, 0.6);
    --border-light: rgba(255, 255, 255, 0.8);
}

* { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }

body {
    font-family: 'Vazirmatn', sans-serif;
    background-color: var(--background);
    color: var(--foreground);
    min-height: 100vh;
    display: flex; flex-direction: column; align-items: center;
    padding: 20px; padding-top: 60px;
    position: relative; overflow-x: hidden;
    transition: background 0.3s;
}

/* Background Ambient Lights (Lamps) */
body::before {
    content: ""; position: fixed; top: -150px; right: -50px; width: 400px; height: 400px;
    background: radial-gradient(circle, var(--glow-orange), transparent 70%);
    filter: blur(60px); opacity: 0.8; z-index: -1;
}
body::after {
    content: ""; position: fixed; bottom: -100px; left: -100px; width: 400px; height: 400px;
    background: radial-gradient(circle, var(--glow-blue), transparent 70%);
    filter: blur(60px); opacity: 0.8; z-index: -1;
}

/* Ticker */
.ticker-container {
    position: fixed; top: 0; left: 0; width: 100%; height: 40px;
    background: rgba(0,0,0,0.3); backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px);
    border-bottom: 1px solid rgba(255,255,255,0.1); z-index: 50;
    display: flex; align-items: center; overflow: hidden;
}
.ticker-text {
    white-space: nowrap; animation: ticker 25s linear infinite;
    font-size: 13px; color: #fbbf24; padding: 0 20px;
}
@keyframes ticker { 0% { transform: translateX(100%); } 100% { transform: translateX(-100%); } }

.container { width: 100%; max-width: 800px; }

/* Header */
.header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; }
.brand { font-size: 26px; font-weight: 800; letter-spacing: -1px; text-shadow: 0 2px 10px rgba(0,0,0,0.3); }
.bot-badge {
    font-size: 12px; background: var(--secondary-bg); color: var(--foreground);
    padding: 4px 12px; border-radius: 20px; text-decoration: none;
    display: inline-flex; align-items: center; margin-top: 4px; border: 1px solid var(--border-light);
}
.theme-btn {
    width: 42px; height: 42px; border-radius: 14px;
    background: var(--secondary-bg); border: 1px solid var(--border-light);
    display: flex; justify-content: center; align-items: center; font-size: 20px;
    cursor: pointer; backdrop-filter: blur(5px); box-shadow: 0 4px 10px rgba(0,0,0,0.1);
}

/* Card */
.card {
    background: var(--card);
    border: 1px solid var(--border-light);
    border-radius: var(--radius); padding: 24px;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.2);
    backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
}

.grid-layout { display: grid; grid-template-columns: 1fr; gap: 24px; }
@media (min-width: 768px) { .grid-layout { grid-template-columns: 1fr 1.2fr; } .col-info { order: 1; } .col-actions { order: 2; } }

/* Profile */
.profile { display: flex; align-items: center; gap: 16px; margin-bottom: 24px; }
.avatar {
    width: 68px; height: 68px; border-radius: 50%;
    background: var(--primary-grad); color: white;
    display: flex; justify-content: center; align-items: center; font-size: 30px;
    box-shadow: 0 4px 15px rgba(124, 58, 237, 0.5); position: relative;
}
.online-dot {
    position: absolute; bottom: 2px; right: 2px; width: 14px; height: 14px;
    background: #10b981; border: 2px solid rgba(30,30,30,1); border-radius: 50%;
}
.user-name { font-size: 20px; font-weight: 700; }
.status-badge { font-size: 12px; padding: 3px 10px; border-radius: 10px; margin-top: 5px; display: inline-block; font-weight: 600; }
.st-active { background: rgba(16, 185, 129, 0.2); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.3); }
.st-inactive { background: rgba(239, 68, 68, 0.2); color: #f87171; border: 1px solid rgba(239, 68, 68, 0.3); }

/* Progress */
.prog-con { margin-bottom: 24px; }
.progress-bar {
    height: 10px; background: rgba(0,0,0,0.3); border-radius: 20px;
    overflow: hidden; border: 1px solid rgba(255,255,255,0.1);
}
.progress-fill {
    height: 100%; width: 0%; background: linear-gradient(90deg, #10b981, #f59e0b);
    box-shadow: 0 0 15px rgba(16, 185, 129, 0.6); transition: width 1s;
}
.progress-text { display: flex; justify-content: space-between; font-size: 12px; margin-top: 8px; color: #9ca3af; }

/* --- GLASS / JELLY BUTTONS (REMASTERED) --- */
.btn {
    position: relative;
    display: inline-flex; align-items: center; justify-content: center;
    width: 100%; height: 46px;
    font-size: 14px; font-weight: 600; color: #ffffff;
    text-decoration: none; cursor: pointer;
    border-radius: 16px; /* Rounded Jelly Look */
    
    /* Glass Base */
    backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px);
    border: 1px solid rgba(255, 255, 255, 0.15);
    border-top: 1px solid rgba(255, 255, 255, 0.4); /* Top Highlight */
    border-bottom: 1px solid rgba(0, 0, 0, 0.1);
    
    /* Shadows for Volume (Jelly Effect) */
    box-shadow: 
        0 4px 12px rgba(0, 0, 0, 0.2),
        inset 0 1px 0 rgba(255, 255, 255, 0.3),
        inset 0 -2px 4px rgba(0, 0, 0, 0.1);
        
    transition: all 0.2s cubic-bezier(0.25, 0.8, 0.25, 1);
    overflow: hidden;
}

/* Inner Glow (Lamp Effect) */
.btn::after {
    content: ""; position: absolute; top: 0; left: 0; width: 100%; height: 50%;
    background: linear-gradient(to bottom, rgba(255,255,255,0.15), transparent);
    pointer-events: none;
}

/* Primary Button (Purple Jelly) */
.btn-pri {
    background: var(--btn-pri-bg);
    box-shadow: 
        0 8px 20px rgba(124, 58, 237, 0.3),
        inset 0 1px 0 rgba(255, 255, 255, 0.4);
}

/* Secondary Button (Glass Jelly) */
.btn-sec {
    background: var(--btn-sec-bg);
    color: var(--foreground);
}

/* Hover State (Lift & Glow) */
.btn:active { transform: scale(0.98); }
.btn:hover {
    transform: translateY(-2px);
    box-shadow: 
        0 12px 24px rgba(0, 0, 0, 0.3),
        inset 0 1px 0 rgba(255, 255, 255, 0.5);
}
.btn-pri:hover {
    box-shadow: 
        0 12px 28px rgba(124, 58, 237, 0.5),
        inset 0 1px 0 rgba(255, 255, 255, 0.5);
}
/* ----------------------------------------- */

.act-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 16px; }

/* Stats */
.stats-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 24px; }
.stat-item {
    background: var(--secondary-bg); padding: 12px; border-radius: 12px;
    border: 1px solid var(--border-light); display: flex; flex-direction: column;
}
.stat-lbl { font-size: 11px; color: #9ca3af; margin-bottom: 4px; }
.stat-val { font-size: 15px; font-weight: 700; text-align: right; direction: ltr; }

/* Downloads */
.dl-sec { margin-top: 24px; border-top: 1px solid var(--border-light); padding-top: 20px; }
.dl-title { font-size: 13px; margin-bottom: 12px; opacity: 0.7; }
.dl-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
.dl-item {
    display: flex; flex-direction: column; align-items: center; gap: 6px;
    padding: 12px; border-radius: 12px; text-decoration: none; color: var(--foreground);
    background: var(--secondary-bg); border: 1px solid var(--border-light);
    transition: 0.2s; backdrop-filter: blur(5px);
}
.dl-item:hover { background: rgba(255,255,255,0.1); transform: translateY(-2px); border-color: #f59e0b; }
.dl-item.recom { border: 1px solid #f59e0b; background: rgba(245, 158, 11, 0.1); box-shadow: 0 0 15px rgba(245, 158, 11, 0.2); }

/* Toast */
.toast {
    position: fixed; bottom: 30px; left: 50%; transform: translateX(-50%) translateY(20px);
    background: #ffffff; color: #000; padding: 12px 24px; border-radius: 30px;
    font-weight: 700; opacity: 0; transition: 0.3s; z-index: 999; pointer-events: none;
    box-shadow: 0 10px 30px rgba(0,0,0,0.3);
}
.toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }

/* Modal */
.modal-overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.85); backdrop-filter: blur(8px);
    z-index: 100; display: none; align-items: center; justify-content: center;
}
.modal-box {
    background: #1a1a1a; border: 1px solid #333; width: 90%; max-width: 380px;
    padding: 24px; border-radius: 20px; text-align: center; color: #fff;
    box-shadow: 0 20px 50px rgba(0,0,0,0.5);
}
.conf-row {
    display: flex; justify-content: space-between; align-items: center;
    background: rgba(255,255,255,0.05); padding: 10px; border-radius: 10px; margin-bottom: 8px;
}
    </style>
</head>
<body>
    <div class="ticker-container">
        <div class="ticker-text" id="newsTxt">__NEWS__</div>
    </div>
    <div class="toast" id="toast">کپی شد!</div>

    <div class="container">
        <div class="header">
            <div>
                <div class="brand" id="brandTxt">__BRAND__</div>
                <a href="https://t.me/__BOT__" class="bot-badge">🤖 @__BOT__</a>
            </div>
            <div class="theme-btn" id="themeToggle">
                <span id="themeIcon">🌙</span>
            </div>
        </div>

        <div class="card">
            <div class="grid-layout">
                
                <!-- Actions -->
                <div class="col-actions">
                    <div class="profile">
                        <div class="avatar">
                            👤
                            {% if user.online_at %} <div class="online-dot"></div> {% endif %}
                        </div>
                        <div>
                            <div class="user-name">{{ user.username }}</div>
                            {% if user.status.name == 'active' %}
                                <span class="status-badge st-active">فعال</span>
                            {% else %}
                                <span class="status-badge st-inactive">غیرفعال</span>
                            {% endif %}
                        </div>
                    </div>

                    <div class="prog-con">
                        <div class="progress-bar"><div class="progress-fill" id="pBar"></div></div>
                        <div class="progress-text"><span>مصرف شده</span><span id="pText">0%</span></div>
                    </div>

                    <div class="act-grid">
                        <button class="btn btn-pri" onclick="forceCopy('{{ subscription_url }}')">کپی لینک</button>
                        <button class="btn btn-sec" onclick="openModal('qrModal')">QR Code</button>
                    </div>
                    
                    <a href="{{ subscription_url }}" class="btn btn-sec" style="width:100%; margin-bottom:10px">🚀 اتصال مستقیم (Add)</a>
                    <button class="btn btn-sec" style="width:100%" onclick="showConfigs()">📂 نمایش کانفیگ‌ها</button>
                    
                    <a href="https://t.me/__SUP__" class="btn" style="width:100%; margin-top:16px; background:transparent; border:none; box-shadow:none; color:var(--muted-fg); font-size:12px">
                        💬 ارتباط با پشتیبانی
                    </a>
                </div>

                <!-- Info -->
                <div class="col-info">
                    <div class="stats-grid">
                        <div class="stat-item">
                            <span class="stat-lbl">تاریخ انقضا</span>
                            <span class="stat-val" id="expDate">
                                {% if user.expire %}{{ user.expire }}{% else %}نامحدود{% endif %}
                            </span>
                        </div>
                        <div class="stat-item">
                            <span class="stat-lbl">حجم کل</span>
                            <span class="stat-val">{{ user.data_limit | filesizeformat }}</span>
                        </div>
                        <div class="stat-item">
                            <span class="stat-lbl">مصرف شده</span>
                            <span class="stat-val">{{ user.used_traffic | filesizeformat }}</span>
                        </div>
                        <div class="stat-item">
                            <span class="stat-lbl">باقی‌مانده</span>
                            <span class="stat-val" id="remText" style="color: #3b82f6">...</span>
                        </div>
                    </div>

                    <div class="dl-sec">
                        <div class="dl-title">دانلود اپلیکیشن</div>
                        <div class="dl-grid">
                            <a href="__ANDROID__" class="dl-item" id="dlAnd"><span class="dl-icon">🤖</span><span class="dl-name">اندروید</span></a>
                            <a href="__IOS__" class="dl-item" id="dlIos"><span class="dl-icon">🍏</span><span class="dl-name">آیفون</span></a>
                            <a href="__WIN__" class="dl-item" id="dlWin"><span class="dl-icon">💻</span><span class="dl-name">ویندوز</span></a>
                        </div>
                    </div>
                </div>

            </div>
        </div>
    </div>

    <!-- Modals -->
    <div id="qrModal" class="modal-overlay" onclick="if(event.target===this)closeModal('qrModal')">
        <div class="modal-box">
            <h3>اسکن کد</h3><br>
            <div style="background:white; padding:10px; border-radius:10px; display:inline-block">
                <img src="https://api.qrserver.com/v1/create-qr-code/?size=200x200&data={{ subscription_url }}" width="180">
            </div>
            <button class="btn btn-sec" style="margin-top:20px" onclick="closeModal('qrModal')">بستن</button>
        </div>
    </div>

    <div id="confModal" class="modal-overlay" onclick="if(event.target===this)closeModal('confModal')">
        <div class="modal-box">
            <h3>لیست کانفیگ‌ها</h3><br>
            <div id="confList" style="text-align:left; max-height:300px; overflow-y:auto">درحال دریافت...</div>
            <button class="btn btn-sec" style="margin-top:20px" onclick="closeModal('confModal')">بستن</button>
        </div>
    </div>

    <script>
        // DATA
        const total = {{ user.data_limit }};
        const used = {{ user.used_traffic }};
        
        // Progress
        let p = 0; if(total>0) p = (used/total)*100; if(p>100)p=100;
        document.getElementById('pBar').style.width = p + '%';
        document.getElementById('pText').innerText = Math.round(p) + '%';
        if(p > 85) document.getElementById('pBar').style.background = '#ef4444';

        // Remaining
        const rem = total - used;
        function fmt(b) { 
            if(total===0) return 'نامحدود'; if(b<=0) return '0 MB'; 
            const u=['B','KB','MB','GB','TB']; const i=Math.floor(Math.log(b)/Math.log(1024)); 
            return (b/Math.pow(1024,i)).toFixed(2)+' '+u[i]; 
        }
        document.getElementById('remText').innerText = fmt(rem);

        // Date
        const expEl = document.getElementById('expDate');
        const raw = expEl.innerText.trim();
        if(!raw || raw === 'None' || raw === 'null') expEl.innerText = 'نامحدود';
        else { try { const d = new Date(raw); if(!isNaN(d.getTime())) expEl.innerText = d.toLocaleDateString('fa-IR'); } catch(e){} }

        // Copy
        function forceCopy(text) {
            const ta = document.createElement("textarea");
            ta.value = text; ta.style.position = "fixed"; ta.style.left = "-9999px";
            document.body.appendChild(ta); ta.focus(); ta.select();
            try { document.execCommand('copy'); showToast(); } catch(e){}
            document.body.removeChild(ta);
        }
        function showToast() {
            const t = document.getElementById('toast');
            t.classList.add('show'); setTimeout(()=>t.classList.remove('show'), 2000);
        }

        // Configs
        function showConfigs() {
            openModal('confModal');
            const list = document.getElementById('confList');
            list.innerHTML = '...';
            fetch(window.location.pathname + '/links').then(r=>r.text()).then(text => {
                if(text) {
                    list.innerHTML = '';
                    list.innerHTML += '<div style="margin-bottom:10px"><button class="btn btn-pri" style="height:34px; font-size:12px" onclick="forceCopy(\\''+text.replace(/\\n/g, '\\\\n')+'\\')">کپی همه</button></div>';
                    const lines = text.split('\\n');
                    lines.forEach(line => {
                        const l = line.trim();
                        if(l && (l.startsWith('vless')||l.startsWith('vmess')||l.startsWith('trojan')||l.startsWith('ss'))) {
                            let name = 'Config';
                            let proto = l.split('://')[0].toUpperCase();
                            if(l.includes('#')) name = decodeURIComponent(l.split('#')[1]);
                            list.innerHTML += \`<div class="conf-row"><div><span class="status-badge st-active" style="font-size:10px">\${proto}</span> <span style="font-size:12px">\${name}</span></div><button class="btn btn-sec" style="width:auto; height:28px; padding:0 12px; font-size:11px" onclick="forceCopy('\${l}')">کپی</button></div>\`;
                        }
                    });
                }
            }).catch(() => list.innerHTML = 'خطا');
        }

        // Smart OS
        const ua = navigator.userAgent.toLowerCase();
        if(ua.includes('android')) document.getElementById('dlAnd').classList.add('recom');
        else if(ua.includes('iphone')||ua.includes('ipad')) document.getElementById('dlIos').classList.add('recom');
        else if(ua.includes('win')) document.getElementById('dlWin').classList.add('recom');

        // Theme Logic
        function toggleTheme() {
            const root = document.documentElement;
            const icon = document.getElementById('themeIcon');
            if (root.getAttribute('data-theme') === 'light') {
                root.removeAttribute('data-theme'); localStorage.setItem('theme', 'dark');
                if (icon) icon.innerText = '🌙';
            } else {
                root.setAttribute('data-theme', 'light'); localStorage.setItem('theme', 'light');
                if (icon) icon.innerText = '☀️';
            }
        }
        (function initTheme() {
            const saved = localStorage.getItem('theme');
            const root = document.documentElement;
            const icon = document.getElementById('themeIcon');
            if (saved === 'light') {
                root.setAttribute('data-theme', 'light');
                if (icon) icon.innerText = '☀️';
            } else {
                root.removeAttribute('data-theme');
                if (icon) icon.innerText = '🌙';
            }
        })();

        // Bind Toggle
        (function bindBtn(){
            var b = document.getElementById('themeToggle');
            if(b) b.addEventListener('click', function(e){ e.preventDefault(); toggleTheme(); });
        })();

        function openModal(id){document.getElementById(id).style.display='flex';}
        function closeModal(id){document.getElementById(id).style.display='none';}
    </script>
</body>
</html>
EOF

# 3. Replacements
BRAND_ESC=$(sed_escape "$IN_BRAND")
BOT_ESC=$(sed_escape "$IN_BOT")
SUP_ESC=$(sed_escape "$IN_SUP")
NEWS_ESC=$(sed_escape "$IN_NEWS")

sed -i "s|__BRAND__|$BRAND_ESC|g" "$TEMPLATE_FILE"
sed -i "s|__BOT__|$BOT_ESC|g" "$TEMPLATE_FILE"
sed -i "s|__SUP__|$SUP_ESC|g" "$TEMPLATE_FILE"
sed -i "s|__NEWS__|$NEWS_ESC|g" "$TEMPLATE_FILE"
sed -i "s|__ANDROID__|$LNK_AND|g" "$TEMPLATE_FILE"
sed -i "s|__IOS__|$LNK_IOS|g" "$TEMPLATE_FILE"
sed -i "s|__WIN__|$LNK_WIN|g" "$TEMPLATE_FILE"

# Config Update
if [ ! -f "$ENV_FILE" ]; then touch "$ENV_FILE"; fi
sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"
echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE"
echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE"

# Restart
if command -v pasarguard &> /dev/null; then pasarguard restart; else systemctl restart pasarguard 2>/dev/null; fi
echo -e "${GREEN}✔ Theme Installed!${NC}"