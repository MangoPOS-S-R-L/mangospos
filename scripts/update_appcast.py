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

SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def _item_os(item):
    enclosure = item.find('enclosure')
    if enclosure is None:
        return None
    # Escrito como 'sparkle:os' y releído con el namespace expandido.
    return enclosure.get('{%s}os' % SPARKLE_NS) or enclosure.get('sparkle:os')


def update_appcast(version, signature, file_size, os_name):
    if not os.path.exists('appcast.xml'):
        create_initial_appcast()

    ET.register_namespace('sparkle', 'http://www.andymatuschak.org/xml-namespaces/sparkle')
    tree = ET.parse('appcast.xml')
    root = tree.getroot()
    channel = root.find('channel')

    # Chequear si ya existe la versión DE ESTA PLATAFORMA para no duplicar
    # (Windows y Mac pueden compartir número de versión).
    target_os = 'windows' if os_name == 'windows' else 'macos'
    for item in channel.findall('item'):
        title = item.find('title')
        if title is not None and title.text == version and _item_os(item) in (None, target_os):
            print(f"La versión {version} ({target_os}) ya existe en appcast.xml. Actualizando...")
            channel.remove(item)

    new_item = ET.SubElement(channel, 'item')
    
    title = ET.SubElement(new_item, 'title')
    title.text = version
    
    pubDate = ET.SubElement(new_item, 'pubDate')
    pubDate.text = formatdate(timeval=None, localtime=False, usegmt=True)
    
    # Sparkle tags need namespace prefix
    sparkle_url = f"https://mangopos.com/MangoPOS-{version}-{os_name}.{'dmg' if os_name == 'macos' else 'exe'}"
    enclosure = ET.SubElement(new_item, 'enclosure')
    # Nombres calificados: así ElementTree conserva xmlns:sparkle al escribir
    # (con 'sparkle:os' literal la segunda corrida fallaba: «unbound prefix»).
    sp = lambda name: '{%s}%s' % (SPARKLE_NS, name)
    enclosure.set('url', sparkle_url)
    enclosure.set(sp('version'), version)
    enclosure.set(sp('shortVersionString'), version)
    enclosure.set(sp('os'), target_os)
    enclosure.set('length', str(file_size))
    enclosure.set('type', 'application/octet-stream')
    enclosure.set(sp('edSignature'), signature)

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
