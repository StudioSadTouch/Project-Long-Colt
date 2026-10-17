# Top-down fixture plot + crude practical-light coverage on covered floors (no occlusion; sky/ambient excluded).
import ast, json, math, numpy as np, matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, Circle
R="/workspace/lc-lockout-lighting/"
src=open(R+"tools/lockout/build_lockout.py").read(); tree=ast.parse(src)
L={n.targets[0].id:ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and isinstance(n.targets[0],ast.Name) and n.targets[0].id in("P","RAMPS")}
P=L["P"]; fx=json.load(open(R+"tools/lighting/lockout_fixtures.json"))
SPEC={"fluoro":(2.2,5.5,65,"#cfe8ff","s"),"fluoro_long":(2.6,8,65,"#e8f4ff","s"),"sodium":(2.5,9,55,"#ff9a3c","o"),"work":(3.0,14,38,"#ffe0b0","^"),
      "work_shadowed":(6.0,16,38,"#ff3030","^"),"panel":(0.6,3.5,75,"#7fe8d0","D"),"beacon":(0,0,0,"#ff2010","*")}
def aim_dir(f):
    k,a,p=f["kind"],f["aim"],f["pos"]
    if k.startswith("fluoro"): return (0,-1,0)
    if a=="up": return (0,1,0)
    if k in("work","work_shadowed"): d=np.subtract(a,p); return d/np.linalg.norm(d)
    if k=="sodium": d=np.array([a[0],0,a[2]],float)*math.cos(math.radians(40)); d[1]=-math.sin(math.radians(40)); return d
    if k=="panel": return np.array(a,float)
    return None
def lux(pt):
    s=0
    for f in fx["fixtures"]:
        e,rng,ang,_,_=SPEC[f["kind"]]
        if e==0: continue
        v=np.subtract(pt,f["pos"]); d=np.linalg.norm(v)
        if d>rng or d<1e-3: continue
        if pt[1]>f["pos"][1]: continue
        ad=aim_dir(f); c=np.dot(v/d,ad)
        if c<math.cos(math.radians(ang)): continue
        # Godot-like attenuation: (1-(d/r)^4)^2 / d^2 style falloff, normal = +Y floor
        att=max(0,1-(d/rng)**4)**2/max(d*d,0.25); s+=e*att*max(0,-v[1]/d)
    return s
# covered floors (ceiling above within ~4.2 m): name -> ceiling underside
COVERED={"BottomMid (under Top Mid)":(-8,8,-8,8,0),"Sword hall (under BR1 link)":(-10,-8,-4,0,0),
 "Sword room (under BR Bridge)":(-14,-8,-11.25,-8.75,2),"Green Hall (under Bottom Blue)":(-3,3,14,19.4,0),
 "Bottom Blue (under Top Blue)":(-6,6,14,19.4,3),"Left Mag (under Top Blue)":(-6,-3,12,16,6),"Right Mag (under Top Blue)":(3,6,12,16,6),
 "BR1 (under BR2)":(-21,-13,-4,3,4.5),"BR2 (under BR3)":(-21,-13,-5,1,7.5),"S1 (under S2)":(13,21,-6,-1,4.5),"S2 (under S3)":(13,21,-7,-3,7.5)}
fig,ax=plt.subplots(figsize=(13,13)); ax.set_facecolor("#1b1d1f")
report=[]
for n,cx,cz,sx,sz,top,t,g in sorted(P,key=lambda p:p[5]):
    if g in("Parapet","Wall"):
        ax.add_patch(Rectangle((cx-sx/2,cz-sz/2),sx,sz,fc="#6e8191",ec="none",alpha=.9)); continue
    ax.add_patch(Rectangle((cx-sx/2,cz-sz/2),sx,sz,fc=plt.cm.Blues(0.25+top/16),ec="#0d0f12",lw=.6,alpha=.55))
for n,(x0,x1,z0,z1,top) in COVERED.items():
    xs=np.linspace(x0+.4,x1-.4,max(3,int((x1-x0)*2))); zs=np.linspace(z0+.4,z1-.4,max(3,int((z1-z0)*2)))
    vals=np.array([[lux((x,top,z)) for x in xs] for z in zs])
    ax.imshow(vals,extent=[xs[0],xs[-1],zs[-1],zs[0]],cmap="inferno",vmin=0,vmax=0.5,alpha=.8,zorder=2)
    ax.add_patch(Rectangle((x0,z0),x1-x0,z1-z0,fill=False,ec="#ffd27f",lw=1.2,ls="--",zorder=3))
    report.append((n,top,vals.min(),vals.mean(),(vals<0.02).mean()))
for f in fx["fixtures"]:
    e,rng,ang,colr,mk=SPEC[f["kind"]]; x,y,z=f["pos"]
    ax.plot(x,z,mk,ms=11 if mk!="*" else 14,mfc=colr,mec="k",zorder=5)
    ax.text(x+.4,z-.4,f["name"],fontsize=6,color="w",zorder=6)
    if f["kind"]=="work_shadowed": ax.add_patch(Circle((x,z),1.0,fill=False,ec="#ff3030",lw=2,zorder=5))
s=fx["sun_to"]; ax.annotate("",xy=(-20,-17),xytext=(-20+6*s[0],-17+6*s[2]),arrowprops=dict(arrowstyle="->",color="#fff3d0",lw=3))
ax.text(-25,-19.5,"sun travel (from SW, 35 deg)",color="#fff3d0",fontsize=9)
for k,(e,rng,ang,colr,mk) in SPEC.items(): ax.plot([],[],mk,mfc=colr,mec="k",ms=10,label=k.replace("_"," "))
ax.plot([],[],ls="--",color="#ffd27f",label="covered floor: practical-light heat (no ambient)")
ax.legend(loc="lower left",fontsize=8,facecolor="#2a2d31",labelcolor="w")
ax.set_xlim(-28,28); ax.set_ylim(28,-22); ax.set_aspect("equal"); ax.grid(alpha=.15)
ax.set_xlabel("X (m, +X east)"); ax.set_ylabel("Z (m, +Z south; -Z north)")
ax.set_title(f"Lockout lighting: {len(fx['fixtures'])} fixtures (red ring = realtime-shadowed spot)")
fig.savefig("/workspace/lighting/lockout_fixture_plot.png",dpi=100,bbox_inches="tight")
for r in report: print(f"{r[0]:32s} y={r[1]:4.1f}  min={r[2]:.3f}  mean={r[3]:.3f}  dark(<0.02)={r[4]*100:.0f}%")
