import argparse
import json
import os
import xml.etree.ElementTree as ET
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--config", required=True)
parser.add_argument("--repositories", required=True)
parser.add_argument("--owner", default="1000:1000")
args = parser.parse_args()

path = Path(args.config)
if not path.exists():
    print(f"{path} does not exist yet; skipping")
    raise SystemExit(0)

repositories = json.loads(Path(args.repositories).read_text(encoding="utf-8"))
tree = ET.parse(path)
root = tree.getroot()

container = root.find("PluginRepositories")
if container is None:
    container = ET.SubElement(root, "PluginRepositories")

def text(item, name):
    child = item.find(name)
    return (child.text or "").strip() if child is not None else ""

existing = list(container.findall("RepositoryInfo"))
for repository in repositories:
    name = repository["name"].strip()
    url = repository["url"].strip()

    # Match by name or URL so a declared repository updates an entry the UI
    # already created instead of adding a duplicate.
    item = next(
        (candidate for candidate in existing
         if text(candidate, "Name").lower() == name.lower()
         or text(candidate, "Url").lower() == url.lower()),
        None,
    )
    if item is None:
        item = ET.SubElement(container, "RepositoryInfo")
        existing.append(item)

    name_element = item.find("Name")
    if name_element is None:
        name_element = ET.SubElement(item, "Name")
    name_element.text = name

    url_element = item.find("Url")
    if url_element is None:
        url_element = ET.SubElement(item, "Url")
    url_element.text = url

    if item.find("Enabled") is None:
        ET.SubElement(item, "Enabled").text = "true"

tree.write(path, encoding="utf-8", xml_declaration=True)

uid, gid = (int(part) for part in args.owner.split(":", 1))
os.chown(path, uid, gid)
