#!/usr/bin/env python3
"""
Konversi data/BidangTanah_5.js (hasil qgis2web) -> file SQL siap impor ke Supabase.

Pemakaian (dari folder root proyek WebGIS):
    python tools/convert_to_sql.py data/BidangTanah_5.js sql_import

Hasil: sql_import/import_bidang_001.sql, 002, ... (500 bidang per file, supaya muat
di SQL Editor Supabase). Jalankan berurutan.

Catatan:
- Kolom PATH (path lokal laptop, mis. "D:/DATA KULIAH/...") sengaja TIDAK diimpor.
- NIB kosong / bukan 13-14 digit diimpor sebagai NULL dan dilaporkan di layar.
"""
import json, os, re, sys

CHUNK = 500


def load_geojson(path):
    text = open(path, encoding="utf-8").read()
    start = text.index("=") + 1
    return json.loads(text[start:].strip().rstrip(";"))


def q(v):
    """Literal SQL teks (atau NULL)."""
    if v is None or str(v).strip() == "":
        return "NULL"
    return "'" + str(v).replace("'", "''") + "'"


def num(v):
    try:
        return repr(float(v)) if v not in (None, "") else "NULL"
    except (TypeError, ValueError):
        return "NULL"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)

    feats = load_geojson(src)["features"]
    rows, bad_nib = [], []
    for f in feats:
        p = f["properties"]
        nib = p.get("NIB")
        if nib is not None and not re.fullmatch(r"[0-9]{13,14}", str(nib)):
            bad_nib.append((p.get("fid"), nib))
            nib = None
        geom = json.dumps(f["geometry"], separators=(",", ":"))
        rows.append(
            "(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"
            "ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(%s),4326)),3)))"
            % (
                q(p.get("fid")), q(nib), q(p.get("NOMOR")), q(p.get("NAMA")),
                q(p.get("TIPE_HAK")), q(p.get("TAHUN")), q(p.get("KODE")), q(p.get("DUSUN")),
                num(p.get("LUAS_M2")), num(p.get("AKURASI")), q(geom),
            )
        )

    head = ("INSERT INTO public.bidang_tanah "
            "(fid,nib,nomor,nama,tipe_hak,tahun,kode,dusun,luas_m2,akurasi,geom) VALUES\n")
    n_files = 0
    for i in range(0, len(rows), CHUNK):
        n_files += 1
        name = os.path.join(outdir, "import_bidang_%03d.sql" % n_files)
        with open(name, "w", encoding="utf-8") as fh:
            fh.write(head + ",\n".join(rows[i:i + CHUNK]) + ";\n")

    print("Fitur dibaca      :", len(feats))
    print("File SQL dibuat   :", n_files, "(di %s/)" % outdir)
    print("NIB tidak valid   :", len(bad_nib), "-> diimpor sebagai NULL", bad_nib[:5])
    nulls = sum(1 for f in feats if not f["properties"].get("NIB"))
    print("NIB kosong (NULL) :", nulls)


if __name__ == "__main__":
    main()
