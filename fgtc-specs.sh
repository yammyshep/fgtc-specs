#!/bin/bash

SERVER_URL=http://127.0.0.1:8000

TYPE=other
MANUFACTURER=($(sudo dmidecode --string system-manufacturer))
MODEL=$(sudo dmidecode --string system-product-name)
OPERATING_SYSTEM=$(cat /etc/*-release | awk '/PRETTY_NAME/' | cut -d\" -f2)

PROCESSOR_MODELS=$(sudo dmidecode --string processor-version)

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

PROCESSORS_JSON="[]"
for i in "${!PROCESSOR_MODELS[@]}"; do
    PROCESSORS_JSON=$(echo $PROCESSORS_JSON | jq \
        --arg model "${PROCESSOR_MODELS[$i]}" \
        '. += [{model: $model}]')
done

FASTEST_LINKSPEED=null
for i in $(netstat -i | cut -f1 -d" " | tail -n+3); do
    LINKSPEED=$(ethtool --json $i 2> /dev/null | jq '.[0]."supported-link-modes"[-1]' | sed 's/[^0-9]*//g')
    if (( LINKSPEED > FASTEST_LINKSPEED )); then
        FASTEST_LINKSPEED=$LINKSPEED
    fi
done

WIRELESS="none"
WIRELESS_INFO=$(iw list)
if [[ $(grep "HT Capability" <<< $WIRELESS_INFO) ]]; then
    WIRELESS="n"
fi
if [[ $(grep "VHT Capabilities" <<< $WIRELESS_INFO) ]]; then
    WIRELESS="ac"
fi
if [[ $(grep "+HTC HE Supported" <<< $WIRELESS_INFO) ]]; then
    WIRELESS="ax"
fi
#TODO: Detect WiFi 7 (802.11be) adapters
#if [[ $(grep "" <<< $WIRELESS_INFO) ]]; then
#    WIRELESS="be"
#fi

BLUETOOTH=false
if [[ -n "$(rfkill list | grep -i bluetooth)" ]]; then
    BLUETOOTH=true
fi

BATTERIES_JSON="[]"
for i in $(upower -e | grep battery_BAT); do
    BATTERY_DESIGN=$(bc <<< "$(upower -i $i | grep energy-full-design: | sed 's/[^0-9\.]*//g')*1000")
    BATTERY_REMAIN=$(bc <<< "$(upower -i $i | grep energy-full: | sed 's/[^0-9\.]*//g')*1000")
    BATTERIES_JSON=$(echo $BATTERIES_JSON | jq \
    --arg design "$(printf "%.0f" $BATTERY_DESIGN)" \
    --arg remain "$(printf "%.0f" $BATTERY_REMAIN)" \
    '. + [{design_capacity: $design, remaining_capacity: $remain}]')
done

BUILD_JSON=$( jq -n \
    --arg type "$TYPE" \
    --arg manufacturer "$MANUFACTURER" \
    --arg model "$MODEL" \
    --arg os "$OPERATING_SYSTEM" \
    --arg wired "$FASTEST_LINKSPEED" \
    --arg wireless null \
    --arg bluetooth "$BLUETOOTH" \
    --argjson processors "$PROCESSORS_JSON" \
    --argjson memory "$MEMORY_JSON" \
    --argjson batteries "$BATTERIES_JSON" \
    '{type: $type, manufacturer: $manufacturer, model: $model, operating_system: $os, wired_networking: $wired, wireless_networking: $wireless, bluetooth: $bluetooth, processors: $processors, memory: $memory, batteries: $batteries}'
)

echo $BUILD_JSON
echo $WIRELESS

exit 0
RESPONSE=$(curl --json "$BUILD_JSON" ${SERVER_URL}/build)

ID=$(echo $RESPONSE | jq '.id' | tr -d '"')
echo $ID

xdg-open ${SERVER_URL}/build/create?edit=${ID}