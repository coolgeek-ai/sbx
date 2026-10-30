#!/usr/bin/env python3
"""Emulates v2rayNG FmtBase.getItemFormQuery + CoreOutboundBuilder (read from 2.3.14 source) -> Xray outbound JSON.
usage: link2xray.py <link> <override_host> <override_port>"""
import sys, json, urllib.parse as up, base64
link, host_override, port_override = sys.argv[1], sys.argv[2], int(sys.argv[3])
u = up.urlsplit(link)
# v2rayNG getQueryParam: split("&") -> split("=") destructure first two (value truncated at 2nd '=')
q = {}
for kv in (u.query.split("&") if u.query else []):
    parts = kv.split("=")
    k, v = parts[0], parts[1] if len(parts) > 1 else None
    if v is None: raise SystemExit("PARSE FAIL (param without '=')")
    q[k] = up.unquote(v)
user = up.unquote(u.username) if u.username else None
scheme = u.scheme
def stream(security, extra):
    ss = {"network": {"tcp":"tcp","ws":"ws"}.get(q.get("type","tcp"), q.get("type"))}
    if security not in ("tls","reality"): security = None   # FmtBase: anything else -> null
    if security: ss["security"] = security
    if security == "tls":
        t = {"serverName": q.get("sni") or None, "fingerprint": q.get("fp") or None}
        if q.get("alpn"): t["alpn"] = q["alpn"].split(",")
        pin = extra.get("pin")
        insecure = any(q.get(k)=="1" for k in ("insecure","allowInsecure","allow_insecure"))
        if pin: t["pinnedPeerCertSha256"] = pin
        if insecure and not pin: t["allowInsecure"] = True
        ss["tlsSettings"] = {k:v for k,v in t.items() if v}
        if insecure and not pin: ss["tlsSettings"]["allowInsecure"] = True
    if security == "reality":
        ss["realitySettings"] = {k:v for k,v in {"serverName":q.get("sni"),"fingerprint":q.get("fp"),
            "publicKey":q.get("pbk"),"shortId":q.get("sid") or None,"spiderX":q.get("spx")}.items() if v}
    if ss["network"] == "ws":
        ss["wsSettings"] = {"path": q.get("path","/"), "headers": {"Host": q["host"]} if q.get("host") else {}}
    return ss
if scheme == "vless":
    sec = q.get("security")
    ob = {"protocol":"vless","settings":{"vnext":[{"address":host_override,"port":port_override,
          "users":[{"id":user,"encryption":q.get("encryption","none"),**({"flow":q["flow"]} if q.get("flow") else {})}]}]},
          "streamSettings": stream(sec, {})}
elif scheme == "trojan":
    sec = q.get("security","tls")
    ob = {"protocol":"trojan","settings":{"servers":[{"address":host_override,"port":port_override,"password":user}]},
          "streamSettings": stream(sec, {"pin": q.get("pcs")})}
elif scheme in ("hysteria2","hy2"):
    sec = q.get("security","tls")
    ss = stream(sec, {"pin": q.get("pinSHA256")}); ss["network"]="hysteria"
    ss["hysteriaSettings"]={"version":2,"auth":user}
    ob = {"protocol":"hysteria","settings":{"address":host_override,"port":port_override,"version":2},"streamSettings":ss}
elif scheme == "ss":
    ui = u.username
    if ":" not in ui:
        ui += "=" * (-len(ui) % 4); ui = base64.urlsafe_b64decode(ui.replace("+","-").replace("/","_")).decode()
    m, p = ui.split(":",1)
    ob = {"protocol":"shadowsocks","settings":{"servers":[{"address":host_override,"port":port_override,"method":m,"password":p}]}}
print(json.dumps(ob))
