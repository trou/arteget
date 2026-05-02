# arteget HLS: m3u8-based replacement for parse_m3u
# Copyright 2008-2026 Raphaël Rigo
# GPL v2

from urllib.parse import urljoin

import m3u8

# Map quality option to preferred resolution / name patterns (best first).
# sq=small, eq=medium, mq=medium-high, xq=extra (1080p).
QUALITY_PREFERENCE = {
    "sq": ["v360", "v480", "v720", "v1080"],
    "eq": ["v480", "v720", "v360", "v1080"],
    "mq": ["v720", "v1080", "v480", "v360"],
    "xq": ["v1080", "v720", "v480", "v360"],
}


def _resolve_uri(base_uri: str, uri: str) -> str:
    if not uri:
        return base_uri
    if not base_uri.endswith("/"):
        base_uri = base_uri.rsplit("/", 1)[0] + "/"
    return urljoin(base_uri, uri)


def _init_segment_url(media_playlist: m3u8.M3U8) -> str | None:
    """Get first init segment (EXT-X-MAP) URL from a media playlist, or None."""
    if not getattr(media_playlist, "segment_map", None):
        return None
    for init in media_playlist.segment_map:
        if init and getattr(init, "uri", None):
            base = getattr(media_playlist, "base_uri", None) or ""
            return _resolve_uri(base, init.uri)
    return None


def get_video_audio_urls(
    playlist_url: str,
    quality: str,
    *,
    fetch=None,
) -> tuple[str, str]:
    """
    Parse HLS master playlist and return (video_init_url, audio_init_url)
    for the selected quality, matching legacy parse_m3u behaviour.
    """
    if fetch is not None:
        content = fetch(playlist_url)
        master = m3u8.loads(content, uri=playlist_url)
    else:
        master = m3u8.load(playlist_url)

    base_uri = getattr(master, "base_uri", None) or playlist_url.rsplit("/", 1)[0] + "/"

    # Select video variant by quality
    preferred = QUALITY_PREFERENCE.get(quality, QUALITY_PREFERENCE["xq"])
    video_playlist = None
    for name in preferred:
        for pl in master.playlists:
            pl_uri = getattr(pl, "uri", None) or ""
            if name in pl_uri:
                video_playlist = pl
                break
        if video_playlist is not None:
            break
    if video_playlist is None and master.playlists:
        video_playlist = master.playlists[0]

    if not video_playlist:
        raise ValueError("No video playlist found in master")

    vid_p_url = _resolve_uri(base_uri, video_playlist.uri)

    # Select audio: first EXT-X-MEDIA TYPE=AUDIO with URI
    aud_p_url = None
    for m in getattr(master, "media", []) or []:
        if (getattr(m, "type", None) or "").upper() == "AUDIO" and getattr(
            m, "uri", None
        ):
            aud_p_url = _resolve_uri(base_uri, m.uri)
            break
    if not aud_p_url:
        raise ValueError("No audio media playlist found in master")

    # Load media playlists and get init segment URLs (EXT-X-MAP)
    if fetch is not None:
        vid_content = fetch(vid_p_url)
        vid_pl = m3u8.loads(vid_content, uri=vid_p_url)
        aud_content = fetch(aud_p_url)
        aud_pl = m3u8.loads(aud_content, uri=aud_p_url)
    else:
        vid_pl = m3u8.load(vid_p_url)
        aud_pl = m3u8.load(aud_p_url)

    vid_url = _init_segment_url(vid_pl)
    aud_url = _init_segment_url(aud_pl)
    if not vid_url or not aud_url:
        raise ValueError(
            "Could not find EXT-X-MAP (init segment) in video or audio playlist"
        )

    return (vid_url, aud_url)


def get_subtitles_list(master: m3u8.M3U8, base_uri: str) -> list[dict]:
    """
    From a parsed master playlist, return list of subtitle tracks (EXT-X-MEDIA TYPE=SUBTITLES).
    Each item: {"index": i, "group_id": str, "language": str, "name": str, "uri": str}.
    """
    out = []
    for i, m in enumerate(getattr(master, "media", []) or []):
        if (getattr(m, "type", None) or "").upper() != "SUBTITLES":
            continue
        uri = getattr(m, "uri", None)
        if not uri:
            continue
        out.append(
            {
                "index": i,
                "group_id": getattr(m, "group_id", None) or "",
                "language": getattr(m, "language", None) or "",
                "name": getattr(m, "name", None) or "",
                "uri": _resolve_uri(base_uri, uri),
            }
        )
    return out


def get_subtitle_vtt_urls(subtitle_playlist_url: str, fetch) -> list[str]:
    """
    Fetch subtitle m3u8 and return list of VTT segment URLs (resolved).
    Handles both segmented playlists and single-VTT playlists.
    """
    content = fetch(subtitle_playlist_url)
    sub_pl = m3u8.loads(content, uri=subtitle_playlist_url)
    base_uri = (
        getattr(sub_pl, "base_uri", None)
        or subtitle_playlist_url.rsplit("/", 1)[0] + "/"
    )
    segments = getattr(sub_pl, "segments", []) or []
    if segments:
        return [
            _resolve_uri(base_uri, getattr(s, "uri", None) or "")
            for s in segments
            if getattr(s, "uri", None)
        ]
    # No segments: some manifests have a single resource; check for segment_map (init) or other
    if getattr(sub_pl, "segment_map", None):
        for init in sub_pl.segment_map:
            if init and getattr(init, "uri", None):
                return [_resolve_uri(base_uri, init.uri)]
    return []
