#!/bin/bash

# ==========================================
# Theme: FarsNetVIP Ultimate (Glass / Liquid UI)
# Status: FIXED GLASS VERSION + WORKING THEME TOGGLE
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

# Helper: Extract previous Brand value from existing HTML (Smart Default)
get_prev() {
    if [ -f "$TEMPLATE_FILE" ]; then
        grep 'id="brandTxt"' "$TEMPLATE_FILE" | head -n1 | sed -E 's/.*id="brandTxt">([^<]+)<.*/\1/'
    fi
}

# Helper: escape برای sed
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

/* پایه رنگ‌ها (حالت پیش‌فرض: تیره) */
:root {
    --background: #020617;              /* خیلی تیره، نزدیک مشکی */
    --foreground: #f9fafb;
    --card: rgba(15, 23, 42, 0.65);     /* شیشه‌ای تیره */
    --card-foreground: #f9fafb;
    --primary: #7c3aed;                 /* بنفش اصلی */
    --primary-fg: #f9fafb;
    --secondary: rgba(15, 23, 42, 0.4);
    --secondary-fg: #e5e7eb;
    --muted: rgba(15, 23, 42, 0.3);
    --muted-fg: #a1a1aa;
    --border: rgba(148, 163, 184, 0.4);
    --input: rgba(15, 23, 42, 0.7);
    --ring: #7c3aed;
    --radius: 0.9rem;
    --success: #10b981;
    --warning: #f59e0b;
    --destructive: #ef4444;
    --glow-orange: rgba(249, 115, 22, 0.55);  /* نور نارنجی */
    --glow-blue: rgba(56, 189, 248, 0.35);
}

/* حالت روشن روی <html> */
html[data-theme="light"] {
    --background: #f9fafb;
    --foreground: #020617;
    --card: rgba(255, 255, 255, 0.92);
    --card-foreground: #020617;
    --primary: #7c3aed;
    --primary-fg: #ffffff;
    --secondary: rgba(249, 250, 251, 0.95);
    --secondary-fg: #111827;
    --muted: rgba(243, 244, 246, 0.9);
    --muted-fg: #6b7280;
    --border: rgba(209, 213, 219, 0.9);
    --input: rgba(229, 231, 235, 0.95);
    --glow-orange: rgba(249, 115, 22, 0.3);
    --glow-blue: rgba(56, 189, 248, 0.25);
}

/* پس‌زمینه‌ی مخصوص حالت روشن (واضح‌تر) */
html[data-theme="light"] body {
    background:
        radial-gradient(circle at top right, rgba(249, 250, 251, 0.9), transparent 55%),
        radial-gradient(circle at bottom left, rgba(191, 219, 254, 0.85), transparent 55%),
        #e5e7eb;
}

/* عمومی */
* {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
    -webkit-tap-highlight-color: transparent;
}

body {
    font-family: 'Vazirmatn', sans-serif;
    background:
        radial-gradient(circle at top right, var(--glow-orange), transparent 55%),
        radial-gradient(circle at bottom left, var(--glow-blue), transparent 55%),
        #020617;
    color: var(--foreground);
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 20px;
    padding-top: 60px;
    position: relative;
    overflow-x: hidden;
    transition: background-color 0.4s ease, color 0.4s ease;
}

/* اورب‌های نوری پس‌زمینه (نور لامپ‌ها) */
body::before,
body::after {
    content: "";
    position: fixed;
    z-index: -1;
    border-radius: 999px;
    filter: blur(45px);
    opacity: 0.9;
    pointer-events: none;
}
body::before {
    width: 380px;
    height: 380px;
    top: -120px;
    right: -80px;
    background: radial-gradient(circle, var(--glow-orange), transparent 60%);
}
body::after {
    width: 320px;
    height: 320px;
    bottom: -100px;
    left: -60px;
    background: radial-gradient(circle, var(--glow-blue), transparent 60%);
}

/* نوار خبر (Ticker) */
.ticker-container {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 40px;
    background: rgba(15, 23, 42, 0.8);
    border-bottom: 1px solid rgba(148, 163, 184, 0.35);
    z-index: 50;
    overflow: hidden;
    display: flex;
    align-items: center;
    backdrop-filter: blur(16px);
    -webkit-backdrop-filter: blur(16px);
}
.ticker-text {
    white-space: nowrap;
    animation: ticker 28s linear infinite;
    font-size: 13px;
    font-weight: 500;
    color: #fed7aa; /* نارنجی روشن */
    padding-inline: 40px;
}
@keyframes ticker {
    0%   { transform: translateX(100%); }
    100% { transform: translateX(-100%); }
}

.container {
    width: 100%;
    max-width: 800px;
}

/* هدر */
.header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 24px;
}
.brand {
    font-size: 24px;
    font-weight: 700;
    text-shadow: 0 0 22px rgba(15, 23, 42, 0.8);
}
.bot-badge {
    font-size: 12px;
    background: linear-gradient(135deg, rgba(15, 23, 42, 0.8), rgba(30, 64, 175, 0.9));
    color: var(--secondary-fg);
    padding: 4px 12px;
    border-radius: 999px;
    text-decoration: none;
    display: inline-flex;
    align-items: center;
    gap: 4px;
    margin-top: 6px;
    border: 1px solid rgba(148, 163, 184, 0.5);
    box-shadow: 0 0 20px rgba(15, 23, 42, 0.9);
}
.theme-btn {
    width: 40px;
    height: 40px;
    border-radius: 14px;
    background: radial-gradient(circle at 30% 0%, #ffffff33, transparent 55%),
                rgba(15, 23, 42, 0.85);
    border: 1px solid rgba(148, 163, 184, 0.5);
    display: flex;
    justify-content: center;
    align-items: center;
    font-size: 18px;
    box-shadow:
        0 0 0 1px rgba(148, 163, 184, 0.5),
        0 18px 35px rgba(15, 23, 42, 0.9);
    backdrop-filter: blur(18px);
    -webkit-backdrop-filter: blur(18px);
    transition: transform 0.15s ease, box-shadow 0.15s ease, background 0.15s ease;
}
.theme-btn:hover {
    transform: translateY(-1px);
    box-shadow:
        0 0 0 1px rgba(248, 250, 252, 0.4),
        0 20px 40px rgba(15, 23, 42, 0.95);
}

/* کارت اصلی */
.card {
    position: relative;
    background: radial-gradient(circle at 0% 0%, rgba(248, 250, 252, 0.22), transparent 55%),
                var(--card);
    border: 1px solid rgba(148, 163, 184, 0.55);
    border-radius: var(--radius);
    padding: 24px;
    box-shadow:
        0 0 0 1px rgba(148, 163, 184, 0.4),
        0 32px 80px rgba(15, 23, 42, 0.95),
        0 0 80px rgba(249, 115, 22, 0.18);
    backdrop-filter: blur(22px);
    -webkit-backdrop-filter: blur(22px);
    overflow: hidden;
}
.card::before {
    /* هاله‌ی نرم داخل کارت مثل نور لامپ */
    content: "";
    position: absolute;
    inset: -30%;
    background:
        radial-gradient(circle at 10% -10%, rgba(248, 250, 252, 0.35), transparent 60%),
        radial-gradient(circle at 110% 110%, rgba(249, 115, 22, 0.35), transparent 65%);
    opacity: 0.38;
    z-index: -1;
}
.grid-layout {
    display: grid;
    grid-template-columns: 1fr;
    gap: 24px;
}
@media (min-width: 768px) {
    .grid-layout {
        grid-template-columns: 1fr 1.2fr;
    }
    .col-info { order: 1; }
    .col-actions { order: 2; }
}

/* پروفایل */
.profile {
    display: flex;
    align-items: center;
    gap: 16px;
    margin-bottom: 24px;
}
.avatar {
    width: 64px;
    height: 64px;
    background: radial-gradient(circle at 30% 0%, #ffffff44, transparent 55%),
                linear-gradient(135deg, #4c1d95, #7c3aed);
    color: var(--primary-fg);
    border-radius: 50%;
    display: flex;
    justify-content: center;
    align-items: center;
    font-size: 28px;
    position: relative;
    box-shadow:
        0 0 0 3px rgba(15, 23, 42, 1),
        0 0 30px rgba(124, 58, 237, 0.7);
}
.online-dot {
    position: absolute;
    bottom: 2px;
    right: 2px;
    width: 14px;
    height: 14px;
    background: var(--success);
    border: 2px solid var(--card);
    border-radius: 50%;
    box-shadow: 0 0 0 2px var(--background), 0 0 12px rgba(34, 197, 94, 0.9);
}
.user-name {
    font-size: 20px;
    font-weight: 700;
}
.status-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 10px;
    border-radius: 999px;
    font-size: 12px;
    font-weight: 600;
    margin-top: 4px;
}
.st-active {
    background: rgba(16, 185, 129, 0.18);
    color: var(--success);
    border: 1px solid rgba(16, 185, 129, 0.35);
    box-shadow: 0 0 12px rgba(16, 185, 129, 0.35);
}
.st-inactive {
    background: rgba(239, 68, 68, 0.16);
    color: var(--destructive);
    border: 1px solid rgba(239, 68, 68, 0.35);
    box-shadow: 0 0 12px rgba(239, 68, 68, 0.35);
}

/* نوار مصرف */
.prog-con {
    margin-bottom: 24px;
}
.progress-bar {
    height: 9px;
    background: rgba(15, 23, 42, 0.8);
    border-radius: 999px;
    overflow: hidden;
    border: 1px solid rgba(148, 163, 184, 0.5);
}
.progress-fill {
    height: 100%;
    width: 0%;
    background: linear-gradient(90deg, #22c55e, #eab308, #f97316);
    transition: width 0.9s ease;
    box-shadow: 0 0 18px rgba(249, 115, 22, 0.7);
}
.progress-text {
    display: flex;
    justify-content: space-between;
    font-size: 12px;
    margin-top: 6px;
    color: var(--muted-fg);
    font-weight: 500;
}

/* آمار */
.stats-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
    margin-bottom: 24px;
}
.stat-item {
    background: linear-gradient(145deg, rgba(15, 23, 42, 0.86), rgba(15, 23, 42, 0.7));
    padding: 12px;
    border-radius: calc(var(--radius) - 4px);
    display: flex;
    flex-direction: column;
    border: 1px solid rgba(148, 163, 184, 0.5);
    box-shadow:
        0 0 0 1px rgba(15, 23, 42, 0.95),
        0 12px 30px rgba(15, 23, 42, 0.9);
}
.stat-lbl {
    font-size: 11px;
    color: var(--muted-fg);
}
.stat-val {
    font-size: 14px;
    font-weight: 700;
    direction: ltr;
    text-align: right;
}

/* دکمه‌ها (ژله‌ای + نور داخل) */
.btn {
    position: relative;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: calc(var(--radius) - 4px);
    font-size: 14px;
    font-weight: 500;
    height: 40px;
    width: 100%;
    cursor: pointer;
    text-decoration: none;
    border: 1px solid rgba(148, 163, 184, 0.5);
    overflow: hidden;
    color: var(--foreground);
    background: radial-gradient(circle at 20% 0%, #ffffff44, transparent 55%),
                linear-gradient(135deg, rgba(30, 64, 175, 0.9), rgba(79, 70, 229, 0.95));
    box-shadow:
        0 0 0 1px rgba(15, 23, 42, 0.95),
        0 18px 40px rgba(15, 23, 42, 0.95),
        0 0 28px rgba(249, 115, 22, 0.65);
    backdrop-filter: blur(18px);
    -webkit-backdrop-filter: blur(18px);
    transition: transform 0.12s ease, box-shadow 0.12s ease, background 0.12s ease;
}
.btn::before {
    /* نور داخل دکمه مثل لامپ کوچیک */
    content: "";
    position: absolute;
    width: 130%;
    height: 130%;
    top: -90%;
    left: -15%;
    background: radial-gradient(circle, rgba(248, 250, 252, 0.45), transparent 70%);
    opacity: 0.34;
    pointer-events: none;
}
.btn-pri {
    color: var(--primary-fg);
}
.btn-sec {
    background: linear-gradient(135deg, rgba(15, 23, 42, 0.9), rgba(15, 23, 42, 0.9));
    box-shadow:
        0 0 0 1px rgba(15, 23, 42, 0.95),
        0 16px 32px rgba(15, 23, 42, 0.95);
}
.btn:hover {
    transform: translateY(-1px);
    box-shadow:
        0 0 0 1px rgba(248, 250, 252, 0.35),
        0 26px 52px rgba(15, 23, 42, 1),
        0 0 36px rgba(249, 115, 22, 0.8);
}
.btn:active {
    transform: translateY(1px) scale(0.99);
    box-shadow:
        0 0 0 1px rgba(148, 163, 184, 0.5),
        0 10px 20px rgba(15, 23, 42, 0.9);
}

.act-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
    margin-bottom: 16px;
}

/* دانلود اپ‌ها */
.dl-sec {
    margin-top: 24px;
    border-top: 1px solid var(--border);
    padding-top: 16px;
}
.dl-title {
    font-size: 13px;
    font-weight: 600;
    margin-bottom: 12px;
    color: var(--muted-fg);
}
.dl-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 8px;
}
.dl-item {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    padding: 12px;
    border-radius: 12px;
    border: 1px solid rgba(148, 163, 184, 0.6);
    text-decoration: none;
    color: var(--foreground);
    transition: 0.18s ease;
    background: rgba(15, 23, 42, 0.8);
    box-shadow:
        0 0 0 1px rgba(15, 23, 42, 1),
        0 12px 28px rgba(15, 23, 42, 0.95);
    backdrop-filter: blur(18px);
    -webkit-backdrop-filter: blur(18px);
}
.dl-item:hover {
    border-color: rgba(249, 115, 22, 0.9);
    background: radial-gradient(circle at 30% 0%, rgba(248, 250, 252, 0.3), transparent 55%),
                rgba(15, 23, 42, 0.95);
    box-shadow:
        0 0 0 1px rgba(248, 250, 252, 0.4),
        0 22px 40px rgba(15, 23, 42, 1),
        0 0 30px rgba(249, 115, 22, 0.9);
}
.dl-item.recom {
    border-color: rgba(249, 115, 22, 0.95);
    box-shadow:
        0 0 0 1px rgba(249, 115, 22, 0.9),
        0 22px 40px rgba(15, 23, 42, 1),
        0 0 35px rgba(249, 115, 22, 0.95);
}
.dl-icon {
    font-size: 20px;
}
.dl-name {
    font-size: 11px;
    font-weight: 500;
}

/* Toast */
.toast {
    position: fixed;
    bottom: 24px;
    left: 50%;
    transform: translateX(-50%);
    background: rgba(248, 250, 252, 0.96);
    color: #020617;
    padding: 10px 20px;
    border-radius: 999px;
    font-size: 14px;
    font-weight: 600;
    opacity: 0;
    pointer-events: none;
    transition: 0.3s;
    z-index: 100;
    box-shadow:
        0 12px 28px rgba(15, 23, 42, 0.9),
        0 0 30px rgba(249, 115, 22, 0.6);
}
.toast.show {
    opacity: 1;
    bottom: 32px;
}

/* Modals */
.modal-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.78);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    z-index: 50;
    display: none;
    align-items: center;
    justify-content: center;
}
.modal-box {
    background: rgba(15, 23, 42, 0.9);
    border: 1px solid rgba(148, 163, 184, 0.6);
    padding: 24px;
    border-radius: var(--radius);
    width: 90%;
    max-width: 400px;
    max-height: 80vh;
    overflow-y: auto;
    text-align: center;
    box-shadow:
        0 0 0 1px rgba(15, 23, 42, 1),
        0 22px 40px rgba(15, 23, 42, 1),
        0 0 40px rgba(249, 115, 22, 0.75);
}

/* کانفیگ‌ها */
.conf-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 10px;
    border: 1px solid rgba(148, 163, 184, 0.6);
    border-radius: 10px;
    margin-bottom: 8px;
    text-align: left;
    background: rgba(15, 23, 42, 0.9);
    box-shadow:
        0 0 0 1px rgba(15, 23, 42, 1),
        0 10px 22px rgba(15, 23, 42, 0.95);
}
.conf-name {
    font-size: 12px;
    font-family: monospace;
    direction: ltr;
    max-width: 70%;
    overflow: hidden;
    text-overflow: ellipsis;
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
            <!-- دکمه تم بدون onclick، فقط با id -->
            <div class="theme-btn" id="themeToggle">
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

        // 7. Theme (Dark / Light)
        function toggleTheme() {
            const root = document.documentElement; // <html>
            const icon = document.getElementById('themeIcon');

            if (root.getAttribute('data-theme') === 'light') {
                root.removeAttribute('data-theme');
                localStorage.setItem('theme', 'dark');
                if (icon) icon.innerText = '🌙';
            } else {
                root.setAttribute('data-theme', 'light');
                localStorage.setItem('theme', 'light');
                if (icon) icon.innerText = '☀️';
            }
        }

        // اعمال تم ذخیره‌شده (on load)
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

        // اتصال دکمه تم بدون استفاده از onclick
        (function bindThemeButton() {
            var btn = document.getElementById('themeToggle');
            if (btn) {
                btn.style.cursor = 'pointer';
                btn.addEventListener('click', function(e) {
                    e.preventDefault();
                    toggleTheme();
                });
            }
        })();

        function openModal(id){document.getElementById(id).style.display='flex';}
        function closeModal(id){document.getElementById(id).style.display='none';}
    </script>
</body>
</html>
EOF

# 3. Replace Placeholders (با escape برای ایمنی در sed)
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

# Update Panel Config (.env)
if [ ! -f "$ENV_FILE" ]; then
    touch "$ENV_FILE"
fi
sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"
echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE"
echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE"

# Restart Panel
if command -v pasarguard &> /dev/null; then
    pasarguard restart
else
    systemctl restart pasarguard 2>/dev/null
fi

echo -e "${GREEN}✔ Theme Installed!${NC}"