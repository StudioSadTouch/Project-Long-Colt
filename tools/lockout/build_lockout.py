# Generates overhead + elevation diagrams and the primitive table for the Lockout greybox.
# ALL geometry is ESTIMATED from Bungie-era screenshots/design doc; see lockout_spec.md.
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, FancyArrow
# name, cx, cz, sx(width X), sz(depth Z), top_y, thickness, group
P = [
 ("BotMid_Floor",      0,   0, 16, 16, 0.0, 0.5, "Center"),
 ("TopMid_Deck",       0,   0, 16, 16, 4.5, 0.5, "Center"),
 ("GreenHall_Floor",   0,  15,  6, 14, 0.0, 0.5, "Blue/Lift"),
 ("BottomBlue_Ledge",  0,  17, 12,  6, 2.5, 0.5, "Blue/Lift"),
 ("BlueRamp",          0, 10.5, 4,  7, 3.5, 0.4, "Blue/Lift"),   # sloped 2.5->4.5
 ("LeftMag",          -4.5,14,  3,  4, 6.0, 0.5, "Blue/Lift"),
 ("RightMag",          4.5,14,  3,  4, 6.0, 0.5, "Blue/Lift"),
 ("TopBlue_Deck",      0,  18, 12,  8, 9.0, 0.5, "Blue/Lift"),
 ("BlueLift_Pad",      0,  21,  3,  3, 0.0, 0.1, "Blue/Lift"),
 ("S1_Floor",         16,  -1, 10, 10, 4.5, 0.5, "Sniper"),
 ("S2_Floor",         17,  -4,  8,  6, 7.5, 0.5, "Sniper"),
 ("S3_SnipeDeck",     16,  -6, 10,  6,10.5, 0.5, "Sniper"),
 ("SnipeRamp",        21.5, 0,  2.5,10, 9.0, 0.4, "Sniper"),     # sloped 7.5->10.5
 ("Elbow_South",      12,  19, 10, 2.5, 2.5, 0.4, "Elbow"),
 ("Elbow_North",      16,  12, 2.5,12, 3.2, 0.4, "Elbow"),       # sloped 2.5->3.9
 ("BR1_Floor",       -16,   1, 10, 10, 4.5, 0.5, "BR"),
 ("BR2_Floor",       -17,  -1,  8,  8, 7.5, 0.5, "BR"),
 ("BR3_Roof",        -17,  -3,  8,  8,10.5, 0.5, "BR"),
 ("OpenRamp",        -22.5, 4,  2.5,12, 2.25,0.4, "BR"),         # sloped 0->4.5
 ("BR_Bridge",       -10, -10, 10, 2.5, 7.5, 0.4, "BR"),
 ("Sword_Room",      -11, -12,  6,  6, 2.0, 0.5, "Library/Sword"),
 ("Library_Floor",    -1, -14, 12,  8, 7.5, 0.5, "Library/Sword"),
 ("S1_TopMid_Link",   10.5, 0,  5,  4, 4.5, 0.5, "Sniper"),
 ("BR1_TopMid_Link", -10.5, 2,  5,  4, 4.5, 0.5, "BR"),
]
def col(y):
    import matplotlib.cm as cm
    return cm.viridis(min(max((y+0.5)/11.5,0),1))
fig, ax = plt.subplots(figsize=(13,13))
for n,cx,cz,sx,sz,y,t,g in sorted(P,key=lambda p:p[5]):
    ax.add_patch(Rectangle((cx-sx/2,cz-sz/2),sx,sz,fc=col(y),ec="k",alpha=0.75,lw=1))
    ax.text(cx,cz,f"{n}\ny={y}",ha="center",va="center",fontsize=7,color="white" if y<6 else "black",weight="bold")
# connections (arrows)
C=[((0,14),(0,7.5),"Blue ramp"),((6,19),(16,19),"Elbow"),((16,18),(16,6),"Elbow->S1 jump"),
   ((0,21),(0,16),"Grav lift up to Top Blue"),((-22.5,10),(-22.5,-2),"Open ramp"),((21.5,5),(21.5,-5),"Snipe ramp"),
   ((-15,-10),(-5,-10),"BR bridge"),((-1,-10),(-1,-7.5),"Library drop")]
for a,b,l in C:
    ax.annotate("",xy=b,xytext=a,arrowprops=dict(arrowstyle="->",color="red",lw=2))
    ax.text((a[0]+b[0])/2+0.6,(a[1]+b[1])/2,l,color="red",fontsize=7)
W=[(0,0.0,"Shotgun? (BotMid)","s"),(16,-6,"Sniper (S3)","*"),(-11,-12,"Energy Sword","D"),(0,18,"BR + 2 Magnums (Top Blue)","^"),
   (-17,-3,"BR (BR tower)","^"),(0,15,"Shotgun+SMG (Green/Bottom Blue)","s")]
for x,z,l,m in W:
    ax.plot(x,z,m,ms=12,mfc="orange",mec="k"); ax.text(x+0.8,z+1.2,l,fontsize=7,color="darkorange",weight="bold")
S=[(0,20),(-18,4),(18,2),(-2,-16),(0,-4),(12,19),(-11,-12),(16,-4)]
for x,z in S: ax.plot(x,z,"o",ms=7,mfc="cyan",mec="k")
ax.plot([],[],"o",mfc="cyan",mec="k",label="Suggested FFA spawn (estimated)")
ax.plot([],[],"*",mfc="orange",mec="k",label="Weapon (sourced item, estimated position)")
ax.legend(loc="lower left",fontsize=8)
ax.set_xlim(-28,28); ax.set_ylim(28,-22)  # +Z down the page = south
ax.set_xticks(range(-28,29,2),minor=True); ax.set_yticks(range(-22,29,2),minor=True)
ax.grid(which="both",alpha=0.3); ax.set_aspect("equal")
ax.set_xlabel("X (m, +X = east)"); ax.set_ylabel("Z (m, +Z = south; Godot -Z = north)")
ax.arrow(23,-17,0,-3,width=0.3,color="k"); ax.text(23.6,-19,"N (-Z)",fontsize=10)
sm=plt.cm.ScalarMappable(cmap="viridis",norm=plt.Normalize(-0.5,11)); fig.colorbar(sm,ax=ax,shrink=0.5,label="Floor top height Y (m)")
ax.set_title("Lockout (Halo 2, 2004) greybox — overhead, ESTIMATED meters\nOrigin = centre of Top Mid at ground (Bottom Mid floor); 1 grid = 2 m")
fig.savefig("/workspace/lockout/lockout_overhead.png",dpi=110,bbox_inches="tight")
# elevation (looking north, X vs Y)
fig,ax=plt.subplots(figsize=(14,6))
for n,cx,cz,sx,sz,y,t,g in P:
    ax.add_patch(Rectangle((cx-sx/2,y-t),sx,t,fc=col(y),ec="k",alpha=0.7)); ax.text(cx,y+0.2,n,fontsize=6,ha="center")
ax.add_patch(Rectangle((-0.4,y:=0),0.8,2.1,fc="red")); ax.text(0.6,1,"Spartan 2.1 m",fontsize=7,color="red")
ax.set_xlim(-26,26); ax.set_ylim(-1,13); ax.grid(alpha=0.3); ax.set_aspect("equal")
ax.set_xlabel("X (m, east)"); ax.set_ylabel("Y (m)"); ax.set_title("Side elevation looking north (all Z collapsed) — ESTIMATED")
fig.savefig("/workspace/lockout/lockout_elevation.png",dpi=110,bbox_inches="tight")
# table
print("| Node | Group | Center (x, y, z) | Size (x, y, z) | Notes |\n|---|---|---|---|---|")
for n,cx,cz,sx,sz,y,t,g in P:
    note="SLOPED: rotate to match rise in connection table" if "Ramp" in n or "Elbow_North" in n else ""
    print(f"| {n} | {g} | ({cx}, {y-t/2:.2f}, {cz}) | ({sx}, {t}, {sz}) | {note} |")
