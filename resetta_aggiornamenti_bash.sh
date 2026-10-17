#!/bin/bash
# ================================================================
# RESETTA AGGIORNAMENTI macOS — v8 (OCLP-AWARE)
# ================================================================
# Rimuove il badge "1" e le notifiche di aggiornamento macOS da
# Impostazioni di Sistema e impedisce che ricompaiano.
#
# NOVITÀ v8 (companion OCLP — 17/10/2026):
#  • RILEVAMENTO OCLP: se il Mac boota con OpenCore (NVRAM
#    opencore-version) mostra e registra IL MOTIVO per cui le
#    notifiche vengono silenziate: l'hardware non supporta
#    ufficialmente quel macOS e gli aggiornamenti vanno fatti
#    con la procedura OCLP (minor: aggiorna OCLP → reinstalla
#    root patch; major: installer USB — "non raccomandato"
#    via Impostazioni secondo la guida ufficiale Dortania)
#  • LAUNCHDAEMON DI SISTEMA (it.enrico.resetta-aggiornamenti)
#    al posto del LaunchAgent per-utente della v7: protegge
#    TUTTI gli utenti dal boot, su ogni Mac; sui Mac non-OCLP
#    resta in silenzio (rileva OpenCore e esce senza toccare)
#  • SELF-INSTALL: si copia in
#    /Library/Application Support/Resetta Aggiornamenti/
#  • comandi PAUSA/ATTIVA per gli aggiornamenti veri
#  • launcher .command opzionale sulla Scrivania
#
# STORIA: v5 (17/03/2026) demoni+preferenze+ncprefs · v6
# (11/04/2026) scoperta CoreFollowUp (items.db + followupd),
# backup+RIPRISTINA_TUTTO.sh · v7-bash (16/10/2026) edizione
# bash per Mac senza Python3/CLT · v8 OCLP-aware (questa).
#
# Uso:
#   resetta_aggiornamenti_bash.sh status        → sola lettura + motivi
#   sudo resetta_aggiornamenti_bash.sh resetta [--si]
#       operazione completa + LaunchDaemon (idempotente, con backup)
#   sudo resetta_aggiornamenti_bash.sh ripristina [cartella]
#       annulla l'ultimo backup (e sospende il daemon) — PRIMA di
#       aggiornare macOS volontariamente
#   sudo resetta_aggiornamenti_bash.sh pausa [giorni]  (default 14)
#       sospende la pulizia automatica per N giorni
#   sudo resetta_aggiornamenti_bash.sh attiva
#       riattiva subito la pulizia automatica
# ================================================================

DEMONI=(
    "com.apple.softwareupdated"
    "com.apple.mobile.softwareupdated"
    "com.apple.MobileSoftwareUpdate.CleanupPreparePathService"
    "com.apple.MobileSoftwareUpdate.CryptegraftService"
    "com.apple.softwareupdate_firstrun_tasks"
)

CACHE_FILES=(
    "/var/db/softwareupdate/Library/Caches/softwareupdated/Cache.db"
    "/var/db/softwareupdate/Library/Caches/softwareupdated/Cache.db-shm"
    "/var/db/softwareupdate/Library/Caches/softwareupdated/Cache.db-wal"
    "/var/db/softwareupdate/Library/HTTPStorages/softwareupdated/httpstorages.sqlite"
    "/var/db/softwareupdate/Library/HTTPStorages/softwareupdated/httpstorages.sqlite-shm"
    "/var/db/softwareupdate/Library/HTTPStorages/softwareupdated/httpstorages.sqlite-wal"
)

# Companion OCLP: posizioni di sistema
APP_SUPPORT_DIR="/Library/Application Support/Resetta Aggiornamenti"
SCRIPT_INSTALLATO="$APP_SUPPORT_DIR/resetta_aggiornamenti_bash.sh"
DAEMON_LABEL="it.enrico.resetta-aggiornamenti"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
DAEMON_LOG="$APP_SUPPORT_DIR/silenzia.log"
PAUSA_FILE="$APP_SUPPORT_DIR/pausa-fino"
INTERVALLO=1800                    # 30 minuti
AGENT_VECCHIO="com.resetta-aggiornamenti"   # v7 per-utente, migrato in v8
OC_NVRAM_GUID="4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102"
BACKUP_BASE="$HOME/resetta-aggiornamenti-backup"

VERDE='\033[32m'; ROSSO='\033[31m'; GIALLO='\033[33m'; BOLD='\033[1m'; NC='\033[0m'

# ----------------------------------------------------------------
# Supporto
# ----------------------------------------------------------------

trova_utenti() {
    dscl . list /Users UniqueID 2>/dev/null | while read -r nome uid; do
        if [ "${uid:-0}" -ge 500 ] && [ -d "/Users/$nome" ]; then
            echo "$nome"
        fi
    done
}

flags_ncprefs() {   # $1 = home utente → stampa i flags o niente
    local plist="$1/Library/Preferences/com.apple.ncprefs.plist"
    [ -f "$plist" ] || return 1
    local i=0 bid flags
    while bid=$(plutil -extract "apps.$i.bundle-id" raw "$plist" 2>/dev/null); do
        if [[ "$bid" == *SoftwareUpdateNotification* ]]; then
            flags=$(plutil -extract "apps.$i.flags" raw "$plist" 2>/dev/null) || return 1
            echo "$flags"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

patcha_ncprefs() {  # $1 = home utente → spegne il bit badge; stampa 1 se ha modificato
    local plist="$1/Library/Preferences/com.apple.ncprefs.plist"
    [ -f "$plist" ] || { echo 0; return; }
    local i=0 bid flags nuovo
    while bid=$(plutil -extract "apps.$i.bundle-id" raw "$plist" 2>/dev/null); do
        if [[ "$bid" == *SoftwareUpdateNotification* ]]; then
            flags=$(plutil -extract "apps.$i.flags" raw "$plist" 2>/dev/null)
            if [ -n "$flags" ] && [ $(( flags & 2 )) -ne 0 ]; then
                nuovo=$(( flags & ~2 ))
                if plutil -replace "apps.$i.flags" -integer "$nuovo" "$plist" 2>/dev/null; then
                    echo 1
                    return
                fi
            fi
            echo 0
            return
        fi
        i=$((i + 1))
    done
    echo 0
}

patch_ncprefs() {   # $1 = home utente, $2 = backup dir (versione con log+backup)
    local plist="$1/Library/Preferences/com.apple.ncprefs.plist"
    [ -f "$plist" ] || { loga "  ${GIALLO}·${NC} ncprefs.plist non trovato, skip"; return; }
    cp -p "$plist" "$2/$(basename "$1")_com.apple.ncprefs.plist.bak"
    RESTORE+="cp '$2/$(basename "$1")_com.apple.ncprefs.plist.bak' '$plist'\n"
    RESTORE+="chown $(basename "$1"):staff '$plist'\n"
    local i=0 bid flags nuovo
    while bid=$(plutil -extract "apps.$i.bundle-id" raw "$plist" 2>/dev/null); do
        if [[ "$bid" == *SoftwareUpdateNotification* ]]; then
            flags=$(plutil -extract "apps.$i.flags" raw "$plist" 2>/dev/null)
            if [ -n "$flags" ]; then
                nuovo=$(( flags & ~2 ))
                if plutil -replace "apps.$i.flags" -integer "$nuovo" "$plist" 2>/dev/null; then
                    loga "  ${VERDE}✓${NC} badge notifica OFF (flags: $flags → $nuovo)"
                else
                    loga "  ${ROSSO}✗${NC} errore plutil sul replace"
                fi
            fi
            return
        fi
        i=$((i + 1))
    done
    loga "  ${GIALLO}·${NC} voce SoftwareUpdateNotification assente"
}

conta_followup() {  # $1 = home utente → numero record softwareupdate (o "")
    local db="$1/Library/CoreFollowUp/items.db"
    [ -f "$db" ] || return 1
    sqlite3 "$db" "SELECT COUNT(*) FROM items WHERE client_identifier LIKE '%softwareupdate%';" 2>/dev/null
}

loga() {
    echo -e "$1"
    [ -n "$LOGFILE" ] && echo -e "$1" | sed $'s/\033\\[[0-9;]*m//g' >> "$LOGFILE"
}

# ----------------------------------------------------------------
# Rilevamento OCLP + motivi
# ----------------------------------------------------------------

OC_DETECT=0; OC_VERSION=""; OCLP_VERSION=""; HW_MODEL=""; MACOS_VERS=""

rileva_oclp() {
    OC_VERSION=$(nvram "$OC_NVRAM_GUID:opencore-version" 2>/dev/null | awk -F'\t' '{print $NF}' | sed 's/%00$//')
    OCLP_VERSION=$(nvram "$OC_NVRAM_GUID:OCLP-Version" 2>/dev/null | awk -F'\t' '{print $NF}' | sed 's/%00$//')
    HW_MODEL=$(sysctl -n hw.model 2>/dev/null)
    MACOS_VERS=$(sw_vers -productVersion 2>/dev/null)
    OC_DETECT=0
    [ -n "$OC_VERSION" ] && OC_DETECT=1
}

max_macos_ufficiale() {   # $1 = hw.model → "versione (descrizione)" o ""
    case "$1" in
        Macmini3,1)                 echo "10.7 Lion";;
        Macmini4,1|Macmini5,*)      echo "10.13 High Sierra";;
        Macmini6,*)                 echo "10.15 Catalina";;
        Macmini7,1)                 echo "12 Monterey";;
        MacBook4,1|MacBook5,*|MacBook6,1|MacBook7,1) echo "10.11 El Capitan";;
        MacBook8,*)                 echo "11 Big Sur";;
        MacBookAir2,1|MacBookAir3,*) echo "10.11 El Capitan";;
        MacBookAir4,*)              echo "10.11 El Capitan";;
        MacBookAir5,*)              echo "10.15 Catalina";;
        MacBookAir6,*)              echo "11 Big Sur";;
        MacBookAir7,*)              echo "13 Ventura";;
        MacBookPro4,*|MacBookPro5,*) echo "10.11 El Capitan";;
        MacBookPro6,*|MacBookPro7,*|MacBookPro8,*) echo "10.13 High Sierra";;
        MacBookPro9,*|MacBookPro10,*) echo "10.15 Catalina";;
        MacBookPro11,*|MacBookPro12,*) echo "11 Big Sur";;
        MacBookPro13,*|MacBookPro14,*) echo "12 Monterey";;
        iMac9,1|iMac10,*|iMac11,*|iMac12,*) echo "10.13 High Sierra";;
        iMac13,*)                   echo "10.15 Catalina";;
        iMac14,*|iMac15,*|iMac16,*) echo "11 Big Sur";;
        iMac17,*|iMac18,*)          echo "12 Monterey";;
        MacPro3,1)                  echo "10.11 El Capitan";;
        MacPro4,1|MacPro5,1)        echo "10.14 Mojave";;
        Xserve3,1)                  echo "10.11 El Capitan";;
        *)                          echo "";;
    esac
}

mostra_motivi() {
    echo -e "${BOLD}── RILEVAMENTO OCLP ─────────────────────────────${NC}"
    if [ "$OC_DETECT" -eq 1 ]; then
        echo -e "  Boot     : ${GIALLO}OpenCore $OC_VERSION${NC}"
        [ -n "$OCLP_VERSION" ] && echo "  OCLP     : $OCLP_VERSION"
        local max_os
        max_os=$(max_macos_ufficiale "$HW_MODEL")
        [ -n "$max_os" ] || max_os="non tabulato (presumi limite superato)"
        echo "  Modello  : $HW_MODEL — ultimo macOS ufficiale: $max_os"
        echo "  In uso   : macOS $MACOS_VERS"
        echo ""
        echo -e "${GIALLO}  ⚠ MOTIVO: questo hardware NON supporta ufficialmente${NC}"
        echo -e "${GIALLO}     questo macOS: il sistema gira grazie a OpenCore${NC}"
        echo -e "${GIALLO}     Legacy Patcher. Secondo la guida ufficiale Dortania:${NC}"
        echo "     • aggiornamenti MINORI: solo dopo aver aggiornato OCLP,"
        echo "       reinstallato OpenCore e, a fine update, i root patch"
        echo "     • upgrade MAJOR: da installer USB («non raccomandato»"
        echo "       via Impostazioni)"
        echo "     Per questo le notifiche di aggiornamento vengono silenziate."
    else
        echo -e "  Boot     : ${VERDE}nativo (nessun OpenCore rilevato)${NC}"
        echo "  Modello  : $HW_MODEL · macOS $MACOS_VERS"
        echo "  Mac non-OCLP: il daemon di pulizia resterà in silenzio."
    fi
    echo -e "${BOLD}─────────────────────────────────────────────────${NC}"
}

# ----------------------------------------------------------------
# STATUS (sola lettura)
# ----------------------------------------------------------------

cmd_status() {
    echo -e "${BOLD}"
    echo "═══════════════════════════════════════════════════"
    echo "  RESETTA AGGIORNAMENTI macOS — STATUS (sola lettura)"
    echo "═══════════════════════════════════════════════════"
    echo -e "${NC}"
    echo "  macOS $MACOS_VERS — edizione bash v8 (OCLP-aware)"
    echo ""
    mostra_motivi
    echo ""

    echo -e "${BOLD}🔧 Demoni software update:${NC}"
    local disabled
    disabled=$(launchctl print-disabled system 2>/dev/null)
    for d in "${DEMONI[@]}"; do
        if echo "$disabled" | grep -q "\"$d\""; then
            echo -e "  ${VERDE}✓ disabilitato${NC}  $d"
        else
            echo -e "  ${GIALLO}⚠ attivo${NC}  $d"
        fi
    done

    echo -e "\n${BOLD}🔧 Preferenze aggiornamenti automatici:${NC}"
    for chiave in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates; do
        val=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate "$chiave" 2>/dev/null)
        [ -z "$val" ] && val="non impostata"
        echo "  ·  $chiave = $val"
    done

    echo -e "\n${BOLD}🔧 Pulizia automatica:${NC}"
    if [ -f "$DAEMON_PLIST" ] && launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
        echo -e "  ${VERDE}✓${NC} LaunchDaemon $DAEMON_LABEL attivo (ogni 30 min)"
    elif [ -f "$DAEMON_PLIST" ]; then
        echo -e "  ${GIALLO}·${NC} LaunchDaemon installato ma non caricato"
    else
        echo -e "  ${GIALLO}·${NC} LaunchDaemon non installato"
    fi
    if [ -f "$PAUSA_FILE" ]; then
        echo -e "  ${GIALLO}⏸${NC} in pausa fino al $(cat "$PAUSA_FILE" 2>/dev/null)"
    fi

    echo -e "\n${BOLD}👤 Stato badge per utente:${NC}"
    for utente in $(trova_utenti); do
        home="/Users/$utente"
        flags=$(flags_ncprefs "$home")
        if [ -n "$flags" ]; then
            if [ $(( flags & 2 )) -ne 0 ]; then
                echo -e "  ${GIALLO}⚠ badge ON${NC}  [$utente] SoftwareUpdateNotification flags=$flags"
            else
                echo -e "  ${VERDE}✓ badge OFF${NC}  [$utente] SoftwareUpdateNotification flags=$flags"
            fi
        else
            echo "  ·  [$utente] ncprefs non leggibile o voce assente"
        fi
        n=$(conta_followup "$home")
        if [ -n "$n" ]; then
            if [ "$n" -gt 0 ]; then
                echo -e "     ${GIALLO}⚠  CoreFollowUp: $n notifiche aggiornamenti in coda${NC}"
            else
                echo -e "     ${VERDE}✓  CoreFollowUp: nessuna notifica in coda${NC}"
            fi
        else
            echo "     ·  CoreFollowUp: non leggibile o inesistente"
        fi
    done

    echo "───────────────────────────────────────────────────"
    if [ "$OC_DETECT" -eq 1 ]; then
        echo -e "  ${BOLD}VERDETTO: Mac OCLP — aggiornamenti solo via procedura OCLP.${NC}"
        echo "  Per silenziare/riparare: sudo bash $0 resetta"
    else
        echo "  Mac non-OCLP: il silenziamento è facoltativo."
    fi
    echo "───────────────────────────────────────────────────"
}

# ----------------------------------------------------------------
# RESETTA (richiede sudo)
# ----------------------------------------------------------------

RESTORE=""
LOGFILE=""

cmd_resetta() {
    local auto_si=0
    [ "${1:-}" = "--si" ] && auto_si=1

    echo -e "${BOLD}"
    echo "═══════════════════════════════════════════════════"
    echo "  RESETTA AGGIORNAMENTI macOS — v8 (OCLP-aware)"
    echo "═══════════════════════════════════════════════════"
    echo -e "${NC}"
    mostra_motivi
    echo ""

    UTENTI=$(trova_utenti)
    [ -z "$UTENTI" ] && { echo -e "${ROSSO}✗ Nessun utente reale trovato.${NC}"; exit 1; }
    echo "  Utenti da trattare: ${BOLD}$(echo $UTENTI | tr '\n' ' ')${NC}"
    if [ "$auto_si" -ne 1 ]; then
        read -p "  ⚠ Operazione aggressiva (demoni OFF). Confermi? (s/n): " conferma
        [ "$conferma" != "s" ] && { echo "Annullato."; exit 0; }
    fi

    # ── Backup (stile v6) ─────────────────────────────────────
    local ts backup_dir restore_script
    ts=$(date +%Y%m%d_%H%M%S)
    backup_dir="$BACKUP_BASE/$ts"
    restore_script="$backup_dir/RIPRISTINA_TUTTO.sh"
    LOGFILE="$backup_dir/operazioni.log"
    mkdir -p "$backup_dir"
    {
        echo "#!/bin/bash"
        echo "# Script di ripristino generato automaticamente il $(date)"
        echo "# Uso: sudo bash $restore_script"
        echo ""
        echo 'if [ "$EUID" -ne 0 ]; then echo "Esegui con sudo"; exit 1; fi'
        echo "set -x"
    } > "$restore_script"
    chmod +x "$restore_script"
    loga "📁 Backup in: $backup_dir"

    # ── Passo 1: demoni ───────────────────────────────────────
    echo -e "\n${BOLD}🔧 Passo 1: Disabilitazione demoni software update${NC}"
    RESTORE+="# --- Ripristino demoni ---\n"
    for d in "${DEMONI[@]}"; do
        launchctl disable "system/$d" 2>/dev/null
        loga "  ${VERDE}✓${NC} disabilitato: $d"
        RESTORE+="launchctl enable system/$d\n"
    done
    RESTORE+="\n"

    # ── Passo 2: preferenze ───────────────────────────────────
    echo -e "\n${BOLD}🔧 Passo 2: Preferenze aggiornamenti automatici OFF${NC}"
    PLIST_SU="/Library/Preferences/com.apple.SoftwareUpdate"
    if [ -f "$PLIST_SU.plist" ]; then
        cp -p "$PLIST_SU.plist" "$backup_dir/com.apple.SoftwareUpdate.plist.bak"
        RESTORE+="cp '$backup_dir/com.apple.SoftwareUpdate.plist.bak' '$PLIST_SU.plist'\n\n"
    fi
    defaults write "$PLIST_SU" AutomaticCheckEnabled -bool false
    defaults write "$PLIST_SU" AutomaticDownload -bool false
    defaults write "$PLIST_SU" AutomaticallyInstallMacOSUpdates -bool false
    defaults write "$PLIST_SU" ConfigDataInstall -bool false
    defaults write "$PLIST_SU" CriticalUpdateInstall -bool false
    defaults write "$PLIST_SU" RecommendedUpdates -array
    defaults write "$PLIST_SU" LastRecommendedUpdatesAvailable -int 0
    defaults write "$PLIST_SU" LastUpdatesAvailable -int 0
    defaults write "$PLIST_SU" LastResultCode -int 0
    defaults delete "$PLIST_SU" FirstOfferDateDictionary 2>/dev/null
    loga "  ${VERDE}✓${NC} controlli automatici disattivati, lista aggiornamenti vuota"
    RESTORE+="defaults delete $PLIST_SU RecommendedUpdates 2>/dev/null\n\n"

    # ── Passo 3: cache ────────────────────────────────────────
    echo -e "\n${BOLD}🔧 Passo 3: Pulizia cache software update${NC}"
    mkdir -p "$backup_dir/cache"
    rimossi=0
    for f in "${CACHE_FILES[@]}"; do
        if [ -f "$f" ]; then
            cp -p "$f" "$backup_dir/cache/$(basename "$f")"
            rm -f "$f"
            rimossi=$((rimossi + 1))
        fi
    done
    loga "  ${VERDE}✓${NC} $rimossi file di cache rimossi (copia in backup)"

    # ── Passo 4: badge per utente + CoreFollowUp (scoperta v6) ─
    echo -e "\n${BOLD}🔧 Passo 4: Badge, notifiche e CoreFollowUp per utente${NC}"
    RESTORE+="# --- Ripristino badge notifiche ---\n"
    for utente in $UTENTI; do
        home="/Users/$utente"
        echo -e "  ${BOLD}[$utente]${NC}"
        patch_ncprefs "$home" "$backup_dir"
        sudo -u "$utente" defaults delete com.apple.systempreferences AttentionPrefBundleIDs 2>/dev/null
        loga "  ${VERDE}✓${NC} AttentionPrefBundleIDs resettato"
        db="$home/Library/CoreFollowUp/items.db"
        if [ -f "$db" ]; then
            cp -p "$db" "$backup_dir/${utente}_items.db.bak"
            RESTORE+="cp '$backup_dir/${utente}_items.db.bak' '$db'\n"
            RESTORE+="chown $utente:staff '$db'\n"
            sqlite3 "$db" "DELETE FROM items WHERE client_identifier LIKE '%softwareupdate%';" 2>/dev/null
            chown "$utente:staff" "$db" 2>/dev/null
            loga "  ${VERDE}✓${NC} CoreFollowUp: notifiche aggiornamenti eliminate"
        else
            loga "  ${GIALLO}·${NC} CoreFollowUp/items.db non trovato, skip"
        fi
    done
    RESTORE+="\n"

    # followupd rigenera il badge: termina entrambi (v6)
    killall followupd 2>/dev/null
    killall SoftwareUpdateNotificationManager 2>/dev/null
    loga "  ${VERDE}✓${NC} followupd / SoftwareUpdateNotificationManager terminati"

    # ── Passo 5: pulizia automatica (LaunchDaemon, v8) ─────────
    echo -e "\n${BOLD}🔧 Passo 5: Pulizia automatica di sistema (LaunchDaemon)${NC}"
    # 5a. migrazione: rimuove il vecchio LaunchAgent per-utente della v7
    for utente in $UTENTI; do
        home="/Users/$utente"
        sudo -u "$utente" launchctl unload "$home/Library/LaunchAgents/$AGENT_VECCHIO.plist" 2>/dev/null
        rm -f "$home/Library/LaunchAgents/$AGENT_VECCHIO.plist" "$home/resetta_badge_auto.sh"
    done
    loga "  ${VERDE}✓${NC} vecchio LaunchAgent v7 rimosso (se presente)"

    # 5b. self-install dello script
    mkdir -p "$APP_SUPPORT_DIR"
    cp -p "$0" "$SCRIPT_INSTALLATO"
    chmod 755 "$SCRIPT_INSTALLATO"
    chown root:wheel "$SCRIPT_INSTALLATO"
    rm -f "$PAUSA_FILE"
    loga "  ${VERDE}✓${NC} script autoinstallato: $SCRIPT_INSTALLATO"

    # 5c. LaunchDaemon
    cat > "$DAEMON_PLIST" <<PLEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$DAEMON_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_INSTALLATO</string>
        <string>--auto</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>$INTERVALLO</integer>
    <key>StandardOutPath</key>
    <string>$DAEMON_LOG</string>
    <key>StandardErrorPath</key>
    <string>$DAEMON_LOG</string>
</dict>
</plist>
PLEOF
    chown root:wheel "$DAEMON_PLIST"
    chmod 644 "$DAEMON_PLIST"
    launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null
    launchctl enable "system/$DAEMON_LABEL" 2>/dev/null
    if launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null; then
        loga "  ${VERDE}✓${NC} LaunchDaemon attivo: $DAEMON_LABEL (ogni 30 min, dal boot)"
    else
        loga "  ${GIALLO}⚠${NC} bootstrap non riuscito, provo load"
        launchctl load "$DAEMON_PLIST" 2>/dev/null
    fi
    RESTORE+="# --- Rimozione pulizia automatica ---\n"
    RESTORE+="launchctl bootout system/$DAEMON_LABEL 2>/dev/null\n"
    RESTORE+="launchctl disable system/$DAEMON_LABEL 2>/dev/null\n"
    RESTORE+="rm -f '$DAEMON_PLIST'\n"
    RESTORE+="\n"

    # 5d. launcher .command sulla Scrivania (facoltativo)
    installa_launcher=1
    if [ "$auto_si" -ne 1 ]; then
        read -p $'\n  Copiare il launcher "Silenzia Aggiornamenti (OCLP).command" sulle Scrivanie? (S/n): ' risposta
        [ "$risposta" = "n" ] && installa_launcher=0
    fi
    if [ "$installa_launcher" -eq 1 ]; then
        for utente in $UTENTI; do
            desktop="/Users/$utente/Desktop"
            [ -d "$desktop" ] || continue
            launcher="$desktop/Silenzia Aggiornamenti (OCLP).command"
            cat > "$launcher" <<LCEOF
#!/bin/bash
# Launcher doppio-click — rigenera il silenzio aggiornamenti (Mac OCLP)
# Generato il $(date "+%d/%m/%Y") da resetta_aggiornamenti_bash.sh v8
clear
echo "═══════════════════════════════════════════════════"
echo "  Silenzia Aggiornamenti (OCLP) — $utente"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Serve la password di amministratore."
echo ""
sudo bash "$SCRIPT_INSTALLATO" resetta
echo ""
echo "Fatto. Puoi chiudere questa finestra."
read -n 1 -p "Premi un tasto per uscire..."
LCEOF
            chmod 755 "$launcher"
            chown "$utente:staff" "$launcher"
            loga "  ${VERDE}✓${NC} [$utente] launcher su Scrivania"
        done
    fi

    # ── Passo 6: riavvio servizi ──────────────────────────────
    echo -e "\n${BOLD}🔧 Passo 6: Riavvio servizi per applicare${NC}"
    killall cfprefsd 2>/dev/null; sleep 1
    killall usernoted 2>/dev/null
    killall NotificationCenter 2>/dev/null; sleep 1
    killall Dock 2>/dev/null
    loga "  ${VERDE}✓${NC} cfprefsd, usernoted, NotificationCenter, Dock riavviati"
    RESTORE+="# --- Riavvio finale ---\n"
    RESTORE+="killall cfprefsd; sleep 1; killall usernoted; killall NotificationCenter; sleep 1; killall Dock\n"
    RESTORE+="echo \"✅ Ripristino completato. Riavvia il Mac per sicurezza.\"\n"

    printf "%b" "$RESTORE" >> "$restore_script"

    echo ""
    echo -e "${VERDE}${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${VERDE}${BOLD}  ✅ OPERAZIONE COMPLETATA${NC}"
    echo -e "${VERDE}${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Script installato : $SCRIPT_INSTALLATO"
    echo "  Daemon            : $DAEMON_LABEL (ogni 30 min, dal boot)"
    echo "  Backup            : $backup_dir"
    echo "  Log operazioni    : $LOGFILE"
    [ "$OC_DETECT" -eq 1 ] && echo "  Motivo registrato : Mac OCLP ($HW_MODEL) — vedi log"
    echo ""
    echo -e "${GIALLO}  PER RIPRISTINARE TUTTO (prima di aggiornare macOS):${NC}"
    echo "    sudo bash '$restore_script'"
    echo "    oppure: sudo bash $0 ripristina"
    echo ""
    echo "  Per aggiornamenti veri: sudo bash $0 pausa [giorni]"
    echo "  Poi riattiva:          sudo bash $0 attiva"
    echo ""
}

# ----------------------------------------------------------------
# RIPRISTINA (richiede sudo)
# ----------------------------------------------------------------

cmd_ripristina() {
    local cartella="${1:-}"
    local auto_si="${2:-0}"
    if [ -z "$cartella" ]; then
        local ultimo
        ultimo=$(ls -d "$BACKUP_BASE"/*/RIPRISTINA_TUTTO.sh 2>/dev/null | sort -r | head -1)
        cartella=${ultimo%/RIPRISTINA_TUTTO.sh}
    fi
    local restore_script="$cartella/RIPRISTINA_TUTTO.sh"
    if [ ! -f "$restore_script" ]; then
        echo -e "${ROSSO}✗ Script di ripristino non trovato.${NC}"
        echo "  Cerca in: $BACKUP_BASE"
        exit 1
    fi
    # Sospende il daemon: non deve risilenziare durante l'aggiornamento
    launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null
    launchctl disable "system/$DAEMON_LABEL" 2>/dev/null
    echo -e "${GIALLO}⏸ Pulizia automatica sospesa (daemon disabilitato)${NC}"
    echo "  Backup: $cartella"
    if [ "$auto_si" -ne 1 ]; then
        read -p "  Confermi il ripristino? (s/n): " conferma
        [ "$conferma" != "s" ] && { echo "Annullato."; exit 0; }
    fi
    bash "$restore_script"
    echo -e "${VERDE}${BOLD}✅ RIPRISTINO COMPLETATO${NC} — riavvia il Mac per sicurezza."
    echo ""
    echo "  Quando l'aggiornamento è finito, riattiva il silenzio:"
    echo "    sudo bash $0 resetta"
    echo ""
}

# ----------------------------------------------------------------
# PAUSA / ATTIVA (richiedono sudo)
# ----------------------------------------------------------------

cmd_pausa() {
    local giorni="${1:-14}"
    mkdir -p "$APP_SUPPORT_DIR"
    date -v+"${giorni}"d +%Y-%m-%d > "$PAUSA_FILE" 2>/dev/null || date +%Y-%m-%d > "$PAUSA_FILE"
    echo -e "${GIALLO}⏸ Pulizia automatica in pausa fino al $(cat "$PAUSA_FILE")${NC}"
    echo "  (Il daemon resta installato ma non interviene.)"
    echo "  Per riattivare prima: sudo bash $0 attiva"
}

cmd_attiva() {
    rm -f "$PAUSA_FILE"
    launchctl enable "system/$DAEMON_LABEL" 2>/dev/null
    launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null
    launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null \
        || launchctl load "$DAEMON_PLIST" 2>/dev/null
    launchctl kickstart -k "system/$DAEMON_LABEL" 2>/dev/null
    echo -e "${VERDE}▶ Pulizia automatica riattivata (pausa rimossa, daemon avviato)${NC}"
}

# ----------------------------------------------------------------
# --auto (uso interno del LaunchDaemon, richiede root)
# ----------------------------------------------------------------

cmd_auto() {
    [ "$(id -u)" -ne 0 ] && exit 1
    # 1. pausa?
    if [ -f "$PAUSA_FILE" ]; then
        oggi=$(date +%Y-%m-%d)
        fino=$(cat "$PAUSA_FILE" 2>/dev/null)
        [[ "$fino" > "$oggi" ]] && exit 0
        rm -f "$PAUSA_FILE"   # pausa scaduta
    fi
    # 2. solo Mac OCLP: senza OpenCore non toccare nulla
    oc=$(nvram "$OC_NVRAM_GUID:opencore-version" 2>/dev/null | awk -F'\t' '{print $NF}')
    [ -z "$oc" ] && exit 0
    # 3. pulizia per utente
    cambi=0
    riga=""
    for utente in $(trova_utenti); do
        home="/Users/$utente"
        c=$(patcha_ncprefs "$home")
        [ "$c" = "1" ] && { cambi=1; riga="$riga badge[$utente]"; }
        n=$(conta_followup "$home")
        if [ -n "$n" ] && [ "$n" -gt 0 ]; then
            sqlite3 "$home/Library/CoreFollowUp/items.db" \
                "DELETE FROM items WHERE client_identifier LIKE '%softwareupdate%';" 2>/dev/null
            cambi=1; riga="$riga corefollowup[$utente]=$n"
        fi
        sudo -u "$utente" defaults delete com.apple.systempreferences \
            AttentionPrefBundleIDs 2>/dev/null
    done
    # 4. se qualcosa è cambiato, rigenera le difese
    if [ "$cambi" -eq 1 ]; then
        killall followupd 2>/dev/null
        killall SoftwareUpdateNotificationManager 2>/dev/null
        killall cfprefsd 2>/dev/null
        killall usernoted 2>/dev/null
        killall NotificationCenter 2>/dev/null
        sleep 1
        killall Dock 2>/dev/null
    fi
    # 5. log (con rotazione leggera)
    echo "$(date '+%Y-%m-%d %H:%M:%S') OCLP=$oc cambi=$cambi$riga" >> "$DAEMON_LOG"
    if [ -f "$DAEMON_LOG" ] && [ "$(wc -l < "$DAEMON_LOG")" -gt 500 ]; then
        tail -n 300 "$DAEMON_LOG" > "$DAEMON_LOG.tmp" && mv "$DAEMON_LOG.tmp" "$DAEMON_LOG"
    fi
    exit 0
}

# ----------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------

rileva_oclp

case "${1:-}" in
    status)
        cmd_status
        ;;
    resetta)
        [ "$EUID" -ne 0 ] && { echo -e "${ROSSO}✗ Esegui con sudo: sudo bash $0 resetta${NC}"; exit 1; }
        cmd_resetta "${2:-}"
        ;;
    ripristina)
        [ "$EUID" -ne 0 ] && { echo -e "${ROSSO}✗ Esegui con sudo: sudo bash $0 ripristina${NC}"; exit 1; }
        cartella=""; auto_si=0
        case "${2:-}" in
            --si) auto_si=1; cartella="${3:-}" ;;
            *)    cartella="${2:-}" ;;
        esac
        cmd_ripristina "$cartella" "$auto_si"
        ;;
    pausa)
        [ "$EUID" -ne 0 ] && { echo -e "${ROSSO}✗ Esegui con sudo: sudo bash $0 pausa [giorni]${NC}"; exit 1; }
        cmd_pausa "${2:-}"
        ;;
    attiva)
        [ "$EUID" -ne 0 ] && { echo -e "${ROSSO}✗ Esegui con sudo: sudo bash $0 attiva${NC}"; exit 1; }
        cmd_attiva
        ;;
    --auto)
        cmd_auto
        ;;
    *)
        echo "RESETTA AGGIORNAMENTI macOS — v8 (OCLP-aware)"
        echo ""
        echo "Uso:"
        echo "  $0 status                        → sola lettura + motivi (no sudo)"
        echo "  sudo $0 resetta [--si]           → operazione completa + LaunchDaemon"
        echo "  sudo $0 ripristina [--si] [cartella] → annulla l'ultimo backup"
        echo "  sudo $0 pausa [giorni]           → sospendi la pulizia (default 14 g)"
        echo "  sudo $0 attiva                   → riattiva subito la pulizia"
        echo ""
        exit 1
        ;;
esac
