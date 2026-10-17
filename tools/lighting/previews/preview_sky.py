# Numpy port of resources/shaders/lockout_sky.gdshader for a preview (approximate: no tonemap/fog).
import numpy as np, matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
def ss(a,b,x):
    t=np.clip((x-a)/(b-a),0,1); return t*t*(3-2*t)
def mix(a,b,t): return a+(b-a)*t
def fract(x): return x-np.floor(x)
def hash21(p): return fract(np.sin(p[...,0]*127.1+p[...,1]*311.7)*43758.5453)
def vnoise(p):
    i=np.floor(p); f=p-i; u=f*f*(3-2*f)
    a=hash21(i); b=hash21(i+[1,0]); c=hash21(i+[0,1]); d=hash21(i+[1,1])
    return mix(mix(a,b,u[...,0]),mix(c,d,u[...,0]),u[...,1])
def rfbm(p):
    amp=.5; s=0
    for k in range(5):
        n=1-np.abs(vnoise(p)*2-1); s=s+amp*n*n; p=p*2.03+[1.7,9.2]; amp*=.5
    return s
def ridge(az,freq,seed,base,h):
    c=np.stack([np.cos(az),np.sin(az)],-1)*freq+seed; return h*(base+(1-base)*np.clip(rfbm(c)*1.5,0,1.5)**1.35)
def nrm(v): return v/np.linalg.norm(v,axis=-1,keepdims=True)
C=lambda *v: np.array(v)
zen,upp,hor,gnd=C(.075,.13,.24),C(.22,.33,.47),C(.66,.73,.80),C(.16,.18,.21)
far_rock,near_rock,snow=C(.36,.42,.49),C(.15,.17,.20),C(.875,.902,.918)
sun=nrm(C(-0.579,0.574,0.579)); sun_col=C(1,.95,.88); sun_e=2.0
def body(eye,d,rad,ca,cb,bands):
    d=d/np.linalg.norm(d); ang=np.arccos(np.clip(eye@d,-1,1))
    t=np.cross(d,[0,1,0]); t/=np.linalg.norm(t); b=np.cross(t,d)
    uv=np.stack([eye@t,eye@b],-1)/np.sin(rad); r2=(uv**2).sum(-1)
    n=t*uv[...,:1]+b*uv[...,1:]-d*np.sqrt(np.maximum(1-r2,0))[...,None]
    lit=ss(-.05,.25,n@sun)
    pat=(.5+.5*np.sin((uv[...,1]+.18*uv[...,0])*17+vnoise(uv*5)*2.5)) if bands else vnoise(uv*7)*.6+vnoise(uv*19)*.4
    alb=mix(cb,ca,pat[...,None]); rim=np.clip(np.sqrt(r2),0,1)**6
    rgb=alb*(.08+.92*lit)[...,None]+C(.55,.65,.8)*(rim*.25*lit)[...,None]
    cov=(1-ss(.96,1,np.sqrt(r2)))*(ang<=rad*1.04); return rgb,cov
def sky(eye):
    e=eye[...,1]
    col=mix(hor,upp,ss(0,.25,e)[...,None]); col=mix(col,zen,ss(.25,.9,e)[...,None])
    col=np.where((e<0)[...,None],mix(hor,gnd,ss(0,-.3,e)[...,None]),col)
    sd=np.linalg.norm(eye-sun,axis=-1); disk=1-ss(.012*.9,.012*1.1,sd)
    col=col+sun_col*sun_e*disk[...,None]*8+sun_col*(np.maximum(eye@sun,0)**48*.35)[...,None]
    bh=ss(0,.3,e)[...,None]
    prgb,pc=body(eye,C(.40,.375,-.836),.13,C(.76,.70,.60),C(.55,.45,.36),True)
    col=mix(col,mix(col,prgb,.85*bh+.15),pc[...,None])
    mrgb,mc=body(eye,C(-.78,.47,-.42),.022,C(.62,.62,.6),C(.62,.62,.6)*.6,False)
    col=mix(col,mrgb,(mc[...,None]*bh))
    az=np.arctan2(eye[...,0],eye[...,2])
    hf=ridge(az,4,[7.3,1.1],.12,.2); hn=ridge(az,7,[-3.1,4.7],.08,.11)
    m=(e<hf)&(e>-.35)
    sl=hf*(.62+.2*vnoise(np.stack([az*30,e*30],-1)))
    rock=mix(far_rock,snow,ss(sl-.01,sl+.01,e)[...,None])
    eps=.004; slope=(ridge(az+eps,4,[7.3,1.1],.12,.2)-ridge(az-eps,4,[7.3,1.1],.12,.2))/(2*eps)
    v=np.stack([-slope*np.cos(az)+np.sin(az),slope*np.sin(az)+np.cos(az)],-1); v=v/np.linalg.norm(v,axis=-1,keepdims=True)
    sf=np.array([sun[0],sun[2]]); sf/=np.linalg.norm(sf); face=np.clip(v@sf,-1,1)
    rock=rock*(.75+.35*face)[...,None]
    col=np.where(m[...,None],mix(rock,hor,.3),col)
    m2=(e<hn)&(e>-.35); sl2=hn*(.6+.25*vnoise(np.stack([az*45,e*45],-1)))
    rock2=mix(near_rock,snow*.9,ss(sl2-.008,sl2+.008,e)[...,None])
    col=np.where(m2[...,None],mix(rock2,hor,.45*.45),col)
    col=mix(col,hor*.8,(ss(-.05,-.35,e)*.6)[...,None]); return col
def aces(x):
    a,b,c,d,e=2.51,.03,2.43,.59,.14; return np.clip((x*(a*x+b))/(x*(c*x+d)+e),0,1)
# panorama: azimuth from north clockwise, elevation -20..70 deg
W,H=1800,600
azd=np.linspace(-180,180,W); eld=np.linspace(70,-20,H)
A,E=np.meshgrid(np.radians(azd),np.radians(eld))
eye=np.stack([np.sin(A)*np.cos(E),np.sin(E),-np.cos(A)*np.cos(E)],-1)
img=aces(sky(eye)*1.0)**(1/2.2)
fig,ax=plt.subplots(figsize=(18,6.4))
ax.imshow(img,extent=[-180,180,-20,70],aspect="auto")
for a,l in [(-180,"S"),(-90,"W"),(0,"N (-Z)"),(90,"E"),(180,"S")]: ax.axvline(a,color="w",lw=.4,alpha=.4); ax.text(a+1,66,l,color="w")
ax.set_xlabel("azimuth (deg, clockwise from north)"); ax.set_ylabel("elevation (deg)")
ax.set_title("Lockout sky shader preview (numpy port, ACES-ish approx; no fog/tonemap exactness) - sun SW 35 deg, gas giant NE, moon NW")
fig.savefig("/workspace/lighting/lockout_sky_preview.png",dpi=90,bbox_inches="tight"); print("ok")
