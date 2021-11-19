#! /bin/bash

GDS_INDEX_FILE="$HOME/.gds_index" # Index file of gdsync

inotifywait -q -m -r -e modify --format '%w%f' --fromfile "$GDS_INDEX_FILE" |
while read file
do
    echo "$file"
    gio set "$file" -t stringv metadata::emblems emblem-colors-red
done

exit 0
