#! /bin/bash

GDS_INDEX_FILE="$HOME/.gds_index" # Index file of gdsync
gdsync.sh --update-gio

inotifywait -q -m -r -e modify --format '%w%f' --fromfile "$GDS_INDEX_FILE" "$GDS_INDEX_FILE" |
while read file
do
    #echo "$file"
    if test "$file" = "$GDS_INDEX_FILE"
    then
        sleep 5
        xfce4-panel --plugin-event=genmon:refresh:bool:true
        $0 &
        exit 0
    else
        gio set "$file" -t stringv metadata::emblems emblem-colors-red
        xfce4-panel --plugin-event=genmon:refresh:bool:true
    fi
done

exit 0
