-- =====================================================================
-- WebGIS Sidomoyo - skema editing Bidang Tanah (Supabase / PostGIS)
-- Jalankan sekali di: Supabase Dashboard > SQL Editor
-- =====================================================================

create extension if not exists postgis with schema extensions;

-- ---------- 1. Tabel utama ------------------------------------------
create table if not exists public.bidang_tanah (
  id          bigint generated always as identity primary key,
  fid         text,                                   -- fid lama dari QGIS (referensi)
  nib         text,
  nomor       text,
  nama        text,
  tipe_hak    text,
  tahun       text,
  kode        text,
  dusun       text,
  luas_m2     numeric,
  akurasi     numeric default 0,
  geom        extensions.geometry(MultiPolygon, 4326) not null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid default auth.uid(),
  constraint nib_format check (nib is null or nib ~ '^[0-9]{13,14}$')
);

create index if not exists bidang_tanah_geom_idx on public.bidang_tanah using gist (geom);
create index if not exists bidang_tanah_nib_idx  on public.bidang_tanah (nib);
-- Catatan: ada 1 NIB ganda di data awal (13040207102430), jadi indeks NIB
-- sengaja tidak UNIQUE. Setelah dirapikan, boleh diganti:
--   create unique index bidang_nib_uq on public.bidang_tanah(nib) where nib is not null;

-- ---------- 2. Daftar admin -----------------------------------------
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  catatan text
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ---------- 3. Row Level Security -----------------------------------
alter table public.bidang_tanah enable row level security;
alter table public.admins       enable row level security;

drop policy if exists "baca publik"   on public.bidang_tanah;
drop policy if exists "admin insert"  on public.bidang_tanah;
drop policy if exists "admin update"  on public.bidang_tanah;
drop policy if exists "admin delete"  on public.bidang_tanah;

create policy "baca publik"  on public.bidang_tanah for select using (true);
create policy "admin insert" on public.bidang_tanah for insert to authenticated with check (public.is_admin());
create policy "admin update" on public.bidang_tanah for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin delete" on public.bidang_tanah for delete to authenticated using (public.is_admin());
-- tabel admins: tanpa policy = tidak bisa diakses lewat API (hanya lewat SQL Editor)

-- ---------- 4. Audit log (siapa mengubah apa) -----------------------
create table if not exists public.audit_bidang (
  id         bigint generated always as identity primary key,
  waktu      timestamptz not null default now(),
  user_id    uuid default auth.uid(),
  aksi       text not null,          -- INSERT / UPDATE / DELETE
  bidang_id  bigint,
  sebelum    jsonb,
  sesudah    jsonb
);
alter table public.audit_bidang enable row level security;
drop policy if exists "admin baca audit" on public.audit_bidang;
create policy "admin baca audit" on public.audit_bidang for select to authenticated using (public.is_admin());

create or replace function public.trg_audit_bidang()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if tg_op = 'DELETE' then
    insert into audit_bidang(aksi,bidang_id,sebelum)
    values ('DELETE', old.id, (to_jsonb(old) - 'geom') || jsonb_build_object('geom', st_asgeojson(old.geom,6)::jsonb));
    return old;
  elsif tg_op = 'UPDATE' then
    insert into audit_bidang(aksi,bidang_id,sebelum,sesudah)
    values ('UPDATE', new.id,
      (to_jsonb(old) - 'geom') || jsonb_build_object('geom', st_asgeojson(old.geom,6)::jsonb),
      (to_jsonb(new) - 'geom') || jsonb_build_object('geom', st_asgeojson(new.geom,6)::jsonb));
    return new;
  else
    insert into audit_bidang(aksi,bidang_id,sesudah)
    values ('INSERT', new.id, (to_jsonb(new) - 'geom') || jsonb_build_object('geom', st_asgeojson(new.geom,6)::jsonb));
    return new;
  end if;
end $$;

-- Impor awal tidak perlu masuk audit: pasang trigger SETELAH impor selesai
-- (lihat PANDUAN.md langkah 4). Jika sudah terlanjur, kosongkan dengan:
--   truncate public.audit_bidang;
drop trigger if exists audit_bidang_trg on public.bidang_tanah;
create trigger audit_bidang_trg after insert or update or delete on public.bidang_tanah
  for each row execute function public.trg_audit_bidang();

-- ---------- 5. Fungsi RPC -------------------------------------------
-- 5a. Seluruh layer sebagai satu GeoJSON (melewati batas 1000 baris REST API)
create or replace function public.bidang_geojson()
returns jsonb language sql stable set search_path = public, extensions as $$
  select jsonb_build_object(
    'type','FeatureCollection',
    'name','BidangTanah_5',
    'crs', jsonb_build_object('type','name','properties',jsonb_build_object('name','urn:ogc:def:crs:OGC:1.3:CRS84')),
    'features', coalesce(jsonb_agg(jsonb_build_object(
        'type','Feature',
        'properties', jsonb_build_object(
            'id',id,'fid',fid,'NIB',nib,'NOMOR',nomor,'NAMA',nama,'TIPE_HAK',tipe_hak,
            'TAHUN',tahun,'KODE',kode,'DUSUN',dusun,'LUAS_M2',luas_m2,'AKURASI',akurasi),
        'geometry', st_asgeojson(geom,6)::jsonb
    ) order by id), '[]'::jsonb))
  from public.bidang_tanah;
$$;

-- 5b. Simpan 1 fitur (insert bila id kosong, update bila ada). Mengikuti RLS pemanggil.
create or replace function public.simpan_bidang(feat jsonb)
returns bigint language plpgsql security invoker set search_path = public, extensions as $$
declare
  p   jsonb := feat->'properties';
  g   geometry;
  rid bigint := nullif(p->>'id','')::bigint;
begin
  g := st_multi(st_collectionextract(st_makevalid(st_setsrid(st_geomfromgeojson(feat->'geometry'),4326)), 3));
  if g is null or st_isempty(g) then
    raise exception 'Geometri harus berupa poligon yang valid';
  end if;

  if rid is null then
    insert into bidang_tanah(fid,nib,nomor,nama,tipe_hak,tahun,kode,dusun,luas_m2,akurasi,geom)
    values (nullif(p->>'fid',''), nullif(p->>'NIB',''), nullif(p->>'NOMOR',''), nullif(p->>'NAMA',''),
            nullif(p->>'TIPE_HAK',''), nullif(p->>'TAHUN',''), nullif(p->>'KODE',''), nullif(p->>'DUSUN',''),
            coalesce(nullif(p->>'LUAS_M2','')::numeric, round(st_area(g::geography))),
            coalesce(nullif(p->>'AKURASI','')::numeric, 0), g)
    returning id into rid;
  else
    update bidang_tanah set
      nib=nullif(p->>'NIB',''), nomor=nullif(p->>'NOMOR',''), nama=nullif(p->>'NAMA',''),
      tipe_hak=nullif(p->>'TIPE_HAK',''), tahun=nullif(p->>'TAHUN',''), kode=nullif(p->>'KODE',''),
      dusun=nullif(p->>'DUSUN',''),
      luas_m2 = coalesce(nullif(p->>'LUAS_M2','')::numeric, round(st_area(g::geography))),
      geom=g, updated_at=now(), updated_by=auth.uid()
    where id = rid;
    if not found then raise exception 'Bidang id % tidak ditemukan atau tidak ada izin', rid; end if;
  end if;
  return rid;
end $$;

-- 5c. Hapus 1 fitur
create or replace function public.hapus_bidang(bid bigint)
returns void language sql security invoker set search_path = public as $$
  delete from public.bidang_tanah where id = bid;
$$;

revoke all on function public.simpan_bidang(jsonb) from public, anon;
revoke all on function public.hapus_bidang(bigint) from public, anon;
grant execute on function public.bidang_geojson()       to anon, authenticated;
grant execute on function public.simpan_bidang(jsonb)   to authenticated;
grant execute on function public.hapus_bidang(bigint)   to authenticated;

-- ---------- 6. Menjadikan akun sebagai admin ------------------------
-- (1) Buat user: Dashboard > Authentication > Users > Add user (email + password)
-- (2) Matikan pendaftaran publik: Authentication > Sign In / Providers >
--     "Allow new users to sign up" = OFF
-- (3) Jalankan (ganti emailnya):
--   insert into public.admins(user_id, catatan)
--   select id, 'Admin Kalurahan' from auth.users where email = 'admin@contoh.id';
