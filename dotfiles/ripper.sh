#!/usr/bin/env bash
#
# Author: postmodern
# Description:
#   Rips a DVD to a H.264 MKV file, with chapters and tags. Ignores any
#   bad blocks or sectors on the DVD.
# Dependencies:
#  * gddrescue
#  * handbrake-cli
#  * mkvtoolnix
#

set -e
#set -x

shopt -s extglob

rip_dvd_version=0.12.0

dvd_device="/dev/dvd"
dvd_blocksize=2048
dvd_fps=30
video_codec="x264"
video_quality="20.0"
audio_codec="vorbis"
x264_tune="film"
x264_preset="veryslow"
x264_profile="high"
ddrescue_passes=2
cleanup="true"
handbrake_opts=()

function print_help()
{
    cat <<USAGE
usage: rip_dvd [OPTIONS] "TITLE" [-- HANDBRAKE_OPTS]

Options:
    -d,--device DEV         The dvd device.
                        Default: $dvd_device
    -t,--dvd-title NUM      Rips the specific title from the DVD.
    -c,--chapters N[-M]     Rips the specific chapter(s)
    --start-at [[HH:]MM:]SS     Starts ripping at the absolute time.
    --stop-at [[HH:]MM:]SS      Stops ripping at the given time.
    --x264-tune TUNE        What type of video to tune for.
                        Default: $x264_tune
    --x264-profile PROFILE      Encoding profile
                        Default: $x264_profile
    --x264-preset PRESET        Encoding preset
                        Default: $x264_preset
    --video-codec           Video codec to encode with
                        Default: $video_codec
    --video-quality         Video quality
                        Default: $video_quality
    --audio-codec           Audio codec to encode with
                        Default: $audio_codec
    -T,--content-type TYPE      MKV Content-Type
    -K,--keyowrds WORD,[...]    MKV Keywords
    --ddrescue-passes 0,1,2,3   The number of ddrescue passes
    --[no-]cleanup          Delete files after ripping
    -V,--version            Print the version
    -h,--help           Print this message

Examples:
    rip_dvd "Stargate I"
    rip_dvd --dvd-title 3 "Stargate I"
    rip_dvd --dvd-title 3 --chapters 2-40 "Stargate I"
    rip_dvd --dvd-title 3 --start-at 42 --stop-at 1:45:00.500 "Stargate I" -- --detelecine

USAGE
}

function parse_options()
{
    while (( $# > 0 )); do
        case "$1" in
            -d|--device)
                dvd_device="$2"
                shift 2
                ;;
            -t|--dvd-title)
                dvd_title="$2"
                shift 2
                ;;
            -c|--chapters)
                chapters="$2"
                first_chapter="${2%%-*}"
                last_chapter="${2##*-}"
                shift 2
                ;;
            --start-at)
                start_at="$2"
                shift 2
                ;;
            --stop-at)
                stop_at="$2"
                shift 2
                ;;
            --video-codec)
                video_codec="$2"
                shift 2
                ;;
            --video-quality)
                video_quality="$2"
                shift 2
                ;;
            --audio-codec)
                audio_codec="$2"
                shift 2
                ;;
            --x264-profile)
                x264_profile="$2"
                shift 2
                ;;
            --x264-tune)
                x264_tune="$2"
                shift 2
                ;;
            --x264-preset)
                x264_preset="$2"
                shift 2
                ;;
            -T|--content-type)
                mkv_content_type="$2"
                shift 2
                ;;
            -K|--keywords)
                mkv_keywords="$2"
                shift 2
                ;;
            --cleanup)
                cleanup="true"
                shift
                ;;
            --ddrescue-passes)
                ddrescue_passes="$1"
                shift 2
                ;;
            --no-cleanup)
                cleanup="false"
                shift
                ;;
            -V|--version)
                echo "rip_dvd $rip_dvd_version"
                exit
                ;;
            -h|--help)
                print_help
                exit
                ;;
            --)
                shift
                handbrake_opts+=($@)
                break
                ;;
            -*)
                error "unknown option $1"
                exit -1
                ;;
            *)
                if [[ -n "$title" ]]; then
                    error "additional argument $1"
                    exit -1
                fi

                title="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$title" ]]; then
        error "no title argument given"
        exit -1
    fi

    output="${title}.mkv"
    working_dir="$title"
}

function log()
{
    if [[ -t 1 ]]; then
        echo -e "\x1b[1m\x1b[32m>>>\x1b[0m \x1b[1m$1\x1b[0m"
    else
        echo ">>> $1"
    fi
}

function warn()
{
    if [[ -t 1 ]]; then
        echo -e "\x1b[1m\x1b[33m***\x1b[0m \x1b[1m$1\x1b[0m" >&2
    else
        echo "*** $1" >&2
    fi
}

function error()
{
    if [[ -t 1 ]]; then
        echo -e "\x1b[1m\x1b[31m!!!\x1b[0m \x1b[1m$1\x1b[0m" >&2
    else
        echo "!!! $1" >&2
    fi
}

function fail()
{
    error "$@"
    exit -1
}

function load_dvd_info()
{
    if [[ -z "$dvd_title" ]]; then
        local line="$(lsdvd dvd.iso | tail -n 1)"

        dvd_title="${line#Longest track: }"
    fi
}

function time2s()
{
    local time="$1"
    local parts=(${time//:/ })

    for i in $(seq 0 $(( ${#parts[@]} - 1 ))); do
        parts[$i]=${parts[$i]#0}
    done

    case "${#parts[@]}" in
        3)  echo -n $(( ${parts[0]} * 3600 + ${parts[1]} * 60 + ${parts[2]} )) ;;
        2)  echo -n $(( ${parts[0]} * 60 + ${parts[1]} )) ;;
        1)  echo -n ${parts[0]} ;;
        0)  echo -n 0 ;;
    esac
}

function time2frame()
{
    local s="$(time2s "$1")"

    echo -n $(( s * dvd_fps ))
}

function chapter2time()
{
    local chapter="${1#\#}"
    local line="$(dvdxchap -t "$dvd_title" "$dvd_device" | grep "CHAPTER0*${chapter}=")"
    local time="${line#*=}"

    echo -n "${time%.*}"
}

function chapter2frame()
{
    time2frame "$(chapter2time "$1")"
}

function backup_file()
{
    local file="$1"

    if [[ -f "$file" ]]; then
        cp "$file" "${file}.bak"
    fi
}

function enter_working_directory()
{
    mkdir -p "$working_dir"
    pushd "$working_dir" > /dev/null

    output="../$output"
}

function copy_dvd()
{
    if [[ -f dvd.iso ]]; then
        return
    fi

    ddrescue -b "$dvd_blocksize" -r 0 -n "$dvd_device" dvd.iso.part dvd.log

    if (( ddrescue_passes > 1 )); then
        ddrescue -b "$dvd_blocksize" -d "$dvd_device" -r 0 dvd.iso.part dvd.log
    fi

    if (( ddrescue_passes > 2 )); then
        ddrescue -b "$dvd_blocksize" -d -R "$dvd_device" -r 0 dvd.iso.part dvd.log
    fi

    mv dvd.iso.part dvd.iso
}

function rip_dvd_title()
{
    if [[ -f video.mkv ]]; then
        return
    fi

    local options=(
        --input dvd.iso
        --format mkv
        --output video.mkv.part
        --markers
        --use-opencl
    )

    if [[ -n "$dvd_title" ]]; then
        options+=(--title "$dvd_title")
    else
        options+=(--main-feature)
    fi

    # seeking options
    if [[ -n "$chapters" ]]; then
        options+=(--chapters "$chapters")
    fi

    local start_at_frame stop_at_frame

    if [[ -n "$start_at" ]]; then
        if [[ "$start_at" == "#"* ]]; then
            start_at_frame="$(chapter2frame "$start_at")"
        else
            start_at_frame="$(time2frame "$start_at")"
        fi

        options+=(--start-at "frame:${start_at_frame}")
    fi

    if [[ -n "$stop_at" ]]; then
        if [[ "$stop_at" == "#"* ]]; then
            stop_at_frame="$(chapter2frame "$stop_at")"
        else
            stop_at_frame="$(time2frame "$stop_at")"
        fi

        if [[ -n "$start_at_frame" ]]; then
            stop_at_frame=$(( stop_at_frame - start_at_frame ))
        fi

        options+=(--stop-at "frame:${stop_at_frame}")
    fi

    # video options
    options+=(
        --encoder "$video_codec"
        --quality "$video_quality"
        --loose-anamorphic
    )

    case "$video_codec" in
        x264)
            options+=(
                --x264-preset "$x264_preset"
                --x264-profile "$x264_profile"
                --x264-tune "$x264_tune"
            )
            ;;
    esac

    # audio options
    options+=(--aencoder "$audio_codec")

    HandBrakeCLI "${options[@]}" "${handbrake_opts[@]}"
    mv video.mkv.part video.mkv
}

function generate_tags_xml()
{
    backup_file tags.xml

    cat > tags.xml <<EOS
<Tags>
  <Tag>
    <Targets>
      <TargetTypeValue>50</TargetTypeValue>
    </Targets>
    <Simple>
      <Name>TITLE</Name>
      <String>$title</String>
    </Simple>
  </Tag>
  <Tag>
    <Targets>
      <TargetTypeValue>50</TargetTypeValue>
    </Targets>
    <Simple>
      <Name>ORIGINAL_MEDIA_TYPE</Name>
      <String>DVD</String>
    </Simple>
  </Tag>
EOS

    if [[ -n "$mkv_content_type" ]]; then
        cat >> tags.xml <<EOS
  <Tag>
    <Targets>
      <TargetTypeValue>50</TargetTypeValue>
    </Targets>
    <Simple>
      <Name>CONTENT_TYPE</Name>
      <String>$mkv_content_type</String>
    </Simple>
  </Tag>
EOS
    fi

    if [[ -n "$mkv_keywords" ]]; then
        cat >> tags.xml <<EOS
  <Tag>
    <Targets>
      <TargetTypeValue>50</TargetTypeValue>
    </Targets>
    <Simple>
      <Name>KEYWORDS</Name>
      <String>$mkv_keywords</String>
    </Simple>
  </Tag>
EOS
    fi

    cat >> tags.xml <<EOS
  <Tag>
    <Targets>
      <TargetTypeValue>50</TargetTypeValue>
    </Targets>
    <Simple>
      <Name>RIP_DVD_VERSION</Name>
      <String>$rip_dvd_version</String>
    </Simple>
  </Tag>
EOS

    if [[ -n "$dvd_title" ]]; then
        cat >> tags.xml <<EOS
  <Tag>
    <Targets>
      <TargetTypeValue>50</TargetTypeValue>
    </Targets>
    <Simple>
      <Name>RIP_DVD_TITLE</Name>
      <String>$dvd_title</String>
    </Simple>
  </Tag>
EOS
    fi

    if [[ -n "$chapters" ]]; then
        cat >> tags.xml <<EOS
  <Tag>
    <Targets>
      <TargetTypeValue>50</TargetTypeValue>
    </Targets>
    <Simple>
      <Name>RIP_DVD_CHAPTERS</Name>
      <String>$chapters</String>
    </Simple>
  </Tag>
EOS
    fi

    if [[ -n "$start_at" ]]; then
        cat >> tags.xml <<EOS
  <Tag>
    <Targets>
      <TargetTypeValue>50</TargetTypeValue>
    </Targets>
    <Simple>
      <Name>RIP_DVD_START_AT</Name>
      <String>$start_at</String>
    </Simple>
  </Tag>
EOS
    fi

    if [[ -n "$stop_at" ]]; then
        cat >> tags.xml <<EOS
  <Tag>
    <Targets>
      <TargetTypeValue>50</TargetTypeValue>
    </Targets>
    <Simple>
      <Name>RIP_DVD_STOP_AT</Name>
      <String>$stop_at</String>
    </Simple>
  </Tag>
EOS
    fi

    if ((  ${#handbrake_opts[@]} > 0 )); then
        cat >> tags.xml <<EOS
  <Tag>
    <Targets>
      <TargetTypeValue>50</TargetTypeValue>
    </Targets>
    <Simple>
      <Name>RIP_DVD_HANDBRAKE_OPTS</Name>
      <String>${handbrake_opts[@]}</String>
    </Simple>
  </Tag>
EOS
    fi

    cat >> tags.xml <<EOS
</Tags>
EOS

    mkvpropedit video.mkv -t global:tags.xml >/dev/null
}

function leave_working_directory()
{
    popd >/dev/null
    output="${output#../}"

    if [[ "$cleanup" == "true" ]]; then
        mv "$working_dir/video.mkv" "$output"
        rm -r "$working_dir"
    fi
}

parse_options "$@"

enter_working_directory

log "Copying DVD $dvd_device ..."
copy_dvd
load_dvd_info

log "Ripping DVD \"$title\" ${start_at:+@$start_at${stop_at:+-$stop_at} }${chapters:+Chapters $chapters }..."
rip_dvd_title
log "DVD ripped!"

log "Adding tags"
generate_tags_xml

leave_working_directory
