#!/bin/bash

CYAN='\033[0;36m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'

TEMPLATE_DIR="/var/lib/pasarguard/templates/subscription"
TEMPLATE_FILE="$TEMPLATE_DIR/index.html"
ENV_FILE="/opt/pasarguard/.env"

if [ "$EUID" -ne 0 ]; then echo -e "${RED}Run as root.${NC}"; exit 1; fi

get_prev() { if [ -f "$TEMPLATE_FILE" ]; then grep 'id="brandTxt"' "$TEMPLATE_FILE" | head -n1 | sed -E 's/.*id="brandTxt">([^<]+)<.*/\1/'; fi }
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'; }

clear
echo -e "${CYAN}=== FarsNetVIP Theme ===${NC}"

PREV_BRAND=$(get_prev); [ -z "$PREV_BRAND" ] && PREV_BRAND="FarsNetVIP"

read -p "Brand [$PREV_BRAND]: " IN_BRAND
read -p "Bot User [MyBot]: " IN_BOT
read -p "Support ID [Support]: " IN_SUP
read -p "News [خوش آمدید]: " IN_NEWS

[ -z "$IN_BRAND" ] && IN_BRAND="$PREV_BRAND"
[ -z "$IN_BOT" ] && IN_BOT="MyBot"
[ -z "$IN_SUP" ] && IN_SUP="Support"
[ -z "$IN_NEWS" ] && IN_NEWS="خوش آمدید"

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
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>__BRAND__</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@400;600;800&display=swap');
        
        /* ========== DARK MODE (DEFAULT) ========== */
        :root {
            --color-bg: #0a0a0a;
            --color-text: #e5e5e5;
            --color-text-muted: #888888;
            --color-card: rgba(25, 25, 30, 0.8);
            --color-border: rgba(255, 255, 255, 0.1);
            --color-btn-primary: rgba(56, 189, 248, 0.8); /* Sky Blue */
            --color-btn-secondary: rgba(255, 255, 255, 0.1);
            --color-glow-1: rgba(249, 115, 22, 0.4);
            --color-glow-2: rgba(59, 130, 246, 0.3);
        }
        
        /* ========== LIGHT MODE ========== */
        :root.light {
            --color-bg: #f5f5f5;
            --color-text: #1a1a1a;
            --color-text-muted: #666666;
            --color-card: rgba(255, 255, 255, 0.9);
            --color-border: rgba(0, 0, 0, 0.1);
            --color-btn-primary: rgba(14, 165, 233, 0.9); /* Sky Blue */
            --color-btn-secondary: rgba(0, 0, 0, 0.08);
            --color-glow-1: rgba(249, 115, 22, 0.2);
            --color-glow-2: rgba(59, 130, 246, 0.2);
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }
        
        body {
            font-family: 'Vazirmatn', sans-serif;
            background-color: var(--color-bg);
            color: var(--color-text);
            min-height: 100vh;
            padding: 60px 20px 20px;
            transition: background-color 0.3s, color 0.3s;
        }

        .orb { position: fixed; width: 300px; height: 300px; border-radius: 50%; filter: blur(80px); z-index: -1; pointer-events: none; transition: background 0.3s; }
        .orb-1 { top: -100px; right: -50px; background: var(--color-glow-1); }
        .orb-2 { bottom: -100px; left: -50px; background: var(--color-glow-2); }

        .ticker { position: fixed; top: 0; left: 0; width: 100%; height: 40px; background: rgba(0,0,0,0.3); backdrop-filter: blur(10px); display: flex; align-items: center; overflow: hidden; z-index: 100; }
        .ticker span { white-space: nowrap; animation: scroll 20s linear infinite; color: #fbbf24; font-size: 13px; }
        @keyframes scroll { 0% { transform: translateX(100%); } 100% { transform: translateX(-100%); } }

        .container { max-width: 800px; margin: 0 auto; }

        .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
        .brand { font-size: 24px; font-weight: 800; }
        .bot-link { display: inline-block; margin-top: 5px; font-size: 12px; color: var(--color-text-muted); text-decoration: none; background: rgba(255,255,255,0.1); padding: 4px 12px; border-radius: 20px; }

        .theme-btn { width: 44px; height: 44px; border-radius: 12px; border: 1px solid var(--color-border); background: rgba(255,255,255,0.1); font-size: 20px; cursor: pointer; display: flex; align-items: center; justify-content: center; transition: transform 0.2s; }
        .theme-btn:active { transform: scale(0.9); }

        .card { background: var(--color-card); border: 1px solid var(--color-border); border-radius: 20px; padding: 24px; backdrop-filter: blur(20px); transition: background 0.3s, border 0.3s; }

        .grid { display: grid; gap: 24px; }
        @media (min-width: 768px) { .grid { grid-template-columns: 1fr 1fr; } }

        .profile { display: flex; gap: 15px; align-items: center; margin-bottom: 20px; }
        .avatar { width: 60px; height: 60px; border-radius: 50%; background: linear-gradient(135deg, #fbbf24, #f97316); color: #7c2d12; display: flex; align-items: center; justify-content: center; font-size: 28px; position: relative; }
        .online-dot { position: absolute; bottom: 2px; right: 2px; width: 12px; height: 12px; background: #10b981; border-radius: 50%; border: 2px solid var(--color-bg); }
        .username { font-size: 18px; font-weight: 700; }
        .status { display: inline-block; margin-top: 4px; font-size: 12px; padding: 2px 10px; border-radius: 10px; }
        .status.active { background: rgba(16,185,129,0.2); color: #34d399; }
        .status.inactive { background: rgba(239,68,68,0.2); color: #f87171; }

        .progress-wrap { height: 10px; background: rgba(0,0,0,0.2); border-radius: 10px; overflow: hidden; margin-bottom: 5px; }
        .progress-fill { height: 100%; background: linear-gradient(90deg, #10b981, #f59e0b); width: 0%; transition: width 1s; }
        .progress-text { display: flex; justify-content: space-between; font-size: 12px; color: var(--color-text-muted); margin-bottom: 20px; }

        /* BUTTONS */
        .btn { position: relative; display: flex; align-items: center; justify-content: center; height: 50px; border-radius: 16px; font-size: 14px; font-weight: 600; cursor: pointer; text-decoration: none; overflow: hidden; background: linear-gradient(135deg, rgba(255, 255, 255, 0.12) 0%, rgba(255, 255, 255, 0.05) 50%, rgba(255, 255, 255, 0.02) 100%); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); border: 1px solid rgba(255, 255, 255, 0.15); border-top: 1px solid rgba(255, 255, 255, 0.3); border-bottom: 1px solid rgba(0, 0, 0, 0.2); box-shadow: 0 8px 32px rgba(0, 0, 0, 0.3), inset 0 1px 2px rgba(255, 255, 255, 0.15), inset 0 -2px 4px rgba(0, 0, 0, 0.2); color: var(--color-text); transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1); }
        .btn::before { content: ''; position: absolute; top: -60%; left: 20%; width: 60%; height: 120%; background: radial-gradient(ellipse at center, rgba(249, 115, 22, 0.5) 0%, rgba(236, 72, 153, 0.3) 30%, transparent 70%); opacity: 0.6; transition: all 0.4s ease; pointer-events: none; }
        .btn::after { content: ''; position: absolute; top: 0; left: -100%; width: 100%; height: 100%; background: linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.25), transparent); transition: left 0.5s ease; pointer-events: none; }
        .btn:hover { transform: translateY(-3px); box-shadow: 0 15px 40px rgba(0, 0, 0, 0.35), inset 0 1px 3px rgba(255, 255, 255, 0.2), inset 0 -2px 6px rgba(0, 0, 0, 0.2); }
        .btn:hover::before { opacity: 0.9; top: -40%; }
        .btn:hover::after { left: 100%; }
        .btn:active { transform: scale(0.97); box-shadow: 0 5px 20px rgba(0, 0, 0, 0.3), inset 0 2px 8px rgba(255, 255, 255, 0.3), inset 0 -2px 4px rgba(0, 0, 0, 0.2); }

        .btn-primary { background: linear-gradient(135deg, rgba(56, 189, 248, 0.6) 0%, rgba(14, 165, 233, 0.4) 50%, rgba(2, 132, 199, 0.3) 100%); color: white; border: 1px solid rgba(56, 189, 248, 0.3); border-top: 1px solid rgba(56, 189, 248, 0.5); box-shadow: 0 8px 32px rgba(56, 189, 248, 0.25), inset 0 1px 2px rgba(255, 255, 255, 0.2), inset 0 -2px 4px rgba(0, 0, 0, 0.15); }
        .btn-primary::before { background: radial-gradient(ellipse at center, rgba(56, 189, 248, 0.6) 0%, rgba(14, 165, 233, 0.3) 40%, transparent 70%); }
        .btn-primary:hover { box-shadow: 0 15px 45px rgba(56, 189, 248, 0.35), inset 0 1px 3px rgba(255, 255, 255, 0.25), inset 0 -2px 6px rgba(0, 0, 0, 0.15); }
        .btn-primary:active::before { background: radial-gradient(ellipse at center, rgba(255, 255, 255, 0.7) 0%, rgba(56, 189, 248, 0.5) 40%, rgba(14, 165, 233, 0.4) 60%, transparent 80%); }

        .btn-secondary { background: linear-gradient(135deg, rgba(255, 255, 255, 0.1) 0%, rgba(255, 255, 255, 0.05) 50%, rgba(255, 255, 255, 0.02) 100%); color: var(--color-text); }

        :root.light .btn { background: linear-gradient(135deg, rgba(255,255,255,0.95), rgba(255,255,255,0.7)); border: 1px solid rgba(255,255,255,0.8); border-top: 2px solid white; border-bottom: 1px solid rgba(0,0,0,0.08); color: var(--color-text); }
        :root.light .btn-primary { background: linear-gradient(135deg, rgba(56,189,248,0.9), rgba(14,165,233,0.7)); color: white; border: 1px solid rgba(14,165,233,0.3); border-top: 2px solid rgba(125,211,252,0.6); }
        :root.light .btn-primary::before { background: radial-gradient(ellipse at center, rgba(255,255,255,0.6) 0%, rgba(56,189,248,0.4) 40%, transparent 70%); }
        :root.light .btn-secondary { background: linear-gradient(135deg, rgba(255,255,255,0.98), rgba(245,245,250,0.6)); }

        .btn-grid { display: grid; grid-template-columns: 1fr; gap: 10px; margin-bottom: 10px; }

        .stats { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 15px; }
        .stat-box { background: rgba(255,255,255,0.05); padding: 12px; border-radius: 12px; border: 1px solid var(--color-border); transition: background 0.3s; }
        :root.light .stat-box { background: rgba(0,0,0,0.03); }
        .stat-label { font-size: 11px; color: var(--color-text-muted); margin-bottom: 4px; }
        .stat-value { font-size: 14px; font-weight: 700; text-align: left; direction: ltr; }

        .downloads { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-top: 15px; padding-top: 15px; border-top: 1px solid var(--color-border); }
        .dl-btn { display: flex; flex-direction: column; align-items: center; gap: 5px; padding: 12px; background: rgba(255,255,255,0.05); border-radius: 12px; text-decoration: none; color: var(--color-text); font-size: 11px; border: 1px solid var(--color-border); transition: all 0.3s; }
        :root.light .dl-btn { background: rgba(0,0,0,0.03); }
        .dl-btn:hover { transform: translateY(-2px); background: rgba(255,255,255,0.1); }
        :root.light .dl-btn:hover { background: rgba(0,0,0,0.06); }
        .dl-btn.recommended { border-color: #f59e0b; background: rgba(245,158,11,0.1); }

        .toast { position: fixed; bottom: 30px; left: 50%; transform: translateX(-50%) translateY(20px); background: white; color: black; padding: 12px 24px; border-radius: 30px; font-weight: 700; opacity: 0; transition: 0.3s; z-index: 1000; }
        .toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }

        .modal { position: fixed; inset: 0; background: rgba(0,0,0,0.8); backdrop-filter: blur(5px); display: none; align-items: center; justify-content: center; z-index: 500; }
        .modal-box { background: #1a1a1a; padding: 24px; border-radius: 20px; text-align: center; width: 90%; max-width: 350px; color: white; }
        .copy-input { width: 100%; background: rgba(255,255,255,0.1); border: 1px solid rgba(255,255,255,0.2); color: white; padding: 10px; border-radius: 8px; margin-top: 10px; font-family: monospace; font-size: 12px; text-align: center; }
        
        /* Hidden but focusable input for iOS copy hack */
        #clipboard-helper { position: absolute; left: -9999px; top: -9999px; opacity: 0; }
    </style>
</head>
<body>
    <div class="orb orb-1"></div>
    <div class="orb orb-2"></div>
    
    <div class="ticker"><span>__NEWS__</span></div>
    <div class="toast" id="toast">کپی شد!</div>
    <input type="text" id="clipboard-helper" readonly>

    <div class="container">
        <div class="header">
            <div>
                <div class="brand" id="brandTxt">__BRAND__</div>
                <a href="https://t.me/__BOT__" class="bot-link">🤖 @__BOT__</a>
            </div>
            <button class="theme-btn" id="themeBtn">🌙</button>
        </div>

        <div class="card">
            <div class="grid">
                <div>
                    <div class="profile">
                        <div class="avatar">
                            👤
                            {% if user.online_at %}<div class="online-dot"></div>{% endif %}
                        </div>
                        <div>
                            <div class="username">{{ user.username }}</div>
                            {% if user.status.name == 'active' %}
                                <span class="status active">فعال</span>
                            {% else %}
                                <span class="status inactive">غیرفعال</span>
                            {% endif %}
                        </div>
                    </div>

                    <div class="progress-wrap">
                        <div class="progress-fill" id="progressBar"></div>
                    </div>
                    <div class="progress-text">
                        <span>مصرف شده</span>
                        <span id="progressText">0%</span>
                    </div>

                    <div class="btn-grid">
                        <button class="btn btn-primary" onclick="handleCopy('{{ subscription_url }}')">کپی لینک</button>
                        <button class="btn btn-secondary" onclick="openModal('qrModal')">QR Code</button>
                    </div>
                    <a href="{{ subscription_url }}" class="btn btn-secondary" style="width:100%; margin-bottom:10px">🚀 اتصال مستقیم</a>
                    <button class="btn btn-secondary" style="width:100%" onclick="showConfigs()">📂 کانفیگ‌ها</button>
                    <a href="https://t.me/__SUP__" style="display:block; text-align:center; margin-top:15px; color:var(--color-text-muted); font-size:13px; text-decoration:none">💬 پشتیبانی</a>
                </div>

                <div>
                    <div class="stats">
                        <div class="stat-box">
                            <div class="stat-label">انقضا</div>
                            <div class="stat-value" id="expDate">{% if user.expire %}{{ user.expire }}{% else %}نامحدود{% endif %}</div>
                        </div>
                        <div class="stat-box">
                            <div class="stat-label">حجم کل</div>
                            <div class="stat-value">{{ user.data_limit | filesizeformat }}</div>
                        </div>
                        <div class="stat-box">
                            <div class="stat-label">مصرف شده</div>
                            <div class="stat-value">{{ user.used_traffic | filesizeformat }}</div>
                        </div>
                        <div class="stat-box">
                            <div class="stat-label">باقیمانده</div>
                            <div class="stat-value" id="remaining" style="color:#3b82f6">...</div>
                        </div>
                    </div>

                    <div class="downloads">
                        <a href="__ANDROID__" class="dl-btn" id="dlAndroid"><span>🤖</span>Android</a>
                        <a href="__IOS__" class="dl-btn" id="dlIos"><span>🍏</span>iOS</a>
                        <a href="__WIN__" class="dl-btn" id="dlWin"><span>💻</span>Windows</a>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- QR Modal -->
    <div class="modal" id="qrModal" onclick="if(event.target===this)closeModal('qrModal')">
        <div class="modal-box">
            <h3>اسکن کنید</h3><br>
            <div style="background:white; padding:10px; border-radius:10px; display:inline-block">
                <img src="https://api.qrserver.com/v1/create-qr-code/?size=200x200&data={{ subscription_url }}" width="180">
            </div>
            <br><br>
            <button class="btn btn-secondary" style="background:#333; color:white" onclick="closeModal('qrModal')">بستن</button>
        </div>
    </div>

    <!-- Config Modal -->
    <div class="modal" id="configModal" onclick="if(event.target===this)closeModal('configModal')">
        <div class="modal-box">
            <h3>کانفیگ‌ها</h3><br>
            <div id="configList" style="text-align:left; max-height:300px; overflow-y:auto; font-size:12px">...</div>
            <br>
            <button class="btn btn-secondary" style="background:#333; color:white" onclick="closeModal('configModal')">بستن</button>
        </div>
    </div>

    <!-- Manual Copy Modal -->
    <div class="modal" id="copyModal" onclick="if(event.target===this)closeModal('copyModal')">
        <div class="modal-box">
            <h3>کپی دستی</h3>
            <p style="font-size:12px; color:#aaa; margin:10px 0">مرورگر اجازه کپی خودکار نداد. لطفا دستی کپی کنید:</p>
            <input type="text" class="copy-input" id="manualCopyInput" readonly>
            <br><br>
            <button class="btn btn-secondary" style="background:#333; color:white" onclick="closeModal('copyModal')">بستن</button>
        </div>
    </div>

    <script>
        var themeBtn = document.getElementById('themeBtn');
        var root = document.documentElement;
        
        if (localStorage.getItem('theme') === 'light') {
            root.classList.add('light');
            themeBtn.textContent = '☀️';
        }
        
        themeBtn.onclick = function() {
            if (root.classList.contains('light')) {
                root.classList.remove('light');
                themeBtn.textContent = '🌙';
                localStorage.setItem('theme', 'dark');
            } else {
                root.classList.add('light');
                themeBtn.textContent = '☀️';
                localStorage.setItem('theme', 'light');
            }
        };

        var total = 0, used = 0;
        try { total = parseInt('{{ user.data_limit }}') || 0; } catch(e) {}
        try { used = parseInt('{{ user.used_traffic }}') || 0; } catch(e) {}

        var percent = total > 0 ? Math.min((used / total) * 100, 100) : 0;
        var pBar = document.getElementById('progressBar');
        var pText = document.getElementById('progressText');
        if (pBar) pBar.style.width = percent + '%';
        if (pText) pText.textContent = Math.round(percent) + '%';
        if (percent > 85 && pBar) pBar.style.background = '#ef4444';

        function formatBytes(b) {
            if (total === 0) return 'نامحدود';
            if (b <= 0) return '0 MB';
            var units = ['B', 'KB', 'MB', 'GB', 'TB'];
            var i = Math.floor(Math.log(b) / Math.log(1024));
            return (b / Math.pow(1024, i)).toFixed(2) + ' ' + units[i];
        }
        var remEl = document.getElementById('remaining');
        if (remEl) remEl.textContent = formatBytes(total - used);

        var expEl = document.getElementById('expDate');
        if (expEl) {
            var rawDate = expEl.textContent.trim();
            if (rawDate && rawDate !== 'None' && rawDate !== 'null' && rawDate !== 'نامحدود') {
                try {
                    var d = new Date(rawDate);
                    if (!isNaN(d.getTime())) expEl.textContent = d.toLocaleDateString('fa-IR');
                } catch(e) {}
            }
        }

        // === HYBRID COPY LOGIC (FIXED) ===
        function handleCopy(text) {
            if(!text || text === '') {
                alert('لینکی وجود ندارد!');
                return;
            }

            // 1. Try Modern Clipboard (HTTPS)
            if (navigator.clipboard && window.isSecureContext) {
                navigator.clipboard.writeText(text)
                    .then(showToast)
                    .catch(function() { fallbackCopy(text); });
            } else {
                // 2. Fallback for HTTP / Older Browsers
                fallbackCopy(text);
            }
        }

        function fallbackCopy(text) {
            // Use the permanent input to avoid DOM manipulation blocks
            var helper = document.getElementById('clipboard-helper');
            
            // Make it visible just for the copy action
            helper.style.display = 'block';
            helper.style.left = '0';
            helper.style.top = '0';
            helper.style.opacity = '1';
            
            helper.value = text;
            helper.focus();
            helper.select();
            helper.setSelectionRange(0, 99999); // For iOS

            try {
                var result = document.execCommand('copy');
                if (result) {
                    showToast();
                } else {
                    openManualCopy(text);
                }
            } catch (err) {
                openManualCopy(text);
            }
            
            // Hide it again
            helper.style.left = '-9999px';
            helper.style.opacity = '0';
        }

        function openManualCopy(text) {
            var modal = document.getElementById('copyModal');
            var input = document.getElementById('manualCopyInput');
            input.value = text;
            modal.style.display = 'flex';
            
            // Select text for user convenience
            input.focus();
            input.select();
        }

        function showToast() {
            var t = document.getElementById('toast');
            t.classList.add('show');
            setTimeout(function() { t.classList.remove('show'); }, 2000);
        }

        function openModal(id) { document.getElementById(id).style.display = 'flex'; }
        function closeModal(id) { document.getElementById(id).style.display = 'none'; }

        function showConfigs() {
            openModal('configModal');
            var list = document.getElementById('configList');
            list.innerHTML = '...';
            fetch(window.location.pathname + '/links')
                .then(function(r) { return r.text(); })
                .then(function(text) {
                    if (text) {
                        list.innerHTML = '<button class="btn btn-primary" style="height:32px; font-size:12px; margin-bottom:10px; width:100%" onclick="handleCopy(\'' + text.replace(/\n/g, '\\n') + '\')">کپی همه</button>';
                        var lines = text.split('\n');
                        lines.forEach(function(line) {
                            var l = line.trim();
                            if (l && (l.indexOf('vmess') === 0 || l.indexOf('vless') === 0 || l.indexOf('trojan') === 0 || l.indexOf('ss://') === 0)) {
                                var name = 'Config';
                                if (l.indexOf('#') > -1) name = decodeURIComponent(l.split('#')[1]);
                                list.innerHTML += '<div style="background:rgba(255,255,255,0.1); padding:10px; border-radius:8px; margin-bottom:8px; display:flex; justify-content:space-between; align-items:center"><span>' + name + '</span><button class="btn btn-secondary" style="width:auto; height:28px; padding:0 12px; font-size:11px" onclick="handleCopy(\'' + l + '\')">کپی</button></div>';
                            }
                        });
                    }
                })
                .catch(function() { list.innerHTML = 'خطا در دریافت'; });
        }

        var ua = navigator.userAgent.toLowerCase();
        if (ua.indexOf('android') > -1) document.getElementById('dlAndroid').classList.add('recommended');
        else if (ua.indexOf('iphone') > -1 || ua.indexOf('ipad') > -1) document.getElementById('dlIos').classList.add('recommended');
        else if (ua.indexOf('win') > -1) document.getElementById('dlWin').classList.add('recommended');
    </script>
</body>
</html>
EOF

sed -i "s|__BRAND__|$(sed_escape "$IN_BRAND")|g" "$TEMPLATE_FILE"
sed -i "s|__BOT__|$(sed_escape "$IN_BOT")|g" "$TEMPLATE_FILE"
sed -i "s|__SUP__|$(sed_escape "$IN_SUP")|g" "$TEMPLATE_FILE"
sed -i "s|__NEWS__|$(sed_escape "$IN_NEWS")|g" "$TEMPLATE_FILE"
sed -i "s|__ANDROID__|$LNK_AND|g" "$TEMPLATE_FILE"
sed -i "s|__IOS__|$LNK_IOS|g" "$TEMPLATE_FILE"
sed -i "s|__WIN__|$LNK_WIN|g" "$TEMPLATE_FILE"

if [ ! -f "$ENV_FILE" ]; then touch "$ENV_FILE"; fi
sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"
echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE"
echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE"

if command -v pasarguard &> /dev/null; then pasarguard restart; else systemctl restart pasarguard 2>/dev/null; fi
echo -e "${GREEN}✔ Done!${NC}"