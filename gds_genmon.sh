#! /bin/bash

GDS_INDEX_FILE="$HOME/.gds_index" # Index file of gdsync

file_not_sync()
{
    while read file
    do
        if gio info -a metadata::emblems "$file" | grep emblem-colors-red
        then
            return 0
        fi
    done < "$GDS_INDEX_FILE"
    return 1
}

if (($# == 0))
then
    if file_not_sync
    then
        echo "<img>/usr/share/icons/elementary-xfce-darker/actions/22/process-stop.png</img>"
        echo "<tool>Some files need to be synced</tool>"
    else
        echo "<img>/usr/share/icons/elementary-xfce/status/24/process-completed.png</img>"
        echo "<tool>All files are in sync</tool>"
    fi
    echo "<click>$0 action</click>"
else
    action_list=('1' 'Sync' '2' 'Pull a file from server' '3' 'Delete a file from server' '4' 'Update GIO (advanced)')
    action="$(zenity --width=200 --height=200 --hide-header --list --hide-column=1 --print-column=1 --text='Select action:' --column='num' --column='text' "${action_list[@]}")"

    case $action in
        1) gdsync.sh --sync ;;
        2) gdsync.sh --pull ;;
        3) gdsync.sh --rdel ;;
        4) gdsync.sh --update-gio ;;
        *) ;;
    esac
fi

exit 0

