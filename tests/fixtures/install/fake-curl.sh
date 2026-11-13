#!/bin/sh
set -eu

output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--output)
            [ "$#" -ge 2 ] || { printf '%s\n' 'fake curl: missing output path' >&2; exit 2; }
            output=$2
            shift 2
            ;;
        --retry|--connect-timeout|--max-time)
            [ "$#" -ge 2 ] || { printf '%s\n' "fake curl: missing value for $1" >&2; exit 2; }
            shift 2
            ;;
        -f|-s|-S|-L|-fsSL|--fail|--silent|--show-error|--location)
            shift
            ;;
        --)
            shift
            ;;
        https://*)
            [ -z "$url" ] || { printf '%s\n' 'fake curl: multiple URLs' >&2; exit 2; }
            url=$1
            shift
            ;;
        http://*)
            printf '%s\n' 'fake curl: HTTPS required' >&2
            exit 2
            ;;
        *)
            printf '%s\n' "fake curl: unsupported argument: $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$url" ] || { printf '%s\n' 'fake curl: missing URL' >&2; exit 2; }
[ -n "$output" ] || { printf '%s\n' 'fake curl: missing output path' >&2; exit 2; }
[ -n "${FARPILOT_TEST_DOWNLOADS:-}" ] || { printf '%s\n' 'fake curl: FARPILOT_TEST_DOWNLOADS is required' >&2; exit 2; }

name=${url##*/}
case "$name" in
    ''|.|..|*%2f*|*%2F*|*%5c*|*%5C*)
        printf '%s\n' 'fake curl: unsafe URL basename' >&2
        exit 2
        ;;
esac
source=$FARPILOT_TEST_DOWNLOADS/$name
if [ ! -f "$source" ] || [ -L "$source" ]; then
    printf '%s\n' "fake curl: fixture is missing or unsafe: $name" >&2
    exit 22
fi
if [ -n "${FARPILOT_TEST_CURL_LOG:-}" ]; then
    printf '%s\n' "$url" >> "$FARPILOT_TEST_CURL_LOG"
fi
cp "$source" "$output"
