from PIL import Image, ImageDraw
S=1400
img=Image.new("RGBA",(S,S),(0,0,0,0))
d=ImageDraw.Draw(img)
cx=cy=S//2
col=(0,0,0,255)
s=2.0
lw=int(40*s); bw=int(150*s); bh=int(300*s)
body_top=cy-int(230*s); body_bot=body_top+bh
# mic body
d.rounded_rectangle([cx-bw//2,body_top,cx+bw//2,body_bot],radius=bw//2,fill=col)
# cradle arc
aw=int(300*s); ah=int(300*s); arc_top=body_bot-int(150*s)
d.arc([cx-aw//2,arc_top,cx+aw//2,arc_top+ah],start=15,end=165,fill=col,width=lw)
# stem
stem_top=arc_top+ah//2+int(20*s); stem_bot=stem_top+int(110*s)
d.line([cx,stem_top,cx,stem_bot],fill=col,width=lw)
# base
basew=int(200*s)
d.line([cx-basew//2,stem_bot,cx+basew//2,stem_bot],fill=col,width=lw)
# waves
gap=int(70*s); wbw=int(34*s); hmap={-4:80,-3:150,3:150,4:80}
for k,h in hmap.items():
    x=cx+k*gap; hh=int(h*s)
    d.rounded_rectangle([x-wbw//2,cy-hh//2,x+wbw//2,cy+hh//2],radius=wbw//2,fill=col)
# trim to content + pad to square
bbox=img.getbbox()
g=img.crop(bbox)
w,h=g.size; side=max(w,h)+80
canvas=Image.new("RGBA",(side,side),(0,0,0,0))
canvas.paste(g,((side-w)//2,(side-h)//2),g)
canvas=canvas.resize((512,512),Image.LANCZOS)
canvas.save("MicGlyph.png")
canvas.resize((1024,1024),Image.LANCZOS).save("MicGlyph@2x.png")
print("glyph:",canvas.size)
