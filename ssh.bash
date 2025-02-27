#!/usr/bin/env bash

print_usage() {
    echo "Usage: $PROGRAM ssh action [--flag]"
    echo "Actions:"
    echo "  add:               add new key to password store"
    echo "  list|ls:           list keys in password store"
    echo "    --print:           print list of keys to stdout"
    echo "  edit:              add/edit/remove passphrase for encrypted keys"
    echo "  show|cat:          print the public key to stdout"
    echo "    --private:         print the private key to stdout"
    echo "    --passphrase:      print the encryption passphrase to stdout"
    echo "    --copy:            copy the output to the clipboard"
    echo "    --qr:              print a qr-code to stdout"
    echo "  extract:           extract keys from password store and save to user SSH directory"
    echo "    --public:          extract public key only"
    echo "    --private:         extract private key only"
    echo "  delete|remove|rm:  remove keys from password store"
    echo "  agent:             add key to SSH agent"
    exit 0
}

# TODO: add dependency checks
# TODO: add README

SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
PASS_SSH_DIR="${PASS_SSH_DIR:-ssh_keys}"
GIT_DIR="${PASSWORD_STORE_GIT:-$PREFIX}/.git"
FZF="fzf --height 40% --reverse --no-multi"
CLIPBOARD_COPY="wl-copy" # "wl-copy" for wayland, "xclip -selection clipboard" for x11

# list of all keys currently stored in password store
key_list=$(find $PREFIX/$PASS_SSH_DIR -mindepth 1 -type d)

# helper function to extract comment from a public key
__extract_key_comment () {
    awk '{print substr($0, index($0, $3))}' $SSH_DIR/$1.pub
}

# add new key to password store
cmd_add() {
    local key_name="$(ls $SSH_DIR/*.pub | $FZF | xargs -n 1 basename | sed 's/.pub$//')" # filename of the key in user SSH directory
    local dir_name="$(__extract_key_comment $key_name)" # this is going to be the name of the key directory in the password store

    # key_name was fuzzily selected from available public keys.
    # Check if a corresponding private key also exists
    if [[ ! -f "$SSH_DIR/$key_name" ]]; then
        echo "No private key exists for the chosen key."
        exit 1
    fi

    # Check for a valid name for the key directory in the password store
    if [[ -d "$PREFIX/$PASS_SSH_DIR/$dir_name" ]]; then
        read -r -p "A key with name $dir_name already exists in the store. Do you want to pick a different name? [Y/n] " response
        if [[ $response != [nN] ]]; then
            read -p "Enter name: " dir_name
        else
            echo "Remove the existing key and try again."
            exit 0
        fi
    fi
    if [[ -z "$dir_name" ]]; then
        read -r -p "The name of the key cannot be empty. Do you want to pick a name? [Y/n]" response
        if [[ $response != [nN] ]]; then
            read -p "Enter name: " dir_name
        else
            exit 0
        fi
    fi
    if [[ -z "$dir_name" ]]; then
        echo "Error: the name of the key cannot be empty."
        exit 1
    fi

    # create the key directory at the password store
    mkdir -p "$PREFIX/$PASS_SSH_DIR/$dir_name"
    set_gpg_recipients "$PREFIX/$PASS_SSH_DIR/$dir_name"

    # add the keys to the password store
    local priv_key="$PREFIX/$PASS_SSH_DIR/$dir_name/$key_name.gpg"
    local pub_key="$PREFIX/$PASS_SSH_DIR/$dir_name/$key_name.pub.gpg"
    cat "$SSH_DIR/$key_name" | $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$priv_key" "${GPG_OPTS[@]}"
    cat "$SSH_DIR/$key_name.pub" | $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$pub_key" "${GPG_OPTS[@]}"

    # add the encryption passphrase
    read -r -p "If the private key is encrypted, you can optionally save the passphrase. Do you want to add it? [Y/n]" response
    if [[ $response != [nN] ]]; then
        local passfile="$PREFIX/$PASS_SSH_DIR/$dir_name/passphrase.gpg"
        read -s -p "Enter passphrase: " key_passphrase
        echo
        read -s -p "Enter passphrase again: " key_passphrase_2
        echo

        # keep trying until both passphrases match
        while [[ "$key_passphrase" != "$key_passphrase_2" ]]; do
            echo "Passphrase doesn't match. Try again."
            read -s -p "Enter passphrase: " key_passphrase
            echo
            read -s -p "Enter passphrase again: " key_passphrase_2
            echo
        done

        if [[ -n "$key_passphrase" ]]; then
            echo "$key_passphrase" | $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile" "${GPG_OPTS[@]}"
        else
            echo "No passphrase provided. Continuing without it. Run pass ssh edit to add it later."
        fi
    fi

    # version control
    if [[ -d $GIT_DIR && -d "$PREFIX/$PASS_SSH_DIR/$dir_name" ]]; then
        git -C $PREFIX add "$PREFIX/$PASS_SSH_DIR/$dir_name"
        git -C $PREFIX commit -m "Added $dir_name SSH keys"
    fi
}

# list keys in password store
cmd_list () {
    local print_list=false

    while [[ "$1" == --* ]]; do
        case "$1" in
            --print)
                print_list=true
                shift;;
            *)
                echo "Error: unknown option: $1"
                exit 1;;
        esac
    done

    if [[ -n "$key_list" ]]; then

        # print list to stdout
        if $print_list; then
            local num_keys=$(echo "$key_list" | wc -l)
            echo "Total keys found: $num_keys"
            # ask before printing if too many keys
            if [[ $num_keys -gt 15 ]]; then
                read -p "Are you sure you want to print all of them? [y/N]" response
                if [[ $response != [yY] ]]; then
                    exit 0
                else
                    echo "$key_list" |  xargs -n 1 basename
                fi
            else
                echo "$key_list" |  xargs -n 1 basename
            fi

        # show list wiyh fzf
        else
            echo "$key_list" |  xargs -n 1 basename | $FZF
        fi
    else
        echo "No SSH key in password store."
        exit 0
    fi
}

# add/edit/remove encryption passphrase
cmd_edit () {
    if [[ -n "$key_list" ]]; then

        local dir_name="$(echo $key_list | xargs -n 1 basename | $FZF)"
        if [[ -z "$dir_name" ]]; then
            echo "No key selected."
            exit 0
        fi

        local passfile="$PREFIX/$PASS_SSH_DIR/$dir_name/passphrase.gpg"
        set_gpg_recipients "$PREFIX/$PASS_SSH_DIR/$dir_name"

        # if a passphrase already exists, edit or remove it
        if [[ -f "$passfile" ]]; then
            read -p "Do you want to overwrite the passphrase? [Y/n]" response
            if [[ $response != [nN] ]]; then
                read -s -p "Enter new passphrase: " key_passphrase
                echo
                read -s -p "Enter new passphrase again: " key_passphrase_2
                echo

                # keep trying until both passphrases match
                while [[ "$key_passphrase" != "$key_passphrase_2" ]]; do
                    echo "Passphrase doesn't match. Try again."
                    read -s -p "Enter new passphrase: " key_passphrase
                    echo
                    read -s -p "Enter new passphrase again: " key_passphrase_2
                done

                # edit the passphrase
                if [[ -n "$key_passphrase" ]]; then
                    rm -f "$passfile"
                    echo "$key_passphrase" | $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile" "${GPG_OPTS[@]}"
                    if [[ -d $GIT_DIR && -f "$passfile" ]]; then
                        git -C $PREFIX add "$passfile"
                        git -C $PREFIX commit -m "Updated passphrase for $dir_name SSH keys"
                    fi
                # if empty passphrase, delete the existing passphrase
                else
                    read -p "No passphrase provided. Do you want to remove the existing passphrase? [y/N]" response
                    if [[ $response != [yY] ]]; then
                        exit 0
                    else
                        rm -f "$passfile"
                        if [[ -d $GIT_DIR && ! -f "$passfile" ]]; then
                            git -C $PREFIX rm -qr "$passfile"
                            git -C $PREFIX commit -m "Removed passphrase for $dir_name SSH keys"
                        fi
                    fi
                fi
            fi

        # if a passphrase does not exist, add it
        else
            read -p "No passphrase found. Do you want to add it? [Y/n]" response
            if [[ $response != [nN] ]]; then
                read -s -p "Enter passphrase: " key_passphrase
                echo
                read -s -p "Enter passphrase again: " key_passphrase_2
                echo

                # keep trying until both passphrases match
                while [[ "$key_passphrase" != "$key_passphrase_2" ]]; do
                    echo "Passphrase doesn't match. Try again."
                    read -s -p "Enter passphrase: " key_passphrase
                    echo
                    read -s -p "Enter passphrase again: " key_passphrase_2
                    echo
                done

                if [[ -n "$key_passphrase" ]]; then
                    echo "$key_passphrase" | $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile" "${GPG_OPTS[@]}"
                    if [[ -d $GIT_DIR && -f "$passfile" ]]; then
                        git -C $PREFIX add "$passfile"
                        git -C $PREFIX commit -m "Added passphrase for $dir_name SSH keys"
                    fi
                else
                    echo "No passphrase provided. Nothing is added."
                    exit 0
                fi
            fi
        fi

    else
        echo "Error: no SSH key in password store."
        exit 1
    fi
}

# print public key/private key/encryption passphrase to stdout and optionally copy to clipboard
cmd_show () {
    local show_private=false
    local show_passphrase=false
    local copy_to_clipboard=false
    local show_qr=false

    while [[ "$1" == --* ]]; do
        case "$1" in
            --private)
                show_private=true
                shift;;
            --passphrase)
                show_passphrase=true
                shift;;
            --copy)
                copy_to_clipboard=true
                shift;;
            --qr)
                show_qr=true
                shift;;
            *)
                echo "Error: unknown option: $1"
                exit 1;;
        esac
    done

    # can only print one file
    if $show_private && $show_passphrase; then
        echo "Error: can't use --private and --passphrase together."
        exit 1
    fi

    if [[ -n "$key_list" ]]; then

        local dir_name="$(echo $key_list | xargs -n 1 basename | $FZF)"
        if [[ -z "$dir_name" ]]; then
            echo "No key selected."
            exit 0
        fi

        local pub_key=$(find "$PREFIX/$PASS_SSH_DIR/$dir_name" -name "*.pub.gpg")
        local private_key="${pub_key%.pub.gpg}"
        local passfile="$PREFIX/$PASS_SSH_DIR/$dir_name/passphrase.gpg"

        if [[ -f "$private_key.gpg" ]]; then # ensure that both public and private keys exist in the password store
            # print private key
            if $show_private; then
                if $show_qr; then
                    $GPG -d "${GPG_OPTS[@]}" "$private_key.gpg" | qrencode -t ansiutf8 || exit $?
                else
                    $GPG -d "${GPG_OPTS[@]}" "$private_key.gpg" || exit $?
                fi
                if $copy_to_clipboard; then
                     $GPG -d "${GPG_OPTS[@]}" "$private_key.gpg" | $CLIPBOARD_COPY || exit $?
                fi
            # print encryption passphrase if exists
            elif $show_passphrase; then
                if [[ -f "$passfile" ]]; then
                    if $show_qr; then
                        $GPG -d "${GPG_OPTS[@]}" "$passfile" | qrencode -t ansiutf8 || exit $?
                    else
                        $GPG -d "${GPG_OPTS[@]}" "$passfile" || exit $?
                    fi
                    if $copy_to_clipboard; then
                        $GPG -d "${GPG_OPTS[@]}" "$passfile" | $CLIPBOARD_COPY || exit $?
                    fi
                else
                    echo "Error: no passphrase found."
                    exit 1
                fi
            # print public key
            else
                if $show_qr; then
                    $GPG -d "${GPG_OPTS[@]}" "$private_key.pub.gpg" | qrencode -t ansiutf8 || exit $?
                else
                    $GPG -d "${GPG_OPTS[@]}" "$private_key.pub.gpg" || exit $?
                fi
                if $copy_to_clipboard; then
                    $GPG -d "${GPG_OPTS[@]}" "$private_key.pub.gpg" | $CLIPBOARD_COPY || exit $?
                fi
            fi
        else
            echo "Error: key files missing"
            exit 1
        fi
    else
        echo "Error: no SSH key in password store."
        exit 1
    fi
}

# extract keys to user SSH directory
cmd_extract () {
    local exract_private=true
    local extract_public=true

    while [[ "$1" == --* ]]; do
        case "$1" in
            --private)
                extract_public=false
                shift;;
            --public)
                extract_private=false
                shift;;
            *)
                echo "Error: unknown option: $1"
                exit 1;;
        esac
    done

    # if both flags are set, extract both which is the default behavior with no flag
    if [[ ! $extract_private ]] && [[ ! $extract_public ]]; then
        exract_private=true
        extract_public=true
    fi

    if [[ -n "$key_list" ]]; then
        local dir_name="$(echo $key_list | xargs -n 1 basename | $FZF)"
        if [[ -z "$dir_name" ]]; then
            echo "No key selected."
            exit 0
        fi

        # check if both public and private key exists in the password store
        local pub_key=$(find "$PREFIX/$PASS_SSH_DIR/$dir_name" -name "*.pub.gpg")
        local private_key="${pub_key%.pub.gpg}"
        if [[ ! -f "$private_key.gpg" ]]; then
            echo "Error: key files missing"
            exit 1
        fi

        # this will be the filename of the key at the user SSH directory
        local key_name="$(basename $private_key)"

        while : ; do
            # check for collisions and find a valid filename for the key
            if $extract_private && $extract_public; then
                if [[ -f "$SSH_DIR/$key_name" ]] || [[ -f "$SSH_DIR/$key_name.pub" ]]; then
                    key_name_exists=true
                else
                    key_name_exists=false
                fi
            elif $extract_private; then
                if [[ -f "$SSH_DIR/$key_name" ]]; then
                    key_name_exists=true
                else
                    key_name_exists=false
                fi
            else
                if [[ -f "$SSH_DIR/$key_name.pub" ]]; then
                    key_name_exists=true
                else
                    key_name_exists=false
                fi
            fi

            # in case of collision, ask user to provide a filename
            if $key_name_exists; then
                read -r -p "A key with filename $key_name already exists at '$SSH_DIR'. Do you want to pick a different name? [Y/n] " response
                if [[ $response != [nN] ]]; then
                    read -p "Enter name: " key_name
                else
                    echo "Remove the existing key and try again."
                    exit 0
                fi
            fi

            # break the loop when there is no collision
            [[ ! $key_name_exists ]] || break
        done

        # extract private key
        if $extract_private; then
            $GPG -o "$SSH_DIR/$key_name" -d "${GPG_OPTS[@]}" "$private_key.gpg" || exit $?
            echo "$key_name private key is extracted at $SSH_DIR"
        fi

        # extract public key
        if $extract_public; then
            $GPG -o "$SSH_DIR/$key_name.pub" -d "${GPG_OPTS[@]}" "$private_key.pub.gpg" || exit $?
            echo "$key_name.pub public key is extracted at $SSH_DIR"
        fi
    else
        echo "Error: no SSH key in password store."
        exit 1
    fi
}

# delete key from password store
cmd_delete () {
    if [[ -n "$key_list" ]]; then

        local dir_name="$(echo $key_list | xargs -n 1 basename | $FZF)"
        if [[ -z "$dir_name" ]]; then
            echo "No key selected."
            exit 0
        fi

        rm -r -f "$PREFIX/$PASS_SSH_DIR/$dir_name"
        if [[ -d $GIT_DIR && ! -d "$PREFIX/$PASS_SSH_DIR/$dir_name" ]]; then
            git -C $PREFIX rm -qr "$PREFIX/$PASS_SSH_DIR/$dir_name"
            git -C $PREFIX commit -m "Removed $dir_name SSH keys"
        fi
    else
        echo "Error: no SSH key in password store."
        exit 1
    fi
}

# add key from password store to the agent
cmd_agent () {
    if [[ -n "$key_list" ]]; then
        local dir_name="$(echo $key_list | xargs -n 1 basename | $FZF)"
        if [[ -z "$dir_name" ]]; then
            echo "No key selected."
            exit 0
        fi

        # check if both public and private key exists in the password store
        local pub_key=$(find "$PREFIX/$PASS_SSH_DIR/$dir_name" -name "*.pub.gpg")
        local private_key="${pub_key%.pub.gpg}"
        local passfile="$PREFIX/$PASS_SSH_DIR/$dir_name/passphrase.gpg"
        if [[ ! -f "$private_key.gpg" ]]; then
            echo "Error: key files missing"
            exit 1
        fi

        # if encryption passphrase exists, copy to clipboard
        if [[ -f "$passfile" ]]; then
            read -r -p "Passphrase for this key is in password store. Do you want to copy it in the clipboard? [Y/n]" response
            if [[ $response != [nN] ]]; then
                $GPG -q -d "${GPG_OPTS[@]}" "$passfile" | $CLIPBOARD_COPY
            fi
        fi

        # add to agent
        ssh-add - <<< "$($GPG -q -d ${GPG_OPTS[@]} $private_key.gpg)"

    else
        echo "Error: no SSH key in password store."
        exit 1
    fi
}

case $1 in
    add)
        shift && cmd_add "$@";;
    list|ls)
        shift && cmd_list "$@";;
    edit)
        shift && cmd_edit "$@";;
    show|cat)
        shift && cmd_show "$@";;
    extract)
        shift && cmd_extract "$@";;
    delete|remove|rm)
        shift && cmd_delete "$@";;
    agent)
        shift && cmd_agent "$@";;
    *)
        print_usage;;
esac
