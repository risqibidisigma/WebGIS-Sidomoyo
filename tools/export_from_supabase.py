#!/usr/bin/env python3
"""
Ekspor layer Bidang Tanah dari Supabase -> data/BidangTanah_5.js (format qgis2web).

Peta publik (map.html) tetap membaca file statis ini, sehingga:
  * tetap cepat dan tetap hidup walau Supabase sedang di-pause,
  * tidak ada API key yang perlu ditanam di map.html.

Environment:
    SUPABASE_URL        https://xxxx.supabase.co
    SUPABASE_ANON_KEY   kunci anon/publishable (aman publik; akses dibatasi RLS)

Pemakaian:
    python tools/export_from_supabase.py data/BidangTanah_5.js
"""
import json, os, sys, urllib.request

OUT = sys.argv[1] if len(sys.argv) > 1 else "data/BidangTanah_5.js"
URL = os.environ["SUPABASE_URL"].rstrip("/")
KEY = os.environ["SUPABASE_ANON_KEY"]


def fetch():
    req = urllib.request.Request(
        URL + "/rest/v1/rpc/bidang_geojson",
        data=b"{}",
        headers={"apikey": KEY, "Authorization": "Bearer " + KEY,
                 "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def to_qgis2web(fc):
    feats = []
    for f in fc["features"]:
        p = f["properties"]
        luas = p.get("LUAS_M2")
        feats.append({
            "type": "Feature",
            # urutan & tipe atribut dibuat sama dengan ekspor qgis2web awal
            "properties": {
                "fid": p.get("fid") or str(p["id"]),
                "AKURASI": float(p.get("AKURASI") or 0),
                "LUAS_M2": None if luas is None else str(int(round(float(luas)))),
                "NOMOR": p.get("NOMOR"),
                "NIB": p.get("NIB"),
                "TAHUN": p.get("TAHUN"),
                "TIPE_HAK": p.get("TIPE_HAK"),
                "NAMA": p.get("NAMA"),
                "KODE": p.get("KODE"),
                "DUSUN": p.get("DUSUN"),
            },
            "geometry": f["geometry"],
        })
    return {"type": "FeatureCollection", "name": "BidangTanah_5",
            "crs": fc["crs"], "features": feats}


def existing_count(path):
    try:
        t = open(path, encoding="utf-8").read()
        return len(json.loads(t[t.index("=") + 1:].strip().rstrip(";"))["features"])
    except Exception:
        return 0


def main():
    new = to_qgis2web(fetch())
    n_new, n_old = len(new["features"]), existing_count(OUT)

    # Pengaman: jangan timpa peta publik dengan data kosong / menyusut drastis.
    if n_new == 0 or (n_old and n_new < 0.5 * n_old):
        sys.exit("DIBATALKAN: database berisi %d fitur, file saat ini %d. "
                 "Periksa database sebelum sinkronisasi." % (n_new, n_old))

    text = "var json_BidangTanah_5 = " + json.dumps(new, ensure_ascii=False,
                                                    separators=(",", ":")) + ";\n"
    try:
        same = open(OUT, encoding="utf-8").read() == text
    except FileNotFoundError:
        same = False
    if same:
        print("Tidak ada perubahan (%d fitur)." % n_new)
        return
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print("Diperbarui: %d fitur (sebelumnya %d) -> %s" % (n_new, n_old, OUT))


if __name__ == "__main__":
    main()
