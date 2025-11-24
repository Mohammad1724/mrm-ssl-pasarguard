#!/bin/bash

# ==========================================
# Theme: FarsNetVIP Ultimate (Fixed Version)
# Fixes: Desktop Mode, Copy Bug, Connect Link, Support UI
# ==========================================

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration
ENV_FILE_PATH="/opt/pasarguard/.env"
TEMPLATE_DIR="/var/lib/pasarguard/templates/subscription"
TEMPLATE_FILE="/var/lib/pasarguard/templates/subscription/index.html"

# Clear Screen
clear
echo -e "${CYAN}=======================================${NC}"
echo -e "${YELLOW}   FarsNetVIP Pro Theme Installer    ${NC}"
echo -e "${CYAN}=======================================${NC}"

# --- INPUTS ---
echo -e "${BLUE}[1] Branding Info:${NC}"
read -p "Enter Brand Name (e.g. FarsNetVIP): " IN_BRAND
if [ -z "$IN_BRAND" ]; then IN_BRAND="FarsNetVIP"; fi

echo -e "\n${BLUE}[2] Telegram Info:${NC}"
read -p "Enter Bot Username (without @): " IN_BOT_USER
if [ -z "$IN_BOT_USER" ]; then IN_BOT_USER="YourBot"; fi

read -p "Enter Admin/Support ID (without @): " IN_ADMIN_ID
if [ -z "$IN_ADMIN_ID" ]; then IN_ADMIN_ID="Support"; fi

echo -e "\n${BLUE}[3] Tutorial Text:${NC}"
read -p "Step 1 (App): " TUT_1
if [ -z "$TUT_1" ]; then TUT_1="1. نرم‌افزار مورد نیاز را از پایین صفحه دانلود کنید."; fi
read -p "Step 2 (Copy): " TUT_2
if [ -z "$TUT_2" ]; then TUT_2="2. لینک اشتراک را کپی کنید."; fi
read -p "Step 3 (Connect): " TUT_3
if [ -z "$TUT_3" ]; then TUT_3="3. وارد برنامه شوید و دکمه اتصال را بزنید."; fi

# --- INSTALLATION ---
echo -e "\n${BLUE}Creating directories...${NC}"
mkdir -p "$TEMPLATE_DIR"

echo -e "${BLUE}Generating HTML template...${NC}"
cat << EOF > "$TEMPLATE_FILE"
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$IN_BRAND | {{ user.username }}</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@200;400;700;900&display=swap');

        :root {
            /* Night Mode Colors */
            --bg-grad-1: #0f0c29; --bg-grad-2: #302b63; --bg-grad-3: #24243e;
            --text-main: #ffffff; --text-sub: rgba(255, 255, 255, 0.7);
            --panel-bg: rgba(15, 15, 25, 0.65); 
            --panel-border: rgba(255, 255, 255, 0.15);
            --panel-shadow: 0 25px 60px rgba(0, 0, 0, 0.7);
            
            --btn-bg: rgba(255, 255, 255, 0.08); 
            --btn-border: rgba(255, 255, 255, 0.2);
            --btn-inner: inset 0 0 15px rgba(255,255,255,0.05);
            
            --brand-grad: linear-gradient(135deg, #ffffff 0%, #00C6FF 100%);
            --accent: #00C6FF;
        }

        [data-theme="light"] {
            /* Day Mode Colors */
            --bg-grad-1: #89f7fe; --bg-grad-2: #66a6ff; --bg-grad-3: #f0f2f5;
            --text-main: #1a1a1a; --text-sub: rgba(0, 0, 0, 0.7);
            --panel-bg: rgba(255, 255, 255, 0.6);
            --panel-border: rgba(255, 255, 255, 0.8);
            --panel-shadow: 0 25px 60px rgba(0, 100, 200, 0.3);
            
            --btn-bg: rgba(255, 255, 255, 0.5); 
            --btn-border: rgba(255, 255, 255, 0.9);
            --btn-inner: inset 0 0 20px rgba(255,255,255,0.8);
            
            --brand-grad: linear-gradient(135deg, #005bea 0%, #00c6fb 100%);
            --accent: #005bea;
        }

        * { box-sizing: border-box; outline: none; -webkit-tap-highlight-color: transparent; }
        
        body {
            margin: 0; padding: 20px; font-family: 'Vazirmatn', sans-serif;
            background: linear-gradient(45deg, var(--bg-grad-1), var(--bg-grad-2), var(--bg-grad-3));
            background-size: 400% 400%; animation: gradientBG 15s ease infinite;
            color: var(--text-main); min-height: 100vh;
            display: flex; justify-content: center; align-items: center;
            overflow-x: hidden; transition: 0.5s;
        }
        @keyframes gradientBG { 0% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } 100% { background-position: 0% 50%; } }

        /* Desktop & Mobile Layout Container */
        .dashboard-container {
            width: 100%;
            max-width: 450px; /* Default Mobile Width */
            transition: max-width 0.5s ease;
        }

        /* --- DESKTOP MODE STYLES --- */
        @media (min-width: 850px) {
            .dashboard-container {
                max-width: 950px; /* Wider for Desktop */
            }
            .glass-card-content {
                display: grid;
                grid-template-columns: 1fr 1.2fr; /* Two Columns */
                gap: 40px;
                align-items: start;
                text-align: right;
            }
            .desktop-left { order: 2; } /* Actions on right/left depending on RTL */
            .desktop-right { order: 1; border-left: 1px solid var(--panel-border); padding-left: 40px; }
            
            .brand-text { font-size: 40px !important; }
        }

        /* Header */
        .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px; padding: 0 10px; }
        .brand-text {
            font-size: 30px; font-weight: 900;
            background: var(--brand-grad); -webkit-background-clip: text; -webkit-text-fill-color: transparent;
            filter: drop-shadow(0 2px 10px rgba(0, 198, 255, 0.4));
        }
        .bot-badge {
            font-size: 12px; background: var(--btn-bg); padding: 5px 12px; border-radius: 20px;
            border: 1px solid var(--btn-border); color: var(--text-main); text-decoration: none;
            display: inline-block; margin-top: 5px;
        }

        .icon-btn {
            width: 40px; height: 40px; border-radius: 50%; background: var(--btn-bg); border: 1px solid var(--btn-border);
            display: flex; justify-content: center; align-items: center; cursor: pointer; font-size: 18px;
            box-shadow: var(--btn-inner); transition: 0.3s;
        }
        .icon-btn:hover { transform: scale(1.1); }

        /* Main Card */
        .glass-card {
            background: var(--panel-bg);
            backdrop-filter: blur(40px) saturate(180%); -webkit-backdrop-filter: blur(40px) saturate(180%);
            border: 1px solid var(--panel-border); border-radius: 40px; padding: 30px;
            box-shadow: var(--panel-shadow); position: relative; overflow: hidden;
        }

        /* User Info */
        .user-header { display: flex; align-items: center; gap: 15px; margin-bottom: 25px; }
        .avatar {
            width: 70px; height: 70px; background: linear-gradient(135deg, #00C6FF, #0072FF);
            border-radius: 20px; display: flex; align-items: center; justify-content: center; font-size: 32px;
            box-shadow: 0 10px 30px rgba(0, 114, 255, 0.4); border: 2px solid rgba(255,255,255,0.3);
        }
        .user-text h1 { margin: 0; font-size: 22px; font-weight: 800; }
        .status-badge {
            font-size: 11px; padding: 4px 12px; border-radius: 8px; background: rgba(0, 255, 136, 0.2); 
            color: #00ff88; border: 1px solid rgba(0, 255, 136, 0.3); font-weight: 700; margin-top: 5px; display: inline-block;
        }
        [data-theme="light"] .status-badge { color: #006e3b; background: rgba(0, 255, 136, 0.5); }
        .status-expired { background: rgba(255, 50, 50, 0.2) !important; color: #ff4444 !important; border-color: #ff4444 !important; }

        /* Data Grid */
        .info-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 20px; }
        .info-box {
            background: var(--btn-bg); border: 1px solid var(--btn-border); padding: 15px;
            border-radius: 18px; display: flex; flex-direction: column; box-shadow: var(--btn-inner);
        }
        .lbl { font-size: 11px; opacity: 0.7; margin-bottom: 3px; }
        .val { font-size: 16px; font-weight: 800; direction: ltr; text-align: right; }

        /* Progress Bar */
        .progress-wrapper { margin-bottom: 25px; }
        .progress-track { height: 14px; background: rgba(0,0,0,0.2); border-radius: 10px; overflow: hidden; border: 1px solid rgba(255,255,255,0.1); }
        .progress-fill { height: 100%; background: linear-gradient(90deg, #00C6FF, #0072FF); width: 0%; transition: width 1s; box-shadow: 0 0 15px #00C6FF; }
        .progress-text { display: flex; justify-content: space-between; font-size: 12px; margin-top: 5px; font-weight: bold; }

        /* Action Buttons */
        .actions-grid { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 10px; margin-bottom: 15px; }
        .action-btn {
            background: var(--btn-bg); border: 1px solid var(--btn-border); color: var(--text-main);
            padding: 15px 5px; border-radius: 20px; text-decoration: none; text-align: center;
            display: flex; flex-direction: column; align-items: center; gap: 8px; cursor: pointer;
            transition: 0.2s; box-shadow: var(--btn-inner);
        }
        .action-btn:active { transform: scale(0.95); }
        .action-btn i { font-size: 22px; font-style: normal; }
        .btn-title { font-size: 11px; font-weight: 700; }

        /* Support Button (Revised) */
        .support-btn {
            width: 100%; padding: 15px; margin-top: 10px;
            background: linear-gradient(90deg, rgba(0, 198, 255, 0.2), rgba(0, 114, 255, 0.2));
            border: 1px solid var(--btn-border); border-radius: 20px; color: var(--text-main);
            text-decoration: none; display: flex; justify-content: center; align-items: center; gap: 10px;
            font-weight: bold; font-size: 14px; transition: 0.3s; box-shadow: var(--btn-inner);
        }
        .support-btn:hover { background: linear-gradient(90deg, rgba(0, 198, 255, 0.4), rgba(0, 114, 255, 0.4)); }

        /* App Links */
        .apps-row {
            margin-top: 20px; background: var(--btn-bg); padding: 15px; border-radius: 25px;
            display: flex; justify-content: space-around; border: 1px solid var(--btn-border);
        }
        .app-link { text-decoration: none; color: var(--text-main); display: flex; flex-direction: column; align-items: center; font-size: 10px; gap: 5px; opacity: 0.8; transition: 0.3s; }
        .app-link:hover { opacity: 1; transform: translateY(-3px); }
        .app-icon { font-size: 22px; width: 40px; height: 40px; background: rgba(255,255,255,0.1); border-radius: 12px; display: flex; justify-content: center; align-items: center; border: 1px solid rgba(255,255,255,0.2); }

        /* Modals */
        .modal {
            position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.8);
            backdrop-filter: blur(10px); z-index: 1000; display: none; justify-content: center; align-items: center; opacity: 0; transition: 0.3s;
        }
        .modal.show { opacity: 1; display: flex; }
        .modal-box { background: var(--panel-bg); padding: 30px; border-radius: 30px; border: 1px solid var(--panel-border); text-align: center; width: 90%; max-width: 350px; }
        .close-modal { background: #ff4757; color: white; border: none; padding: 8px 25px; border-radius: 10px; margin-top: 15px; cursor: pointer; font-weight: bold;}
        .step-row { background: rgba(255,255,255,0.05); padding: 10px; margin: 5px 0; border-radius: 10px; text-align: right; font-size: 12px; }

        /* Hidden input for copy */
        #subLinkHolder { position: absolute; left: -9999px; }

    </style>
</head>
<body>

    <!-- Hidden Copy Target -->
    <input type="text" id="subLinkHolder" value="{{ subscription_url }}">

    <div class="dashboard-container">
        <div class="header">
            <div>
                <div class="brand-text">$IN_BRAND</div>
                <a href="https://t.me/$IN_BOT_USER" class="bot-badge">🤖 @$IN_BOT_USER</a>
            </div>
            <div style="display:flex; gap:10px">
                <div class="icon-btn" onclick="openModal('tutModal')">?</div>
                <div class="icon-btn" onclick="toggleTheme()">🌙</div>
            </div>
        </div>

        <div class="glass-card">
            <div class="glass-card-content">
                
                <!-- Left Column (Desktop) / Top (Mobile) -->
                <div class="desktop-left">
                    <div class="user-header">
                        <div class="avatar">👤</div>
                        <div class="user-text">
                            <h1>{{ user.username }}</h1>
                            {% if user.status == 'active' %}
                                <span class="status-badge">● سرویس فعال</span>
                            {% else %}
                                <span class="status-badge status-expired">● غیرفعال</span>
                            {% endif %}
                        </div>
                    </div>

                    <div class="progress-wrapper">
                        <div class="progress-track"><div class="progress-fill" id="trafficBar"></div></div>
                        <div class="progress-text">
                            <span>مصرف شده</span>
                            <span id="percentText">0%</span>
                        </div>
                    </div>

                    <div class="actions-grid">
                        <!-- Connect Button: Tries to open link, copies on click as fallback -->
                        <a href="{{ subscription_url }}" class="action-btn" onclick="copyLinkFallback()">
                            <i>🚀</i><span class="btn-title">اتصال</span>
                        </a>
                        <div class="action-btn" onclick="openModal('qrModal')">
                            <i>🔳</i><span class="btn-title">کیوآر</span>
                        </div>
                        <div class="action-btn" onclick="copyLinkFallback()">
                            <i>📋</i><span class="btn-title" id="copyBtnText">کپی</span>
                        </div>
                    </div>

                    <!-- Visible Support Button -->
                    <a href="https://t.me/$IN_ADMIN_ID" class="support-btn">
                        💬 پشتیبانی و تمدید سرویس
                    </a>
                </div>

                <!-- Right Column (Desktop) / Bottom (Mobile) -->
                <div class="desktop-right">
                    <div class="info-grid">
                        <div class="info-box">
                            <span class="lbl">تاریخ انقضا</span>
                            <span class="val">{{ user.expire_date }}</span>
                        </div>
                        <div class="info-box">
                            <span class="lbl">حجم کل</span>
                            <span class="val">{{ user.data_limit | filesizeformat }}</span>
                        </div>
                        <div class="info-box">
                            <span class="lbl">مصرف شده</span>
                            <span class="val">{{ user.used_traffic | filesizeformat }}</span>
                        </div>
                        <div class="info-box">
                            <span class="lbl">باقی‌مانده</span>
                            <span class="val" id="remData" style="color: var(--accent)">---</span>
                        </div>
                    </div>

                    <div class="apps-row">
                        <a href="https://play.google.com/store/apps/details?id=com.v2ray.ang" class="app-link"><div class="app-icon">🤖</div><span>Android</span></a>
                        <a href="https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690" class="app-link"><div class="app-icon">🍏</div><span>iOS</span></a>
                        <a href="https://github.com/2dust/v2rayN/releases" class="app-link"><div class="app-icon">💻</div><span>Windows</span></a>
                    </div>
                </div>

            </div>
        </div>
    </div>

    <!-- Modals -->
    <div id="qrModal" class="modal">
        <div class="modal-box">
            <h3>اسکن کد اتصال</h3>
            <div style="background:white; padding:10px; border-radius:20px; display:inline-block">
                <img src="https://api.qrserver.com/v1/create-qr-code/?size=180x180&data={{ subscription_url }}" width="180">
            </div>
            <br><button class="close-modal" onclick="closeModal('qrModal')">بستن</button>
        </div>
    </div>

    <div id="tutModal" class="modal">
        <div class="modal-box">
            <h3>راهنمای اتصال</h3>
            <div class="step-row">$TUT_1</div>
            <div class="step-row">$TUT_2</div>
            <div class="step-row">$TUT_3</div>
            <button class="close-modal" onclick="closeModal('tutModal')">متوجه شدم</button>
        </div>
    </div>

    <script>
        // --- Logic ---
        const total = {{ user.data_limit }};
        const used = {{ user.used_traffic }};
        const subLink = document.getElementById('subLinkHolder').value;

        // Calc Percent
        let p = 0;
        if(total > 0) p = (used / total) * 100;
        if(p>100) p=100;
        document.getElementById('trafficBar').style.width = p + '%';
        document.getElementById('percentText').innerText = Math.round(p) + '%';

        // Calc Remaining
        function fmt(b) {
            if(b<=0) return '0 MB';
            const s = ['B','KB','MB','GB','TB'];
            const i = Math.floor(Math.log(b)/Math.log(1024));
            return (b/Math.pow(1024,i)).toFixed(2)+' '+s[i];
        }
        document.getElementById('remData').innerText = fmt(total - used);

        // --- Robust Copy Function (Works on http) ---
        function copyLinkFallback() {
            const input = document.getElementById('subLinkHolder');
            input.style.display = 'block';
            input.select();
            try {
                document.execCommand('copy');
                showCopySuccess();
            } catch (err) {
                alert('لینک کپی نشد. لطفا دستی کپی کنید.');
            }
            input.style.display = 'none';
        }

        function showCopySuccess() {
            const btn = document.getElementById('copyBtnText');
            const old = btn.innerText;
            btn.innerText = 'کپی شد!';
            btn.style.color = '#00ff88';
            setTimeout(() => {
                btn.innerText = old;
                btn.style.color = 'inherit';
            }, 2000);
        }

        // --- UI Functions ---
        function toggleTheme() {
            const b = document.body;
            const icn = document.querySelector('.icon-btn:last-child');
            if(b.getAttribute('data-theme') === 'light') {
                b.removeAttribute('data-theme');
                localStorage.setItem('theme', 'dark');
                icn.innerText = '🌙';
            } else {
                b.setAttribute('data-theme', 'light');
                localStorage.setItem('theme', 'light');
                icn.innerText = '☀️';
            }
        }
        if(localStorage.getItem('theme') === 'light') {
            document.body.setAttribute('data-theme', 'light');
            document.querySelector('.icon-btn:last-child').innerText = '☀️';
        }

        function openModal(id) {
            document.getElementById(id).classList.add('show');
        }
        function closeModal(id) {
            document.getElementById(id).classList.remove('show');
        }
        
        // Close modal on outside click
        window.onclick = function(event) {
            if (event.target.classList.contains('modal')) {
                event.target.classList.remove('show');
            }
        }
    </script>
</body>
</html>
EOF

echo -e "${BLUE}Updating .env configuration...${NC}"
sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE_PATH"
sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE_PATH"
echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE_PATH"
echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE_PATH"

echo -e "${GREEN}✔ FarsNetVIP Theme Installed Successfully.${NC}"
echo -e "${YELLOW}Please wait while panel restarts...${NC}"

if command -v pasarguard &> /dev/null; then
    pasarguard restart
else
    systemctl restart pasarguard 2>/dev/null
fi

echo -e "${GREEN}Done! Check your subscription link now.${NC}"