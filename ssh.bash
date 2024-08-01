#!/usr/bin/env bash

print_usage() {
    echo "Usage: $PROGRAM ssh action"
    echo "Actions:"
    echo "  add:        add new key to password store"
    echo "  list|ls:    list keys in password store"
    echo "  show|cat:   print the public key to stdout"
    echo "  extract:    extract keys from password store and save to user SSH directory"
    echo "  remove|rm:  remove keys from password store"
    echo "  agent:      add key to SSH agent"
    exit 0
}

# TODO: add dependency checks
# TODO: add encryption passphrase management for encrypted keys
# TODO: add README

SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
PASS_SSH_DIR="${PASS_SSH_DIR:-ssh_keys}"
GIT_DIR="${PASSWORD_STORE_GIT:-$PREFIX}/.git"

key_list=$(find $PREFIX/$PASS_SSH_DIR -mindepth 1 -type d)

__extract_key_comment () {
    awk '{print substr($0, index($0, $3))}' $SSH_DIR/$1.pub
}

cmd_add() {
    local key_name="$(ls $SSH_DIR/*.pub | fzf | xargs -n 1 basename | sed 's/.pub$//')"
    local dir_name="$(__extract_key_comment $key_name)"

    if [[ ! -f "$SSH_DIR/$key_name" ]]; then
        echo "No private key exists for the chosen key."
        exit 1
    fi

    # Check for a valid dir_name
    if [ -d "$PREFIX/$PASS_SSH_DIR/$dir_name" ]; then
        read -r -p "A key with name $dir_name already exists in the store. Do you want to pick a different name? [Y/n] " response
        if [[ $response != [nN] ]]; then
            read -p "Enter name: " dir_name
        else
            echo "Remove the existing key and try again."
            exit 0
        fi
    fi
    if [ -z "$dir_name" ]; then
        read -r -p "The name of the key cannot be empty. Do you want to pick a name? [Y/n]" response
        if [[ $response != [nN] ]]; then
            read -p "Enter name: " dir_name
        else
            exit 0
        fi
    fi
    if [ -z "$dir_name" ]; then
        echo "Error: the name of the key cannot be empty."
        exit 1
    fi

    mkdir -p "$PREFIX/$PASS_SSH_DIR/$dir_name"
    local priv_key="$PREFIX/$PASS_SSH_DIR/$dir_name/$key_name.gpg"
    local pub_key="$PREFIX/$PASS_SSH_DIR/$dir_name/$key_name.pub.gpg"
    set_git "$priv_key"
    set_git "$pub_key"
    set_gpg_recipients "$PREFIX/$PASS_SSH_DIR/$dir_name"

    cat "$SSH_DIR/$key_name" | $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$priv_key" "${GPG_OPTS[@]}"
    cat "$SSH_DIR/$key_name.pub" | $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$pub_key" "${GPG_OPTS[@]}"

    git_add_file $priv_key "Added $dir_name SSH private key."
    git_add_file $pub_key "Added $dir_name SSH public key."
}

cmd_list () {
    if [[ -n "$key_list" ]]; then
        echo "$(basename $key_list)"
    else
        echo "No SSH key in password store."
        exit 0
    fi
}

cmd_show() {
    if [[ -n "$key_list" ]]; then
        local dir_name="$(echo $key_list | xargs -n 1 basename | fzf)"
        local pub_key=$(find "$PREFIX/$PASS_SSH_DIR/$dir_name" -name "*.pub.gpg")
        local private_key="${pub_key%.pub.gpg}"
        if [[ -f "$private_key.gpg" ]]; then
            $GPG -d "${GPG_OPTS[@]}" "$private_key.pub.gpg" | cat || exit $?
        else
            echo "Error: key files missing"
            exit 1
        fi
    else
        echo "Error: no SSH key in password store."
        exit 1
    fi
}

cmd_extract () {
    if [[ -n "$key_list" ]]; then
        local dir_name="$(echo $key_list | xargs -n 1 basename | fzf)"
        local pub_key=$(find "$PREFIX/$PASS_SSH_DIR/$dir_name" -name "*.pub.gpg")
        local private_key="${pub_key%.pub.gpg}"
        if [[ ! -f "$private_key.gpg" ]]; then
            echo "Error: key files missing"
            exit 1
        fi
        local key_name="$(basename $private_key)"

        if [ -f "$SSH_DIR/$key_name" ] || [ -f "$SSH_DIR/$key_name.pub"]; then
            read -r -p "A key with filename $key_name already exists at '$SSH_DIR'. Do you want to pick a different name? [Y/n] " response
            if [[ $response != [nN] ]]; then
                read -p "Enter name: " key_name
            else
                echo "Remove the existing key and try again."
                exit 0
            fi
        fi

        $GPG -o "$SSH_DIR/$key_name.pub" -d "${GPG_OPTS[@]}" "$private_key.pub.gpg" || exit $?
        $GPG -o "$SSH_DIR/$key_name" -d "${GPG_OPTS[@]}" "$private_key.gpg" || exit $?
        echo "$key_name keys are extracted at $SSH_DIR"
    else
        echo "Error: no SSH key in password store."
        exit 1
    fi
}

cmd_delete () {
    if [[ -n "$key_list" ]]; then
        local dir_name="$(echo $key_list | xargs -n 1 basename | fzf)"
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

cmd_agent () {
    if [[ -n "$key_list" ]]; then
        local dir_name="$(echo $key_list | xargs -n 1 basename | fzf)"
        local pub_key=$(find "$PREFIX/$PASS_SSH_DIR/$dir_name" -name "*.pub.gpg")
        local private_key="${pub_key%.pub.gpg}"
        if [[ ! -f "$private_key.gpg" ]]; then
            echo "Error: key files missing"
            exit 1
        fi

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
