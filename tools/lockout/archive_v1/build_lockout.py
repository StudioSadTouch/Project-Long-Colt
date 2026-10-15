# Generates overhead + elevation diagrams and the primitive table for the Lockout greybox.
# ALL geometry is ESTIMATED from Bungie-era screenshots/design doc; see lockout_spec.md.
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, FancyArrow
# name, cx, cz, sx(width X), sz(depth Z), top_y, thickness, group
P = [
 # --- floors / decks (top_y = walk surface) ---
 ("BotMid_Floor",      0,   0, 16, 16, 0.0, 0.5, "Center"),
 ("TopMid_Deck",       0,   0, 16, 16, 4.5, 0.5, "Center"),
 ("GreenHall_Floor",   0,  15,  6, 14, 0.0, 0.5, "Blue/Lift"),
 ("GreenWest_Floor", -4.5, 11,  3,  6, 0.0, 0.5, "Blue/Lift"),   # foot of BottomBlue_StairsW
 ("BottomBlue_Ledge",  0, 16.7,16, 5.4, 3.0, 0.5, "Blue/Lift"),  # raised 2.5->3.0: 2.5 m headroom over Green Hall
 ("LeftMag",         -5.5,14,  5,  4, 6.0, 0.5, "Blue/Lift"),
 ("RightMag",         5.5,14,  5,  4, 6.0, 0.5, "Blue/Lift"),
 ("TopBlue_Deck",      0, 15.4,12,  8, 9.0, 0.5, "Blue/Lift"),   # moved north: south edge z=19.4, lift column clear
 ("BlueLift_Pad",      0,  21,  3,  3, 0.0, 0.1, "Blue/Lift"),
 ("S1_Floor",         16,   0, 10, 12, 4.5, 0.5, "Sniper"),      # z -6..6
 ("S2_Floor",         17,  -4,  8,  6, 7.5, 0.5, "Sniper"),
 ("S2_Landing",       12,  -2,  2,  4, 7.5, 0.5, "Sniper"),      # top of S1_S2_Stairs, joins S2 west edge
 ("S2_RampFoot",    21.25,  0, 4.5, 2, 7.5, 0.5, "Sniper"),      # S2 south edge -> SnipeRamp
 ("S3_SnipeDeck",     16,  -6, 10,  6,10.5, 0.5, "Sniper"),
 ("S3_EastLanding", 22.25, -8, 2.5, 2,10.5, 0.5, "Sniper"),      # top of SnipeRamp
 ("Elbow_South",      12,  19, 10, 2.5, 3.0, 0.4, "Elbow"),
 ("BR1_Floor",       -16,   1, 10, 10, 4.5, 0.5, "BR"),
 ("BR2_Floor",       -17,  -1,  8,  8, 7.5, 0.5, "BR"),
 ("BR2_Landing",     -12,  -2,  2,  4, 7.5, 0.5, "BR"),         # top of BR1_BR2_Stairs
 ("BR2_BridgeLink",  -15,  -8,  2,  6, 7.5, 0.5, "BR"),         # BR2 north edge -> BR_Bridge
 ("BR2_WestLedge", -20.5,-9.3,  9,  2, 6.5, 0.5, "BR"),         # Open Ramp Jump landing
 ("BR3_Roof",        -17,  -3,  8,  8,10.5, 0.5, "BR"),
 ("BR3_Landing",     -20,   2,  2,  2,10.5, 0.5, "BR"),         # top of BR2_BR3_Stairs
 ("BR_Courtyard",    -17,   9, 18,  6, 0.0, 0.5, "BR"),         # ground west of Bottom Mid, foot of Open Ramp
 ("OpenRamp_Top",    -24,  -3,  2,  2, 4.5, 0.5, "BR"),
 ("OpenRamp_Link",   -22,  -3,  2,  2, 4.5, 0.5, "BR"),         # OpenRamp_Top -> BR1 west door
 ("BR_Bridge",       -10, -10, 10, 2.5, 7.5, 0.4, "BR"),
 ("Sword_Room",      -11, -12,  6,  6, 2.0, 0.5, "Library/Sword"),
 ("Sword_Hall_Floor", -9, 0.5,  2, 11, 0.0, 0.5, "Library/Sword"),  # Bottom Mid west door -> Sword_Ramp foot
 ("Library_Floor",    -1, -14, 12,  8, 7.5, 0.5, "Library/Sword"),
 ("S1_TopMid_Link",   10.5,-2,  5,  4, 4.5, 0.5, "Sniper"),      # moved to z -4..0 so the S1 stairs don't block it
 ("BR1_TopMid_Link", -10.5,-2,  5,  4, 4.5, 0.5, "BR"),
 # --- parapets (1.05 m) and walls: top_y = top of wall, thickness = wall height ---
 ("Parapet_TopMid_N",   0,  -7.85,16, 0.3, 5.55, 1.05, "Parapet"),
 ("Parapet_TopMid_SW", -5,   7.85, 6, 0.3, 5.55, 1.05, "Parapet"),   # gap x -2..2 = Blue Ramp
 ("Parapet_TopMid_SE",  5,   7.85, 6, 0.3, 5.55, 1.05, "Parapet"),
 ("Parapet_TopMid_E1", 7.85, -6,  0.3, 4, 5.55, 1.05, "Parapet"),    # gap z -4..0 = S1 link
 ("Parapet_TopMid_E2", 7.85,  4,  0.3, 8, 5.55, 1.05, "Parapet"),
 ("Parapet_TopMid_W1",-7.85, -6,  0.3, 4, 5.55, 1.05, "Parapet"),    # gap z -4..0 = BR link
 ("Parapet_TopMid_W2",-7.85,  4,  0.3, 8, 5.55, 1.05, "Parapet"),
 ("Parapet_TopBlue_NW",-4,  11.55, 4, 0.3,10.05, 1.05, "Parapet"),   # gap x -2..2 = drop to Top Mid
 ("Parapet_TopBlue_NE", 4,  11.55, 4, 0.3,10.05, 1.05, "Parapet"),
 ("Parapet_TopBlue_W", -5.85,15.4,0.3, 8,10.05, 1.05, "Parapet"),
 ("Parapet_TopBlue_E",  5.85,15.4,0.3, 8,10.05, 1.05, "Parapet"),    # south edge open = lift arrival
 ("Parapet_Library_SW",-5.5,-10.15,3,0.3, 8.55, 1.05, "Parapet"),    # gap x -4..2 = Library window drop
 ("Parapet_Library_SE", 3.5,-10.15,3,0.3, 8.55, 1.05, "Parapet"),
 ("Parapet_BRBridge_N",-10,-11.1, 10,0.3, 8.55, 1.05, "Parapet"),
 ("Parapet_BRBridge_S", -8, -8.9,  6,0.3, 8.55, 1.05, "Parapet"),    # x -11..-5; west end open to BR2_BridgeLink
 ("Parapet_S3_N",      16, -8.85,10, 0.3,11.55, 1.05, "Parapet"),
 ("Parapet_S3_W",   11.15, -6,  0.3, 6,11.55, 1.05, "Parapet"),
 ("Parapet_BR3_W", -20.85, -4,  0.3, 6,11.55, 1.05, "Parapet"),      # z -7..-1; z -1..1 open to BR3_Landing
 ("Parapet_BR3_N",    -17,-6.85, 8, 0.3,11.55, 1.05, "Parapet"),
 ("Parapet_Elbow_S",   12, 20.1, 10, 0.3, 4.05, 1.05, "Parapet"),
 ("Wall_BotMid_N",      0, -7.75,16, 0.5, 4.0, 4.0, "Wall"),
 ("Wall_BotMid_E",   7.75,  0,  0.5,16, 4.0, 4.0, "Wall"),
 ("Wall_BotMid_SW",  -7,  7.75,  2, 0.5, 4.0, 4.0, "Wall"),          # door x -6..3 (stairs + Green Hall)
 ("Wall_BotMid_SE", 5.5,  7.75,  5, 0.5, 4.0, 4.0, "Wall"),
 ("Wall_BotMid_W1",-7.75,-6, 0.5,  4, 4.0, 4.0, "Wall"),             # door z -4..-1.5 -> Sword hall
 ("Wall_BotMid_W2",-7.75,1.75,0.5,6.5,4.0, 4.0, "Wall"),             # z -1.5..5; door z 5..8 -> BR courtyard
 ("Wall_BR1_W",     -21.25,2, 0.5,  8, 7.0, 2.5, "Wall"),            # z -2..6; door z -4..-2 = Open Ramp link
 ("Wall_BR1_N",       -16,-4.25,10,0.5, 7.0, 2.5, "Wall"),
 ("Wall_S1_E",      21.25,1.5, 0.5,  9, 7.0, 2.5, "Wall"),           # z -3..6 under S2_RampFoot
 ("Wall_S1_N",        16,-6.25,10, 0.5, 7.0, 2.5, "Wall"),
]
RAMPS = [
 # name, (x0, z0, y0) low end centre, (x1, z1, y1) high end centre, width, thickness, group
 ("BlueRamp",          (0, 14, 3.0),     (0, 7.0, 4.5),    4.0, 0.4, "Blue/Lift"),
 ("BottomBlue_StairsW",(-5, 8.0, 0.0),   (-5, 14, 3.0),    2.0, 0.4, "Blue/Lift"),
 ("LeftMag_Ramp",      (-7, 19.4, 3.0),  (-7, 14, 6.0),    2.0, 0.4, "Blue/Lift"),
 ("RightMag_Ramp",     (7, 19.4, 3.0),   (7, 14, 6.0),     2.0, 0.4, "Blue/Lift"),
 ("Elbow_North",       (16, 10.75, 2.7), (16, 18.0, 3.0),  2.5, 0.4, "Elbow"),   # lip z=10.75, gap 4.75 to S1
 ("S1_S2_Stairs",      (12, 5.0, 4.5),   (12, 0.0, 7.5),   2.0, 0.4, "Sniper"),
 ("SnipeRamp",         (22.25, -1, 7.5), (22.25, -7, 10.5),2.5, 0.4, "Sniper"),
 ("BR1_BR2_Stairs",    (-12, 5.0, 4.5),  (-12, 0.0, 7.5),  2.0, 0.4, "BR"),
 ("BR2_BR3_Stairs",    (-14, 2, 7.5),    (-19, 2, 10.5),   2.0, 0.4, "BR"),
 ("OpenRamp",          (-24, 10, 0.0),   (-24, -2, 4.5),   2.0, 0.4, "BR"),
 ("Sword_Ramp",        (-9, -5, 0.0),    (-9, -9, 2.0),    2.0, 0.4, "Library/Sword"),
]
def col(y):
    import matplotlib.cm as cm
    return cm.viridis(min(max((y+0.5)/11.5,0),1))
fig, ax = plt.subplots(figsize=(13,13))
for n,(x0,z0,y0),(x1,z1,y1),w,t,g in RAMPS:
    ax.plot([x0,x1],[z0,z1],color=col((y0+y1)/2),lw=w*6,alpha=0.6); ax.text((x0+x1)/2,(z0+z1)/2,f"{n}\n{y0}->{y1}",fontsize=6,ha="center")
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
W=[(0,0.0,"Shotgun? (BotMid)","s"),(16,-6,"Sniper (S3)","*"),(-11,-12,"Energy Sword","D"),(0,16,"BR + 2 Magnums (Top Blue)","^"),
   (-17,-3,"BR (BR tower)","^"),(0,15,"Shotgun+SMG (Green/Bottom Blue)","s")]
for x,z,l,m in W:
    ax.plot(x,z,m,ms=12,mfc="orange",mec="k"); ax.text(x+0.8,z+1.2,l,fontsize=7,color="darkorange",weight="bold")
S=[(0,17),(-18,4),(18,2),(-2,-16),(0,-4),(12,19),(-11,-12),(16,-4)]
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
    note=""
    print(f"| {n} | {g} | ({cx}, {y-t/2:.2f}, {cz}) | ({sx}, {t}, {sz}) | {note} |")
