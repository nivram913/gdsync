#! /bin/bash

GD_DIR="$HOME/gdrive/" # Directory with Google Drive access
GDS_INDEX_FILE="$HOME/.gds_index" # Index file of gdsync
ENC_PASSWORD='' # Password for symetric encryption (AES-256-CBC in use) / SHOULD BE EMPTY
USE_GNOME_KEYRING=true # Switch to use Gnome Keyring for storing ENC_PASSWORD (will prompt for password at first run)
PBKDF_ITER='100000' # PBKDF2 iteration count (default: 100000, higher = stronger)
REMOTE_DIR="gdsync_testing" # Directory on Google Drive holding sync items
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
    echo "--sync        Perform a synchronization of all syncing files"
    echo "--pull        Interactively pull a file from server that is not locally present"
    echo "--update-gio  Update GIO emblem on synced files"
    echo "--force-pull  Force pulling of specified file(s)"
    echo "--force-push  Force pushing of specified file(s)"
} >&2

# check the prensence of Google Drive directory in GD_DIR,
# access right on the Google account
# and Internet connectivity
# return 1 if some fails, 0 otherwise
verify_gd_dir()
{
    if ! test -d "$GD_DIR/.gd"
    then
        return 1
    fi
    
    cd "$GD_DIR"
    if ! drive about > /dev/null 2>&1
    then
        return 1
    fi
    
    cd - > /dev/null
    
    return 0
}

load_remote_mtime()
{
    local file_names clear_filename enc_filename mtime line
    cd "$GD_DIR"
    
    while read line
    do
        if test -z "$line"
        then
            continue
        fi
        file_names="${line%/*}"
        clear_filename="/${file_names#*/}"
        enc_filename="${file_names%%/*}"
        mtime="${line##*/}"
        REMOTE_MTIME["$clear_filename"]="$mtime"
        REMOTE_ENCRYPTED_NAMES["$clear_filename"]="$enc_filename"
    done <<< "$(drive pull -piped "$REMOTE_DIR/mtime.lst" | openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF_ITER" -pass pass:"$ENC_PASSWORD")"
    
    cd - > /dev/null
}

save_remote_mtime()
{
    cd "$GD_DIR"
    drive trash -quiet "$REMOTE_DIR/mtime.lst"
    (for file in "${!REMOTE_MTIME[@]}"; do echo "${REMOTE_ENCRYPTED_NAMES["$file"]}$file/${REMOTE_MTIME["$file"]}"; done) | openssl enc -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF_ITER" -pass pass:"$ENC_PASSWORD" | drive push -piped "$REMOTE_DIR/mtime.lst"
    cd - > /dev/null
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
    local REMOTE_NAME file sub_file IFS_BAK
    
    for file in "$@"
    do
        if test -n "${PROCESSED_FILES["$file"]}"
        then
            continue
        fi
        
        if test -d "$file"
        then
            IFS_BAK="$IFS"
            IFS="
"
            for sub_file in $(find "$file" -type f 2>/dev/null)
            do
                gds_add "$sub_file"
            done
            IFS="$IFS_BAK"
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
            else
                cd "$GD_DIR"
                openssl enc -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF_ITER" -in "$file" -pass pass:"$ENC_PASSWORD" | drive push -piped "$REMOTE_DIR/$REMOTE_NAME"
                cd - > /dev/null
                
                REMOTE_MTIME["$file"]="$(stat --format=%Y "$file")"
                REMOTE_ENCRYPTED_NAMES["$file"]="$REMOTE_NAME"
                LOCAL_MTIME["$file"]=${REMOTE_MTIME["$file"]}
                gio set "$file" -t stringv metadata::emblems emblem-colors-green
            fi
            PROCESSED_FILES["$file"]="processed"
        else
            echo "$file doesn't exist ! Skipping..." >&2
            continue
        fi
    done
}

# remove files in arguments from index file
gds_del()
{
    local file
    
    for file in "$@"
    do
        if test -n "${PROCESSED_FILES["$file"]}"
        then
            continue
        fi
        
        if test -d "$file"
        then
            IFS_BAK="$IFS"
            IFS="
"
            for sub_file in $(find "$file" -type f 2>/dev/null)
            do
                gds_del "$sub_file"
            done
            IFS="$IFS_BAK"
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
    done
}

# Perform a synchronization
gds_sync()
{
    local file file_dir filename
    
    for file in "${!LOCAL_MTIME[@]}"
    do
        if test "${LOCAL_MTIME["$file"]}" -lt "${REMOTE_MTIME["$file"]}"
        then
            file_dir="${file%/*}"
            filename="${file##*/}"
            
            cd "$GD_DIR"
            drive pull -piped "$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}" | openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF_ITER" -out "$file_dir/$filename.gds" -pass pass:"$ENC_PASSWORD"
            cd - > /dev/null
            
            mv "$file" "$file.gdsbak"
            mv "$file_dir/$filename.gds" "$file"
            touch --date="@${REMOTE_MTIME["$file"]}" "$file"
            LOCAL_MTIME["$file"]=${REMOTE_MTIME["$file"]}
            gio set "$file" -t stringv metadata::emblems emblem-colors-green
        elif test "${LOCAL_MTIME["$file"]}" -gt "${REMOTE_MTIME["$file"]}"
        then
            cd "$GD_DIR"
            drive trash -quiet "$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}"
            openssl enc -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF_ITER" -in "$file" -pass pass:"$ENC_PASSWORD" | drive push -piped "$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}"
            cd - > /dev/null
            
            REMOTE_MTIME["$file"]=${LOCAL_MTIME["$file"]}
            gio set "$file" -t stringv metadata::emblems emblem-colors-green
        fi
    done
}

# Update emblem of synced files
gds_update_gio()
{
    for file in "${!LOCAL_MTIME[@]}"
    do
        if test ${LOCAL_MTIME["$file"]} -eq ${REMOTE_MTIME["$file"]}
        then
            gio set "$file" -t stringv metadata::emblems emblem-colors-green
        else
            gio set "$file" -t stringv metadata::emblems emblem-colors-red
        fi
    done
}

# Interactively pull a file from server that is not locally present
gds_pull()
{
    local file selected_files
    local -a remote_files
    
    for file in "${!REMOTE_MTIME[@]}"
    do
        if test -z ${LOCAL_MTIME["$file"]}
        then
            remote_files+=("" "$file")
        fi
    done
    
    selected_files="$(zenity --list --column="" --text="Select file(s) to pull from server:" --checklist --column="Remote file" "${remote_files[@]}")"
    if test -z "$selected_files"
    then
        return
    fi
    
    IFS_BAK="$IFS"
    IFS="|"
    for file in "$selected_files"
    do
        cd "$GD_DIR"
        drive pull -piped "$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}" | openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF_ITER" -out "$file" -pass pass:"$ENC_PASSWORD"
        cd - > /dev/null
        
        touch --date="@${REMOTE_MTIME["$file"]}" "$file"
        LOCAL_MTIME["$file"]=${REMOTE_MTIME["$file"]}
        gio set "$file" -t stringv metadata::emblems emblem-colors-green
    done
    IFS="$IFS_BAK"
}

# Force pulling files
gds_force_pull()
{
    local file sub_file IFS_BAK file_dir filename
    
    for file in "$@"
    do
        if test -n "${PROCESSED_FILES["$file"]}"
        then
            continue
        fi
        
        if test -d "$file"
        then
            IFS_BAK="$IFS"
            IFS="
"
            for sub_file in $(find "$file" -type f 2>/dev/null)
            do
                gds_force_pull "$sub_file"
            done
            IFS="$IFS_BAK"
            continue
        fi
        
        if test -z "${LOCAL_MTIME["$file"]}"
        then
            echo "$file not syncing ! Skipping..." >&2
            continue
        fi
        
        if test -f "$file"
        then
            file_dir="${file%/*}"
            filename="${file##*/}"
            
            cd "$GD_DIR"
            drive pull -piped "$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}" | openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF_ITER" -out "$file_dir/$filename.gds" -pass pass:"$ENC_PASSWORD"
            cd - > /dev/null
            
            mv "$file" "$file.gdsbak"
            mv "$file_dir/$filename.gds" "$file"
            touch --date="@${REMOTE_MTIME["$file"]}" "$file"
            LOCAL_MTIME["$file"]=${REMOTE_MTIME["$file"]}
            gio set "$file" -t stringv metadata::emblems emblem-colors-green
            
            PROCESSED_FILES["$file"]="processed"
        else
            echo "$file doesn't exist ! Skipping..." >&2
            continue
        fi
    done
}

# Force pushing files
gds_force_push()
{
    local file sub_file IFS_BAK
    
    for file in "$@"
    do
        if test -n "${PROCESSED_FILES["$file"]}"
        then
            continue
        fi
        
        if test -d "$file"
        then
            IFS_BAK="$IFS"
            IFS="
"
            for sub_file in $(find "$file" -type f 2>/dev/null)
            do
                gds_force_push "$sub_file"
            done
            IFS="$IFS_BAK"
            continue
        fi
        
        if test -z "${LOCAL_MTIME["$file"]}"
        then
            echo "$file not syncing ! Skipping..." >&2
            continue
        fi
        
        if test -f "$file"
        then
            cd "$GD_DIR"
            openssl enc -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF_ITER" -in "$file" -pass pass:"$ENC_PASSWORD" | drive push -piped "$REMOTE_DIR/${REMOTE_ENCRYPTED_NAMES["$file"]}"
            cd - > /dev/null
            
            REMOTE_MTIME["$file"]="$(stat --format=%Y "$file")"
            LOCAL_MTIME["$file"]=${REMOTE_MTIME["$file"]}
            gio set "$file" -t stringv metadata::emblems emblem-colors-green
            PROCESSED_FILES["$file"]="processed"
        else
            echo "$file doesn't exist ! Skipping..." >&2
            continue
        fi
    done
}

prompt_password()
{
    if test -z "$ENC_PASSWORD"
    then
        if $USE_GNOME_KEYRING
        then
            ENC_PASSWORD="$(secret-tool search application gds 2>/dev/null | grep "secret =" | cut -d '=' -f2)"
            if test -z "$ENC_PASSWORD"
            then
                if ! ENC_PASSWORD="$(zenity --password --title='Google Drive Sync Password')"
                then
                    echo "No password provided..." >&2
                    kill %%
                    exit 1
                fi
                echo -n "$ENC_PASSWORD" | secret-tool store --label="Google Drive Sync" "application" "gds"
            fi
        fi
    fi
}

if (($# == 0))
then
    usage
    exit 1
fi

(trap "kill -- -$$" EXIT; while true; do zenity --width=200 --info --text="Google Drive sync in progress..." --title="Google Drive Sync" --icon-name='network-transmit-receive'; done) &

if ! verify_gd_dir
then
    echo "No drive directory at $GD_DIR or no internet connection" >&2
    kill %%
    exit 1
fi

prompt_password

load_local_mtime
load_remote_mtime

case "$1" in
    --add) shift; gds_add "$@" ;;
    --del) shift; gds_del "$@" ;;
    --sync) gds_sync ;;
    --pull) shift; gds_pull ;;
    --force-pull) shift; if (($# > 0)); then gds_force_pull "$@"; else gds_force_pull "${!LOCAL_MTIME[@]}"; fi ;;
    --force-push) shift; if (($# > 0)); then gds_force_push "$@"; else gds_force_push "${!LOCAL_MTIME[@]}"; fi ;;
    --update-gio) gds_update_gio ;;
    *) usage; kill %%; exit 1 ;;
esac

save_local_mtime
save_remote_mtime

kill %%

exit 0

