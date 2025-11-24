#!/bin/bash

# ==========================================
# Theme Name: MRM FARSNETVIP (Apple Liquid Glass)
# Created for: Pasarguard Panel
# ==========================================

# Configuration
ENV_FILE_PATH="/opt/pasarguard/.env"
TEMPLATE_DIR="/var/lib/pasarguard/templates/subscription"
TEMPLATE_FILE="/var/lib/pasarguard/templates/subscription/index.html"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}--- Install FarsNetVIP Theme (Apple Liquid Style) ---${NC}"
echo -e "${YELLOW}This will replace the current subscription page with FarsNetVIP branding.${NC}"
read -p "Continue? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" ]]; then
    echo -e "${YELLOW}Cancelled.${NC}"
    exit 0
fi

echo -e "${BLUE}Creating directories...${NC}"
mkdir -p "$TEMPLATE_DIR"

echo -e "${BLUE}Writing HTML template...${NC}"
cat << 'EOF' > "$TEMPLATE_FILE"
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>اشتراک {{ user.username }}</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@200;500;800;900&display=swap');

        :root {
            /* --- NIGHT MODE (Default) --- */
            --bg-grad-1: #0f0c29;
            --bg-grad-2: #302b63;
            --bg-grad-3: #24243e;
            --text-main: #ffffff;
            --text-sub: rgba(255, 255, 255, 0.65);
            --panel-bg: rgba(15, 15, 25, 0.4);
            --panel-border: rgba(255, 255, 255, 0.12);
            --panel-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.6);
            --btn-bg: rgba(255, 255, 255, 0.06);
            --btn-border: rgba(255, 255, 255, 0.15);
            --btn-inner-glow: inset 0 0 15px rgba(255, 255, 255, 0.07), inset 0 0 3px rgba(255, 255, 255, 0.15);
            --btn-shadow: 0 10px 20px rgba(0,0,0,0.3);
            --brand-grad-start: #fff;
            --brand-grad-end: #00C6FF;
        }

        [data-theme="light"] {
            /* --- DAY MODE (Liquid Ice) --- */
            --bg-grad-1: #a1c4fd;
            --bg-grad-2: #c2e9fb;
            --bg-grad-3: #f0f2f5;
            --text-main: #1d1d1f;
            --text-sub: rgba(0, 0, 0, 0.65);
            --panel-bg: rgba(255, 255, 255, 0.35);
            --panel-border: rgba(255, 255, 255, 0.7);
            --panel-shadow: 0 25px 50px -12px rgba(50, 100, 150, 0.25);
            --btn-bg: rgba(255, 255, 255, 0.4);
            --btn-border: rgba(255, 255, 255, 0.9);
            --btn-inner-glow: inset 0 0 20px rgba(255, 255, 255, 0.7), inset 0 0 2px rgba(255, 255, 255, 1);
            --btn-shadow: 0 10px 25px rgba(161, 196, 253, 0.5);
            --brand-grad-start: #005bea;
            --brand-grad-end: #00c6fb;
        }

        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; outline: none; user-select: none; }
        
        body {
            margin: 0; padding: 20px;
            font-family: 'Vazirmatn', sans-serif;
            background: linear-gradient(45deg, var(--bg-grad-1), var(--bg-grad-2), var(--bg-grad-3));
            background-size: 400% 400%;
            animation: gradientBG 15s ease infinite;
            color: var(--text-main);
            display: flex; justify-content: center; align-items: center;
            min-height: 100vh; overflow: hidden;
            transition: all 0.5s ease;
        }

        @keyframes gradientBG {
            0% { background-position: 0% 50%; }
            50% { background-position: 100% 50%; }
            100% { background-position: 0% 50%; }
        }

        .orb { position: absolute; border-radius: 50%; filter: blur(70px); z-index: -1; animation: float 10s infinite alternate; }
        .orb-1 { width: 250px; height: 250px; background: #ff0055; top: -50px; left: -50px; opacity: 0.5; }
        .orb-2 { width: 280px; height: 280px; background: #00f2ff; bottom: -50px; right: -50px; opacity: 0.5; animation-delay: -5s; }
        @keyframes float { from { transform: translate(0,0); } to { transform: translate(30px, 30px); } }

        .dashboard { width: 100%; max-width: 400px; position: relative; z-index: 1; }

        .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 25px; padding: 0 10px; }
        
        .brand-box { display: flex; flex-direction: column; }
        .brand-text {
            font-size: 34px; 
            font-weight: 900;
            letter-spacing: 1px;
            background: linear-gradient(135deg, var(--brand-grad-start) 0%, var(--brand-grad-end) 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            filter: drop-shadow(0 2px 15px rgba(0, 198, 255, 0.5));
            line-height: 1.2;
        }
        .brand-sub { font-size: 10px; letter-spacing: 3px; opacity: 0.8; margin-top: -2px; font-weight: 500; }

        .theme-toggle {
            width: 48px; height: 48px;
            border-radius: 50%;
            background: var(--btn-bg);
            border: 1px solid var(--btn-border);
            box-shadow: var(--btn-inner-glow), var(--btn-shadow);
            backdrop-filter: blur(10px);
            display: flex; justify-content: center; align-items: center;
            cursor: pointer; font-size: 22px;
            transition: 0.4s;
        }
        .theme-toggle:active { transform: scale(0.9); }

        .glass-card {
            background: var(--panel-bg);
            backdrop-filter: blur(30px) saturate(160%);
            -webkit-backdrop-filter: blur(30px) saturate(160%);
            border: 1px solid var(--panel-border);
            border-radius: 40px;
            padding: 40px 25px;
            box-shadow: var(--panel-shadow);
            text-align: center;
            position: relative;
            overflow: hidden;
            transition: 0.5s;
        }
        
        .glass-card::before {
            content: ''; position: absolute; top: 0; left: 0; width: 100%; height: 60%;
            background: linear-gradient(180deg, rgba(255,255,255,0.1) 0%, rgba(255,255,255,0) 100%);
            pointer-events: none;
        }

        .avatar {
            width: 95px; height: 95px; margin: 0 auto 15px;
            background: linear-gradient(135deg, #00C6FF, #0072FF);
            border-radius: 50%;
            display: flex; align-items: center; justify-content: center;
            font-size: 42px; color: white;
            box-shadow: 0 10px 30px rgba(0, 114, 255, 0.45);
            border: 3px solid rgba(255,255,255,0.25);
            position: relative; z-index: 2;
        }

        h1 { margin: 5px 0; font-size: 26px; font-weight: 800; position: relative; z-index: 2; }
        
        .status-badge {
            font-size: 12px; padding: 6px 16px; border-radius: 20px;
            background: rgba(0, 255, 136, 0.15); color: #00ff88;
            border: 1px solid rgba(0, 255, 136, 0.25);
            box-shadow: 0 0 20px rgba(0, 255, 136, 0.15);
            display: inline-block; margin-bottom: 30px; margin-top: 5px;
            position: relative; z-index: 2;
        }
        .status-expired { color: #ff4444; background: rgba(255, 0, 0, 0.15); border-color: rgba(255, 0, 0, 0.25); box-shadow: none; }

        .info-row {
            display: flex; justify-content: space-between; align-items: center;
            background: var(--btn-bg);
            border: 1px solid var(--btn-border);
            box-shadow: var(--btn-inner-glow);
            padding: 16px 22px; border-radius: 24px; margin-bottom: 12px;
            position: relative; z-index: 2;
        }
        .label { font-size: 12px; color: var(--text-sub); font-weight: 500; }
        .value { font-size: 16px; font-weight: 700; font-family: monospace; letter-spacing: 0.5px; }

        .progress-container { margin: 30px 0; text-align: left; position: relative; z-index: 2; }
        .progress-track {
            height: 14px; background: rgba(0,0,0,0.15); border-radius: 20px;
            border: 1px solid rgba(255,255,255,0.1); overflow: hidden;
            box-shadow: inset 0 2px 5px rgba(0,0,0,0.2);
        }
        .progress-fill {
            height: 100%; width: 0%;
            background: linear-gradient(90deg, #00C6FF, #0072FF);
            border-radius: 20px;
            box-shadow: 0 0 20px rgba(0, 198, 255, 0.5);
            position: relative; transition: width 1s ease;
        }
        .progress-fill::after {
            content: ''; position: absolute; top: 0; left: 0; bottom: 0; right: 0;
            background: linear-gradient(90deg, transparent, rgba(255,255,255,0.6), transparent);
            transform: translateX(-100%); animation: shimmer 3s infinite;
        }
        @keyframes shimmer { 100% { transform: translateX(100%); } }
        
        .usage-text { display: flex; justify-content: space-between; font-size: 12px; margin-top: 10px; color: var(--text-sub); font-weight: 600;}

        .actions { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; margin-top: 15px; position: relative; z-index: 2; }
        
        .glass-btn {
            background: var(--btn-bg);
            border: 1px solid var(--btn-border);
            box-shadow: var(--btn-inner-glow), var(--btn-shadow);
            backdrop-filter: blur(10px);
            -webkit-backdrop-filter: blur(10px);
            border-radius: 26px;
            padding: 20px;
            color: var(--text-main);
            text-decoration: none;
            display: flex; flex-direction: column; align-items: center; gap: 10px;
            transition: all 0.3s cubic-bezier(0.34, 1.56, 0.64, 1);
            cursor: pointer;
        }

        .glass-btn:active { transform: scale(0.94); }
        @media(hover: hover) {
            .glass-btn:hover { transform: translateY(-5px); box-shadow: var(--btn-inner-glow), 0 15px 35px rgba(0,0,0,0.25); }
        }
        
        .icon-box { font-size: 26px; filter: drop-shadow(0 0 10px rgba(255,255,255,0.4)); }
        .btn-text { font-size: 13px; font-weight: 700; }
        .btn-primary .icon-box { color: #FFD700; }
        .btn-secondary .icon-box { color: #00F2FF; }

    </style>
</head>
<body>

    <div class="orb orb-1"></div>
    <div class="orb orb-2"></div>

    <div class="dashboard">
        <div class="header">
            <!-- HERE IS YOUR BRANDING -->
            <div class="brand-box">
                <span class="brand-text">FarsNetVIP</span>
                <span class="brand-sub">ULTIMATE CONNECTION</span>
            </div>
            <div class="theme-toggle" onclick="toggleTheme()">🌙</div>
        </div>

        <div class="glass-card">
            <div class="avatar">👤</div>
            <h1>{{ user.username }}</h1>
            {% if user.status == 'active' %} 
                <span class="status-badge">● سرویس فعال</span> 
            {% else %} 
                <span class="status-badge status-expired">● غیرفعال</span> 
            {% endif %}

            <div class="info-row">
                <span class="value">{{ user.expire_date }}</span>
                <span class="label">تاریخ انقضا</span>
            </div>
            <div class="info-row">
                <span class="value">{{ user.data_limit | filesizeformat }}</span>
                <span class="label">حجم کل</span>
            </div>

            <div class="progress-container">
                <div class="progress-track">
                    <div class="progress-fill" id="trafficBar"></div>
                </div>
                <div class="usage-text">
                    <span>مصرف: {{ user.used_traffic | filesizeformat }}</span>
                    <span id="percentText">0%</span>
                </div>
            </div>

            <div class="actions">
                <button class="glass-btn btn-primary" onclick="copyToClipboard()">
                    <span class="icon-box">⚡</span>
                    <span class="btn-text" id="copyText">کپی لینک</span>
                </button>
                <a href="{{ subscription_url }}" class="glass-btn btn-secondary">
                    <span class="icon-box">📲</span>
                    <span class="btn-text">اتصال سریع</span>
                </a>
            </div>
        </div>
    </div>

    <script>
        const used = {{ user.used_traffic }};
        const total = {{ user.data_limit }};
        let percent = 0;
        if (total > 0) { percent = (used / total) * 100; if (percent > 100) percent = 100; }
        document.getElementById('trafficBar').style.width = percent + '%';
        document.getElementById('percentText').innerText = Math.round(percent) + '%';

        function toggleTheme() {
            const body = document.body;
            const btn = document.querySelector('.theme-toggle');
            
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
            document.querySelector('.theme-toggle').innerText = '☀️';
        }

        function copyToClipboard() {
            const link = "{{ subscription_url }}";
            navigator.clipboard.writeText(link).then(() => {
                const t = document.getElementById('copyText');
                const original = t.innerText;
                t.innerText = "کپی شد!";
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