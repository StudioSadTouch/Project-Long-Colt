import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
rows=[("Sky (shader)",[("zenith","#13213d"),("upper","#385478"),("horizon","#a8bacc"),("far rock","#5c6b7d"),("snow","#dfe6ea")]),
("Board: frozen blue-grey",[("#1d2630","#1d2630"),("#3e4c5a","#3e4c5a"),("#6e8191","#6e8191"),("#a9b8c4","#a9b8c4"),("#dfe6ea","#dfe6ea"),("accent #c47a2c","#c47a2c")]),
("Key + fill",[("sun 1.0/.95/.88","#fff2e0"),("fog .60/.68/.76","#99adc2"),("ambient sky","#6e8191")]),
("Practicals",[("sodium","#ff9942"),("fluoro","#d1edff"),("halogen work","#ffe0b8"),("readout","#80ebd1"),("beacon","#ff1f12")])]
fig,ax=plt.subplots(figsize=(12,5.2)); ax.set_facecolor("#16181b"); fig.patch.set_facecolor("#16181b")
for r,(t,cs) in enumerate(rows):
    y=len(rows)-1-r; ax.text(-0.1,y+.4,t,ha="right",va="center",color="w",fontsize=11)
    for i,(n,c) in enumerate(cs):
        ax.add_patch(Rectangle((i*1.6,y+.1),1.5,.7,fc=c)); ax.text(i*1.6+.75,y+.02,n,ha="center",va="top",color="#ccc",fontsize=8)
ax.set_xlim(-3.6,10); ax.set_ylim(-.3,len(rows)); ax.axis("off")
ax.set_title("Lockout lighting palette: cold high-altitude day, warm practicals (sodium accent from board)",color="w")
fig.savefig("/workspace/lighting/lockout_palette_swatch.png",dpi=100,bbox_inches="tight",facecolor=fig.get_facecolor())
