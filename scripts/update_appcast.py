import sys
import os
import xml.etree.ElementTree as ET
from email.utils import formatdate
import datetime

def create_initial_appcast():
    appcast_content = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>MangoPOS Updates</title>
        <description>Últimas actualizaciones para MangoPOS</description>
        <language>es</language>
    </channel>
</rss>"""
    with open('appcast.xml', 'w') as f:
        f.write(appcast_content)

def update_appcast(version, signature, file_size):
    if not os.path.exists('appcast.xml'):
        create_initial_appcast()

    ET.register_namespace('sparkle', 'http://www.andymatuschak.org/xml-namespaces/sparkle')
    tree = ET.parse('appcast.xml')
    root = tree.getroot()
    channel = root.find('channel')

    # Chequear si ya existe la versión para no duplicar
    for item in channel.findall('item'):
        title = item.find('title')
        if title is not None and title.text == version:
            print(f"La versión {version} ya existe en appcast.xml. Actualizando...")
            channel.remove(item)

    new_item = ET.SubElement(channel, 'item')
    
    title = ET.SubElement(new_item, 'title')
    title.text = version
    
    pubDate = ET.SubElement(new_item, 'pubDate')
    pubDate.text = formatdate(timeval=None, localtime=False, usegmt=True)
    
    # Sparkle tags need namespace prefix
    sparkle_url = f"https://mangopos.com/MangoPOS-{version}-{os_name}.{'dmg' if os_name == 'macos' else 'exe'}"
    enclosure = ET.SubElement(new_item, 'enclosure')
    enclosure.set('url', sparkle_url)
    enclosure.set('sparkle:version', version)
    enclosure.set('sparkle:shortVersionString', version)
    enclosure.set('sparkle:os', 'windows' if os_name == 'windows' else 'macos')
    enclosure.set('length', str(file_size))
    enclosure.set('type', 'application/octet-stream')
    enclosure.set('sparkle:edSignature', signature)

    # Añadir indentación
    ET.indent(tree, space="    ", level=0)
    tree.write('appcast.xml', encoding='utf-8', xml_declaration=True)
    print("appcast.xml actualizado exitosamente.")

if __name__ == "__main__":
    if len(sys.argv) < 5:
        print("Uso: python update_appcast.py <version> <signature> <file_size> <os_name>")
        sys.exit(1)
        
    version = sys.argv[1]
    signature = sys.argv[2]
    file_size = sys.argv[3]
    os_name = sys.argv[4].lower()
    
    update_appcast(version, signature, file_size, os_name)
