#!/bin/bash

MAP="/usr/share/rudyraindesktop/boot-stages.map"

CURRENT_STAGE=""

while IFS= read -r line; do
    case "$line" in
        \#*)
            if [[ "$line" == *"Stage 3"* ]]; then CURRENT_STAGE="rudy-extra-ui.target"; fi
            if [[ "$line" == *"Stage 4"* ]]; then CURRENT_STAGE="rudy-extensions.target"; fi
            if [[ "$line" == *"Stage 5"* ]]; then CURRENT_STAGE="rudy-apps.target"; fi
            if [[ "$line" == *"Stage 6"* ]]; then CURRENT_STAGE="rudy-everything-else.target"; fi
            continue
            ;;
        "")
            continue
            ;;
        *)
            UNIT="$line"
            DIR="/etc/systemd/system/$UNIT.d"
            mkdir -p "$DIR"
            cat > "$DIR/override.conf" <<EOF
[Unit]
After=$CURRENT_STAGE
EOF
            ;;
    esac
done < "$MAP"
