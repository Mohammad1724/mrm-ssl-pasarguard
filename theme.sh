#!/bin/bash

CYAN='\033[0;36m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'

# Force UTF-8
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

TEMPLATE_DIR="/var/lib/pasarguard/templates/subscription"
TEMPLATE_FILE="$TEMPLATE_DIR/index.html"
ENV_FILE="/opt/pasarguard/.env"

if [ "$EUID" -ne 0 ]; then echo -e "${RED}Run as root.${NC}"; exit 1; fi

get_prev() { if [ -f "$TEMPLATE_FILE" ]; then grep 'id="brandTxt"' "$TEMPLATE_FILE" | head -n1 | sed -E 's/.*id="brandTxt">([^<]+)<.*/\1/'; fi }
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'; }

clear
echo -e "${CYAN}=== FarsNetVIP Theme (Buttons Restored) ===${NC}"

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
        
        /* DARK MODE */
        :root {
            --bg: #0a0a0a; --txt: #e5e5e5; --mute: #888;
            --card: rgba(25, 25, 30, 0.8); --brd: rgba(255, 255, 255, 0.1);
            --pri: rgba(56, 189, 248, 0.8); /* Sky Blue */
            --sec: rgba(255, 255, 255, 0.1);
            --g1: rgba(249, 115, 22, 0.4); --g2: rgba(59, 130, 246, 0.3);
        }
        /* LIGHT MODE */
        :root.light {
            --bg: #f5f5f5; --txt: #1a1a1a; --mute: #666;
            --card: rgba(255, 255, 255, 0.9); --brd: rgba(0, 0, 0, 0.1);
            --pri: rgba(14, 165, 233, 0.9);
            --sec: rgba(0, 0, 0, 0.08);
            --g1: rgba(249, 115, 22, 0.2); --g2: rgba(59, 130, 246, 0.2);
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Vazirmatn', sans-serif; background: var(--bg); color: var(--txt); min-height: 100vh; padding: 60px 20px 20px; transition: 0.3s; }
        
        .orb { position: fixed; width: 300px; height: 300px; border-radius: 50%; filter: blur(80px); z-index: -1; pointer-events: none; transition: background 0.3s; }
        .o1 { top: -100px; right: -50px; background: var(--g1); } .o2 { bottom: -100px; left: -50px; background: var(--g2); }

        .ticker { position: fixed; top: 0; left: 0; width: 100%; height: 40px; background: rgba(0,0,0,0.3); backdrop-filter: blur(10px); display: flex; align-items: center; overflow: hidden; z-index: 100; }
        .ticker span { white-space: nowrap; animation: s 20s linear infinite; color: #fbbf24; font-size: 13px; }
        @keyframes s { 0% { transform: translateX(100%); } 100% { transform: translateX(-100%); } }

        .con { max-width: 800px; margin: 0 auto; }
        .head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
        .br { font-size: 24px; font-weight: 800; }
        .bl { display: inline-block; margin-top: 5px; font-size: 12px; color: var(--mute); text-decoration: none; background: rgba(255,255,255,0.1); padding: 4px 12px; border-radius: 20px; }
        
        .tb { width: 44px; height: 44px; border-radius: 12px; border: 1px solid var(--brd); background: rgba(255,255,255,0.1); font-size: 20px; cursor: pointer; display: flex; align-items: center; justify-content: center; transition: 0.2s; }
        .tb:active { transform: scale(0.9); }

        .card { background: var(--card); border: 1px solid var(--brd); border-radius: 20px; padding: 24px; backdrop-filter: blur(20px); transition: 0.3s; }
        .grid { display: grid; gap: 24px; } @media (min-width: 768px) { .grid { grid-template-columns: 1fr 1fr; } }

        .prof { display: flex; gap: 15px; align-items: center; margin-bottom: 20px; }
        .av { width: 60px; height: 60px; border-radius: 50%; background: linear-gradient(135deg, #fbbf24, #f97316); color: #7c2d12; display: flex; align-items: center; justify-content: center; font-size: 28px; position: relative; }
        .dot { position: absolute; bottom: 2px; right: 2px; width: 12px; height: 12px; background: #10b981; border-radius: 50%; border: 2px solid var(--bg); }
        .nm { font-size: 18px; font-weight: 700; }
        .st { display: inline-block; margin-top: 4px; font-size: 12px; padding: 2px 10px; border-radius: 10px; }
        .st.act { background: rgba(16,185,129,0.2); color: #34d399; } .st.in { background: rgba(239,68,68,0.2); color: #f87171; }

        .pw { height: 10px; background: rgba(0,0,0,0.2); border-radius: 10px; overflow: hidden; margin-bottom: 5px; }
        .pf { height: 100%; background: linear-gradient(90deg, #10b981, #f59e0b); width: 0%; transition: width 1s; }
        .pt { display: flex; justify-content: space-between; font-size: 12px; color: var(--mute); margin-bottom: 20px; }

        /* GLASS BUTTONS */
        .btn { position: relative; display: flex; align-items: center; justify-content: center; height: 50px; border-radius: 16px; font-size: 14px; font-weight: 600; cursor: pointer; text-decoration: none; overflow: hidden; background: linear-gradient(135deg, rgba(255,255,255,0.12), rgba(255,255,255,0.02)); backdrop-filter: blur(20px); border: 1px solid rgba(255,255,255,0.15); border-top: 1px solid rgba(255,255,255,0.3); box-shadow: 0 8px 32px rgba(0,0,0,0.3); color: var(--txt); transition: 0.3s; }
        .btn::before { content: ''; position: absolute; top: -60%; left: 20%; width: 60%; height: 120%; background: radial-gradient(ellipse, rgba(249,115,22,0.5), transparent 70%); opacity: 0.6; pointer-events: none; }
        .btn:active { transform: scale(0.97); }
        .btn:hover { transform: translateY(-3px); box-shadow: 0 15px 40px rgba(0,0,0,0.35); }
        
        .btn-p { background: linear-gradient(135deg, rgba(56,189,248,0.6), rgba(2,132,199,0.3)); color: white; border-color: rgba(56,189,248,0.3); }
        .btn-p::before { background: radial-gradient(ellipse, rgba(56,189,248,0.6), transparent 70%); }
        .btn-s { background: linear-gradient(135deg, rgba(255,255,255,0.1), rgba(255,255,255,0.02)); color: var(--txt); }

        :root.light .btn { background: linear-gradient(135deg, rgba(255,255,255,0.9), rgba(255,255,255,0.7)); border-color: rgba(255,255,255,0.8); color: var(--txt); }
        :root.light .btn-p { background: linear-gradient(135deg, rgba(56,189,248,0.9), rgba(14,165,233,0.7)); color: white; }

        /* TWO COLUMNS FOR COPY & QR (RESTORED) */
        .btn-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 10px; }

        .stats { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 15px; }
        .sb { background: rgba(255,255,255,0.05); padding: 12px; border-radius: 12px; border: 1px solid var(--brd); } :root.light .sb { background: rgba(0,0,0,0.03); }
        .sl { font-size: 11px; color: var(--mute); margin-bottom: 4px; } .sv { font-size: 14px; font-weight: 700; text-align: left; direction: ltr; }

        .dls { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-top: 15px; border-top: 1px solid var(--brd); padding-top: 15px; }
        .db { display: flex; flex-direction: column; align-items: center; gap: 5px; padding: 12px; background: rgba(255,255,255,0.05); border-radius: 12px; text-decoration: none; color: var(--txt); font-size: 11px; border: 1px solid var(--brd); }
        :root.light .db { background: rgba(0,0,0,0.03); } .db.rec { border-color: #f59e0b; background: rgba(245,158,11,0.1); }

        .tst { position: fixed; bottom: 30px; left: 50%; transform: translateX(-50%) translateY(20px); background: white; color: black; padding: 12px 24px; border-radius: 30px; font-weight: 700; opacity: 0; transition: 0.3s; z-index: 1000; }
        .tst.sh { opacity: 1; transform: translateX(-50%) translateY(0); }

        .mod { position: fixed; inset: 0; background: rgba(0,0,0,0.8); backdrop-filter: blur(5px); display: none; align-items: center; justify-content: center; z-index: 500; }
        .mbox { background: #1a1a1a; padding: 24px; border-radius: 20px; text-align: center; width: 90%; max-width: 350px; color: white; }
        .cin { width: 100%; background: rgba(255,255,255,0.1); border: 1px solid rgba(255,255,255,0.2); color: white; padding: 10px; border-radius: 8px; margin-top: 10px; font-family: monospace; font-size: 12px; text-align: center; }
        #cph { position: absolute; left: -9999px; top: -9999px; opacity: 0; }

        .app-list { display: grid; gap: 8px; margin-top: 10px; }
        .app-btn { display: flex; align-items: center; justify-content: space-between; padding: 12px 16px; background: rgba(255,255,255,0.08); border-radius: 12px; color: white; text-decoration: none; border: 1px solid var(--brd); transition: 0.2s; cursor: pointer; }
        .app-btn:hover { background: rgba(255,255,255,0.15); transform: translateX(5px); }
        .app-icon { font-size: 18px; margin-left: 10px; }
    </style>
</head>
<body>
    <div class="orb o1"></div> <div class="orb o2"></div>
    <div class="ticker"><span>__NEWS__</span></div>
    <div class="tst" id="toast">کپی شد!</div>
    <input type="text" id="cph" readonly>

    <div class="con">
        <div class="head">
            <div><div class="br" id="brandTxt">__BRAND__</div><a href="https://t.me/__BOT__" class="bl">🤖 @__BOT__</a></div>
            <button class="tb" id="tBtn">🌙</button>
        </div>

        <div class="card">
            <div class="grid">
                <div>
                    <div class="prof">
                        <div class="av">👤 {% if user.online_at %}<div class="dot"></div>{% endif %}</div>
                        <div>
                            <div class="nm">{{ user.username }}</div>
                            {% if user.status.name == 'active' %}<span class="st act">فعال</span>{% else %}<span class="st in">غیرفعال</span>{% endif %}
                        </div>
                    </div>
                    <div class="pw"><div class="pf" id="pb"></div></div>
                    <div class="pt"><span>مصرف شده</span><span id="pt">0%</span></div>
                    
                    <!-- Two columns for Copy & QR -->
                    <div class="btn-grid">
                        <button class="btn btn-p" onclick="hc('{{ subscription_url }}')">کپی لینک</button>
                        <button class="btn btn-s" onclick="om('qrm')">QR Code</button>
                    </div>
                    
                    <button class="btn btn-s" style="width:100%; margin-bottom:10px" onclick="om('appMod')">🚀 اتصال مستقیم (انتخاب اپ)</button>
                    <button class="btn btn-s" style="width:100%" onclick="sc()">📂 کانفیگ‌ها</button>
                    <a href="https://t.me/__SUP__" style="display:block; text-align:center; margin-top:15px; color:var(--mute); font-size:13px; text-decoration:none">💬 پشتیبانی</a>
                </div>
                <div>
                    <div class="stats">
                        <div class="sb"><div class="sl">انقضا</div><div class="sv" id="ed"></div></div>
                        <div class="sb"><div class="sl">حجم کل</div><div class="sv" id="totDisp">...</div></div>
                        <div class="sb"><div class="sl">مصرف شده</div><div class="sv" id="useDisp">...</div></div>
                        <div class="sb"><div class="sl">باقیمانده</div><div class="sv" id="rem" style="color:#3b82f6">...</div></div>
                    </div>
                    <div class="dls">
                        <a href="__ANDROID__" class="db" id="da"><span>🤖</span>Android</a>
                        <a href="__IOS__" class="db" id="di"><span>🍏</span>iOS</a>
                        <a href="__WIN__" class="db" id="dw"><span>💻</span>Windows</a>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <div class="mod" id="appMod" onclick="if(event.target===this)cm('appMod')">
        <div class="mbox">
            <h3>انتخاب برنامه</h3>
            <p style="font-size:12px; color:#aaa; margin-bottom:15px">با کدام برنامه باز شود؟</p>
            <div class="app-list">
                <div class="app-btn" onclick="openApp('v2rayng')"><span>v2rayNG</span><span class="app-icon">⚡</span></div>
                <div class="app-btn" onclick="openApp('hiddify')"><span>Hiddify</span><span class="app-icon">🦋</span></div>
                <div class="app-btn" onclick="openApp('v2raytun')"><span>v2rayTun</span><span class="app-icon">🛡️</span></div>
                <div class="app-btn" onclick="openApp('happ')"><span>Happ</span><span class="app-icon">🌐</span></div>
                <div class="app-btn" onclick="openApp('sub')"><span>آیفون / Universal</span><span class="app-icon">🍏</span></div>
            </div>
            <br>
            <button class="btn btn-s" style="background:#333; color:white" onclick="cm('appMod')">بستن</button>
        </div>
    </div>

    <div class="mod" id="qrm" onclick="if(event.target===this)cm('qrm')">
        <div class="mbox">
            <h3>اسکن کنید</h3><br>
            <div style="background:white; padding:10px; border-radius:10px; display:inline-block"><img id="qi" src="" width="180"></div>
            <br><br><button class="btn btn-s" style="background:#333; color:white" onclick="cm('qrm')">بستن</button>
        </div>
    </div>

    <div class="mod" id="cfm" onclick="if(event.target===this)cm('cfm')">
        <div class="mbox">
            <h3>کانفیگ‌ها</h3><br><div id="cl" style="text-align:left; max-height:300px; overflow-y:auto; font-size:12px">...</div><br>
            <button class="btn btn-s" style="background:#333; color:white" onclick="cm('cfm')">بستن</button>
        </div>
    </div>

    <div class="mod" id="cpm" onclick="if(event.target===this)cm('cpm')">
        <div class="mbox">
            <h3>کپی دستی</h3><p style="font-size:12px; color:#aaa; margin:10px 0">لینک را انتخاب و کپی کنید:</p>
            <input type="text" class="cin" id="cpi" readonly onclick="this.select()"><br><br>
            <button class="btn btn-s" style="background:#333; color:white" onclick="cm('cpm')">بستن</button>
        </div>
    </div>

    <script>
        var subUrl = '{{ subscription_url }}';
        var totStr = '{{ user.data_limit }}';
        var useStr = '{{ user.used_traffic }}';
        var expStr = '{{ user.expire }}';
        
        {% raw %}
        if (!subUrl || subUrl.indexOf('{{') !== -1) subUrl = window.location.href;
        document.getElementById('qi').src = 'https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=' + subUrl;

        var root = document.documentElement; var tb = document.getElementById('tBtn');
        if (localStorage.getItem('theme') === 'light') { root.classList.add('light'); tb.textContent = '☀️'; }
        tb.onclick = function() {
            if (root.classList.contains('light')) { root.classList.remove('light'); tb.textContent = '🌙'; localStorage.setItem('theme', 'dark'); }
            else { root.classList.add('light'); tb.textContent = '☀️'; localStorage.setItem('theme', 'light'); }
        };

        var tot = parseInt(totStr)||0; var use = parseInt(useStr)||0;
        var per = tot > 0 ? Math.min((use/tot)*100, 100) : 0;
        document.getElementById('pb').style.width = per+'%'; document.getElementById('pt').textContent = Math.round(per)+'%';
        if(per>85) document.getElementById('pb').style.background = '#ef4444';

        function fb(b) { 
            if(tot===0) return 'نامحدود'; if(b<=0) return '0 B'; 
            var u=['B','KB','MB','GB','TB']; var i=Math.floor(Math.log(b)/Math.log(1024)); 
            return parseFloat((b/Math.pow(1024,i)).toFixed(2))+' '+u[i]; 
        }
        
        document.getElementById('totDisp').textContent = fb(tot);
        document.getElementById('useDisp').textContent = fb(use);
        document.getElementById('rem').textContent = fb(tot-use);

        var ed = document.getElementById('ed');
        if(ed) {
            var r = expStr.trim();
            if(!r || r==='None' || r==='null' || r==='نامحدود') ed.innerText = 'نامحدود';
            else {
                try {
                    var d = new Date(r);
                    if(!isNaN(d.getTime())) {
                        var sh = d.toLocaleDateString('fa-IR');
                        var diff = Math.floor((d - new Date())/(1000*60*60*24));
                        var txt = diff<0 ? '(منقضی)' : (diff===0 ? '(امروز)' : '('+diff+' روز)');
                        var c = diff<0 ? '#ef4444' : (diff===0 ? '#f59e0b' : '#10b981');
                        ed.innerHTML = sh + '<br><span style="font-size:11px; opacity:0.8; color:'+c+'">' + txt + '</span>';
                    } else ed.innerText = r;
                } catch(e) { ed.innerText = r; }
            }
        }

        function hc(t) {
            if(!t || t.indexOf('{{') !== -1) t = subUrl;
            if(navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(t).then(st).catch(function(){fbc(t)});
            else fbc(t);
        }
        function fbc(t) {
            var h = document.getElementById('cph');
            h.style.display='block'; h.value=t; h.focus(); h.select(); h.setSelectionRange(0,99999);
            try { if(document.execCommand('copy')) st(); else omc(t); } catch(e){ omc(t); }
            h.style.display='none';
        }
        function omc(t) { document.getElementById('cpi').value = t; om('cpm'); }
        function st() { var t=document.getElementById('toast'); t.classList.add('sh'); setTimeout(function(){t.classList.remove('sh')},2000); }
        function om(i) { document.getElementById(i).style.display='flex'; }
        function cm(i) { document.getElementById(i).style.display='none'; }

        function openApp(app) {
            var t = subUrl; var n = document.title; var l = '';
            if(app === 'v2rayng') l = 'v2rayng://install-sub?url=' + encodeURIComponent(t) + '&name=' + encodeURIComponent(n);
            else if(app === 'hiddify') l = 'hiddify://install-sub?url=' + encodeURIComponent(t) + '&name=' + encodeURIComponent(n);
            else if(app === 'v2raytun') l = 'v2raytun://install-sub?url=' + encodeURIComponent(t) + '&name=' + encodeURIComponent(n);
            else if(app === 'happ') l = 'happ://install-sub?url=' + encodeURIComponent(t) + '&name=' + encodeURIComponent(n);
            else { try { var b = btoa(t); l = 'sub://' + b + '#' + encodeURIComponent(n); } catch(e) { l = t; } }
            window.location.href = l; setTimeout(function(){ cm('appMod'); }, 500);
        }

        function sc() {
            om('cfm'); var l=document.getElementById('cl'); l.innerHTML='...';
            fetch(window.location.pathname+'/links').then(function(r){return r.text()}).then(function(t){
                if(t){
                    l.innerHTML='<button class="btn btn-p" style="height:32px;font-size:12px;margin-bottom:10px;width:100%" onclick="hc(\''+t.replace(/\n/g,'\\n')+'\')">کپی همه</button>';
                    t.split('\n').forEach(function(x){
                        var z=x.trim();
                        if(z && (z.indexOf('vmess')===0 || z.indexOf('vless')===0 || z.indexOf('trojan')===0 || z.indexOf('ss://')===0)){
                            var n='Config'; if(z.indexOf('#')>-1) n=decodeURIComponent(z.split('#')[1]);
                            l.innerHTML+='<div style="background:rgba(255,255,255,0.1);padding:8px;border-radius:8px;margin-bottom:8px;display:flex;justify-content:space-between;align-items:center"><span>'+n+'</span><button class="btn btn-s" style="width:auto;height:24px;padding:0 10px;font-size:11px" onclick="hc(\''+z+'\')">کپی</button></div>';
                        }
                    });
                }
            }).catch(function(){l.innerHTML='خطا'});
        }

        var u=navigator.userAgent.toLowerCase();
        if(u.indexOf('android')>-1) document.getElementById('da').classList.add('rec');
        else if(u.indexOf('iphone')>-1||u.indexOf('ipad')>-1) document.getElementById('di').classList.add('rec');
        else if(u.indexOf('win')>-1) document.getElementById('dw').classList.add('rec');
        {% endraw %}
    </script>
</body>
</html>
EOF

# Fix Encoding
python3 -c "import sys; f='$TEMPLATE_FILE'; d=open(f,'rb').read(); open(f,'w',encoding='utf-8').write(d.decode('utf-8','ignore'))"

# Replacements
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