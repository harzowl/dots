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

for element in root.findall("PluginRepositories"):
    root.remove(element)

container = ET.SubElement(root, "PluginRepositories")
for repository in repositories:
    item = ET.SubElement(container, "RepositoryInfo")
    ET.SubElement(item, "Name").text = repository["name"]
    ET.SubElement(item, "Url").text = repository["url"]

tree.write(path, encoding="utf-8", xml_declaration=True)

uid, gid = (int(part) for part in args.owner.split(":", 1))
os.chown(path, uid, gid)
