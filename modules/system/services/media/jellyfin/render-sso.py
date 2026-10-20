#!/usr/bin/env python3
import os
import xml.etree.ElementTree as ET
from pathlib import Path


def env(name, default=""):
    return os.environ.get(name, default)


provider = env("JELLYFIN_SSO_PROVIDER", "keycloak")
secret_env = env("JELLYFIN_SSO_SECRET_ENV")
secret = os.environ.get(secret_env)
if not secret:
    raise SystemExit(f"missing secret: {secret_env}")

root = ET.Element(
    "PluginConfiguration",
    {
        "xmlns:xsi": "http://www.w3.org/2001/XMLSchema-instance",
        "xmlns:xsd": "http://www.w3.org/2001/XMLSchema",
    },
)
ET.SubElement(root, "SamlConfigs")
oid = ET.SubElement(root, "OidConfigs")
item = ET.SubElement(oid, "item")
key = ET.SubElement(item, "key")
ET.SubElement(key, "string").text = provider
value = ET.SubElement(item, "value")
config = ET.SubElement(value, "PluginConfiguration")


def text(name, value):
    ET.SubElement(config, name).text = str(value)


def strings(name, values):
    element = ET.SubElement(config, name)
    for value in values:
        ET.SubElement(element, "string").text = value


text("OidEndpoint", env("JELLYFIN_SSO_ENDPOINT"))
text("OidClientId", env("JELLYFIN_SSO_CLIENT_ID"))
text("OidSecret", secret)
text("Enabled", "true")
text("EnableAuthorization", env("JELLYFIN_SSO_ENABLE_AUTHORIZATION", "false"))
text("EnableAllFolders", env("JELLYFIN_SSO_ENABLE_ALL_FOLDERS", "true"))
strings("EnabledFolders", [])
strings("AdminRoles", [value for value in env("JELLYFIN_SSO_ADMIN_ROLES").split(",") if value])
strings("Roles", [value for value in env("JELLYFIN_SSO_ROLES").split(",") if value])
text("EnableFolderRoles", "false")
text("EnableLiveTvRoles", "false")
text("EnableLiveTv", "false")
text("EnableLiveTvManagement", "false")
strings("LiveTvRoles", [])
strings("LiveTvManagementRoles", [])
ET.SubElement(config, "FolderRoleMappings")
text("RoleClaim", env("JELLYFIN_SSO_ROLE_CLAIM"))
strings("OidScopes", [value for value in env("JELLYFIN_SSO_SCOPES").split(",") if value])
ET.SubElement(config, "CanonicalLinks")
text("DisableHttps", "false")
text("DoNotValidateEndpoints", "false")
text("DoNotValidateIssuerName", "false")
text("DisablePushedAuthorization", env("JELLYFIN_SSO_DISABLE_PUSHED_AUTHORIZATION", "true"))
text("SchemeOverride", env("JELLYFIN_SSO_SCHEME", "https"))
text("PortOverride", env("JELLYFIN_SSO_PORT", "443"))
text("NewPath", env("JELLYFIN_SSO_NEW_PATH", "true"))

path = Path(env("JELLYFIN_SSO_CONFIG_DIR")) / "plugins" / "configurations" / "SSO-Auth.xml"
path.parent.mkdir(parents=True, exist_ok=True)
ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)

owner = env("JELLYFIN_SSO_OWNER", "1000:1000")
uid, gid = (int(part) for part in owner.split(":", 1))
os.chown(path, uid, gid)
os.chmod(path, 0o640)
