#! /usr/bin/env python3
# arteget CLI
# Copyright 2008-2026 Raphaël Rigo
# GPL v2

import argparse
import logging
import os
import re
import sys
import shutil

from arteget import api

logger = logging.getLogger(__name__)

LOG_ERROR = -1
LOG_QUIET = 0
LOG_NORMAL = 1
LOG_DEBUG = 2
LOG_DEBUG2 = 3

QUALITY = ["sq", "eq", "mq", "xq"]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Download television programs from Arte +7 site",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=""":
  URL: download the video on this page
  program: download the latest available broadcasts of "program"
""",
    )
    parser.add_argument(
        "program_or_url", nargs="?", help="program name or Arte video URL"
    )
    parser.add_argument("--quiet", action="store_true", help="only error output")
    parser.add_argument(
        "--variant",
        metavar="VARIANT",
        help="try to download specified version (e.g. 'VF-STF', 'VA-STA', 'VO-STF'), "
        "'list' display available values and exit.",
    )
    parser.add_argument(
        "-D",
        "--description",
        action="store_true",
        help="save description along with the file",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="debug output")
    parser.add_argument(
        "-V", "--veryverbose", action="store_true", help="debug2 output"
    )
    parser.add_argument(
        "-m",
        "--min-dur",
        metavar="M",
        type=int,
        default=0,
        help="minimum duration (seconds)",
    )
    parser.add_argument(
        "-f", "--force", action="store_true", help="overwrite destination file"
    )
    parser.add_argument(
        "-l",
        "--lang",
        metavar="LANG",
        default="fr",
        help='choose language, german (de) or french (fr) (default is "fr")',
    )
    parser.add_argument(
        "-q",
        "--qual",
        metavar="QUAL",
        choices=QUALITY,
        default="xq",
        help="choose quality (default: xq)",
    )
    parser.add_argument(
        "-o",
        "--output",
        dest="filename",
        metavar="filename",
        help="filename if downloading only one program",
    )
    parser.add_argument(
        "--subs",
        metavar="SUB",
        help="subtitles: use 'list' to list available tracks, or index (e.g. 0) / group-id (e.g. subtitle_0) to download; outputs .vtt and .srt",
    )
    parser.add_argument(
        "-n", "--num", metavar="N", type=int, default=1, help="download N programs"
    )
    parser.add_argument(
        "-d",
        "--dest",
        metavar="directory",
        dest="dest",
        help="destination directory",
    )
    args = parser.parse_args()

    # Resolve log level and configure logging
    if args.quiet:
        args.log = LOG_QUIET
    elif args.veryverbose:
        args.log = LOG_DEBUG2
    elif args.verbose:
        args.log = LOG_DEBUG
    else:
        args.log = LOG_NORMAL

    log_level = (
        logging.ERROR
        if args.log == LOG_QUIET
        else (logging.DEBUG if args.log >= LOG_DEBUG else logging.INFO)
    )
    logging.basicConfig(level=log_level, format="%(message)s")

    if args.dest is not None:
        if not os.path.isdir(args.dest):
            logger.error("Destination is not a directory")
            sys.exit(1)

    if not args.program_or_url:
        parser.print_help()
        sys.exit(0)

    progname = args.program_or_url

    if not shutil.which("wget"):
        logger.error("wget not found")
        sys.exit(1)
    if not shutil.which("ffmpeg"):
        logger.error("ffmpeg not found")
        sys.exit(1)

    if re.match(r"^https:", progname):
        logger.info("Trying with URL")
        vid_id_match = re.search(r"([0-9]{6}-[0-9]{3}(-[AF])?)", progname)
        if not vid_id_match:
            api.fatal("No video id in URL")
        vid_id = vid_id_match.group(1)
        url_match = re.search(r".*arte\.tv(\/.*)", progname)
        videos = [{"url": url_match.group(1) if url_match else "", "id": vid_id}]
    else:
        videos = api.get_videos(args.lang, progname, args.num, args)

    if len(videos) > 1:
        logger.info("Found %d videos", len(videos))
    for video in videos:
        logger.debug("%s", video)
        try:
            api.dump_video(video, args)
        except SystemExit:
            raise
        print()


if __name__ == "__main__":
    main()
