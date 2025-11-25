#!/bin/bash

# ==========================================
# Theme: FarsNetVIP Ultimate (Shadcn UI + Logic Fixes)
# Status: FINAL STABLE VERSION
# ==========================================

# Colors
CYAN='\033[0;36m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'

# Paths
TEMPLATE_DIR="/var/lib/pasarguard/templates/subscription"
TEMPLATE_FILE="$TEMPLATE_DIR/index.html"
ENV_FILE="/opt/pasarguard/.env"

# Helper: Extract previous value for "Smart Default"
get_prev() { 
    if [ -f "$TEMPLATE_FILE" ]; then 
        grep "$1" "$TEMPLATE_FILE" | head -n1 | sed -E "s/.*$1[^A-Za-z0-9_@]*([A-Za-z0-9_@. \-]+).*/\1/"
    fi 
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

# Links (Fixed)
LNK_AND="https://play.google.com/store/apps/details?id=com.v2ray.ang"
LNK_IOS="https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690"
LNK_WIN="https://github.com/2dust/v2rayN/releases"

echo -e "\n${BLUE}Installing Theme...${NC}"
mkdir -p "$TEMPLATE_DIR"

# 2. Generate HTML (Single File, No Dependencies)
cat << 'EOF' > "$TEMPLATE_FILE"
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>__BRAND__ | {{ user.username }}</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;500;600;700&display=swap');
        
        :root {
            /* Shadcn Dark Theme Colors */
            --background: #09090b;
            --foreground: #fafafa;
            --card: #18181b;
            --card-foreground: #fafafa;
            --primary: #7c3aed; /* Violet */
            --primary-fg: #fafafa;
            --secondary: #27272a;
            --secondary-fg: #fafafa;
            --muted: #27272a;
            --muted-fg: #a1a1aa;
            --border: #27272a;
            --input: #27272a;
            --ring: #7c3aed;
            --radius: 0.75rem;
            --success: #10b981;
            --warning: #f59e0b;
            --destructive: #ef4444;
        }

        [data-theme="light"] {
            --background: #ffffff;
            --foreground: #09090b;
            --card: #ffffff;
            --card-foreground: #09090b;
            --primary: #7c3aed;
            --primary-fg: #fafafa;
            --secondary: #f4f4f5;
            --secondary-fg: #18181b;
            --muted: #f4f4f5;
            --muted-fg: #71717a;
            --border: #e4e4e7;
            --input: #e4e4e7;
        }

        * { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
        
        body {
            font-family: 'Vazirmatn', sans-serif;
            background-color: var(--background);
            color: var(--foreground);
            min-height: 100vh;
            display: flex; flex-direction: column; align-items: center;
            padding: 20px; padding-top: 60px;
            transition: all 0.3s;
        }

        /* Ticker */
        .ticker-wrap {
            position: fixed; top: 0; left: 0; width: 100%; height: 40px;
            background: var(--card); border-bottom: 1px solid var(--border);
            z-index: 50; overflow: hidden; display: flex; align-items: center;
        }
        .ticker {
            white-space: nowrap; animation: ticker 30s linear infinite;
            font-size: 13px; font-weight: 500; color: var(--primary);
        }
        @keyframes ticker { 0% { transform: translateX(-100%); } 100% { transform: translateX(100%); } }

        .container { width: 100%; max-width: 800px; }

        /* Header */
        .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; }
        .brand { font-size: 24px; font-weight: 700; }
        .bot-badge { 
            font-size: 12px; background: var(--secondary); color: var(--secondary-fg);
            padding: 4px 12px; border-radius: 20px; text-decoration: none; display: inline-block; margin-top: 4px;
        }
        .theme-btn {
            width: 40px; height: 40px; border-radius: 10px; background: var(--secondary);
            border: 1px solid var(--border); display: flex; justify-content: center; align-items: center;
            cursor: pointer; font-size: 18px; transition: 0.2s;
        }

        /* Card */
        .card {
            background: var(--card); border: 1px solid var(--border);
            border-radius: var(--radius); padding: 24px;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
        }

        .grid-layout { display: grid; grid-template-columns: 1fr; gap: 24px; }
        @media (min-width: 768px) { .grid-layout { grid-template-columns: 1fr 1.2fr; } .col-info { order: 1; } .col-actions { order: 2; } }

        /* Profile */
        .profile { display: flex; align-items: center; gap: 16px; margin-bottom: 24px; }
        .avatar {
            width: 64px; height: 64px; background: var(--primary); color: var(--primary-fg);
            border-radius: 50%; display: flex; justify-content: center; align-items: center;
            font-size: 28px; position: relative;
        }
        .online-dot {
            position: absolute; bottom: 2px; right: 2px; width: 14px; height: 14px;
            background: var(--success); border: 2px solid var(--card); border-radius: 50%;
            box-shadow: 0 0 0 2px var(--background);
        }
        .user-name { font-size: 20px; font-weight: 700; }
        .status-badge {
            display: inline-flex; align-items: center; padding: 2px 10px;
            border-radius: 99px; font-size: 12px; font-weight: 600; margin-top: 4px;
        }
        .st-active { background: rgba(16, 185, 129, 0.15); color: var(--success); border: 1px solid rgba(16, 185, 129, 0.2); }
        .st-inactive { background: rgba(239, 68, 68, 0.15); color: var(--destructive); border: 1px solid rgba(239, 68, 68, 0.2); }

        /* Progress */
        .prog-con { margin-bottom: 24px; }
        .prog-bar { height: 8px; background: var(--secondary); border-radius: 99px; overflow: hidden; }
        .prog-fill { height: 100%; background: var(--primary); width: 0%; transition: width 1s ease; }
        .prog-txt { display: flex; justify-content: space-between; font-size: 12px; margin-top: 6px; color: var(--muted-fg); font-weight: 500; }

        /* Stats Grid */
        .stats-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 24px; }
        .stat-item {
            background: var(--secondary); padding: 12px; border-radius: calc(var(--radius) - 4px);
            display: flex; flex-direction: column; border: 1px solid var(--border);
        }
        .stat-lbl { font-size: 11px; color: var(--muted-fg); }
        .stat-val { font-size: 14px; font-weight: 700; direction: ltr; text-align: right; }

        /* Buttons */
        .btn {
            display: inline-flex; align-items: center; justify-content: center;
            border-radius: calc(var(--radius) - 4px); font-size: 14px; font-weight: 500;
            height: 40px; width: 100%; cursor: pointer; transition: 0.2s; text-decoration: none;
            border: 1px solid transparent;
        }
        .btn-pri { background: var(--primary); color: var(--primary-fg); }
        .btn-pri:hover { opacity: 0.9; }
        .btn-sec { background: transparent; border-color: var(--border); color: var(--foreground); }
        .btn-sec:hover { background: var(--secondary); }
        
        .act-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 16px; }
        
        /* Downloads */
        .dl-sec { margin-top: 24px; border-top: 1px solid var(--border); pt: 16px; }
        .dl-title { font-size: 13px; font-weight: 600; margin-bottom: 12px; color: var(--muted-fg); }
        .dl-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; }
        .dl-item {
            display: flex; flex-direction: column; align-items: center; gap: 8px;
            padding: 12px; border-radius: 8px; border: 1px solid var(--border);
            text-decoration: none; color: var(--foreground); transition: 0.2s;
        }
        .dl-item:hover { border-color: var(--primary); background: var(--secondary); }
        .dl-item.recom { border: 1px solid var(--primary); background: rgba(124, 58, 237, 0.1); }
        .dl-icon { font-size: 20px; }
        .dl-name { font-size: 11px; font-weight: 500; }

        /* Toast */
        .toast {
            position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%);
            background: var(--foreground); color: var(--background);
            padding: 10px 20px; border-radius: 99px; font-size: 14px; font-weight: 600;
            opacity: 0; pointer-events: none; transition: 0.3s; z-index: 100;
        }
        .toast.show { opacity: 1; bottom: 32px; }

        /* Modals */
        .modal-overlay {
            position: fixed; inset: 0; background: rgba(0,0,0,0.8); backdrop-filter: blur(4px);
            z-index: 50; display: none; align-items: center; justify-content: center;
        }
        .modal-box {
            background: var(--background); border: 1px solid var(--border);
            padding: 24px; border-radius: var(--radius); width: 90%; max-width: 400px;
            max-height: 80vh; overflow-y: auto; text-align: center;
        }
        .conf-row {
            display: flex; justify-content: space-between; align-items: center;
            padding: 10px; border: 1px solid var(--border); border-radius: 8px; margin-bottom: 8px;
            text-align: left;
        }
        .conf-name { font-size: 12px; font-family: monospace; direction: ltr; max-width: 70%; overflow: hidden; text-overflow: ellipsis; }
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
            <div class="theme-btn" onclick="toggleTheme()">
                <span id="themeIcon">🌙</span>
            </div>
        </div>

        <div class="card">
            <div class="grid-layout">
                
                <!-- Column 1: Actions -->
                <div class="col-actions">
                    <div class="profile">
                        <div class="avatar">
                            👤
                            {% if user.online_at %}
                                <div class="online-dot"></div>
                            {% endif %}
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
                        <div class="progress-text">
                            <span>مصرف شده</span>
                            <span id="pText">0%</span>
                        </div>
                    </div>

                    <div class="act-grid">
                        <button class="btn btn-pri" onclick="forceCopy('{{ subscription_url }}')">کپی لینک</button>
                        <button class="btn btn-sec" onclick="openModal('qrModal')">QR Code</button>
                    </div>
                    
                    <a href="{{ subscription_url }}" class="btn btn-sec" style="width:100%; margin-bottom:10px">🚀 اتصال مستقیم (Add)</a>
                    <button class="btn btn-sec" style="width:100%" onclick="showConfigs()">📂 نمایش کانفیگ‌ها</button>
                    
                    <a href="https://t.me/__SUP__" class="btn" style="width:100%; margin-top:16px; color:var(--muted-fg)">
                        💬 ارتباط با پشتیبانی
                    </a>
                </div>

                <!-- Column 2: Info -->
                <div class="col-info">
                    <div class="stats-grid">
                        <div class="stat-item">
                            <span class="stat-lbl">تاریخ انقضا</span>
                            <span class="stat-val" id="expDate">
                                {% if user.expire %}
                                    {{ user.expire }}
                                {% else %}
                                    نامحدود
                                {% endif %}
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
                            <span class="stat-val" id="remText" style="color: var(--primary)">...</span>
                        </div>
                    </div>

                    <div class="dl-sec">
                        <div class="dl-title">دانلود اپلیکیشن</div>
                        <div class="dl-grid">
                            <a href="__ANDROID__" class="dl-item" id="dlAnd">
                                <span class="dl-icon">🤖</span><span class="dl-name">اندروید</span>
                            </a>
                            <a href="__IOS__" class="dl-item" id="dlIos">
                                <span class="dl-icon">🍏</span><span class="dl-name">آیفون</span>
                            </a>
                            <a href="__WIN__" class="dl-item" id="dlWin">
                                <span class="dl-icon">💻</span><span class="dl-name">ویندوز</span>
                            </a>
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
            <div style="background:white; padding:15px; border-radius:12px; display:inline-block">
                <img src="https://api.qrserver.com/v1/create-qr-code/?size=200x200&data={{ subscription_url }}" width="200">
            </div>
            <button class="btn btn-sec" style="margin-top:20px" onclick="closeModal('qrModal')">بستن</button>
        </div>
    </div>

    <div id="confModal" class="modal-overlay" onclick="if(event.target===this)closeModal('confModal')">
        <div class="modal-box">
            <h3>لیست کانفیگ‌ها</h3><br>
            <div id="confList" style="text-align:left">درحال دریافت...</div>
            <button class="btn btn-sec" style="margin-top:20px" onclick="closeModal('confModal')">بستن</button>
        </div>
    </div>

    <script>
        // --- DATA ---
        const total = {{ user.data_limit }};
        const used = {{ user.used_traffic }};
        
        // 1. Progress
        let p = 0; if(total > 0) p = (used/total)*100; if(p>100)p=100;
        document.getElementById('pBar').style.width = p + '%';
        document.getElementById('pText').innerText = Math.round(p) + '%';
        if(p > 85) document.getElementById('pBar').style.background = 'var(--destructive)';

        // 2. Remaining
        const rem = total - used;
        function fmt(b) { 
            if(total===0) return 'نامحدود'; if(b<=0) return '0 MB'; 
            const u=['B','KB','MB','GB','TB']; const i=Math.floor(Math.log(b)/Math.log(1024)); 
            return (b/Math.pow(1024,i)).toFixed(2)+' '+u[i]; 
        }
        document.getElementById('remText').innerText = fmt(rem);

        // 3. Date Fix
        const expEl = document.getElementById('expDate');
        const raw = expEl.innerText.trim();
        if(!raw || raw === 'None' || raw === 'null') {
            expEl.innerText = 'نامحدود';
        } else {
            try {
                const d = new Date(raw);
                if(!isNaN(d.getTime())) expEl.innerText = d.toLocaleDateString('fa-IR');
            } catch(e){}
        }

        // 4. Copy
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

        // 5. Config List
        function showConfigs() {
            openModal('confModal');
            const list = document.getElementById('confList');
            list.innerHTML = '...';
            
            fetch(window.location.pathname + '/links')
                .then(r => r.text())
                .then(text => {
                    if(text) {
                        list.innerHTML = '';
                        // Button to Copy All
                        list.innerHTML += '<div style="margin-bottom:10px"><button class="btn btn-pri" style="height:30px; font-size:12px" onclick="forceCopy(\\''+text.replace(/\\n/g, '\\\\n')+'\\')">کپی همه کانفیگ‌ها</button></div>';
                        
                        const lines = text.split('\\n');
                        lines.forEach(line => {
                            const l = line.trim();
                            if(l && (l.startsWith('vless') || l.startsWith('vmess') || l.startsWith('trojan') || l.startsWith('ss'))) {
                                let name = 'Config';
                                let proto = l.split('://')[0].toUpperCase();
                                if(l.includes('#')) name = decodeURIComponent(l.split('#')[1]);
                                
                                list.innerHTML += \`
                                    <div class="conf-row">
                                        <div>
                                            <span class="status-badge st-active" style="font-size:10px">\${proto}</span>
                                            <span class="conf-name">\${name}</span>
                                        </div>
                                        <button class="btn btn-sec" style="width:auto; height:28px; padding:0 10px; font-size:11px" onclick="forceCopy('\${l}')">کپی</button>
                                    </div>
                                \`;
                            }
                        });
                    }
                }).catch(() => list.innerHTML = 'خطا');
        }

        // 6. Smart OS
        const ua = navigator.userAgent.toLowerCase();
        if(ua.includes('android')) document.getElementById('dlAnd').classList.add('recom');
        else if(ua.includes('iphone') || ua.includes('ipad')) document.getElementById('dlIos').classList.add('recom');
        else if(ua.includes('win')) document.getElementById('dlWin').classList.add('recom');

        // 7. Theme
        function toggleTheme() {
            const b = document.body;
            if(b.getAttribute('data-theme')==='light') {
                b.removeAttribute('data-theme'); localStorage.setItem('theme','dark');
                document.getElementById('themeIcon').innerText = '🌙';
            } else {
                b.setAttribute('data-theme','light'); localStorage.setItem('theme','light');
                document.getElementById('themeIcon').innerText = '☀️';
            }
        }
        if(localStorage.getItem('theme')==='light') {
            document.body.setAttribute('data-theme','light');
            document.getElementById('themeIcon').innerText = '☀️';
        }

        function openModal(id){document.getElementById(id).style.display='flex';}
        function closeModal(id){document.getElementById(id).style.display='none';}
    </script>
</body>
</html>
EOF

# 3. Replace Placeholders
sed -i "s|__BRAND__|$IN_BRAND|g" "$TEMPLATE_FILE"
sed -i "s|__BOT__|$IN_BOT|g" "$TEMPLATE_FILE"
sed -i "s|__SUP__|$IN_SUP|g" "$TEMPLATE_FILE"
sed -i "s|__NEWS__|$IN_NEWS|g" "$TEMPLATE_FILE"
sed -i "s|__ANDROID__|$LNK_AND|g" "$TEMPLATE_FILE"
sed -i "s|__IOS__|$LNK_IOS|g" "$TEMPLATE_FILE"
sed -i "s|__WIN__|$LNK_WIN|g" "$TEMPLATE_FILE"

# Update Panel Config
sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"
echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE"
echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE"

# Restart
if command -v pasarguard &> /dev/null; then pasarguard restart; else systemctl restart pasarguard 2>/dev/null; fi
echo -e "${GREEN}✔ Theme Installed!${NC}"