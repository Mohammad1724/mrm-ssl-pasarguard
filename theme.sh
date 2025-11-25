#!/bin/bash

# ==========================================
# Theme: FarsNetVIP (Fix: Expire Date)
# ==========================================

# Colors & Paths
CYAN='\033[0;36m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
TEMPLATE_DIR="/var/lib/pasarguard/templates/subscription"
TEMPLATE_FILE="$TEMPLATE_DIR/index.html"
ENV_FILE="/opt/pasarguard/.env"

# Helper
get_val() { if [ -f "$TEMPLATE_FILE" ]; then grep "$1:" "$TEMPLATE_FILE" | sed -n 's/.*: "\(.*\)",/\1/p'; fi; }

clear
echo -e "${CYAN}=== FarsNetVIP Installer (Date Fix) ===${NC}"

# Load Previous Settings
DEF_BRAND=${1:-$(get_val "brandName")}; DEF_BRAND=${DEF_BRAND:-"FarsNetVIP"}
DEF_NEWS=${2:-$(get_val "newsText")}; DEF_NEWS=${DEF_NEWS:-"🔥 به جمع کاربران ویژه خوش آمدید!"}
DEF_BOT=${3:-$(get_val "botUsername")}; DEF_BOT=${DEF_BOT:-"MyBot"}
DEF_SUPPORT=${4:-$(get_val "supportID")}; DEF_SUPPORT=${DEF_SUPPORT:-"Admin"}

echo -e "${GREEN}Tip: Press Enter to keep current settings.${NC}\n"
read -p "Brand Name [$DEF_BRAND]: " IN_BRAND; IN_BRAND=${IN_BRAND:-$DEF_BRAND}
read -p "News Text [$DEF_NEWS]: " IN_NEWS; IN_NEWS=${IN_NEWS:-$DEF_NEWS}
read -p "Bot Username (no @) [$DEF_BOT]: " IN_BOT; IN_BOT=${IN_BOT:-$DEF_BOT}
read -p "Support ID (no @) [$DEF_SUPPORT]: " IN_SUP; IN_SUP=${IN_SUP:-$DEF_SUPPORT}

echo -e "\n${BLUE}Installing...${NC}"
mkdir -p "$TEMPLATE_DIR"

# Generate HTML with Date Logic Fix
cat << 'EOF' > "$TEMPLATE_FILE"
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>User Panel</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;500;700;900&display=swap');
        :root {
            --bg-body: linear-gradient(135deg, #0f0c29 0%, #302b63 50%, #24243e 100%);
            --card-bg: rgba(20, 20, 30, 0.75); --card-border: rgba(255, 255, 255, 0.1);
            --text-main: #ffffff; --text-sub: rgba(255, 255, 255, 0.6);
            --btn-bg: rgba(255, 255, 255, 0.08); --btn-border: rgba(255, 255, 255, 0.15);
            --accent: #00C6FF; --brand-grad: linear-gradient(90deg, #fff, #00C6FF);
            --shadow: 0 20px 40px rgba(0,0,0,0.5);
            --alert-bg: rgba(255, 71, 87, 0.2); --alert-txt: #ff4757;
        }
        [data-theme="light"] {
            --bg-body: linear-gradient(135deg, #89f7fe 0%, #66a6ff 100%);
            --card-bg: rgba(255, 255, 255, 0.75); --card-border: rgba(255, 255, 255, 0.8);
            --text-main: #333; --text-sub: rgba(0, 0, 0, 0.6);
            --btn-bg: rgba(255, 255, 255, 0.5); --btn-border: rgba(255, 255, 255, 0.9);
            --accent: #005bea; --brand-grad: linear-gradient(90deg, #005bea, #00c6fb);
            --shadow: 0 20px 40px rgba(0,0,0,0.15);
        }
        * { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
        body { font-family: 'Vazirmatn', sans-serif; background: var(--bg-body); background-attachment: fixed; color: var(--text-main); min-height: 100vh; display: flex; flex-direction: column; align-items: center; padding: 15px; padding-top: 60px; padding-bottom: 40px; }
        
        /* CSS Classes */
        .ticker-wrap { position: fixed; top: 0; left: 0; width: 100%; background: rgba(0,0,0,0.4); backdrop-filter: blur(8px); height: 40px; overflow: hidden; z-index: 100; border-bottom: 1px solid rgba(255,255,255,0.1); }
        .ticker { display: inline-block; white-space: nowrap; padding-right: 100%; animation: ticker 25s linear infinite; line-height: 40px; font-size: 12px; color: #fff; font-weight: 500; }
        @keyframes ticker { 0% { transform: translate3d(0, 0, 0); } 100% { transform: translate3d(100%, 0, 0); } }
        .container { width: 100%; max-width: 900px; margin-top: 15px; }
        .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; padding: 0 5px; }
        .brand { font-size: 28px; font-weight: 900; background: var(--brand-grad); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
        .bot-link { font-size: 12px; background: var(--btn-bg); padding: 4px 12px; border-radius: 15px; text-decoration: none; color: var(--text-main); border: 1px solid var(--btn-border); display: inline-block; margin-top: 5px; font-weight: bold; }
        .header-btns { display: flex; gap: 10px; }
        .circle-btn { width: 42px; height: 42px; border-radius: 50%; background: var(--btn-bg); border: 1px solid var(--btn-border); display: flex; justify-content: center; align-items: center; cursor: pointer; font-size: 18px; backdrop-filter: blur(5px); transition: 0.2s; }
        .circle-btn:active { transform: scale(0.9); }
        .alert-box { display: none; background: var(--alert-bg); border: 1px solid var(--alert-txt); color: var(--alert-txt); padding: 10px; border-radius: 15px; text-align: center; font-weight: bold; font-size: 12px; margin-bottom: 15px; animation: pulse 2s infinite; }
        @keyframes pulse { 0% { opacity: 1; } 50% { opacity: 0.7; } 100% { opacity: 1; } }
        .main-card { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 35px; padding: 30px; backdrop-filter: blur(30px); -webkit-backdrop-filter: blur(30px); box-shadow: var(--shadow); }
        .layout-row { display: flex; flex-direction: column; gap: 30px; }
        @media (min-width: 768px) { .layout-row { flex-direction: row; align-items: stretch; } .col-right { flex: 1; border-left: 1px solid var(--card-border); padding-left: 30px; order: 1; } .col-left { flex: 1; order: 2; } }
        .user-profile { display: flex; align-items: center; gap: 15px; margin-bottom: 25px; }
        .avatar { width: 65px; height: 65px; background: linear-gradient(135deg, #00C6FF, #0072FF); border-radius: 22px; display: flex; justify-content: center; align-items: center; font-size: 30px; color: white; box-shadow: 0 10px 20px rgba(0,198,255,0.3); }
        .user-text h2 { font-size: 20px; margin-bottom: 5px; font-weight: 800; }
        .badge { font-size: 11px; padding: 4px 10px; border-radius: 8px; font-weight: bold; display: inline-block; }
        .badge.active { background: rgba(0,255,136,0.2); color: #00ff88; border: 1px solid rgba(0,255,136,0.3); }
        .badge.inactive { background: rgba(255,50,50,0.2); color: #ff4444; border: 1px solid rgba(255,50,50,0.3); }
        [data-theme="light"] .badge.active { color: #007a43; background: rgba(0,255,136,0.5); }
        .progress-box { margin-bottom: 25px; }
        .bar-bg { height: 12px; background: rgba(0,0,0,0.2); border-radius: 6px; overflow: hidden; }
        .bar-fill { height: 100%; background: var(--accent); width: 0%; transition: width 1s; box-shadow: 0 0 10px var(--accent); }
        .bar-txt { display: flex; justify-content: space-between; font-size: 12px; margin-top: 8px; font-weight: bold; color: var(--text-sub); }
        .data-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 20px; }
        .data-item { background: var(--btn-bg); border: 1px solid var(--btn-border); padding: 12px; border-radius: 16px; display: flex; flex-direction: column; }
        .d-label { font-size: 10px; opacity: 0.7; margin-bottom: 4px; }
        .d-value { font-size: 14px; font-weight: 800; direction: ltr; text-align: right; }
        .btn-grid { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 10px; margin-bottom: 15px; }
        .action-btn { background: var(--btn-bg); border: 1px solid var(--btn-border); color: var(--text-main); text-decoration: none; padding: 15px 5px; border-radius: 18px; text-align: center; display: flex; flex-direction: column; align-items: center; gap: 8px; cursor: pointer; transition: 0.2s; }
        .action-btn:active { transform: scale(0.95); }
        .btn-title { font-size: 11px; font-weight: bold; }
        .config-btn { display: flex; justify-content: center; align-items: center; gap: 10px; width: 100%; padding: 12px; background: var(--btn-bg); border: 1px solid var(--btn-border); border-radius: 18px; color: var(--text-main); margin-bottom: 10px; cursor: pointer; font-size: 12px; transition: 0.2s; }
        .config-btn:hover { background: rgba(255,255,255,0.1); }
        .support-btn { display: flex; justify-content: center; align-items: center; gap: 10px; width: 100%; padding: 16px; background: linear-gradient(90deg, rgba(0,198,255,0.15), rgba(0,114,255,0.15)); border: 1px solid var(--accent); border-radius: 20px; color: var(--text-main); text-decoration: none; font-weight: bold; font-size: 14px; margin-top: 5px; box-shadow: 0 5px 15px rgba(0,0,0,0.1); }
        .smart-dl { margin-top: 20px; display: none; }
        .dl-main-btn { display: flex; align-items: center; gap: 10px; background: var(--accent); color: white; padding: 12px; border-radius: 15px; text-decoration: none; font-weight: bold; font-size: 13px; justify-content: center; box-shadow: 0 5px 15px rgba(0,0,0,0.2); }
        .dl-sub-links { display: flex; justify-content: center; gap: 15px; margin-top: 10px; font-size: 11px; opacity: 0.8; }
        .dl-sub-links a { color: var(--text-main); text-decoration: none; }
        .app-row { margin-top: 20px; background: var(--btn-bg); border: 1px solid var(--btn-border); border-radius: 20px; padding: 15px; display: flex; justify-content: space-around; }
        .app-icon { text-align: center; text-decoration: none; color: var(--text-main); opacity: 0.8; font-size: 10px; }
        .app-img { width: 40px; height: 40px; background: rgba(255,255,255,0.1); border-radius: 12px; display: flex; justify-content: center; align-items: center; font-size: 20px; margin-bottom: 5px; border: 1px solid var(--btn-border); }
        .modal-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.8); backdrop-filter: blur(10px); z-index: 999; display: none; justify-content: center; align-items: center; }
        .modal-box { background: var(--card-bg); border: 1px solid var(--card-border); padding: 25px; border-radius: 25px; width: 90%; max-width: 350px; text-align: center; max-height: 80vh; overflow-y: auto; }
        .close-btn { background: #ff4444; color: white; border: none; padding: 8px 25px; border-radius: 10px; margin-top: 15px; cursor: pointer; font-weight: bold; }
        .tut-row { text-align: right; background: rgba(255,255,255,0.05); padding: 10px; margin: 5px 0; border-radius: 10px; font-size: 12px; }
        .conf-item { background: var(--btn-bg); border: 1px solid var(--btn-border); padding: 10px; margin-bottom: 8px; border-radius: 12px; text-align: left; display: flex; justify-content: space-between; align-items: center; }
        .conf-name { font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 70%; direction: ltr; }
    </style>
</head>
<body>
    <div class="ticker-wrap"><div class="ticker" id="newsTxt">__NEWS__</div></div>

    <div class="container">
        <div class="header">
            <div>
                <div class="brand" id="brandTxt">__BRAND__</div>
                <a href="https://t.me/__BOT__" id="botLink" class="bot-link">🤖 @__BOT__</a>
            </div>
            <div class="header-btns">
                <div class="circle-btn" onclick="openModal('tutModal')">?</div>
                <div class="circle-btn" onclick="toggleTheme()">🌙</div>
            </div>
        </div>
        
        <div class="alert-box" id="renewAlert">⚠️ اعتبار یا حجم سرویس شما رو به اتمام است!</div>

        <div class="main-card">
            <div class="layout-row">
                <div class="col-right">
                    <div class="user-profile">
                        <div class="avatar">👤</div>
                        <div class="user-text">
                            <h2>{{ user.username }}</h2>
                            {% if user.status == 'active' %}<span class="badge active">● فعال</span>{% else %}<span class="badge inactive">● غیرفعال</span>{% endif %}
                        </div>
                    </div>
                    <div class="progress-box">
                        <div class="bar-bg"><div class="bar-fill" id="pBar"></div></div>
                        <div class="bar-txt"><span>مصرف شده</span><span id="pText">0%</span></div>
                    </div>
                    <div class="btn-grid">
                        <a href="{{ subscription_url }}" target="_blank" class="action-btn" onclick="forceCopy('{{ subscription_url }}', false)"><i>🚀</i><span class="btn-title">اتصال</span></a>
                        <div class="action-btn" onclick="openModal('qrModal')"><i>🔳</i><span class="btn-title">کیو‌آر</span></div>
                        <div class="action-btn" onclick="forceCopy('{{ subscription_url }}', true)"><i>📋</i><span class="btn-title" id="cpBtn">کپی</span></div>
                    </div>
                    <div class="config-btn" onclick="showConfigs()">📂 لیست کانفیگ‌ها</div>
                    <a href="https://t.me/__SUP__" id="supportLink" class="support-btn">💬 پشتیبانی و تمدید</a>
                </div>
                <div class="col-left">
                    <div class="data-grid">
                        <!-- DATE FIX HERE: Check if date exists -->
                        <div class="data-item">
                            <span class="d-label">تاریخ انقضا</span>
                            <span class="d-value">
                                {% if user.expire_date %}
                                    {{ user.expire_date }}
                                {% else %}
                                    نامحدود
                                {% endif %}
                            </span>
                        </div>
                        
                        <div class="data-item"><span class="d-label">حجم کل</span><span class="d-value">{{ user.data_limit | filesizeformat }}</span></div>
                        <div class="data-item"><span class="d-label">مصرف شده</span><span class="d-value">{{ user.used_traffic | filesizeformat }}</span></div>
                        <div class="data-item"><span class="d-label">باقی‌مانده</span><span class="d-value" id="remText" style="color: var(--accent)">...</span></div>
                    </div>
                    
                    <div id="smartDL" class="smart-dl">
                        <a id="smartBtn" href="#" class="dl-main-btn">⬇️ دانلود برنامه</a>
                        <div class="dl-sub-links"><a href="#" id="alt1">Link 1</a> | <a href="#" id="alt2">Link 2</a></div>
                    </div>
                    <div id="normalDL" class="app-row">
                        <a href="__ANDROID__" id="lnkAnd" class="app-icon"><div class="app-img">🤖</div>Android</a>
                        <a href="__IOS__" id="lnkIos" class="app-icon"><div class="app-img">🍏</div>iOS</a>
                        <a href="__WIN__" id="lnkWin" class="app-icon"><div class="app-img">💻</div>Win</a>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- Modals -->
    <div id="confModal" class="modal-overlay"><div class="modal-box"><h3>لیست کانفیگ‌ها</h3><br><div id="confList" style="max-height:300px; overflow-y:auto"></div><button class="close-btn" onclick="closeModal('confModal')">بستن</button></div></div>
    <div id="qrModal" class="modal-overlay"><div class="modal-box"><h3>اسکن کنید</h3><br><div style="background:white; padding:10px; border-radius:15px; display:inline-block"><img src="https://api.qrserver.com/v1/create-qr-code/?size=150x150&data={{ subscription_url }}" width="150"></div><br><button class="close-btn" onclick="closeModal('qrModal')">بستن</button></div></div>
    <div id="tutModal" class="modal-overlay"><div class="modal-box"><h3>راهنما</h3><br><div class="tut-row" id="t1">__TUT1__</div><div class="tut-row" id="t2">__TUT2__</div><div class="tut-row" id="t3">__TUT3__</div><button class="close-btn" onclick="closeModal('tutModal')">باشه</button></div></div>
    
    <script>
        // --- INLINE CONFIG ---
        const THEME_CONFIG = {
            brandName: "__BRAND__",
            botUsername: "__BOT__",
            supportID: "__SUP__",
            newsText: "__NEWS__",
            tut1: "__TUT1__",
            tut2: "__TUT2__",
            tut3: "__TUT3__",
            androidUrl: "__ANDROID__",
            iosUrl: "__IOS__",
            winUrl: "__WIN__"
        };

        // Apply Config (This ensures placeholders are replaced if sed fails/delays)
        if(typeof THEME_CONFIG !== 'undefined') {
            document.title = THEME_CONFIG.brandName;
            document.getElementById('brandTxt').innerText = THEME_CONFIG.brandName;
            document.getElementById('newsTxt').innerText = THEME_CONFIG.newsText;
            document.getElementById('botLink').innerText = '🤖 @' + THEME_CONFIG.botUsername;
            document.getElementById('botLink').href = 'https://t.me/' + THEME_CONFIG.botUsername;
            document.getElementById('supportLink').href = 'https://t.me/' + THEME_CONFIG.supportID;
            document.getElementById('t1').innerText = THEME_CONFIG.tut1;
            document.getElementById('t2').innerText = THEME_CONFIG.tut2;
            document.getElementById('t3').innerText = THEME_CONFIG.tut3;
            document.getElementById('lnkAnd').href = THEME_CONFIG.androidUrl;
            document.getElementById('lnkIos').href = THEME_CONFIG.iosUrl;
            document.getElementById('lnkWin').href = THEME_CONFIG.winUrl;
            
            const ua = navigator.userAgent.toLowerCase();
            const sDiv = document.getElementById('smartDL');
            const nDiv = document.getElementById('normalDL');
            const sBtn = document.getElementById('smartBtn');
            const alt1 = document.getElementById('alt1');
            const alt2 = document.getElementById('alt2');

            if (ua.indexOf("android") > -1) {
                sDiv.style.display = "block"; nDiv.style.display = "none";
                sBtn.innerHTML = "🤖 دانلود برنامه اندروید"; sBtn.href = THEME_CONFIG.androidUrl;
                alt1.innerHTML = "iOS"; alt1.href = THEME_CONFIG.iosUrl;
                alt2.innerHTML = "Windows"; alt2.href = THEME_CONFIG.winUrl;
            } else if (ua.indexOf("iphone") > -1 || ua.indexOf("ipad") > -1) {
                sDiv.style.display = "block"; nDiv.style.display = "none";
                sBtn.innerHTML = "🍏 دانلود برنامه آیفون"; sBtn.href = THEME_CONFIG.iosUrl;
                alt1.innerHTML = "Android"; alt1.href = THEME_CONFIG.androidUrl;
                alt2.innerHTML = "Windows"; alt2.href = THEME_CONFIG.winUrl;
            } else if (ua.indexOf("win") > -1) {
                sDiv.style.display = "block"; nDiv.style.display = "none";
                sBtn.innerHTML = "💻 دانلود برنامه ویندوز"; sBtn.href = THEME_CONFIG.winUrl;
                alt1.innerHTML = "Android"; alt1.href = THEME_CONFIG.androidUrl;
                alt2.innerHTML = "iOS"; alt2.href = THEME_CONFIG.iosUrl;
            }
        }
        
        const total = {{ user.data_limit }};
        const used = {{ user.used_traffic }};
        const subUrl = "{{ subscription_url }}";
        
        let p = 0; if(total > 0) p = (used/total)*100; else if(total==0 && used>0) p=100; if(p>100)p=100;
        document.getElementById('pBar').style.width = p + '%'; document.getElementById('pText').innerText = Math.round(p) + '%';
        
        const rem = total - used;
        if (total > 0 && (rem/total) < 0.2) {
            document.getElementById('renewAlert').style.display = 'block';
            document.getElementById('pBar').style.background = '#ff4757';
            document.getElementById('pBar').style.boxShadow = '0 0 10px #ff4757';
        }

        function fmt(b) { if(total===0) return 'نامحدود'; if(b<=0) return '0 MB'; const u=['B','KB','MB','GB','TB']; const i=Math.floor(Math.log(b)/Math.log(1024)); return (b/Math.pow(1024,i)).toFixed(2)+' '+u[i]; }
        document.getElementById('remText').innerText = fmt(rem);
        
        function forceCopy(text, alert) {
            var textArea = document.createElement("textarea"); textArea.value = text; textArea.contentEditable = true; textArea.readOnly = false; textArea.style.position = "fixed"; textArea.style.left = "-9999px"; document.body.appendChild(textArea); 
            if (navigator.userAgent.match(/ipad|iphone/i)) { var r=document.createRange(); r.selectNodeContents(textArea); var s=window.getSelection(); s.removeAllRanges(); s.addRange(r); textArea.setSelectionRange(0,999999); } else { textArea.select(); }
            try { document.execCommand('copy'); if(alert) { const btn = document.getElementById('cpBtn'); btn.innerText = '✓'; btn.style.color = '#00ff88'; setTimeout(() => { btn.innerText = 'کپی'; btn.style.color = 'inherit'; }, 2000); } } catch (err) {}
            document.body.removeChild(textArea);
        }
        function showConfigs() { openModal('confModal'); document.getElementById('confList').innerHTML = '<p style="font-size:12px; opacity:0.8; margin-bottom:10px">لینک اشتراک اصلی:</p><div class="conf-item"><span class="conf-name" style="direction:ltr">Subscription Link</span><button class="close-btn" style="margin:0; padding:5px 15px; background:var(--accent)" onclick="forceCopy(\''+subUrl+'\', false); this.innerText=\'✓\'">کپی</button></div>'; }
        function toggleTheme() { const b=document.body; const btn=document.querySelector('.circle-btn:last-child'); if(b.getAttribute('data-theme')==='light'){b.removeAttribute('data-theme');localStorage.setItem('theme','dark');btn.innerText='🌙';}else{b.setAttribute('data-theme','light');localStorage.setItem('theme','light');btn.innerText='☀️';} }
        if(localStorage.getItem('theme')==='light'){ document.body.setAttribute('data-theme','light'); document.querySelector('.circle-btn:last-child').innerText='☀️'; }
        function openModal(id){document.getElementById(id).style.display='flex';} function closeModal(id){document.getElementById(id).style.display='none';}
        window.onclick=function(e){if(e.target.classList.contains('modal-overlay'))e.target.style.display='none';}
    </script>
</body>
</html>
EOF

# 2. REPLACE PLACEHOLDERS WITH USER INPUT
sed -i "s|__BRAND__|$IN_BRAND|g" "$TEMPLATE_FILE"
sed -i "s|__BOT__|$IN_BOT|g" "$TEMPLATE_FILE"
sed -i "s|__SUP__|$IN_SUP|g" "$TEMPLATE_FILE"
sed -i "s|__NEWS__|$IN_NEWS|g" "$TEMPLATE_FILE"
sed -i "s|__TUT1__|$TUT_1|g" "$TEMPLATE_FILE"
sed -i "s|__TUT2__|$TUT_2|g" "$TEMPLATE_FILE"
sed -i "s|__TUT3__|$TUT_3|g" "$TEMPLATE_FILE"
sed -i "s|__ANDROID__|https://play.google.com/store/apps/details?id=com.v2ray.ang|g" "$TEMPLATE_FILE"
sed -i "s|__IOS__|https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690|g" "$TEMPLATE_FILE"
sed -i "s|__WIN__|https://github.com/2dust/v2rayN/releases|g" "$TEMPLATE_FILE"

# Update Config
sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"
echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE"
echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE"

if command -v pasarguard &> /dev/null; then pasarguard restart; else systemctl restart pasarguard 2>/dev/null; fi
echo -e "${GREEN}✔ Theme Installed! Check your link.${NC}"