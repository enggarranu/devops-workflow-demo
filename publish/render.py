#!/usr/bin/env python3
"""Rakit halaman hasil deployment untuk GitHub Pages.

    render.py --artifacts <dir> --template publish/template.html --out docs/result

Membaca metadata JSON yang ditulis job linux dan job windows, lalu menulis:

    <out>/linux/index.html
    <out>/windows/index.html
    <out>/history.json

Pembagian tugasnya disengaja: JSON hanya membawa FAKTA dari run (path, perintah,
angka, cap waktu), dan seluruh PROSA dwibahasa tinggal di file ini dan di
template. Jadi menambah bahasa atau memperbaiki kalimat tidak perlu menyentuh
script yang jalan di runner.

Idempotent: boleh dijalankan ulang dengan artifact yang sama, hasilnya sama.
Itu yang membuat job publish bisa mengulang dari state remote terbaru kalau
push-nya kalah lomba dengan run lain.
"""

import argparse
import html
import json
import pathlib
import re
import sys
from datetime import datetime, timedelta, timezone

# WIB tetap UTC+7 sepanjang tahun, tidak ada DST. Jadi offset tetap sudah benar
# dan tidak perlu database timezone di runner.
WIB = timezone(timedelta(hours=7), "WIB")

# Field yang wajib ada. Kalau salah satu hilang, lebih baik job-nya merah
# daripada halaman terbit dengan sel kosong yang tidak jelas sebabnya.
REQUIRED = (
    "platform", "platform_label", "server_label", "runner_image", "runner_os",
    "web_server", "build_id", "version", "run_number", "run_url", "repo",
    "commit_sha", "commit_url", "commit_subject", "deployed_at_utc",
    "deploy_method", "deploy_method_cmd", "pointer", "release_deployed",
    "release_active", "build_v1", "build_v2", "smoke_url", "smoke_tool",
    "smoke", "rollback",
)

# Prosa yang bergantung platform. Dua bahasa, (id, en).
PROSE = {
    "linux": {
        "pointer_kind": (
            "symlink di filesystem, ditukar dengan satu rename",
            "a filesystem symlink, swapped with a single rename",
        ),
        "rollback_detail": (
            "Di Linux rollback selesai setelah satu rename. Folder rilis lama masih "
            "utuh di disk dan tidak pernah ditimpa, jadi tidak ada yang perlu "
            "direstore.",
            "On Linux the rollback is finished after one rename. The old release "
            "directory is still intact on disk and was never overwritten, so there is "
            "nothing to restore.",
        ),
    },
    "windows": {
        "pointer_kind": (
            "atribut physicalPath di applicationHost.config",
            "the physicalPath attribute in applicationHost.config",
        ),
        "rollback_detail": (
            "Di Windows ada satu operasi lagi setelah pointer berganti, yaitu "
            "Restart-WebAppPool, dan operasi itulah yang membuat angka di atas jauh "
            "lebih besar daripada di Linux. Untuk site static seperti ini sebagian "
            "besar nilainya jaga-jaga: stage 7 di halaman utama menunjukkan perubahan "
            "isi sudah terlihat pada request pertama.",
            "On Windows there is one more operation after the pointer moves, "
            "Restart-WebAppPool, and that operation is what makes the number above far "
            "larger than on Linux. For a static site like this one, most of its value "
            "is precaution: stage 7 on the main page shows a content change is already "
            "visible on the first request.",
        ),
    },
}

# Label stage smoke test. Kuncinya nomor stage di workflow.
SMOKE_LABEL = {
    "5":  ("rilis pertama dilayani",
           "the first release is served"),
    "5b": ("rilis kedua menggantikan yang pertama",
           "the second release replaced the first"),
    "5c": ("setelah rollback, rilis pertama kembali dilayani",
           "after rollback, the first release is served again"),
}

OPS_WORD = {
    1: ("satu operasi", "one operation"),
    2: ("dua operasi", "two operations"),
}

HISTORY_KEEP = 10


def e(value):
    """Escape untuk disisipkan ke HTML. Semua nilai lewat sini tanpa kecuali."""
    return html.escape("" if value is None else str(value), quote=True)


def bilingual(pair):
    """Satu pasang (id, en) jadi dua span yang dipilih CSS, bukan JavaScript."""
    return f'<span data-l="id">{e(pair[0])}</span><span data-l="en">{e(pair[1])}</span>'


def parse_utc(text):
    """Baca cap waktu ISO 8601 yang berakhiran Z."""
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def fmt_utc(stamp):
    return stamp.strftime("%Y-%m-%d %H:%M:%S") + " UTC"


def fmt_wib(stamp):
    return stamp.astimezone(WIB).strftime("%Y-%m-%d %H:%M:%S") + " WIB"


def smoke_rows(data):
    """Baris tabel smoke test.

    Statusnya ditulis 'lolos' tanpa dibaca dari mana pun, dan itu bukan
    hardcode yang menyesatkan: step metadata di workflow baru jalan kalau
    ketiga smoke test sudah lewat. Smoke test yang gagal memerahkan job,
    job yang merah tidak memicu job publish, dan halaman ini tidak terbit.
    Keberadaan halaman ini yang jadi buktinya.
    """
    rows = []
    for item in data["smoke"]:
        stage = item["stage"]
        label = SMOKE_LABEL.get(stage, (stage, stage))
        reject = e(item["reject"]) if item.get("reject") else "&#8212;"
        rows.append(
            "          <tr>\n"
            f'            <td class="v">{e(stage)}</td>\n'
            f"            <td>{bilingual(label)}</td>\n"
            f'            <td class="v">{e(item["expect"])}</td>\n'
            f'            <td class="v">{reject}</td>\n'
            '            <td><span class="pass">'
            '<span data-l="id">lolos</span><span data-l="en">pass</span>'
            "</span></td>\n"
            "          </tr>"
        )
    return "\n".join(rows)


def history_rows(entries, current_build):
    if not entries:
        return ('          <tr><td colspan="6">'
                '<span data-l="id">belum ada riwayat</span>'
                '<span data-l="en">no history yet</span></td></tr>')
    rows = []
    for item in entries:
        cls = ' class="now"' if str(item.get("build_id")) == str(current_build) else ""
        stamp = fmt_wib(parse_utc(item["deployed_at_utc"]))[:-4]
        rows.append(
            f"          <tr{cls}>\n"
            f'            <td>{e(item["build_id"])}</td>\n'
            f'            <td>{e(item["version"])}</td>\n'
            f'            <td><a href="{e(item["commit_url"])}">{e(item["commit_short"])}</a></td>\n'
            f"            <td>{e(stamp)}</td>\n"
            f'            <td>{e(item["rollback_ms"])} ms</td>\n'
            f'            <td><a href="{e(item["run_url"])}">#{e(item["run_number"])} &#8599;</a></td>\n'
            "          </tr>"
        )
    return "\n".join(rows)


def load_history(path):
    """Riwayat lama. Hilang atau rusak bukan alasan menggagalkan publish:
    halaman utamanya jauh lebih penting daripada tabel riwayatnya, jadi
    riwayat yang tidak terbaca dimulai dari kosong dengan peringatan."""
    if not path.exists():
        return {"linux": [], "windows": []}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("isi history.json bukan objek")
        return {
            "linux": list(data.get("linux") or []),
            "windows": list(data.get("windows") or []),
        }
    except (ValueError, OSError) as exc:
        print(f"peringatan: history.json tidak terbaca ({exc}), dimulai dari kosong",
              file=sys.stderr)
        return {"linux": [], "windows": []}


def push_history(entries, data):
    """Sisipkan run ini di paling atas, buang duplikat build id yang sama.

    Dedup-nya penting untuk re-run: run_attempt kedua memakai run_number yang
    sama, dan tanpa dedup riwayatnya akan berisi build yang sama dua kali.
    """
    build = str(data["build_id"])
    fresh = {
        "build_id":        data["build_id"],
        "version":         data["version"],
        "run_number":      data["run_number"],
        "run_url":         data["run_url"],
        "commit_short":    data["commit_sha"][:7],
        "commit_url":      data["commit_url"],
        "deployed_at_utc": data["deployed_at_utc"],
        "rollback_ms":     data["rollback"]["ms"],
        "release_active":  data["release_active"],
    }
    kept = [x for x in entries if str(x.get("build_id")) != build]
    # Urut menurun berdasarkan build id, jadi riwayat tetap rapi walaupun ada
    # run lama yang selesai belakangan.
    merged = sorted([fresh] + kept, key=lambda x: int(x["build_id"]), reverse=True)
    return merged[:HISTORY_KEEP]


def render(template, data, history):
    platform = data["platform"]
    prose = PROSE[platform]
    other = "windows" if platform == "linux" else "linux"
    other_label = "Windows" if other == "windows" else "Linux"
    deployed = parse_utc(data["deployed_at_utc"])
    ops = int(data["rollback"]["ops"])

    title_id = f'Hasil {data["platform_label"]} {data["version"]}'
    title_en = f'{data["platform_label"]} result {data["version"]}'

    lede_id = (f'{data["server_label"]} di {data["runner_image"]}. Dua build dideploy, '
               "diverifikasi lewat HTTP, lalu dirollback ke build pertama dan "
               "diverifikasi lagi.")
    lede_en = (f'{data["server_label"]} on {data["runner_image"]}. Two builds deployed, '
               "verified over HTTP, then rolled back to the first build and verified "
               "again.")

    values = {
        "PLATFORM":          platform,
        "PLATFORM_LABEL":    data["platform_label"],
        "SERVER_LABEL":      data["server_label"],
        "RUNNER_IMAGE":      data["runner_image"],
        "RUNNER_OS":         data["runner_os"],
        "WEB_SERVER":        data["web_server"],
        "BUILD_ID":          data["build_id"],
        "VERSION":           data["version"],
        "RUN_NUMBER":        data["run_number"],
        "RUN_URL":           data["run_url"],
        "REPO_URL":          f'https://github.com/{data["repo"]}',
        "COMMIT_SHORT":      data["commit_sha"][:7],
        "COMMIT_URL":        data["commit_url"],
        "COMMIT_SUBJECT":    data["commit_subject"],
        "DEPLOY_UTC":        fmt_utc(deployed),
        "DEPLOY_WIB":        fmt_wib(deployed),
        "DEPLOY_METHOD":     data["deploy_method"],
        "DEPLOY_METHOD_CMD": data["deploy_method_cmd"],
        "POINTER":           data["pointer"],
        "POINTER_KIND_ID":   prose["pointer_kind"][0],
        "POINTER_KIND_EN":   prose["pointer_kind"][1],
        "RELEASE_DEPLOYED":  data["release_deployed"],
        "RELEASE_ACTIVE":    data["release_active"],
        "BUILD_V1":          data["build_v1"],
        "BUILD_V2":          data["build_v2"],
        "SMOKE_URL":         data["smoke_url"],
        "SMOKE_TOOL":        data["smoke_tool"],
        "RB_FROM":           data["rollback"]["from"],
        "RB_TO":             data["rollback"]["to"],
        "RB_TO_RELEASE":     data["rollback"]["to_release"],
        "RB_MS":             data["rollback"]["ms"],
        "RB_OPS_WORD_ID":    OPS_WORD[ops][0],
        "RB_OPS_WORD_EN":    OPS_WORD[ops][1],
        "RB_OPS_DETAIL_ID":  prose["rollback_detail"][0],
        "RB_OPS_DETAIL_EN":  prose["rollback_detail"][1],
        "TITLE_ID":          title_id,
        "TITLE_EN":          title_en,
        "LEDE_ID":           lede_id,
        "LEDE_EN":           lede_en,
        "OTHER_HREF":        f"../{other}/",
        "OTHER_LABEL":       other_label,
    }

    page = template
    for key, value in values.items():
        page = page.replace("{{" + key + "}}", e(value))

    # Dua blok ini sudah berupa HTML, jadi disisipkan setelah yang lain dan
    # tidak lewat escape.
    page = page.replace("{{SMOKE_ROWS}}", smoke_rows(data))
    page = page.replace("{{HISTORY_ROWS}}", history_rows(history, data["build_id"]))

    leftover = set(re.findall(r"\{\{([A-Z_]+)\}\}", page))
    if leftover:
        raise SystemExit(f"placeholder belum terisi di template: {sorted(leftover)}")
    return page


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts", required=True, type=pathlib.Path)
    ap.add_argument("--template", required=True, type=pathlib.Path)
    ap.add_argument("--out", required=True, type=pathlib.Path)
    args = ap.parse_args()

    template = args.template.read_text(encoding="utf-8")
    history_path = args.out / "history.json"
    history = load_history(history_path)

    for platform in ("linux", "windows"):
        source = args.artifacts / f"result-{platform}.json"
        if not source.exists():
            raise SystemExit(f"metadata tidak ada: {source}")
        data = json.loads(source.read_text(encoding="utf-8"))

        missing = [k for k in REQUIRED if k not in data]
        if missing:
            raise SystemExit(f"{source.name} kehilangan field: {missing}")

        history[platform] = push_history(history[platform], data)

        target = args.out / platform
        target.mkdir(parents=True, exist_ok=True)
        page = render(template, data, history[platform])
        (target / "index.html").write_text(page, encoding="utf-8")
        print(f"==> {target / 'index.html'}  ({len(page)} bytes)")

    history_path.write_text(
        json.dumps(history, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"==> {history_path}")


if __name__ == "__main__":
    main()
