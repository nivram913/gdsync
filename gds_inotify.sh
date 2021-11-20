#! /bin/bash

GDS_INDEX_FILE="$HOME/.gds_index" # Index file of gdsync

inotifywait -q -m -r -e modify --format '%w%f' --fromfile "$GDS_INDEX_FILE" "$HOME/.gds_index" |
while read file
do
    echo "$file"
    if test "$file" = "$HOME/.gds_index"
    then
        $0 &
        exit 0
    else
        gio set "$file" -t stringv metadata::emblems emblem-colors-red
    fi
done

exit 0
