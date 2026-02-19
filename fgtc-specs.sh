#!/bin/bash

SERVER_URL="${SERVER_URL:-http://10.100.2.190}"

function install_packages () {
    if command -v apt >/dev/null 2>&1; then
        sudo apt install $1
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install $1
    fi
}

if ! command -v jq >/dev/null 2>&1; then
    install_packages jq
fi

if ! command -v iw >/dev/null 2>&1; then
    install_packages iw
fi

function get_processors_json {
    PROCESSOR_MODELS=$(sudo dmidecode --string processor-version)

    PROCESSORS_JSON="[]"
    for i in "${!PROCESSOR_MODELS[@]}"; do
        PROCESSORS_JSON=$(echo $PROCESSORS_JSON | jq \
            --arg model "${PROCESSOR_MODELS[$i]}" \
            '. += [{model: $model}]')
    done
    echo "$PROCESSORS_JSON"
}

function get_memory_json {
    MEMORY_TYPES=($(sudo dmidecode --type memory | grep -E '^\s*Type:' | awk '{print $2}'))
    MEMORY_SIZES=($(sudo dmidecode --type memory | grep -E '^\s*Size:' | awk '{print $2}'))
    MEMORY_UNITS=($(sudo dmidecode --type memory | grep -E '^\s*Size:' | awk '{print $3}'))
    MEMORY_SPEEDS=($(sudo dmidecode --type memory | grep -E '^\s*Speed:' | awk '{print $2}'))

    MEMORY_JSON="[]"
    for i in "${!MEMORY_TYPES[@]}"; do
        MEMORY_JSON=$(echo $MEMORY_JSON | jq \
            --arg type "${MEMORY_TYPES[$i]#DDR}" \
            --arg size "$((${MEMORY_SIZES[$i]} * 1000))" \
            --arg clock "${MEMORY_SPEEDS[$i]}" \
            '. += [{type: $type, size: $size, clock: $clock}]')
    done
    echo "$MEMORY_JSON"
}

function get_lan_speed {
    FASTEST_LINKSPEED=null
    for i in $(netstat -i | cut -f1 -d" " | tail -n+3); do
        LINKSPEED=$(ethtool --json $i 2> /dev/null | jq '.[0]."supported-link-modes"[-1]' | sed 's/[^0-9]*//g')
        if (( LINKSPEED > FASTEST_LINKSPEED )); then
            FASTEST_LINKSPEED=$LINKSPEED
        fi
    done
    echo $FASTEST_LINKSPEED
}

function get_wlan_standard {
    WIRELESS_INFO=$(iw list)
    #TODO: Detect WiFi 7 (802.11be) adapters
    #if [[ $(grep "" <<< $WIRELESS_INFO) ]]; then
    #    echo "be"
    #fi
    if [[ $(grep "+HTC HE Supported" <<< $WIRELESS_INFO) ]]; then
        echo "ax"
    elif [[ $(grep "VHT Capabilities" <<< $WIRELESS_INFO) ]]; then
        echo "ac"
    elif [[ $(grep "HT Capability" <<< $WIRELESS_INFO) ]]; then
        echo "n"
    else
        echo "null"
    fi
}

function get_bluetooth {
    if [[ -n "$(rfkill list | grep -i bluetooth)" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

function get_batteries_json {
    BATTERIES_JSON="[]"
    for i in $(upower -e | grep battery_BAT); do
        BATTERY_DESIGN=$(bc <<< "$(upower -i $i | grep energy-full-design: | sed 's/[^0-9\.]*//g')*1000")
        BATTERY_REMAIN=$(bc <<< "$(upower -i $i | grep energy-full: | sed 's/[^0-9\.]*//g')*1000")
        BATTERIES_JSON=$(echo $BATTERIES_JSON | jq \
        --arg design "$(printf "%.0f" $BATTERY_DESIGN)" \
        --arg remain "$(printf "%.0f" $BATTERY_REMAIN)" \
        '. + [{design_capacity: $design, remaining_capacity: $remain}]')
    done
    echo "$BATTERIES_JSON"
}

function get_storage_json {
    local STORAGE_JSON="[]"
    while read device; do
        if [[ $(echo $device | cut -d' ' -f3) -eq "1" ]]; then
            local type="hdd"
        else
            local type="ssd"
        fi

        local interface=$(echo $device | cut -d' ' -f2)

        if [[ $interface == "ata" ]]; then
            local interface="sata"
        fi

        if [[ $interface == "nvme" ]]; then
            local form="m2"
        elif [[ $interface == "sata" ]]; then
            if [[ $type == "ssd" ]]; then
                local form="2.5"
            else
                #TODO: Detect laptop hdds?
                local form="3.5"
            fi
        else
            local form="3.5"
        fi

        local STORAGE_JSON=$(echo $STORAGE_JSON | jq \
            --arg type "$type" \
            --arg form "$form" \
            --arg interface "$interface" \
            --arg size "$(($(echo $device | cut -d' ' -f4) / 1000000))" \
            '. += [{
                type: $type,
                form: $form,
                interface: $interface,
                size: $size
            }]'
        )
    done <<< $(lsblk -dbnl -o name,tran,rota,size | grep -Ev 'zram|usb')
    echo "$STORAGE_JSON"
}

function get_device_type {
    local chassis_type=$(hostnamectl chassis)

    case $chassis_type in
    laptop | convertable)
        echo "laptop"
        ;;
    desktop)
        echo "desktop"
        ;;
    *)
        echo "other"
        ;;
    esac
}

MANUFACTURER=($(sudo dmidecode --string system-manufacturer))
MODEL=$(sudo dmidecode --string system-product-name)
OPERATING_SYSTEM=$(cat /etc/*-release | awk '/PRETTY_NAME/' | cut -d\" -f2)

BUILD_JSON=$( jq -n \
    --arg type "$(get_device_type)" \
    --arg manufacturer "$MANUFACTURER" \
    --arg model "$MODEL" \
    --arg os "$OPERATING_SYSTEM" \
    --arg wired "$(get_lan_speed)" \
    --arg wireless "$(get_wlan_standard)" \
    --arg bluetooth "$(get_bluetooth)" \
    --argjson processors "$(get_processors_json)" \
    --argjson memory "$(get_memory_json)" \
    --argjson storage "$(get_storage_json)" \
    --argjson batteries "$(get_batteries_json)" \
    '{
        type: $type,
        manufacturer: $manufacturer,
        model: $model,
        operating_system: $os,
        wired_networking: $wired,
        wireless_networking: $wireless,
        bluetooth: $bluetooth,
        processors: $processors,
        memory: $memory,
        batteries: $batteries,
        storage: $storage
    }'
)

echo "$BUILD_JSON" | jq .

if [[ " $* " != *" --no-submit "* ]]; then
    RESPONSE=$(curl --json "$BUILD_JSON" ${SERVER_URL}/build 2> /dev/null)

    ID=$(echo $RESPONSE | jq '.id' | tr -d '"')
    echo "Build ID: $ID"
    
    if [[ " $* " != *" --no-open "* ]]; then
        xdg-open ${SERVER_URL}/build/create?edit=${ID} 2> /dev/null
    fi
fi
