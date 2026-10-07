"""Preview fixtures; requires Pillow and a full FFmpeg build on PATH."""
from pathlib import Path
from PIL import Image
import subprocess, zipfile, json
import argparse
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
p = parser.parse_args().output
p.mkdir(parents=True, exist_ok=True)
for ext in ['txt','md','csv','json','html']:
    (p/('fixture.'+ext)).write_text('Library fixture 日本語 '+ext+'\n<script>window.fixtureExecuted=true</script>\n'+'very-long-line '*50, encoding='utf-8')
(p/'fixture.rtf').write_text(r'{\rtf1\ansi Library fixture}',encoding='ascii')
(p/'fixture-utf16.txt').write_text('Library fixture 日本語',encoding='utf-16')
(p/'fixture-sjis.txt').write_bytes('Library fixture 日本語'.encode('cp932'))
types='<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
rels='<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
def write_zip(ext,entries):
    with zipfile.ZipFile(p/('fixture.'+ext),'w',compression=zipfile.ZIP_DEFLATED) as z:
        for name,value in entries.items():z.writestr(name,value)
write_zip('docx',{'[Content_Types].xml':types,'_rels/.rels':rels,'word/document.xml':'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Library fixture 日本語</w:t></w:r></w:p><w:sectPr/></w:body></w:document>'})
write_zip('xlsx',{'xl/sharedStrings.xml':'<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Library fixture 日本語</t></si></sst>','xl/worksheets/sheet1.xml':'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>42</v></c></row></sheetData></worksheet>'})
write_zip('pptx',{'ppt/slides/slide1.xml':'<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><a:p><a:r><a:t>Library fixture 日本語</a:t></a:r></a:p></p:cSld></p:sld>'})
for ext in ['odt','ods','odp']:
    write_zip(ext,{'mimetype':'application/vnd.oasis.opendocument.text','content.xml':'<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:p>Library fixture 日本語 '+ext+'</text:p></office:text></office:body></office:document-content>'})
image=Image.new('RGBA',(320,180),(30,90,200,220))
for ext in ['png','webp','gif','tiff','bmp','ico']:
    image.save(p/('fixture.'+ext))
image.convert('RGB').save(p/'fixture.jpg')
image.convert('RGB').save(p/'fixture.pdf',resolution=72)
for ext in ['avif']:
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-i',str(p/'fixture.png'),'-frames:v','1','-y',str(p/('fixture.'+ext))],check=True)
(p/'fixture.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180"><rect width="320" height="180" fill="#245ac8"/></svg>')
print('fixtures',len(list(p.iterdir())))

from pathlib import Path
import subprocess

for ext,codec in [('mp3','libmp3lame'),('wav','pcm_s16le'),('flac','flac'),('ogg','libvorbis'),('opus','libopus'),('aiff','pcm_s16be'),('m4a','aac'),('caf','pcm_s16le'),('wma','wmav2'),('aac','aac'),('m4b','aac')]:
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','sine=frequency=440:duration=1','-c:a',codec,'-y',str(p/('fixture.'+ext))],check=True)
for ext,codec in [('mp4','libx264'),('mov','prores_ks'),('webm','libvpx-vp9'),('avi','mpeg4'),('mkv','mpeg4'),('wmv','wmv2'),('mpg','mpeg1video'),('3gp','h263')]:
    args=['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','testsrc2=duration=1:size=128x96:rate=25','-c:v',codec]
    if codec=='prores_ks': args+=['-pix_fmt','yuv422p10le']
    else: args+=['-pix_fmt','yuv420p']
    subprocess.run(args+['-y',str(p/('fixture.'+ext))],check=True)
print('Generated',len(list(p.iterdir())),'fixtures')
