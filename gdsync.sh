#! /bin/bash

GD_URI="google-drive://address@gmail.com/" # URI with Google Drive access
GDS_INDEX_FILE="$HOME/.gds_index" # Index file of gdsync
GDS_MOD_FILES_INDICATOR="$HOME/.gds_mfiles_indicator" # Indicator of modified files
ENC_PASSWORD='' # Password for symetric encryption (AES-256-CBC in use) / SHOULD BE EMPTY
USE_GNOME_KEYRING=true # Switch to use Gnome Keyring for storing ENC_PASSWORD (will prompt for password at first run)
PBKDF_ITER='100000' # PBKDF2 iteration count (default: 100000, higher = stronger)
REMOTE_DIR="gdsync" # Directory on Google Drive holding sync items

REMOTE_UPDATED=false
declare -A REMOTE_MTIME
declare -A REMOTE_ENCRYPTED_NAMES
declare -A LOCAL_MTIME
declare -A PROCESSED_FILES

# print usage on stderr
usage()
{
    echo "Usage: $0 <option> [<absolute path to files>]"
    echo "--add         Add specified file(s) to the synchronization process"
    echo "--del         Delete specified file(s) from the synchronization process"
    echo "--rdel        Delete specified remote file(s)"
    echo "--sync        Perform a synchronization of all syncing files"
    echo "--pull        Interactively pull a file from server that is not locally present"
    echo "--update-gio  Update GIO emblem on synced files"
    echo "--force-pull  Force pulling of specified file(s)"
    echo "--force-push  Force pushing of specified file(s)"
} >&2

pull_file()
{
    local return_code
    
    gio cat "$GD_URI/$1" | openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF_ITER" -pass pass:"$ENC_PASSWORD"
    return_code=$((PIPESTATUS[0]+PIPESTATUS[1]))
    
    return $return_code
}

push_file()
{
    local return_code
    
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF_ITER" -pass pass:"$ENC_PASSWORD" | gio save "$GD_URI/$1"
    return_code=$((PIPESTATUS[0]+PIPESTATUS[1]))
    
    return $return_code
}

# check the access of Google Drive directory in GD_URI,
# return 1 if some fails, 0 otherwise
verify_gd_dir()
{
    if ! gio info "$GD_URI" > /dev/null 2>&1
    then
        return 1
    fi
    
    return 0
}

load_remote_mtime()
{
    local file_names clear_filename enc_filename mtime line mtime_file
    
    mtime_file="$(pull_file "$REMOTE_DIR/mtime.lst")"
    if (($? > 0))
    then
        zenity --error --text="Error reading remote index (receive)" --title="gdsync" --width=200
        exit 1
    fi
    
    while read line
    do
        if test -z "$line"
        then
            continue
        fi
        if ! echo "$line" | grep -Eq '^[a-zA-Z]+/.+/[0-9]+$'
        then
            zenity --error --text="Error reading remote index (regex)" --title="gdsync" --width=200
            exit 1
        fi
        file_names="${line%/*}"
        clear_filename="/${file_names#*/}"
        enc_filename="${file_names%%/*}"
        mtime="${line##*/}"
        REMOTE_MTIME["$clear_filename"]="$mtime"
        REMOTE_ENCRYPTED_NAMES["$clear_filename"]="$enc_filename"
    done <<< "$mtime_file"
}

save_remote_mtime()
{
    local mtime_file
    
    gio remove "$GD_URI/$REMOTE_DIR/mtime.lst"
    
    mtime_file="$(for file in "${!REMOTE_MTIME[@]}"; do echo "${REMOTE_ENCRYPTED_NAMES["$file"]}$file/${REMOTE_MTIME["$file"]}"; done)"
    echo "$mtime_file" | push_file "$REMOTE_DIR/mtime.lst"
    if ((PIPESTATUS[1] > 0))
    then
        echo -n "$mtime_file" > "$HOME/.mtime.lst.gds"
        zenity --error --text="Error writing remote index (saving to $HOME/.mtime.lst.gds)" --title="gdsync" --width=200
        exit 1
    fi
}

load_local_mtime()
{
    local file
    local -a local_files
    
    if ! test -e "$GDS_INDEX_FILE"
    then
        echo -n > "$GDS_INDEX_FILE"
    fi
    
    readarray -t local_files < "$GDS_INDEX_FILE"
    
    for file in "${local_files[@]}"
    do
        if test -f "$file"
        then
            LOCAL_MTIME["$file"]="$(stat --format=%Y "$file")"
        elif ! test -e "$file"
        then
            unset LOCAL_MTIME["$file"]
        fi
    done
}

save_local_mtime()
{
    echo -n > "$GDS_INDEX_FILE"
    for file in "${!LOCAL_MTIME[@]}"
    do
        echo "$file" >> "$GDS_INDEX_FILE"
    done
}

# add files in arguments to index file and upload them
gds_add()
{
    local REMOTE_NAME file i len failed_files
    
    len="$(find "$@" -type f | wc -l)"
    i=0
    progress_bar 'gdsync - Adding files to sync' < /tmp/gds_progress_ipc &
    exec 3> /tmp/gds_progress_ipc
    
    while read file
    do
        echo "#Processing $file..." >&3
        bc >&3 <<< "scale=2;$i/$len*100"
        ((i++))
        
        if test -n "${PROCESSED_FILES["$file"]}"
        then
            continue
        fi
        
        if test -n "${LOCAL_MTIME["$file"]}"
        then
            echo "$file already syncing ! Skipping..." >&2
            continue
        fi
        
        REMOTE_NAME="$(cat /dev/urandom | tr -dc '[:alpha:]' | head -c 40)"
        
        if test -f "$file"
        then
            if test -n "${REMOTE_MTIME["$file"]}"
            then
                LOCAL_MTIME["$file"]="$(stat --format=%Y "$file")"
                gio set "$file" -t stringv metadata::emblems emblem-colors-red
                echo -n > "$GDS_MOD_FILES_INDICATOR"
                PROCESSED_FILES["$file"]="processed"
            else
                cat "$file" | push_file "$REMOTE_DIR/$REMOTE_NAME"
                if ((PIPESTATUS[1] > 0))
                then
                    PROCESSED_FILES["$file"]="error"
                    continue
                fi
                
                REMOTE_MTIME["$file"]="$(stat --format=%Y "$file")"
                REMOTE_UPDATED=true
                REMOTE_ENCRYPTED_NAMES["$file"]="$REMOTE_NAME"
                LOCAL_MTIME["$file"]=${REMOTE_MTIME["$file"]}
                gio set "$file" -t stringv metadata::emblems emblem-colors-green
                PROCESSED_FILES["$file"]="processed"
            fi
        else
            echo "$file doesn't exist ! Skipping..." >&2
            continue
        fi
    done <<< "$(find "$@" -type f)"
    
    for file in "${!PROCESSED_FILES[@]}"
    do
        if test ${PROCESSED_FILES["$file"]} = "error"
        then
            failed_files="$failed_files $file"
        fi
    done
    
    if test -n "$failed_files"
    then
        zenity --error --text="Error adding some files: $failed_files" --title="gdsync" --width=200
    fi
}

# remove files in arguments from index file
gds_del()
{
    local file i len
    
    len="$(find "$@" -type f | wc -l)"
    i=0
    progress_bar 'gdsync - Removing files from sync' < /tmp/gds_progress_ipc &
    exec 3> /tmp/gds_progress_ipc
    
    while read file
    do
        echo "#Processing $file..." >&3
        bc >&3 <<< "scale=2;$i/$len*100"
        ((i++))
        
        if test -n "${PROCESSED_FILES["$file"]}"
        then
            continue
        fi
        
        if test -z "${LOCAL_MTIME["$file"]}"
        then
            echo "$file not syncing ! Skipping..." >&2
            continue
        fi
        
        unset LOCAL_MTIME["$file"]
        if test -f "$file"
        then
            gio set "$file" -t unset metadata::emblems
        fi
        PROCESSED_FILES["$file"]="processed"
    done <<< "$(find "$@" -type f)"
}

# Perform a synchronization
gds_sync()
{
    local file i len failed_files
    
    len="${#LOCAL_MTIME[@]}"
    i=0
    progress_bar 'gdsync - Syncing files with server' < /tmp/gds_progress_ipc &
    exec 3> /tmp/gds_progress_ipc
    
    for file in "${!LOCAL_MTIME[@]}"
    do
        echo "#Processing $file..." >&3
        bc >&3 <<< "scale=2;$i/$len*100"
        ((i++))
        
        if test "${LOCAL_MTIME["$file"]}" -lt "${REMOTE_MTIME["$file"]}"
        then
            pull_file "$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}" > "$file.gds"
            if (($? > 0))
            then
                failed_files="$failed_files $file"
                rm -f "$file.gds"
                continue
            fi
            rm -f "$file"
            mv "$file.gds" "$file"
            
            touch --date="@${REMOTE_MTIME["$file"]}" "$file"
            LOCAL_MTIME["$file"]=${REMOTE_MTIME["$file"]}
            gio set "$file" -t stringv metadata::emblems emblem-colors-green
        elif test "${LOCAL_MTIME["$file"]}" -gt "${REMOTE_MTIME["$file"]}"
        then
            gio remove "$GD_URI/$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}"
            cat "$file" | push_file "$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}"
            if ((PIPESTATUS[1] > 0))
            then
                failed_files="$failed_files $file"
                continue
            fi
            
            REMOTE_MTIME["$file"]=${LOCAL_MTIME["$file"]}
            REMOTE_UPDATED=true
            gio set "$file" -t stringv metadata::emblems emblem-colors-green
        else
            gio set "$file" -t stringv metadata::emblems emblem-colors-green
        fi
    done
    
    if test -n "$failed_files"
    then
        zenity --error --text="Error syncing some files: $failed_files" --title="gdsync" --width=200
    else
        rm "$GDS_MOD_FILES_INDICATOR"
    fi
}

# Update emblem of synced files
gds_update_gio()
{
    local mfiles=false
    
    for file in "${!LOCAL_MTIME[@]}"
    do
        if test "${LOCAL_MTIME["$file"]}" -eq "${REMOTE_MTIME["$file"]}"
        then
            gio set "$file" -t stringv metadata::emblems emblem-colors-green
        else
            gio set "$file" -t stringv metadata::emblems emblem-colors-red
            mfiles=true
        fi
    done
    
    if $mfiles
    then
        echo -n > "$GDS_MOD_FILES_INDICATOR"
    else
        rm "$GDS_MOD_FILES_INDICATOR"
    fi
}

# Interactively pull a file from server that is not locally present
gds_pull()
{
    local file selected_files i len failed_files
    local -a remote_files
    
    remote_files=("" "ALL")
    
    for file in "${!REMOTE_MTIME[@]}"
    do
        if ! test -f "$file"
        then
            remote_files+=("" "$file")
        fi
    done
    
    selected_files="$(zenity --width=500 --height=500 --list --column='' --text='Select file(s) to pull from server:' --checklist --separator='\n' --print-column='2' --column='Remote file' "${remote_files[@]}")"
    if test -z "$selected_files"
    then
        return
    fi
    
    if test "$(echo "$selected_files" | head -n 1)" = "ALL"
    then
        selected_files=""
        for rf in "${remote_files[@]}"
        do
            if test "$rf" = "ALL" -o -z "$rf"
            then
                continue
            fi
            selected_files="$selected_files
$rf"
        done
        selected_files="$(echo "$selected_files" | tail -n +2)"
    fi
    
    len="$(echo "$selected_files" | wc -l)"
    i=0
    progress_bar 'gdsync - Pulling files from server' < /tmp/gds_progress_ipc &
    exec 3> /tmp/gds_progress_ipc
    
    while read file
    do
        echo "#Processing $file..." >&3
        bc >&3 <<< "scale=2;$i/$len*100"
        ((i++))
        
        directory="${file%/*}"
        if ! test -d "$directory"
        then
            mkdir -p "$directory"
        fi
        
        pull_file "$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}" > "$file.gds"
        if (($? > 0))
        then
            failed_files="$failed_files $file"
            rm -f "$file.gds"
            continue
        fi
        rm -f "$file"
        mv "$file.gds" "$file"
        
        touch --date="@${REMOTE_MTIME["$file"]}" "$file"
        LOCAL_MTIME["$file"]=${REMOTE_MTIME["$file"]}
        gio set "$file" -t stringv metadata::emblems emblem-colors-green
    done <<< "$selected_files"
    
    if test -n "$failed_files"
    then
        zenity --error --text="Error pulling some files: $failed_files" --title="gdsync" --width=200
    fi
}

# Force pulling files
gds_force_pull()
{
    local file i len failed_files
    
    len="$(find "$@" -type f | wc -l)"
    i=0
    progress_bar 'gdsync - Force pulling files from server' < /tmp/gds_progress_ipc &
    exec 3> /tmp/gds_progress_ipc
    
    while read file
    do
        echo "#Processing $file..." >&3
        bc >&3 <<< "scale=2;$i/$len*100"
        ((i++))
        
        if test -n "${PROCESSED_FILES["$file"]}"
        then
            continue
        fi
        
        if test -z "${LOCAL_MTIME["$file"]}"
        then
            echo "$file not syncing ! Skipping..." >&2
            continue
        fi
        
        if test -f "$file"
        then
            pull_file "$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}" > "$file.gds"
            if (($? > 0))
            then
                failed_files="$failed_files $file"
                rm -f "$file.gds"
                continue
            fi
            rm -f "$file"
            mv "$file.gds" "$file"
            
            touch --date="@${REMOTE_MTIME["$file"]}" "$file"
            LOCAL_MTIME["$file"]=${REMOTE_MTIME["$file"]}
            gio set "$file" -t stringv metadata::emblems emblem-colors-green
            
            PROCESSED_FILES["$file"]="processed"
        else
            echo "$file doesn't exist ! Skipping..." >&2
            continue
        fi
    done <<< "$(find "$@" -type f)"
    
    if test -n "$failed_files"
    then
        zenity --error --text="Error pulling some files: $failed_files" --title="gdsync" --width=200
    fi
}

# Force pushing files
gds_force_push()
{
    local file i len failed_files
    
    len="$(find "$@" -type f | wc -l)"
    i=0
    progress_bar 'gdsync - Force pushing files to server' < /tmp/gds_progress_ipc &
    exec 3> /tmp/gds_progress_ipc
    
    while read file
    do
        echo "#Processing $file..." >&3
        bc >&3 <<< "scale=2;$i/$len*100"
        ((i++))
        
        if test -n "${PROCESSED_FILES["$file"]}"
        then
            continue
        fi
        
        if test -z "${LOCAL_MTIME["$file"]}"
        then
            echo "$file not syncing ! Skipping..." >&2
            continue
        fi
        
        if test -f "$file"
        then
            gio remove "$GD_URI/$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}"
            cat "$file" | push_file "$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}"
            if ((PIPESTATUS[1] > 0))
            then
                failed_files="$failed_files $file"
                continue
            fi
            
            REMOTE_MTIME["$file"]="$(stat --format=%Y "$file")"
            REMOTE_UPDATED=true
            LOCAL_MTIME["$file"]=${REMOTE_MTIME["$file"]}
            gio set "$file" -t stringv metadata::emblems emblem-colors-green
            PROCESSED_FILES["$file"]="processed"
        else
            echo "$file doesn't exist ! Skipping..." >&2
            continue
        fi
    done <<< "$(find "$@" -type f)"
    
    if test -n "$failed_files"
    then
        zenity --error --text="Error pulling some files: $failed_files" --title="gdsync" --width=200
    fi
}

# Interactively delete a file from server and untrack associated local file
gds_rdel()
{
    local file selected_files i len
    local -a remote_files
    
    for file in "${!REMOTE_MTIME[@]}"
    do
        if test -f "$file"
        then
            remote_files+=("" "$file" "Yes")
        else
            remote_files+=("" "$file" "No")
        fi
    done
    
    selected_files="$(zenity --width=500 --height=500 --list --column='' --text='Select file(s) to remove from server:' --checklist --column='Remote file' --separator='\n' --print-column='2' --column='Local' "${remote_files[@]}")"
    if test -z "$selected_files"
    then
        return
    fi
    
    len="$(echo "$selected_files" | wc -l)"
    i=0
    progress_bar 'gdsync - Deleting files from server' < /tmp/gds_progress_ipc &
    exec 3> /tmp/gds_progress_ipc
    
    while read file
    do
        echo "#Processing $file..." >&3
        bc >&3 <<< "scale=2;$i/$len*100"
        ((i++))
        
        echo "$file"
        gio remove "$GD_URI/$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}"
        
        unset REMOTE_MTIME["$file"]
        REMOTE_UPDATED=true
        unset REMOTE_ENCRYPTED_NAMES["$file"]
        if test -f "$file"
        then
            unset LOCAL_MTIME["$file"]
            gio set "$file" -t unset metadata::emblems
        fi
    done <<< "$selected_files"
}

prompt_password()
{
    if test -n "$ENC_PASSWORD"
    then
        return
    fi
    if $USE_GNOME_KEYRING
    then
        ENC_PASSWORD="$(secret-tool search application gds 2>/dev/null | grep 'secret =' | cut -d '=' -f2 | tail -c +2)"
        if test -z "$ENC_PASSWORD"
        then
            if ! ENC_PASSWORD="$(zenity --password --title='Google Drive Sync Password')"
            then
                echo "No password provided..." >&2
                exit 1
            fi
            echo -n "$ENC_PASSWORD" | secret-tool store --label="Google Drive Sync" "application" "gds"
        fi
    else
        ENC_PASSWORD="$(zenity --password --title='Google Drive Sync Password')"
    fi
}

progress_bar()
{
    zenity --width=400 --progress --auto-close --no-cancel --title="$1"
}

if (($# == 0))
then
    usage
    exit 1
fi

if test -p /tmp/gds_progress_ipc
then
    echo "Already running..." >&2
    exit 1
fi
#(trap "kill -- -$$" EXIT; while true; do zenity --width=200 --info --text="Google Drive sync in progress..." --title="Google Drive Sync" --icon-name='network-transmit-receive'; done) &

if ! verify_gd_dir
then
    echo "No drive access at $GD_URI or no internet connection" >&2
    exit 1
fi

prompt_password

if test -f "$HOME/.mtime.lst.gds"
then
    cat "$HOME/.mtime.lst.gds" | push_file "$REMOTE_DIR/mtime.lst"
    if ((PIPESTATUS[1] > 0))
    then
        zenity --error --text="Error writing saved remote index (read from $HOME/.mtime.lst.gds)" --title="gdsync" --width=200
        exit 1
    fi
    rm "$HOME/.mtime.lst.gds"
fi

load_local_mtime
load_remote_mtime

for file in "${!LOCAL_MTIME[@]}"
do
    if test -z "${REMOTE_MTIME["$file"]}"
    then
        unset LOCAL_MTIME["$file"]
        gio set "$file" -t unset metadata::emblems
    fi
done

mkfifo --mode=660 /tmp/gds_progress_ipc

case "$1" in
    --add) shift; gds_add "$@" ;;
    --del) shift; gds_del "$@" ;;
    --rdel) gds_rdel ;;
    --sync) gds_sync ;;
    --pull) gds_pull ;;
    --force-pull) shift; if (($# > 0)); then gds_force_pull "$@"; else gds_force_pull "${!LOCAL_MTIME[@]}"; fi ;;
    --force-push) shift; if (($# > 0)); then gds_force_push "$@"; else gds_force_push "${!LOCAL_MTIME[@]}"; fi ;;
    --update-gio) gds_update_gio ;;
    *) usage; exec 3>&-; rm -f /tmp/gds_progress_ipc; exit 1 ;;
esac

exec 3>&-
rm -f /tmp/gds_progress_ipc

save_local_mtime
$REMOTE_UPDATED && save_remote_mtime

xfce4-panel --plugin-event=genmon:refresh:bool:true

exit 0

