"""Generate docs/architecture.png. Run: python3 -m pip install Pillow; python3 docs/diagram/draw_architecture.py

English labels avoid dependence on Korean fonts. Values describe the verified deployment before cleanup.
"""
from pathlib import Path
import math
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
W, H = 1800, 1180
SCALE = 2
im = Image.new('RGB', (W * SCALE, H * SCALE), '#f4f7fb')
d = ImageDraw.Draw(im)
FONT_DIR = Path('/System/Library/Fonts/Supplemental')

def font(size=24, bold=False):
    candidates = [FONT_DIR / ('Arial Bold.ttf' if bold else 'Arial.ttf'),
                  Path('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf' if bold else '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')]
    for p in candidates:
        if p.exists():
            return ImageFont.truetype(str(p), size * SCALE)
    raise RuntimeError('Install Arial or DejaVu Sans before rendering.')

def rect(box, fill, outline, width=2, radius=16):
    d.rounded_rectangle(tuple(int(v * SCALE) for v in box), radius=radius*SCALE,
                        fill=fill, outline=outline, width=width*SCALE)

def text(x, y, value, size=24, fill='#18283d', bold=False):
    d.text((x*SCALE, y*SCALE), value, font=font(size, bold), fill=fill)

def arrow(points, color='#1672cf', width=5, dashed=False):
    pts=[(x*SCALE,y*SCALE) for x,y in points]
    if dashed:
        for a,b in zip(pts,pts[1:]):
            length=math.dist(a,b)
            for i in range(0,math.ceil(length),24*SCALE):
                end=min(i+13*SCALE,length)
                d.line([(a[0]+(b[0]-a[0])*t/length,a[1]+(b[1]-a[1])*t/length) for t in (i,end)],fill=color,width=width*SCALE)
    else:
        d.line(pts,fill=color,width=width*SCALE,joint='curve')
    a,b=pts[-2:]
    angle=math.atan2(b[1]-a[1],b[0]-a[0]); size=17*SCALE
    d.polygon([b,(b[0]-size*math.cos(angle-.48),b[1]-size*math.sin(angle-.48)),(b[0]-size*math.cos(angle+.48),b[1]-size*math.sin(angle+.48))],fill=color)

text(60,40,'B3-1 | Public Nginx service on AWS',42,bold=True)
text(60,100,'Seoul  ap-northeast-2  /  AZ ap-northeast-2a  /  Project=B3-1',25,fill='#52647c')
# A notched VPC boundary keeps account-wide IAM outside the VPC.
vpc = [(415,170),(1045,170),(1045,315),(1740,315),(1740,980),(415,980)]
d.polygon([(x*SCALE,y*SCALE) for x,y in vpc], fill='#ffffff')
d.line([(x*SCALE,y*SCALE) for x,y in vpc+[vpc[0]]], fill='#57718e', width=3*SCALE, joint='curve')
text(445,194,'VPC  10.0.0.0/16',30,bold=True)
text(445,235,'b3-1-vpc',23,fill='#52647c')
rect((820,350,1695,920),'#edf7f0','#3f9360',3)
text(850,372,'Public Subnet  10.0.1.0/24',29,bold=True)
text(850,414,'b3-1-public-subnet  |  ap-northeast-2a',23,fill='#426e50')
rect((1010,485,1645,835),'#fff9ed','#d79422',3)
text(1038,507,'Security Group  b3-1-web-sg',27,bold=True)
text(1038,550,'Inbound: TCP 80  from 0.0.0.0/0',23)
text(1038,587,'Inbound: TCP 22  from 121.135.181.35/32',22)
rect((1070,650,1585,805),'#ffffff','#d79422',2)
text(1096,671,'EC2  |  Nginx  |  t3.micro',28,bold=True)
text(1096,714,'Amazon Linux 2023  |  gp3 8 GiB',23)
text(1096,752,'Auto public IPv4: 3.35.173.185',23)
rect((465,625,765,790),'#eef4ff','#5278b2',2)
text(488,646,'Route Table',27,bold=True)
text(488,688,'b3-1-public-rt',23)
text(488,734,'0.0.0.0/0 -> IGW',24,bold=True)
rect((455,350,750,505),'#ecf3ff','#1672cf',3)
text(480,372,'Internet Gateway',27,bold=True)
text(480,414,'b3-1-igw',25)
text(480,455,'Attached to VPC',21)
rect((55,350,345,505),'#ffffff','#1672cf',3)
text(80,372,'Internet / Users',28,bold=True)
text(80,415,'GET /health -> 200 OK',22)
text(80,455,'GET / -> Hello Cloud - B3-1',18)
# Packet ingress, then IGW to public EC2 via its SG.
arrow([(345,425),(455,425)])
text(355,380,'HTTP 80',19,fill='#1672cf',bold=True)
arrow([(750,457),(930,457),(930,725),(1070,725)])
text(787,476,'HTTP 80',22,fill='#1672cf',bold=True)
# Association/configuration, not an in-line network appliance.
arrow([(765,702),(820,702)],color='#64748b',width=3,dashed=True)
text(469,824,'Subnet association',22,fill='#64748b')
arrow([(600,625),(600,505)],color='#64748b',width=3,dashed=True)
text(467,555,'Default route',20,fill='#64748b')
rect((55,690,345,875),'#fff4e9','#bd6926',3)
text(80,713,'Administrator',28,bold=True)
text(80,757,'121.135.181.35/32',25)
text(80,803,'SSH key: b3-1-key',22)
arrow([(345,745),(395,745),(395,525),(540,525),(540,505)],color='#bd6926',width=5)
arrow([(600,350),(600,325),(1670,325),(1670,870),(1320,870),(1320,805)],color='#bd6926',width=5)
text(980,328,'SSH 22',22,fill='#a15318',bold=True)
text(463,914,'SSH 22 via Internet + IGW; key authentication',22,fill='#a15318',bold=True)
rect((1090,170,1695,310),'#f5f0ff','#825ab5',2)
text(1115,190,'IAM user  b3-1-operator (account-wide)',25,bold=True)
text(1115,232,'Console / CLI -> AWS APIs (HTTPS 443)',23)
text(1115,269,'Policy: B3-1-LeastPrivilege',22)
arrow([(1360,310),(1360,350)],color='#825ab5',width=4,dashed=True)
text(465,285,'IAM authorizes AWS resource operations',22,fill='#825ab5')
rect((55,1020,1740,1135),'#e8eef6','#c7d3e2',1)
text(80,1040,'Blue: HTTP service traffic    Orange: SSH administration    Dashed: configuration / API management',24,bold=True)
text(80,1084,'Verified deployment (2026-11-18); resources removed. Evidence: logs/. Billing review pending.',23)
# Render at final native resolution, keeping anti-aliased text and arrows.
im.resize((W,H),Image.Resampling.LANCZOS).save(ROOT/'docs'/'architecture.png')
print(f'{ROOT / "docs" / "architecture.png"}: {W} x {H} PNG')
