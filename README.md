# arteget

Download television programs from the Arte +7 site.

Requires Python 3.10+, `wget` and `ffmpeg` in your PATH.

## Installation

```sh
pip install .
```

Or run directly without installing:

```sh
./arteget-cli.py <program or URL>
```

## Usage

```
arteget [options] <program name or URL>
```

### Examples

```sh
# Latest broadcast of a program
arteget karambolage

# Latest broadcast that is at least 5 minutes long, with description saved
arteget -D -m 300 karambolage

# Single video by URL
arteget https://www.arte.tv/fr/videos/098342-009-A/karambolage/

# German, standard quality
arteget -q sq -l de karambolage

# Up to 100 broadcasts
arteget -n 100 RC-014034

# List available subtitle tracks
arteget --subs list https://www.arte.tv/fr/videos/098342-009-A/karambolage/

# Download with subtitles (by index or language code)
arteget --subs 0 karambolage

# List available language variants
arteget --variant list karambolage
```

### Quality (`-q` / `--qual`)

| Option | Resolution      |
|--------|-----------------|
| `xq`   | 1080p (default) |
| `mq`   | 720p            |
| `eq`   | 480p            |
| `sq`   | 360p            |

## Notes

Specifying an arbitrary string instead of a URL uses the search engine,
so you have some freedom there.
