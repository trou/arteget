# arteget API: fetch, Arte JSON, get_videos, find_prog, dump_video
# Copyright 2008-2026 Raphaël Rigo
# GPL v2

import json
import logging
import os
import pprint
import re
import subprocess
import time
from typing import NamedTuple, NoReturn
from urllib.parse import quote

import requests

import m3u8

from arteget.hls import get_subtitle_vtt_urls, get_subtitles_list, get_video_audio_urls

logger = logging.getLogger(__name__)


def fetch(uri: str, limit: int = 10, session: requests.Session | None = None) -> str:
    if limit == 0:
        raise ValueError("too many HTTP redirects")
    session = session or requests.Session()
    resp = session.get(uri, allow_redirects=False, timeout=30)
    if resp.is_redirect and resp.headers.get("location"):
        location = resp.headers["location"]
        logger.debug("redirected to %s", location)
        return fetch(location, limit=limit - 1, session=session)
    resp.raise_for_status()
    return resp.text


def fatal(msg: str) -> NoReturn:
    logger.error(msg)
    raise SystemExit(1)


def _unwrap_ok(parsed: dict) -> dict:
    """Unwrap Arte API response envelope {"tag": "Ok", "value": ...}, or fatal on error."""
    if parsed.get("tag") == "Ok":
        return parsed["value"]
    fatal("Server returned an error")


def find_prog(prog: str, options) -> dict:
    prog_enc = quote(prog, safe="")
    lang = options.lang
    search_url = f"https://www.arte.tv/api/rproxy/emac/v4/{lang}/web/pages/SEARCH/?query={prog_enc}"
    logger.debug("Searching for %s at %s", prog, search_url)
    text = fetch(search_url)
    logger.debug("%s", text)
    results = json.loads(text)
    data = results["value"]["zones"][0]["content"]["data"]
    if not data:
        fatal("Cannot find requested program(s)")
    return data[0]


def _resolve_next_url(link: str | None) -> str | None:
    """Turn pagination next link into full URL, or None if no link."""
    if not link:
        return None
    next_entry = link.replace("/api/emac/", "/api/rproxy/emac/")
    if next_entry.startswith("http"):
        return next_entry.replace("api-cdn.arte.tv", "www.arte.tv")
    return "https://www.arte.tv" + next_entry


def _parse_program_page(url: str, id_: str) -> list[dict]:
    """Fallback: parse program page HTML to extract teaser list."""
    prog_page = fetch(url)
    prog_json_match = re.search(r"window\.__INITIAL_STATE__ = (.*);", prog_page)
    if prog_json_match:
        prog_json_str = prog_json_match.group(1)

        def prog_keys(j: dict) -> dict:
            return j.get("pages", {}).get("list", {})

    else:
        prog_json_match = re.search(
            r'<script id="__NEXT_DATA__" type="application/json">([^<]+)</script>',
            prog_page,
        )
        if not prog_json_match:
            fatal("Error: could not parse program JSON")
        prog_json_str = prog_json_match.group(1)

        def prog_keys(j: dict) -> dict:
            return j.get("props", {}).get("pageProps", {})

    logger.debug("%s", prog_json_str)
    logger.debug("Program id: %s", id_)
    try:
        prog_list = prog_keys(json.loads(prog_json_str))
    except (TypeError, json.JSONDecodeError):
        fatal("Error: could not parse program JSON")
    if not prog_list:
        fatal("Error: could not find program info")

    key = id_ + "_{}"
    if key not in prog_list:
        key = next((k for k in prog_list if id_ in k), None)
    if not key:
        for k, v in prog_list.items():
            if isinstance(v, dict) and "zones" in v:
                key = k
                break
    if not key:
        fatal("Error: could not find program info")
    if id_ not in (prog_list[key].get("id") or ""):
        logger.debug("Program id %s doesn't match %s", prog_list[key].get("id"), id_)

    prog_parsed = prog_list[key]["zones"]
    list_ = next(
        (
            p
            for p in prog_parsed
            if (p.get("code") or {}).get("name") == "collection_videos"
        ),
        None,
    )
    if not list_:
        logger.debug("No collection found, trying program")
        list_ = next(
            (
                p
                for p in prog_parsed
                if (p.get("code") or {}).get("name") == "program_content"
            ),
            None,
        )
        if not list_:
            fatal("Could not find program")
        type_ = "program"
    else:
        type_ = "teaser"

    if not list_.get("data"):
        collections = [
            p
            for p in prog_parsed
            if (p.get("code") or {}).get("name") == "collection_subcollection"
        ]
        list_["data"] = [item for c in collections for item in c.get("data", [])]

    return [e for e in list_["data"] if e.get("type") == type_]


def get_videos(lang: str, progname: str, num: int, options) -> list[dict]:
    progs = find_prog(progname, options)
    if not progs or "url" not in progs:
        fatal("Cannot find requested program(s)")
    url = progs["url"]
    id_ = progs["programId"]
    teasers = []

    collec_url = (
        f"https://www.arte.tv/api/rproxy/emac/v4/{options.lang}/web/collections/{id_}"
    )
    logger.info("Getting %s JSON collection at %s", progname, collec_url)
    resp = requests.get(collec_url, timeout=30)
    logger.debug("JSON collection HTTP code: %s", resp.status_code)
    next_url = None
    entries = None
    if resp.status_code == 200:
        logger.debug("%s", resp.text)
        coll_parsed = _unwrap_ok(resp.json())
        if coll_parsed.get("type") == "collection":
            entries = next(
                (
                    e
                    for e in coll_parsed["zones"]
                    if re.match(r"^collection_videos", e.get("code", "") or "")
                ),
                None,
            )
            if entries is None:
                fatal("Could not get collection")
            if not entries["content"]["data"]:
                entries = next(
                    (
                        e
                        for e in coll_parsed["zones"]
                        if re.match(
                            r"^collection_subcollection", e.get("code", "") or ""
                        )
                    ),
                    None,
                )
            if entries:
                teasers.extend(
                    e
                    for e in entries["content"]["data"]
                    if e.get("type") == "teaser"
                    and (e.get("duration") or 0) > getattr(options, "min_dur", 0)
                )
            try:
                next_url = _resolve_next_url(
                    entries["content"]["pagination"]["links"]["next"]
                )
            except (KeyError, TypeError):
                next_url = None
    else:
        fatal("Could not get collection")

    if entries is not None:
        logger.debug("%s", entries)

    while len(teasers) < num and next_url:
        logger.info("Getting %s next page JSON collection at %s", progname, next_url)
        resp = requests.get(next_url, timeout=30)
        if resp.status_code != 200:
            fatal("Could not get next page")
        logger.debug("%s", resp.text)
        coll_parsed = _unwrap_ok(resp.json())
        teasers.extend(
            e
            for e in coll_parsed["data"]
            if e.get("type") == "teaser"
            and (e.get("duration") or 0) > getattr(options, "min_dur", 0)
        )
        next_url = _resolve_next_url(
            coll_parsed.get("pagination", {}).get("links", {}).get("next")
        )
        if not next_url:
            break

    if not teasers:
        teasers = _parse_program_page(url, id_)

    logger.debug("%s", [e.get("programId") for e in teasers])
    prog_res = sorted(teasers, key=lambda e: e.get("programId") or "", reverse=True)[
        :num
    ]
    return [{"title": cur.get("title"), "id": cur["programId"]} for cur in prog_res]


def display_variants(vid_json_data: dict) -> None:
    streams = vid_json_data["attributes"]["streams"]
    logger.debug("%s", streams)
    variants = []
    for h in streams[0]["versions"]:
        v = (h["code"], h["label"])
        if v not in variants:
            variants.append(v)
    if variants:
        logger.info("%7s | %s", "Variant", "Description")
        for v in variants:
            logger.info("%7s | %s", v[0], v[1])
    else:
        logger.info("Unable to find any variant")


def do_wget(url: str, filename: str) -> bool:
    logger.debug('wget -nv -O "%s" "%s"', filename, url)
    r = subprocess.run(["wget", "-nv", "-O", filename, url])
    if r.returncode == 0:
        logger.info("File successfully dumped")
        return True
    if r.returncode == 2:
        logger.warning("wget exited, trying to resume")
        r = subprocess.run(["wget", "-c", "-O", filename, url])
        if r.returncode == 0:
            logger.info("File successfully resumed")
            return True
    logger.error("wget failed")
    return False


class OutputPaths(NamedTuple):
    prefix: str
    out_filename: str
    video_path: str
    video_base: str  # no extension, used for subtitle paths (.vtt / .srt)


def _output_paths(vid_id: str, title: str, qual: str, options) -> OutputPaths:
    dest = getattr(options, "dest", None)
    filename_prefix = (dest + os.sep) if dest else ""
    safe_title = re.sub(r'[/ "*:<>?|\\]', " ", title)
    out_filename = (
        getattr(options, "filename", None) or f"{vid_id}_{safe_title}_{qual}.mp4"
    )
    video_path = filename_prefix + out_filename
    video_base = filename_prefix + os.path.splitext(out_filename)[0]
    return OutputPaths(filename_prefix, out_filename, video_path, video_base)


def _select_stream(streams: list, qual: str, variant: str | None) -> dict | None:
    """Pick one stream by variant/quality; fallback to default quality+slot. Returns stream dict or None."""
    good = None
    if variant:
        good = [
            h
            for h in streams
            if h["mainQuality"]["code"]
            and re.match(r"^" + re.escape(qual) + r"", h["mainQuality"]["code"], re.I)
            and variant == (h.get("versions") or [{}])[0].get("eStat", {}).get("ml5")
        ]
    if not good:
        if variant:
            logger.info("Variant not found ? Trying default")
        good = [
            v
            for v in streams
            if v["mainQuality"]["code"]
            and re.match(r"^" + re.escape(qual) + r"", v["mainQuality"]["code"], re.I)
            and (v.get("protocol") or "").startswith("API_HLS_NG")
            and (v.get("slot") or 0) == 1
        ]
    if len(good) > 1:
        logger.info("Several version matching, downloading the first one")
    return good[0] if good else None


def _merge_vtt_segments(segment_contents: list[str]) -> str:
    """Merge VTT segment strings: first as-is, rest with WEBVTT/NOTE header stripped. Joins with double newline."""
    parts = []
    for i, content in enumerate(segment_contents):
        if i == 0:
            parts.append(content)
        else:
            lines = content.splitlines()
            start = 0
            while start < len(lines):
                stripped = lines[start].strip()
                if (
                    stripped
                    and stripped != "WEBVTT"
                    and not stripped.startswith("NOTE")
                ):
                    break
                start += 1
            if start < len(lines):
                parts.append("\n".join(lines[start:]))
    return "\n\n".join(parts)


def _handle_subtitles(
    playlist_url: str, vid_id: str, title: str, qual: str, options, fetch
) -> None:
    """List or download subtitles from master playlist. Raises SystemExit(0) for --subs list."""
    subs_opt = getattr(options, "subs", None)
    if subs_opt is None:
        return
    master_content = fetch(playlist_url)
    master = m3u8.loads(master_content, uri=playlist_url)
    base_uri = getattr(master, "base_uri", None) or playlist_url.rsplit("/", 1)[0] + "/"
    sub_list = get_subtitles_list(master, base_uri)
    if subs_opt == "list":
        if not sub_list:
            logger.info("No subtitles found")
            raise SystemExit(0)
        logger.info("%7s | %-12s | %-6s | %s", "Index", "Group ID", "Lang", "Name")
        for s in sub_list:
            logger.info(
                "%7s | %-12s | %-6s | %s",
                s["index"],
                s["group_id"],
                s["language"],
                s["name"],
            )
        raise SystemExit(0)
    # Resolve --subs to one track: by index (int or "0") or by group_id / language
    chosen = None
    try:
        idx = int(subs_opt)
        chosen = next((s for s in sub_list if s["index"] == idx), None)
    except ValueError:
        pass
    if chosen is None:
        chosen = next((s for s in sub_list if s["group_id"] == subs_opt), None)
    if chosen is None:
        chosen = next((s for s in sub_list if s["language"] == subs_opt), None)
    if chosen is None or not sub_list:
        if not sub_list:
            fatal("No subtitles found")
        logger.error("Unknown subtitle '%s'. Available:", subs_opt)
        logger.info("%7s | %-12s | %-6s | %s", "Index", "Group ID", "Lang", "Name")
        for s in sub_list:
            logger.info(
                "%7s | %-12s | %-6s | %s",
                s["index"],
                s["group_id"],
                s["language"],
                s["name"],
            )
        fatal("Use --subs list to list tracks, or a valid index / group-id")
    vtt_urls = get_subtitle_vtt_urls(chosen["uri"], fetch=fetch)
    if not vtt_urls:
        fatal("Subtitle playlist has no VTT segments")
    paths = _output_paths(vid_id, title, qual, options)
    vtt_path = paths.video_base + ".vtt"
    srt_path = paths.video_base + ".srt"
    logger.info("Downloading subtitles to %s", vtt_path)
    logger.debug("vtt_urls: %s", vtt_urls)
    if os.path.isfile(vtt_path) and not getattr(options, "force", False):
        logger.info("Subtitle already downloaded: %s", vtt_path)
    else:
        segment_contents = []
        for url in vtt_urls:
            resp = requests.get(url, timeout=30)
            resp.raise_for_status()
            segment_contents.append(resp.content.decode("utf-8", errors="replace"))
        with open(vtt_path, "wt", encoding="utf-8") as f:
            f.write(_merge_vtt_segments(segment_contents))
        logger.info("Wrote %s", vtt_path)
    if os.path.isfile(srt_path) and not getattr(options, "force", False):
        logger.info("SRT already exists: %s", srt_path)
    else:
        r = subprocess.run(["ffmpeg", "-v", "8", "-y", "-i", vtt_path, srt_path])
        if r.returncode == 0:
            logger.info("Wrote %s", srt_path)
        else:
            logger.error("ffmpeg failed to convert VTT to SRT")
            raise SystemExit(1)


def dump_video(vidinfo: dict, options) -> None:
    title = vidinfo.get("title") or vidinfo.get("id", "")
    logger.info("Trying to get %s", title)

    logger.info("Getting video description JSON")
    vid_id = vidinfo["id"]
    lang = options.lang
    videoconf = f"https://api.arte.tv/api/player/v2/config/{lang}/{vid_id}"
    logger.debug("%s", videoconf)

    videoconf_content = fetch(videoconf)
    if re.search(r"(plus|pas) disponible", videoconf_content):
        videoconf = f"https://api.arte.tv/api/player/v2/config/{lang}/{vid_id.replace('-A', '-F')}"
        videoconf_content = fetch(videoconf)
    logger.debug("%s", videoconf_content)
    vid_json = json.loads(videoconf_content)

    if re.search(r'type": "error"', videoconf_content):
        msg = (
            vid_json.get("videoJsonPlayer", {})
            .get("custom_msg", {})
            .get("msg", "Unknown error")
        )
        logger.error("An error happened: %s", msg)
        raise SystemExit(1)

    if getattr(options, "variant", None) == "list":
        display_variants(vid_json["data"])
        raise SystemExit(0)

    logger.debug("%s", vid_json["data"])
    metadata = vid_json["data"]["attributes"].get("metadata", {})
    title = metadata.get("title") or ""
    teaser = metadata.get("description") or ""
    logger.info("%s : %s", title, teaser)

    streams = vid_json["data"]["attributes"]["streams"]
    logger.debug("streams (%s)", type(streams).__name__)
    logger.debug("%s", pprint.pformat(streams))

    qual = options.qual
    variant = getattr(options, "variant", None)
    good = _select_stream(streams, qual, variant)
    if not good:
        fatal("No such quality")

    playlist_url = good.get("url")
    if not playlist_url:
        logger.error("Stream has no URL")
        return

    logger.debug("playlist_url: %s", playlist_url)

    _handle_subtitles(playlist_url, vid_id, title, qual, options, fetch)

    vid_url, aud_url = get_video_audio_urls(playlist_url, qual, fetch=fetch)

    paths = _output_paths(vid_id, title, qual, options)
    filename = paths.video_path

    if os.path.isfile(filename) and not getattr(options, "force", False):
        logger.info("Already downloaded")
        return

    if getattr(options, "description", False):
        logger.info("Dumping description : %s.txt", filename)
        with open(filename + ".txt", "wt") as d:
            d.write(time.strftime("%Y-%m-%d %H:%M:%S\n"))
            d.write(title + "\n" + teaser + "\n")

    logger.info("Dumping video")
    if not do_wget(vid_url, filename + "-video.mp4"):
        return
    logger.info("Dumping audio")
    if not do_wget(aud_url, filename + "-audio.mp4"):
        return

    logger.info("Merging files")
    cmd = [
        "ffmpeg",
        "-v",
        "8",
        "-i",
        filename + "-video.mp4",
        "-i",
        filename + "-audio.mp4",
        "-c:v",
        "copy",
        "-c:a",
        "copy",
        filename,
    ]
    logger.debug("Merging files: %s", cmd)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == 0:
        logger.info("File successfully merged")
    else:
        logger.error("ffmpeg failed")
        return
    try:
        os.unlink(filename + "-video.mp4")
        os.unlink(filename + "-audio.mp4")
    except OSError:
        pass
