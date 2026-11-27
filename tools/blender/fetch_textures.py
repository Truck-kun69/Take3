import json, os, sys, urllib.request, zipfile, io
out = sys.argv[1]
def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "shardfall-asset-fetch/1.0"})
    return urllib.request.urlopen(req, timeout=120).read()
ph = ["brown_leather", "leather_red_02", "fabric_pattern_07", "hessian_230", "velour_velvet", "metal_plate", "rusty_metal_02", "rock_face_03", "denim_fabric"]
acg = ["Metal027", "MetalPlates006", "Metal048A", "Metal034", "Leather037", "Leather026", "Fabric085", "Fabric019", "Chainmail004", "Rock064", "Wood066", "Fabric084"]
for a in ph:
    d = os.path.join(out, "ph_" + a); os.makedirs(d, exist_ok=True)
    files = json.loads(get("https://api.polyhaven.com/files/" + a))
    inc = files["gltf"]["1k"]["gltf"]["include"]
    for path, info in inc.items():
        open(os.path.join(d, os.path.basename(path)), "wb").write(get(info["url"]))
    print("ph", a, sorted(os.listdir(d)))
for a in acg:
    d = os.path.join(out, "acg_" + a); os.makedirs(d, exist_ok=True)
    z = zipfile.ZipFile(io.BytesIO(get(f"https://ambientcg.com/get?file={a}_1K-JPG.zip")))
    for n in z.namelist():
        if n.lower().endswith((".jpg", ".png")) and "/" not in n:
            open(os.path.join(d, n), "wb").write(z.read(n))
    print("acg", a, sorted(os.listdir(d)))
