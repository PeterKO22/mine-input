#!/usr/bin/env python3
# mine-input 交互设计线框图生成器（可复现：改这里 → 重跑 → 重新导入 Figma）
# 用法: python3 generate_svg.py   输出: ./svg/*.svg
import os, html

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "svg")
os.makedirs(OUT, exist_ok=True)

INK="#111827"; MUT="#6B7280"; LINE="#E5E7EB"; BRD="#9CA3AF"; SOFT="#F3F4F6"
ACC="#2563EB"; ACCS="#EFF6FF"; WARN="#DC2626"; OK="#059669"; OKS="#ECFDF5"; WARNS="#FEF2F2"
FONT="'PingFang SC','Hiragino Sans GB','Noto Sans SC',sans-serif"

def esc(s): return html.escape(str(s), quote=True)
def tw(s, size):  # 文本宽度估算
    return sum(size if ord(c) > 0x2E80 else size*0.58 for c in str(s))

def rect(x,y,w,h,r=10,fill="#FFFFFF",stroke=BRD,sw=1,extra=""):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}" {extra}/>'
def text(x,y,s,size=14,fill=INK,weight=400,anchor="start",extra=""):
    return f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" fill="{fill}" font-weight="{weight}" text-anchor="{anchor}" {extra}>{esc(s)}</text>'
def line(x1,y1,x2,y2,stroke=LINE,sw=1,dash=None):
    d=f' stroke-dasharray="{dash}"' if dash else ''
    return f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke}" stroke-width="{sw}"{d}/>'
def arrow(x1,y1,x2,y2,stroke=BRD,sw=1.5):
    return line(x1,y1,x2,y2,stroke,sw)+f'<polygon points="{x2},{y2} {x2-7},{y2-4} {x2-7},{y2+4}" fill="{stroke}"/>'
def chip(x,y,label,fill=SOFT,fg=INK,size=12,h=26,stroke="none",padx=10):
    w=tw(label,size)+padx*2
    return rect(x,y,w,h,h/2,fill,stroke,1)+text(x+w/2,y+h/2+size*0.36,label,size,fg,500,"middle"), w
def toggle(x,y,on=True):
    fill=ACC if on else "#D1D5DB"
    kx=x+20 if on else x+2
    return rect(x,y,40,22,11,fill,"none")+f'<circle cx="{kx+9}" cy="{y+11}" r="8" fill="#FFFFFF"/>'
def artboard(name,w,h,title,sub,inner):
    svg=(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
         f'<rect width="{w}" height="{h}" fill="#FFFFFF"/>' +
         rect(0,0,w,4,0,ACC,"none") +
         text(28,48,title,22,INK,700)+text(28,72,sub,13,MUT) + inner + '</svg>')
    with open(os.path.join(OUT,name),"w",encoding="utf-8") as f: f.write(svg)
    print("✓",name)

# ────────────────────────── macOS ──────────────────────────

def m1():
    # 候选条 · 五笔86+拼音混合 + AI 智能列
    W,H=760,260; o=[]
    o.append(rect(28,100,704,132,16,"#FFFFFF",BRD,1.5))
    # 输入行
    o.append(chip(48,116,"五笔·拼音混合",ACCS,ACC,12,24)[0])
    o.append(chip(176,116,"简",SOFT,INK,12,24)[0])
    o.append(chip(206,116,"中",SOFT,INK,12,24)[0])
    o.append(text(48,168,"kwwl",26,INK,600))
    o.append(line(48,176,148,176,ACC,2))
    o.append(text(160,168,"｜",22,"#D1D5DB"))
    # 候选 chips
    cands=[("1","路"),("2","踢"),("3","嘴"),("4","踩")]
    x=176
    for n,t in cands:
        w=tw(t,20)+42
        o.append(rect(x,142,w,42,8,SOFT,LINE))
        o.append(text(x+10,169,n,12,MUT))
        o.append(text(x+26,171,t,20,INK,500))
        x+=w+8
    o.append(line(x+4,142,x+4,184,LINE))
    o.append(text(x+16,158,"拼音",11,MUT))
    o.append(text(x+16,178,"5 口吻",15,INK,400))
    o.append(text(x+110,178,"6 叩问",15,INK,400))
    # AI 列
    o.append(rect(560,112,152,108,12,ACCS,ACC,1))
    o.append(text(574,136,"AI 智能候选",12,ACC,600))
    o.append(text(574,160,"帮我把这份",13,INK))
    o.append(text(574,180,"报告摘要…",13,INK))
    o.append(text(574,204,"⌥↑ 重排 · 异步",10,MUT))
    # 底部提示
    o.append(text(48,252,"↑↓ 翻页 · Shift 切换中英 · 五笔编码提示: kwwl →「路」· 拼音候选自动前移(无五笔命中时)",12,MUT))
    artboard("M1-候选条-混合输入.svg",W,H,"M1 · 候选条（macOS）","五笔86 + 拼音混合免切换 · AI 智能列异步不阻塞","".join(o))

def m2():
    W,H=760,300; o=[]
    o.append(rect(28,100,704,120,16,"#FFFFFF",BRD,1.5))
    # mic + 波形
    o.append(f'<circle cx="84" cy="160" r="26" fill="{ACCS}" stroke="{ACC}" stroke-width="1.5"/>')
    o.append(f'<circle cx="84" cy="160" r="34" fill="none" stroke="{ACC}" stroke-width="1" stroke-dasharray="3,4" opacity="0.7"/>')
    o.append(text(84,168,"🎙",22,INK,400,"middle"))
    import math
    for i in range(22):
        h=8+abs(math.sin(i*0.9))*34
        o.append(rect(132+i*12,160-h/2,6,h,3,ACC if i<15 else "#BFDBFE","none"))
    o.append(text(132,132,"松开上屏 · Esc 取消 · 右⌘ 按住中",11,MUT))
    # 转写
    o.append(rect(416,122,296,76,10,SOFT,LINE))
    o.append(text(430,148,"帮我把这份报告的摘要",15,INK))
    o.append(text(430,172,"整理成三条要点｜",15,INK))
    o.append(chip(430,182,"离线识别",OKS,OK,10,18)[0])
    # 状态变化条
    o.append(text(48,248,"状态机：idle →(按下) listening →(松开) transcribing → 标点+热词 → 上屏",12,MUT))
    o.append(rect(28,262,340,26,13,WARNS,WARN,1))
    o.append(text(48,279,"低置信兜底：不瞎猜，提示重说",12,WARN,500))
    artboard("M2-PTT语音听写.svg",W,H,"M2 · PTT 语音听写态（macOS）","按住右⌘ 听、松开上屏 · 音频不落盘 · 全程离线","".join(o))

def m3():
    W,H=620,470; o=[]
    o.append(rect(28,100,564,330,16,"#FFFFFF",BRD,1.5))
    o.append(text(52,134,"动态提词器",18,INK,700))
    c,_=chip(176,116,"⌥Esc",SOFT,MUT,11,22)
    o.append(c)
    c,w=chip(388,114,"语音进行中 · 实时刷新",ACCS,ACC,11,24)
    o.append(c)
    # 上下文条
    o.append(rect(52,152,516,44,10,SOFT,LINE))
    o.append(text(66,172,"上下文：微信 · 屏幕摘要「项目排期评审」· 最近输入「下周三前完成」",12,MUT))
    o.append(text(66,190,"来自：C1 屏幕OCR + 语音转写（本机/Hub 拼图）",10,MUT))
    # 建议列表
    suggs=[("把排期风险单独列一节，标注负责人","⏎ 上屏"),("补充：测试窗口建议留出两天缓冲","⏎ 上屏"),("结尾加一句：请各位周五前反馈","⏎ 上屏")]
    y=210
    for s,act in suggs:
        o.append(rect(52,y,516,44,10,"#FFFFFF",LINE))
        o.append(text(68,y+27,s,14,INK))
        o.append(text(536,y+27,act,11,MUT,400,"end"))
        y+=52
    # streaming 行
    o.append(rect(52,y,516,44,10,ACCS,ACC,1))
    o.append(text(68,y+27,"另外建议同步一份会议纪要给…",14,ACC))
    o.append(text(536,y+27,"●●● 生成中",11,ACC,500,"end"))
    # 底部控制
    o.append(text(52,408,"↑↓ 选择 · Tab/⏎ 采纳 · Esc 关闭",12,MUT))
    o.append(text(340,408,"跟随语音实时刷新",12,INK))
    o.append(toggle(520,394,True))
    o.append(text(28,452,"交互约束：只建议不上屏、不抢焦点；采纳需要显式按键",12,MUT))
    artboard("M3-动态提词器.svg",W,H,"M3 · 动态提词器面板（macOS）","⌥Esc 唤起 · 语音中随转写实时刷新后续建议","".join(o))

def settings_window(o, sidebar_sel, title, content_fn):
    o.append(rect(28,96,1224,672,14,"#FFFFFF",BRD,1.5))
    o.append(rect(28,96,236,672,14,SOFT,"none"))
    items=["通用","输入方案","自适应学习","采集与上下文","AI 与同步","隐私与数据","关于"]
    y=140
    for i,it in enumerate(items):
        sel=(i==sidebar_sel)
        if sel: o.append(rect(44,y-22,204,36,8,"#FFFFFF",LINE))
        o.append(rect(58,y-8,14,14,4,ACC if sel else "#D1D5DB","none"))
        o.append(text(84,y+3,it,14,INK if sel else MUT,600 if sel else 400))
        y+=48
    o.append(text(300,142,title,20,INK,700))
    o.append(line(300,158,1228,158,LINE))
    content_fn(o)

def sec(o,y,label):
    o.append(text(300,y,label,13,MUT,600))
def row_toggle(o,y,label,desc,on):
    o.append(text(300,y,label,15,INK,500))
    if desc: o.append(text(300,y+20,desc,12,MUT))
    o.append(toggle(1186,y-16,on))

def m4():
    o=[]
    def c(o):
        sec(o,196,"上屏行为")
        row_toggle(o,232,"四码自动上屏","打满 4 码无重码时直接上屏",True)
        row_toggle(o,292,"空码顶字上屏","继续输入空码时上屏首选",False)
        sec(o,372,"候选")
        o.append(text(300,404,"候选个数",15,INK,500)); o.append(text(1186,404,"8",13,MUT,400,"end"))
        o.append(rect(300,418,886,6,3,LINE,"none")); o.append(rect(300,418,620,6,3,ACC,"none"))
        o.append(f'<circle cx="920" cy="421" r="9" fill="{ACC}"/>')
        sec(o,472,"热键（按住即说 / 提词器）")
        o.append(text(300,504,"PTT 语音键",15,INK,500))
        o.append(rect(1082,486,104,30,8,SOFT,LINE)); o.append(text(1134,506,"右 ⌘",13,INK,500,"middle"))
        o.append(rect(1196,486,30,30,8,"#FFFFFF",BRD)); o.append(text(1211,506,"⏺",12,ACC,500,"middle"))
        o.append(text(300,528,"松开上屏 · 可改为组合键（个别 app 会吞单修饰键）",12,MUT))
        o.append(text(300,568,"提词器快捷键",15,INK,500))
        o.append(rect(1082,550,104,30,8,SOFT,LINE)); o.append(text(1134,570,"⌥ Esc",13,INK,500,"middle"))
        sec(o,628,"外观")
        o.append(text(300,660,"候选框主题",15,INK,500))
        o.append(rect(1042,642,186,30,8,"#FFFFFF",BRD)); o.append(text(1058,662,"跟随系统",13,INK)); o.append(text(1212,662,"▾",12,MUT))
    settings_window(o,0,"通用",c)
    artboard("M4-设置-通用.svg",1280,840,"M4 · 设置 — 通用（macOS）","上屏行为 / 候选 / 热键 / 外观","".join(o))

def m5():
    o=[]
    def card(y,lv,name,desc,on,extra_btn=None,locked=False):
        o.append(rect(300,y,928,120,12,"#FFFFFF",LINE))
        c,w=chip(320,y+18,lv,ACCS,ACC,11,22); o.append(c)
        o.append(text(320+w+12,y+34,name,16,INK,600))
        o.append(text(320,y+66,desc,13,MUT))
        if locked:
            o.append(rect(1130,y+18,76,26,13,SOFT,MUT,1)); o.append(text(1168,y+35,"常开",11,MUT,500,"middle"))
        else:
            o.append(toggle(1166,y+18,on))
        if extra_btn:
            o.append(rect(320,y+82,150,26,13,"#FFFFFF",BRD)); o.append(text(395,y+99,extra_btn,11,INK,500,"middle"))
    def c(o):
        card(180,"L1","词频与自动造词","每次上屏更新权重、自动组词；打过的词组下次直达",True,"重置 L1 数据")
        card(316,"L2","习惯画像与调参建议","统计简拼率/翻页深度/回改率，只出建议不自动改",True,"查看习惯报告 →")
        card(452,"L3","个人语料与热词","上屏文本留存（可选）→ 自动抽高频专名喂语音热词",False,"编辑热词表 (42 条)")
        o.append(rect(300,596,928,52,12,WARNS,WARN,1))
        o.append(text(320,628,"一键学习数据重置：清空词典 + 画像 + 语料，回到出厂手感",13,WARN,500))
        o.append(rect(1064,608,144,28,14,"#FFFFFF",WARN)); o.append(text(1136,627,"学习数据重置…",12,WARN,500,"middle"))
        o.append(text(300,688,"同步：L1-L3 数据经 Hub 在 MacBook ↔ Android 间自动同步（最终一致，分钟级）",12,MUT))
    settings_window(o,2,"自适应学习",c)
    artboard("M5-设置-自适应学习.svg",1280,840,"M5 · 设置 — 自适应学习（macOS）","L1 词频 / L2 画像 / L3 语料·热词 · 全端同步","".join(o))

def m6():
    o=[]
    def c(o):
        o.append(rect(300,180,928,56,12,ACCS,ACC,1))
        o.append(text(320,206,"C0 · 基础上下文",13,ACC,600))
        o.append(text(320,226,"输入框前后文 · 当前应用名 · 最近输入历史（全端可用，常开）",12,MUT))
        o.append(rect(482,192,74,26,13,OKS,OK,1)); o.append(text(519,209,"常开",11,OK,500,"middle"))
        o.append(text(300,262,"剪贴板读取",14,INK,500)); o.append(toggle(1186,248,False))
        o.append(rect(300,300,928,176,12,"#FFFFFF",LINE))
        c1,_=chip(320,316,"C1",WARNS,WARN,11,22); o.append(c1)
        o.append(text(362,332,"屏幕 + 音频采集（按下键盘时触发）",14,INK,600))
        o.append(text(320,360,"屏幕快照 → OCR  ·  系统音频环回 → ASR 转写  ·  仅存于本机/你的 Hub",12,MUT))
        o.append(text(320,392,"采集频率（防抖）",12,INK))
        o.append(rect(460,386,420,6,3,LINE,"none")); o.append(rect(460,386,210,6,3,ACC,"none"))
        o.append(f'<circle cx="670" cy="389" r="9" fill="{ACC}"/>')
        o.append(text(900,392,"2s",12,MUT))
        o.append(text(320,430,"敏感应用黑名单：",12,INK))
        x=460
        for app in ["1Password","网上银行","+ 添加"]:
            c,w=chip(x,414,app,SOFT if app!="+ 添加" else "#FFFFFF",INK if app!="+ 添加" else ACC,11,26,BRD if app=="+ 添加" else "none")
            o.append(c); x+=w+10
        o.append(rect(300,492,928,56,12,OKS,OK,1))
        o.append(text(320,516,"安全输入自动暂停",13,OK,600))
        o.append(text(320,536,"密码框 / 支付场景（Secure Input 信号）自动停止一切采集 —— 不可关闭",12,MUT))
        o.append(rect(1130,504,76,26,13,"#FFFFFF",OK,1)); o.append(text(1168,521,"锁定",11,OK,500,"middle"))
        o.append(text(300,584,"保留策略",14,INK,500))
        o.append(rect(1042,566,186,30,8,"#FFFFFF",BRD)); o.append(text(1058,586,"30 天滚动",13,INK)); o.append(text(1212,586,"▾",12,MUT))
        o.append(rect(300,632,928,64,12,WARNS,WARN,1.5))
        o.append(text(320,658,"一键熔断：立即停止屏幕、音频、语料的一切采集",14,WARN,600))
        o.append(text(320,680,"开启期间状态条图标常显红色指示 · 交互日志保留但不再新增",11,WARN))
        o.append(rect(1052,646,154,36,18,WARN,"none")); o.append(text(1129,669,"停止一切采集",13,"#FFFFFF",600,"middle"))
    settings_window(o,3,"采集与上下文",c)
    artboard("M6-设置-采集与上下文.svg",1280,840,"M6 · 设置 — 采集与上下文（macOS）","C0/C1 分级 · 黑名单 · 安全输入暂停 · 一键熔断","".join(o))

def m7():
    o=[]
    def c(o):
        sec(o,196,"后端模式")
        modes=[("本地 Hub（推荐）",True),("远程 Hub",False),("混合：端侧兜底",False)]
        x=300
        for name,sel in modes:
            o.append(rect(x,212,280,44,10,ACCS if sel else "#FFFFFF",ACC if sel else BRD,1.5 if sel else 1))
            o.append(f'<circle cx="{x+22}" cy="234" r="7" fill="{"#FFFFFF" if sel else "#FFFFFF"}" stroke="{ACC if sel else BRD}" stroke-width="2"/>')
            if sel: o.append(f'<circle cx="{x+22}" cy="234" r="3.5" fill="{ACC}"/>')
            o.append(text(x+42,239,name,13,INK,600 if sel else 400))
            x+=304
        sec(o,292,"Hub 连接")
        o.append(text(300,326,"Hub 地址",14,INK,500))
        o.append(rect(560,306,420,32,8,"#FFFFFF",BRD)); o.append(text(576,327,"http://hub.local:8720",13,INK))
        o.append(rect(996,306,110,32,8,"#FFFFFF",BRD)); o.append(text(1051,327,"测试连接",13,INK,500,"middle"))
        c2,w=chip(1120,309,"已连接 · 32ms",OKS,OK,11,26); o.append(c2)
        sec(o,392,"模型")
        o.append(text(300,426,"Hub 侧模型",14,INK,500))
        o.append(rect(560,406,420,32,8,"#FFFFFF",BRD)); o.append(text(576,427,"Qwen2.5-7B-Instruct-Q4_K_M",13,INK)); o.append(text(962,427,"▾",12,MUT))
        o.append(text(300,462,"端侧兜底模型",14,INK,500))
        o.append(text(300,482,"断网时接管基础纠错/重排（≤2GB GGUF）",12,MUT))
        o.append(toggle(1186,448,True))
        sec(o,532,"同步")
        o.append(text(300,566,"自动同步",14,INK,500)); o.append(text(700,566,"上次同步：2 分钟前",12,MUT)); o.append(toggle(1186,552,True))
        o.append(rect(300,586,928,92,10,SOFT,LINE))
        o.append(text(320,612,"MacBook Pro",13,INK,600)); o.append(text(520,612,"本机 · 在线",12,OK))
        o.append(text(320,646,"Pixel 7",13,INK,600)); o.append(text(520,646,"Android · 38 分钟前同步",12,MUT))
        o.append(rect(1064,598,144,30,15,"#FFFFFF",BRD)); o.append(text(1136,618,"立即同步",13,INK,500,"middle"))
        c3,_=chip(300,700,"传输：TLS · 可选 E2E（Hub 零知识）",SOFT,MUT,11,26); o.append(c3)
    settings_window(o,4,"AI 与同步",c)
    artboard("M7-设置-AI与同步.svg",1280,840,"M7 · 设置 — AI 与同步（macOS）","本地/远程 Hub 可切换 · 模型版本化 · 设备状态","".join(o))

def m8():
    W,H=1280,840; o=[]
    o.append(text(28,120,"首次启动 · 知情同意",26,INK,700))
    o.append(text(28,148,"屏幕与音频采集属于高敏权限，逐项明示、逐项同意 —— 没有「默认全开」",13,MUT))
    # 步骤点
    for i,(lab,cur) in enumerate([("1 欢迎",False),("2 采集分级",True),("3 数据去向",False)]):
        x=28+i*220
        o.append(f'<circle cx="{x+10}" cy="184" r="10" fill="{ACC if cur else "#D1D5DB"}"/>')
        o.append(text(x+30,189,lab,13,INK if cur else MUT,600 if cur else 400))
        if i<2: o.append(line(x+120,184,x+200,184,LINE,2))
    # 三列卡片
    def cons(x,y,title,tag,tagfill,tagfg,lines,btn):
        o.append(rect(x,y,388,320,14,"#FFFFFF",BRD,1.5))
        o.append(text(x+24,y+40,title,17,INK,700))
        c,w=chip(x+24,y+56,tag,tagfill,tagfg,11,22); o.append(c)
        yy=y+112
        for ln in lines:
            o.append(text(x+24,yy,ln,12,MUT)); yy+=24
        if btn=="on":
            o.append(toggle(x+324,y+28,True)); o.append(text(x+24,y+288,"默认开启 · 可随时关",11,OK,500))
        elif btn=="off":
            o.append(toggle(x+324,y+28,False)); o.append(text(x+24,y+288,"默认关闭 · 明确同意后开启",11,WARN,500))
    cons(28,220,"C0 · 基础上下文","推荐",OKS,OK,["· 输入框前后文、当前应用名","· 最近输入历史（本机）","· 用途：候选排序、基础联想","· 数据：仅本机 + 你的 Hub"],"on")
    cons(446,220,"C1 · 屏幕 + 音频","高敏",WARNS,WARN,["· 按下键盘时屏幕快照 → OCR","· 系统音频转写（环境理解）","· 用途：上下文建议、动态提词","· 密码框自动暂停 · 一键熔断"],"off")
    cons(864,220,"数据去向","你的地盘",ACCS,ACC,["· 设备 ──TLS──▶ 你的 AI Hub","· Hub 在你自己家/服务器上","· 可选 E2E：Hub 也看不到明文","· 不经过任何第三方云","· 一键导出 / 一键清空"],"on")
    o.append(rect(28,576,1224,88,14,SOFT,LINE))
    o.append(text(52,610,"我已理解：mine-input 会记录我的输入与屏幕/音频上下文，数据仅存于我的设备与我的 Hub，",13,INK))
    o.append(text(52,634,"我可随时在「采集与上下文」中调整或熔断。",13,INK))
    o.append(rect(872,596,168,44,22,"#FFFFFF",BRD)); o.append(text(956,623,"仅使用基础功能",13,INK,500,"middle"))
    o.append(rect(1056,596,172,44,22,ACC,"none")); o.append(text(1142,623,"同意并继续",13,"#FFFFFF",600,"middle"))
    artboard("M8-首次启动-知情同意.svg",W,H,"M8 · 首次启动 — 知情同意流程（macOS）","逐项分级同意 · 默认只有 C0 开 · 高敏项必须显式勾选","".join(o))

def m9():
    W,H=1280,840; o=[]
    o.append(text(28,120,"习惯报告（L2 画像）",24,INK,700))
    o.append(text(28,146,"只建议、不自动改 —— 应用与否你决定",13,MUT))
    def kpi(x,y,v,lab,sub):
        o.append(rect(x,y,272,120,12,"#FFFFFF",LINE))
        o.append(text(x+24,y+56,v,32,INK,700))
        o.append(text(x+24,y+82,lab,13,MUT))
        o.append(text(x+24,y+104,sub,11,MUT))
    kpi(28,180,"34%","简拼使用率","近 30 天 · 上升 6%")
    kpi(324,180,"1.4","平均翻页深度","理想区间 1.0–1.8")
    kpi(620,180,"6%","回改率","低于上周 2%")
    kpi(916,180,"42","热词命中 / 日","L3 自动更新")
    # 高频词表
    o.append(rect(28,332,576,300,12,"#FFFFFF",LINE))
    o.append(text(52,364,"高频词 Top（五笔/拼音合并）",15,INK,600))
    rows=[("1","项目","五笔 rhkk","142 次"),("2","排期","五笔 rhkk?","98 次"),("3","风险","五笔 mqvb","77 次"),("4","对齐","拼音 duiqi","63 次"),("5","结论","五笔 xwng","51 次")]
    y=398
    for n,w,c,ct in rows:
        o.append(text(52,y,n,12,MUT)); o.append(text(84,y,w,14,INK,500)); o.append(text(220,y,c,12,MUT)); o.append(text(500,y,ct,12,MUT,400,"end"))
        o.append(line(52,y+14,580,y+14,LINE)); y+=44
    # 建议
    o.append(rect(628,332,624,300,12,"#FFFFFF",LINE))
    o.append(text(652,364,"调参建议",15,INK,600))
    adv=[("你常用简拼（34%），建议启用 h/f 模糊音","应用","忽略"),("「对齐」一词常打拼音，建议加入五笔自定义词","应用","忽略"),("翻页深度健康，候选数维持 8 不变","已默认","—")]
    y=392
    for a,b1,b2 in adv:
        o.append(rect(652,y,576,64,10,SOFT,LINE))
        o.append(text(672,y+26,a,13,INK))
        o.append(rect(1064,y+16,72,30,15,"#FFFFFF",BRD)); o.append(text(1100,y+36,b1,12,INK,500,"middle"))
        o.append(rect(1144,y+16,72,30,15,"#FFFFFF",BRD)); o.append(text(1180,y+36,b2,12,MUT,500,"middle"))
        y+=80
    o.append(rect(28,668,1224,64,12,SOFT,LINE))
    o.append(text(52,706,"学习数据：本机 + Hub 双备份 · 一键重置随时回到出厂手感 · 朋友账号数据互相隔离",13,MUT))
    artboard("M9-习惯报告.svg",W,H,"M9 · 习惯报告（macOS）","L2 画像可视化 · 建议一键应用/忽略","".join(o))

def m10():
    W,H=420,520; o=[]
    o.append(rect(28,100,364,380,14,"#FFFFFF",BRD,1.5))
    o.append(text(52,134,"mine-input",15,INK,700))
    c1,w1=chip(52,150,"采集：C1 开",WARNS,WARN,11,22); o.append(c1)
    c2,w2=chip(52+w1+8,150,"同步：正常",OKS,OK,11,22); o.append(c2)
    o.append(line(52,192,368,192,LINE))
    items=[("打开设置…","⌘,"),("立即同步",""),("提词器","⌥Esc"),("习惯报告","")]
    y=222
    for t,k in items:
        o.append(text(52,y,t,14,INK))
        if k: o.append(text(348,y,k,12,MUT,400,"end"))
        y+=40
    o.append(line(52,y-12,368,y-12,LINE))
    o.append(text(52,y+16,"停止一切采集",14,WARN,600))
    o.append(text(348,y+16,"⌥⌘X",12,WARN,400,"end"))
    y+=40
    o.append(text(52,y+16,"学习数据重置…",14,MUT))
    y+=40
    o.append(text(52,y+16,"关于 mine-input",14,MUT))
    o.append(text(28,502,"状态条图标随采集状态变色：灰=C0 · 蓝=C1 · 红=熔断中",12,MUT))
    artboard("M10-状态条菜单.svg",W,H,"M10 · 状态条菜单 + 一键熔断（macOS）","采集状态常显 · 熔断两级入口（菜单 + 设置页）","".join(o))

# ────────────────────────── Android ──────────────────────────

def phone(o, title_note=None):
    o.append(rect(28,96,390,740,28,"#FFFFFF",BRD,1.5))
    o.append(rect(28,96,390,740,28,"none","none"))
    # 状态栏
    o.append(text(52,126,"9:41",12,INK,600))
    o.append(text(394,126,"▲ ■ ■",11,MUT,400,"end"))

def a1():
    W,H=460,900; o=[]
    phone(o)
    # 聊天背景
    o.append(text(52,172,"微信 · 项目群",14,INK,600))
    o.append(rect(52,190,220,52,12,SOFT,"none")); o.append(text(66,212,"排期评审放在周三？",12,INK)); o.append(text(66,230,"记得带风险清单",11,MUT))
    o.append(rect(206,256,190,52,12,ACCS,"none")); o.append(text(220,278,"好的，我先写摘要",12,INK)); o.append(text(220,296,"kwwl",11,ACC))
    # 输入框
    o.append(rect(52,326,338,40,20,"#FFFFFF",BRD)); o.append(text(70,352,"kwwl",15,INK))
    # 候选条
    o.append(rect(28,374,390,52,0,SOFT,"none"))
    x=44
    for n,t in [("1","路"),("2","踢"),("3","嘴")]:
        c,w=chip(x,386,t,ACC if n=="1" else "#FFFFFF",("#FFFFFF" if n=="1" else INK),14,28,ACC if n=="1" else LINE)
        o.append(c); x+=w+8
    c,w=chip(x,386,"拼音 ▸ 口吻",ACCS,ACC,12,28); o.append(c); x+=w+8
    c,w=chip(x,386,"AI",ACCS,ACC,11,28); o.append(c)
    # 键盘
    rows=["qwertyuiop","asdfghjkl","zxcvbnm"]
    y=438
    for r in rows:
        kw=32; gap=4; x0=44+(10-len(r))*(kw+gap)/2
        for i,ch in enumerate(r):
            o.append(rect(x0+i*(kw+gap),y,kw,44,6,"#FFFFFF",LINE))
            o.append(text(x0+i*(kw+gap)+kw/2,y+28,ch,15,INK,400,"middle"))
        y+=52
    # 功能行
    o.append(rect(44,y,52,44,6,SOFT,LINE)); o.append(text(70,y+28,"?123",11,INK,400,"middle"))
    o.append(rect(100,y,44,44,6,SOFT,LINE)); o.append(text(122,y+28,"，",13,INK,400,"middle"))
    o.append(rect(148,y,140,44,6,"#FFFFFF",LINE)); o.append(text(218,y+28,"五笔 · 拼音 混合",11,MUT,400,"middle"))
    o.append(rect(292,y,44,44,6,SOFT,LINE)); o.append(text(314,y+28,"。",13,INK,400,"middle"))
    o.append(rect(340,y,44,44,6,SOFT,LINE)); o.append(text(362,y+28,"⏎",13,INK,400,"middle"))
    y+=52
    # PTT 大键 + 提词
    o.append(rect(44,y,236,52,26,ACC,"none"))
    o.append(text(162,y+33,"🎤  按住说话",15,"#FFFFFF",600,"middle"))
    o.append(rect(288,y,96,52,26,ACCS,ACC,1.5)); o.append(text(336,y+33,"提词 ⌥",13,ACC,600,"middle"))
    artboard("A1-Android键盘.svg",W,H,"A1 · Android 键盘 — 混合输入","五笔86+拼音免切换 · PTT 大键 · AI 候选","".join(o))

def a2():
    W,H=460,900; o=[]
    phone(o)
    o.append(text(52,172,"微信 · 项目群",14,INK,600))
    o.append(rect(52,190,220,52,12,SOFT,"none")); o.append(text(66,212,"排期评审放在周三？",12,INK))
    # 听写面板（键盘区替换）
    o.append(rect(28,374,390,430,0,ACCS,"none"))
    o.append(f'<circle cx="223" cy="440" r="34" fill="{ACC}"/>')
    o.append(text(223,450,"🎙",24,"#FFFFFF",400,"middle"))
    o.append(f'<circle cx="223" cy="440" r="46" fill="none" stroke="{ACC}" stroke-dasharray="3,5"/>')
    import math
    for i in range(24):
        h=8+abs(math.sin(i*0.8))*30
        o.append(rect(90+i*12,520-h/2,6,h,3,ACC if i<16 else "#BFDBFE","none"))
    o.append(rect(52,560,340,90,12,"#FFFFFF",LINE))
    o.append(text(68,590,"帮我把排期风险单独列",15,INK))
    o.append(text(68,616,"一节，标上负责人｜",15,INK))
    o.append(text(68,638,"离线识别 · 32ms/句",10,MUT))
    c,w=chip(52,666,"松开 上屏",ACC,"#FFFFFF",12,30); o.append(c)
    c,w=chip(52+w+10,666,"左滑取消",SOFT,MUT,12,30); o.append(c)
    c,w=chip(52+w*2+20,666,"Esc",SOFT,MUT,12,30); o.append(c)
    o.append(text(52,730,"转写实时滚动 · 提词随语音刷新（见 A3）",11,MUT))
    artboard("A2-Android语音听写.svg",W,H,"A2 · Android 语音听写态","长按 PTT · 实时滚动 · 松开上屏 · 音频不落盘","".join(o))

def a3():
    W,H=460,900; o=[]
    phone(o)
    o.append(text(52,172,"微信 · 项目群",14,INK,600))
    o.append(rect(52,190,340,86,12,ACCS,"none"))
    o.append(text(68,218,"（语音进行中）帮我把排期风险单独",13,INK))
    o.append(text(68,240,"列一节，标上负责人…",13,INK))
    # 提词浮层
    o.append(rect(40,296,380,300,16,"#FFFFFF",ACC,1.5))
    o.append(text(60,328,"提词器",15,INK,700))
    c,w=chip(140,312,"语音中 · 实时刷新",ACCS,ACC,10,22); o.append(c)
    o.append(text(60,352,"上下文：排期评审 · 风险清单",11,MUT))
    suggs=["建议补一句：测试窗口预留两天缓冲","每项风险标注负责人和截止日","结尾加：请周五前反馈意见"]
    y=370
    for s in suggs:
        o.append(rect(60,y,340,48,10,SOFT,"none"))
        o.append(text(76,y+22,s,12,INK))
        o.append(text(76,y+40,"点按采纳",10,ACC,500))
        y+=56
    o.append(rect(60,y,340,44,10,ACCS,ACC,1))
    o.append(text(76,y+28,"另外，会议纪要同步给…",12,ACC))
    o.append(text(372,y+28,"●●●",10,ACC,500,"end"))
    o.append(text(52,632,"浮层不抢焦点 · 采纳后自动收起",11,MUT))
    artboard("A3-Android提词浮层.svg",W,H,"A3 · Android 动态提词浮层","语音中建议实时刷新 · 点按采纳","".join(o))

def a4():
    W,H=460,900; o=[]
    phone(o)
    o.append(text(52,172,"mine-input 设置",18,INK,700))
    items=[("通用","",None),("输入方案","五笔86+拼音",None),("自适应学习","L1 L2 已开",None),("采集与上下文","C2 无障碍：关",False),("AI 与同步","本地 Hub · 已连接",None),("隐私与数据","",None),("关于","",None)]
    y=200
    for name,sub,tg in items:
        o.append(rect(44,y,372,60,10,"#FFFFFF",LINE))
        o.append(text(64,y+28,name,15,INK,500))
        if sub: o.append(text(64,y+48,sub,11,MUT))
        if tg is not None: o.append(toggle(356,y+19,tg))
        else: o.append(text(392,y+34,"›",16,MUT,400,"end"))
        y+=72
    o.append(text(52,740,"Android 特有：C2 读屏需开无障碍服务（侧载版自带说明）",11,MUT))
    artboard("A4-Android设置.svg",W,H,"A4 · Android 设置","与 macOS 同构 · 采集项 Android 上限如实标注","".join(o))

def a5():
    W,H=460,900; o=[]
    phone(o)
    o.append(text(52,172,"连接你的 AI Hub",18,INK,700))
    o.append(text(52,196,"习惯与数据只进你自己的服务器",12,MUT))
    o.append(rect(110,220,200,200,14,SOFT,LINE))
    o.append(text(210,330,"[ 扫码窗口 ]",13,MUT,400,"middle"))
    o.append(text(52,452,"或输入配对码",12,MUT))
    o.append(rect(52,466,356,44,10,"#FFFFFF",BRD)); o.append(text(72,494,"7F2A — 91C4 — 3D08",16,INK,600))
    o.append(rect(52,530,356,44,22,ACC,"none")); o.append(text(230,558,"配对并继续",14,"#FFFFFF",600,"middle"))
    o.append(line(52,610,408,610,LINE))
    o.append(text(52,640,"同意清单（与 macOS 同一份）",13,INK,600))
    chk=[("C0 基础上下文（推荐）",True),("C2 读屏上下文（无障碍服务）",False),("语音热词同步",True)]
    y=664
    for t,on in chk:
        o.append(rect(52,y,18,18,5,ACC if on else "#FFFFFF",ACC if on else BRD,1.5))
        if on: o.append(text(57,y+14,"✓",12,"#FFFFFF",700))
        o.append(text(82,y+14,t,12,INK))
        y+=36
    o.append(text(52,800,"随时可在设置中撤回任一项",11,MUT))
    artboard("A5-Android配对与同意.svg",W,H,"A5 · Android 首次配对 + 同意","扫码/配对码连 Hub · 同一隐私承诺","".join(o))

# ────────────────────────── 流程图 ──────────────────────────

def f1():
    W,H=1640,1060; o=[]
    def box(x,y,w,h,title,sub,fill="#FFFFFF",stroke=BRD,tfc=INK):
        o.append(rect(x,y,w,h,12,fill,stroke,1.5))
        o.append(text(x+w/2,y+30,title,15,tfc,600,"middle"))
        for i,ln in enumerate(str(sub).split("\n")):
            if ln: o.append(text(x+w/2,y+54+i*20,ln,11,MUT,400,"middle"))
    # 主线：onboarding
    box(40,120,220,80,"首次启动","安装 → 权限引导")
    box(320,120,220,80,"知情同意","C0/C1/C2 逐项选择")
    box(600,120,220,80,"配对 AI Hub","扫码 / 配对码")
    box(880,120,220,80,"就绪","默认仅 C0")
    o.append(arrow(260,160,320,160)); o.append(arrow(540,160,600,160)); o.append(arrow(820,160,880,160))
    # 三条输入通路
    box(40,320,300,110,"打字（混合输入）","librime 五笔86+拼音 · 免切换",ACCS,ACC)
    box(40,470,300,110,"语音（PTT）","VAD→SenseVoice→标点→热词",ACCS,ACC)
    box(40,620,300,110,"提词器","⌥Esc / 语音中自动刷新",ACCS,ACC)
    # 引擎
    box(420,320,300,190,"mine-input 客户端内核","候选生成 · 重排接口\n上下文引擎 C0/C1\n交互日志(本地 SQLite)")
    box(420,560,300,170,"自适应学习","L1 词频/造词\nL2 画像/建议\nL3 语料/热词")
    o.append(arrow(340,375,420,380)); o.append(arrow(340,525,420,430)); o.append(arrow(340,675,420,640))
    o.append(line(570,510,570,560,BRD,1.5))
    o.append(arrow(570,645,340,645,MUT,1))
    # Hub
    box(820,320,320,250,"AI Hub（自托管）","模型托管：重排/纠错/续写/提词\n交互记忆归集（跨端拼图）\n多用户分区（朋友隔离）\n部署：家里常驻 / VPS / 混合",WARNS,WARN)
    o.append(arrow(720,415,820,415)); o.append(arrow(720,645,820,520))
    o.append(arrow(820,480,720,480,ACC,1.5))
    # 同步环
    box(1220,320,340,110,"数据同步","词典/画像/热词/配置 · 分钟级一致",OKS,OK)
    box(1220,470,340,100,"建议下行","rescore/complete/suggest 流",OKS,OK)
    box(1220,610,340,100,"设备：MacBook ↔ Android","同一套习惯 · 同一份热词",OKS,OK)
    o.append(arrow(1140,380,1220,375)); o.append(arrow(1220,520,1140,500,ACC,1.5)); o.append(arrow(1220,375,1220,375))
    o.append(line(1390,430,1390,470,OK,1.5)); o.append(arrow(1390,570,1390,610,OK,1.5))
    # 熔断
    box(820,700,320,80,"隐私层：熔断/黑名单/安全输入暂停","一键停止一切采集 · 密码框自动停",WARNS,WARN)
    o.append(arrow(980,620,980,700,WARN,1.5))
    o.append(text(40,850,"图例：蓝=输入通路  红=Hub/高敏  绿=数据面  ·  所有 AI 调用异步，不阻塞按键上屏",12,MUT))
    artboard("F1-核心流程.svg",W,H,"F1 · 核心流程与数据流","onboarding → 输入通路 → 客户端内核 ⇄ AI Hub ⇄ 同步","".join(o))

for fn in (m1,m2,m3,m4,m5,m6,m7,m8,m9,m10,a1,a2,a3,a4,a5,f1):
    fn()
print("done:", len(os.listdir(OUT)), "files ->", OUT)
