#!/bin/bash

# ==========================================
# Theme: FarsNetVIP MRM (Interactive)
# 
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
read -p "Enter Bot Username (without @, e.g. MyShopBot): " IN_BOT_USER
if [ -z "$IN_BOT_USER" ]; then IN_BOT_USER="YourBot"; fi

read -p "Enter Admin/Support ID (without @, e.g. Admin): " IN_ADMIN_ID
if [ -z "$IN_ADMIN_ID" ]; then IN_ADMIN_ID="Support"; fi

read -p "Enter Channel ID (optional, without @): " IN_CHANNEL_ID

echo -e "\n${BLUE}[3] Tutorial Text (Leave empty for default):${NC}"
read -p "Step 1 (Android/iOS App): " TUT_1
if [ -z "$TUT_1" ]; then TUT_1="1. نرم افزار v2rayNG (اندروید) یا V2Box (آیفون) را دانلود کنید."; fi

read -p "Step 2 (Copy Link): " TUT_2
if [ -z "$TUT_2" ]; then TUT_2="2. لینک اشتراک را کپی کنید."; fi

read -p "Step 3 (Connect): " TUT_3
if [ -z "$TUT_3" ]; then TUT_3="3. وارد برنامه شوید و دکمه اتصال را بزنید."; fi

# --- CONFIRMATION ---
echo -e "\n${YELLOW}Summary:${NC}"
echo "Brand: $IN_BRAND"
echo "Bot: @$IN_BOT_USER"
echo "Support: @$IN_ADMIN_ID"
echo ""
read -p "Press Enter to install..."

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
        @import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@200;500;700;900&display=swap');

        :root {
            /* --- NIGHT MODE --- */
            --bg-grad-1: #0f0c29; --bg-grad-2: #302b63; --bg-grad-3: #24243e;
            --text-main: #ffffff; --text-sub: rgba(255, 255, 255, 0.65);
            --panel-bg: rgba(15, 15, 25, 0.55); --panel-border: rgba(255, 255, 255, 0.12);
            --panel-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.6);
            --btn-bg: rgba(255, 255, 255, 0.06); --btn-border: rgba(255, 255, 255, 0.15);
            --btn-inner-glow: inset 0 0 15px rgba(255, 255, 255, 0.07), inset 0 0 3px rgba(255, 255, 255, 0.15);
            --brand-grad: linear-gradient(135deg, #ffffff 0%, #00C6FF 100%);
            --badge-bg: rgba(0, 255, 136, 0.15); --badge-text: #00ff88;
        }

        [data-theme="light"] {
            /* --- DAY MODE --- */
            --bg-grad-1: #a1c4fd; --bg-grad-2: #c2e9fb; --bg-grad-3: #f0f2f5;
            --text-main: #1d1d1f; --text-sub: rgba(0, 0, 0, 0.65);
            --panel-bg: rgba(255, 255, 255, 0.45); --panel-border: rgba(255, 255, 255, 0.7);
            --panel-shadow: 0 25px 50px -12px rgba(50, 100, 150, 0.25);
            --btn-bg: rgba(255, 255, 255, 0.5); --btn-border: rgba(255, 255, 255, 0.9);
            --btn-inner-glow: inset 0 0 20px rgba(255, 255, 255, 0.7), inset 0 0 2px rgba(255, 255, 255, 1);
            --brand-grad: linear-gradient(135deg, #005bea 0%, #00c6fb 100%);
            --badge-bg: rgba(0, 255, 136, 0.5); --badge-text: #004d26;
        }

        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; outline: none; user-select: none; }
        body {
            margin: 0; padding: 20px; font-family: 'Vazirmatn', sans-serif;
            background: linear-gradient(45deg, var(--bg-grad-1), var(--bg-grad-2), var(--bg-grad-3));
            background-size: 400% 400%; animation: gradientBG 15s ease infinite;
            color: var(--text-main); display: flex; justify-content: center; align-items: center;
            min-height: 100vh; overflow: hidden; transition: all 0.5s ease;
        }
        @keyframes gradientBG { 0% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } 100% { background-position: 0% 50%; } }
        
        .orb { position: absolute; border-radius: 50%; filter: blur(80px); z-index: -1; animation: float 10s infinite alternate; }
        .orb-1 { width: 300px; height: 300px; background: #ff0055; top: -50px; left: -50px; opacity: 0.5; }
        .orb-2 { width: 300px; height: 300px; background: #00f2ff; bottom: -50px; right: -50px; opacity: 0.5; animation-delay: -5s; }

        .dashboard { width: 100%; max-width: 420px; position: relative; z-index: 1; display: flex; flex-direction: column; gap: 15px; height: 95vh; justify-content: center; }

        .header { display: flex; justify-content: space-between; align-items: center; padding: 0 5px; margin-bottom: 10px;}
        .brand-text {
            font-size: 32px; font-weight: 900; letter-spacing: 0.5px;
            background: var(--brand-grad); -webkit-background-clip: text; -webkit-text-fill-color: transparent;
            filter: drop-shadow(0 2px 10px rgba(0, 198, 255, 0.4)); line-height: 1.1;
        }
        
        /* Bot Badge */
        .bot-badge {
            font-size: 12px; display: flex; align-items: center; gap: 5px; text-decoration: none;
            background: var(--btn-bg); padding: 6px 12px; border-radius: 15px; 
            border: 1px solid var(--btn-border); color: var(--text-main); font-weight: bold;
            transition: 0.3s; box-shadow: var(--btn-inner-glow);
        }
        .bot-badge:hover { transform: scale(1.05); background: rgba(255,255,255,0.1); }

        .header-actions { display: flex; gap: 10px; }
        .icon-btn {
            width: 42px; height: 42px; border-radius: 50%; background: var(--btn-bg); border: 1px solid var(--btn-border);
            box-shadow: var(--btn-inner-glow); backdrop-filter: blur(10px);
            display: flex; justify-content: center; align-items: center; cursor: pointer; font-size: 18px; transition: 0.3s; color: var(--text-main);
        }
        .icon-btn:active { transform: scale(0.9); }

        /* Main Card */
        .glass-card {
            background: var(--panel-bg); backdrop-filter: blur(30px) saturate(160%); -webkit-backdrop-filter: blur(30px) saturate(160%);
            border: 1px solid var(--panel-border); border-radius: 40px; padding: 25px;
            box-shadow: var(--panel-shadow); text-align: center; position: relative; overflow: hidden;
        }
        .glass-card::before { content: ''; position: absolute; top: 0; left: 0; width: 100%; height: 50%; background: linear-gradient(180deg, rgba(255,255,255,0.1) 0%, rgba(255,255,255,0) 100%); pointer-events: none; }

        .user-info { display: flex; align-items: center; gap: 15px; margin-bottom: 20px; position: relative; z-index: 2; text-align: right; }
        .avatar {
            width: 65px; height: 65px; background: linear-gradient(135deg, #00C6FF, #0072FF); border-radius: 22px;
            display: flex; align-items: center; justify-content: center; font-size: 30px; color: white;
            box-shadow: 0 10px 25px rgba(0, 114, 255, 0.4); border: 2px solid rgba(255,255,255,0.3);
        }
        .user-details h1 { margin: 0; font-size: 20px; font-weight: 800; }
        .status-badge {
            font-size: 10px; padding: 4px 10px; border-radius: 10px; margin-top: 4px;
            background: var(--badge-bg); color: var(--badge-text); border: 1px solid rgba(0,255,136,0.3);
            font-weight: 700; display: inline-block;
        }
        .status-expired { background: rgba(255,0,0,0.15); color: #ff4444; border-color: rgba(255,0,0,0.3); }
        [data-theme="light"] .status-expired { background: rgba(255,0,0,0.25); color: #8a0000; }

        .info-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-bottom: 15px; position: relative; z-index: 2; }
        .info-box {
            background: var(--btn-bg); border: 1px solid var(--btn-border); box-shadow: var(--btn-inner-glow);
            padding: 12px; border-radius: 18px; display: flex; flex-direction: column; gap: 4px;
        }
        .lbl { font-size: 10px; opacity: 0.7; }
        .val { font-size: 14px; font-weight: 800; direction: ltr; }

        .progress-con { margin: 15px 0; position: relative; z-index: 2; text-align: left;}
        .track { height: 12px; background: rgba(0,0,0,0.15); border-radius: 10px; border: 1px solid rgba(255,255,255,0.1); overflow: hidden; }
        .fill { height: 100%; width: 0%; background: linear-gradient(90deg, #00C6FF, #0072FF); border-radius: 10px; position: relative; box-shadow: 0 0 15px rgba(0, 198, 255, 0.5); }
        .prog-txt { display: flex; justify-content: space-between; font-size: 11px; margin-top: 6px; font-weight: 600; opacity: 0.9;}

        .actions { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 10px; position: relative; z-index: 2; }
        .glass-btn {
            background: var(--btn-bg); border: 1px solid var(--btn-border); box-shadow: var(--btn-inner-glow);
            backdrop-filter: blur(5px); border-radius: 18px; padding: 12px 5px; color: var(--text-main);
            text-decoration: none; display: flex; flex-direction: column; align-items: center; gap: 6px;
            transition: 0.2s; cursor: pointer;
        }
        .glass-btn:active { transform: scale(0.95); }
        .glass-btn i { font-size: 20px; font-style: normal; }
        .btn-txt { font-size: 10px; font-weight: 700; }
        .btn-renew i { color: #ff4757; }

        /* Apps Section */
        .apps-section {
            background: var(--btn-bg); border: 1px solid var(--btn-border); border-radius: 25px; padding: 12px;
            box-shadow: var(--btn-inner-glow); backdrop-filter: blur(20px); display: flex; justify-content: space-around; align-items: center;
        }
        .app-item { text-decoration: none; color: var(--text-main); display: flex; flex-direction: column; align-items: center; gap: 5px; font-size: 9px; opacity: 0.8; transition: 0.3s; }
        .app-item:hover { opacity: 1; transform: translateY(-3px); }
        .app-icon { font-size: 20px; background: rgba(255,255,255,0.1); width: 40px; height: 40px; border-radius: 12px; display: flex; align-items: center; justify-content: center; border: 1px solid rgba(255,255,255,0.2); }

        /* Floating Support Button */
        .support-fab {
            position: fixed; bottom: 25px; right: 25px; width: 55px; height: 55px;
            background: linear-gradient(135deg, #00C6FF, #0072FF); border-radius: 50%;
            display: flex; justify-content: center; align-items: center; font-size: 28px; color: white;
            box-shadow: 0 10px 30px rgba(0, 114, 255, 0.5); border: 2px solid rgba(255,255,255,0.3);
            cursor: pointer; z-index: 100; transition: 0.3s; text-decoration: none;
        }
        .support-fab:hover { transform: scale(1.1) rotate(10deg); }

        /* Modals */
        .modal-overlay {
            position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.7); backdrop-filter: blur(15px);
            z-index: 200; display: none; justify-content: center; align-items: center; opacity: 0; transition: opacity 0.3s;
        }
        .modal-overlay.active { display: flex; opacity: 1; }
        .modal-card {
            background: var(--panel-bg); border: 1px solid var(--panel-border); padding: 25px; border-radius: 30px;
            text-align: center; width: 90%; max-width: 350px; box-shadow: 0 20px 60px rgba(0,0,0,0.5);
        }
        .modal-title { margin-top: 0; font-weight: 800; }
        .tutorial-step { text-align: right; font-size: 12px; margin-bottom: 10px; background: rgba(255,255,255,0.05); padding: 10px; border-radius: 15px; }
        .close-btn {
            background: #ff4444; color: white; border: none; padding: 10px 30px; border-radius: 15px; font-weight: bold; cursor: pointer; margin-top: 10px;
        }

    </style>
</head>
<body>

    <div class="orb orb-1"></div><div class="orb orb-2"></div>

    <div class="dashboard">
        <div class="header">
            <div>
                <div class="brand-text">$IN_BRAND</div>
                <div style="margin-top: 5px;">
                    <a href="https://t.me/$IN_BOT_USER" class="bot-badge">🤖 @$IN_BOT_USER</a>
                </div>
            </div>
            
            <div class="header-actions">
                <div class="icon-btn" onclick="showTutorial()">?</div>
                <div class="icon-btn" onclick="toggleTheme()">🌙</div>
            </div>
        </div>

        <!-- Main Card -->
        <div class="glass-card">
            <div class="user-info">
                <div class="avatar">👤</div>
                <div class="user-details">
                    <h1>{{ user.username }}</h1>
                    {% if user.status == 'active' %}
                        <span class="status-badge">● سرویس فعال</span>
                    {% else %}
                        <span class="status-badge status-expired">● غیرفعال</span>
                    {% endif %}
                </div>
            </div>

            <div class="info-grid">
                <div class="info-box">
                    <span class="lbl">انقضا</span>
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
                    <!-- JS Calculated -->
                    <span class="val" id="remData" style="color: #00ff88">---</span>
                </div>
            </div>

            <div class="progress-con">
                <div class="track"><div class="fill" id="trafficBar"></div></div>
                <div class="prog-txt"><span>مصرف</span><span id="percentText">0%</span></div>
            </div>

            <div class="actions">
                <a href="{{ subscription_url }}" class="glass-btn"><i>🚀</i><span class="btn-txt">اتصال</span></a>
                <a href="https://t.me/$IN_BOT_USER" class="glass-btn btn-renew"><i>🔄</i><span class="btn-txt">تمدید</span></a>
                <div class="glass-btn" onclick="showQR()"><i>🔳</i><span class="btn-txt">کیو‌آر</span></div>
                <div class="glass-btn" onclick="copyToClipboard()"><i>📋</i><span class="btn-txt" id="copyBtnTxt">کپی</span></div>
            </div>
        </div>

        <div class="apps-section">
            <a href="https://play.google.com/store/apps/details?id=com.v2ray.ang" class="app-item"><div class="app-icon">🤖</div><span>And</span></a>
            <a href="https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690" class="app-item"><div class="app-icon">🍏</div><span>iOS</span></a>
            <a href="https://github.com/2dust/v2rayN/releases" class="app-item"><div class="app-icon">💻</div><span>Win</span></a>
        </div>
    </div>

    <!-- Floating Support -->
    <a href="https://t.me/$IN_ADMIN_ID" target="_blank" class="support-fab">💬</a>

    <!-- QR Modal -->
    <div class="modal-overlay" id="qrModal">
        <div class="modal-card">
            <h3 class="modal-title">اسکن کد اتصال</h3>
            <div style="background: white; padding: 10px; border-radius: 20px; display: inline-block;">
                 <img src="https://api.qrserver.com/v1/create-qr-code/?size=150x150&data={{ subscription_url }}" width="150">
            </div>
            <br><button class="close-btn" onclick="closeModals()">بستن</button>
        </div>
    </div>

    <!-- Tutorial Modal -->
    <div class="modal-overlay" id="tutorialModal">
        <div class="modal-card">
            <h3 class="modal-title">راهنمای اتصال</h3>
            <div class="tutorial-step">$TUT_1</div>
            <div class="tutorial-step">$TUT_2</div>
            <div class="tutorial-step">$TUT_3</div>
            <button class="close-btn" onclick="closeModals()">متوجه شدم</button>
        </div>
    </div>

    <script>
        const totalBytes = {{ user.data_limit }};
        const usedBytes = {{ user.used_traffic }};
        
        let percent = 0;
        if (totalBytes > 0) { percent = (usedBytes / totalBytes) * 100; if (percent > 100) percent = 100; }
        document.getElementById('trafficBar').style.width = percent + '%';
        document.getElementById('percentText').innerText = Math.round(percent) + '%';

        const remainingBytes = totalBytes - usedBytes;
        function formatBytes(bytes, decimals = 2) {
            if (bytes <= 0) return '0 B';
            const k = 1024;
            const dm = decimals < 0 ? 0 : decimals;
            const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(dm)) + ' ' + sizes[i];
        }
        document.getElementById('remData').innerText = formatBytes(remainingBytes);

        function toggleTheme() {
            const body = document.body;
            const btn = document.querySelector('.icon-btn:last-child');
            if (body.getAttribute('data-theme') === 'light') {
                body.removeAttribute('data-theme');
                localStorage.setItem('theme', 'dark');
                btn.innerText = '🌙';
            } else {
                body.setAttribute('data-theme', 'light');
                localStorage.setItem('theme', 'light');
                btn.innerText = '☀️';
            }
        }
        if(localStorage.getItem('theme') === 'light') {
            document.body.setAttribute('data-theme', 'light');
            document.querySelector('.icon-btn:last-child').innerText = '☀️';
        }

        function showQR() { document.getElementById('qrModal').classList.add('active'); }
        function showTutorial() { document.getElementById('tutorialModal').classList.add('active'); }
        function closeModals() { document.querySelectorAll('.modal-overlay').forEach(el => el.classList.remove('active')); }

        function copyToClipboard() {
            const link = "{{ subscription_url }}";
            navigator.clipboard.writeText(link).then(() => {
                const t = document.getElementById('copyBtnTxt');
                const original = t.innerText;
                t.innerText = "OK!";
                t.style.color = "#00ff88";
                setTimeout(() => { t.innerText = original; t.style.color = "inherit"; }, 2000);
            });
        }
    </script>
</body>
</html>
EOF

echo -e "${BLUE}Updating panel configuration (.env)...${NC}"
# Clean up old configs if any
sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE_PATH"
sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE_PATH"

# Add new config
echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE_PATH"
echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE_PATH"

echo -e "${GREEN}✔ Theme Installed Successfully.${NC}"
echo -e "Restarting Panel..."
if command -v pasarguard &> /dev/null; then
    pasarguard restart
else
    systemctl restart pasarguard 2>/dev/null
fi
echo -e "${GREEN}Done!${NC}"