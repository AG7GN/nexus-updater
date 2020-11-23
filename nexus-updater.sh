#!/usr/bin/env bash
#================================================================
# HEADER
#================================================================
#% SYNOPSIS
#+   ${SCRIPT_NAME} [-hv] 
#+   ${SCRIPT_NAME} [-d DIRECTORY] [-l FILE] [-f FILE] [APP[,APP]...]
#%
#% DESCRIPTION
#%   This script updates the Raspberry Pi image designed for use on the Nexus DR-X.
#%   It can update the Raspbian OS as well as select ham applications.
#%
#% OPTIONS
#%    -h, --help              Print this help
#%    -v, --version           Print script information
#%    -l, --list              List of applications this script has the ability to
#%                            install.
#%    -s, --self-check        Scripts checks for a new version of itself when run and
#%                            automatically updates itself if an update is available.
#%    -f, --force-reinstall   Re-install an application even if it's up to date
#% 
#% COMMANDS 
#%    APP(s)                  Zero or more applications (comma separated) to install,
#%                            or udpate if already installed.
#%                            If no APPs are supplied, the script runs in GUI
#%                            mode and presents a user interface in which the user
#%                            can select one or more APPs for installation or
#%                            upgrade.
#%                                
#% EXAMPLES
#%    Run the script in GUI mode and run the self-checker:
#%
#%      ${SCRIPT_NAME} -s
#%
#%    Run the script from the command line and install or update fldigi and flmsg:
#%
#%      ${SCRIPT_NAME} fldigi,flmsg  
#%    
#%    Run the script from the command line and force a reinstall of fldigi and flmsg:
#%
#%      ${SCRIPT_NAME} -f fldigi,flmsg  
#%    
#================================================================
#- IMPLEMENTATION
#-    version         ${SCRIPT_NAME} 2.0.1
#-    author          Steve Magnuson, AG7GN
#-    license         CC-BY-SA Creative Commons License
#-    script_id       0
#-
#================================================================
#  HISTORY
#     20201120 : Steve Magnuson : Script creation
# 
#================================================================
#  DEBUG OPTION
#    set -n  # Uncomment to check your syntax, without execution.
#    set -x  # Uncomment to debug this shell script
#
#================================================================
# END_OF_HEADER
#================================================================

SYNTAX=false
DEBUG=false
Optnum=$#

#============================
#  FUNCTIONS
#============================

function TrapCleanup() {
  [[ -d "${TMPDIR}" ]] && rm -rf "${TMPDIR}/"
  exit 0
}


function SafeExit() {
  # Delete temp files, if any
  [[ -d "${TMPDIR}" ]] && rm -rf "${TMPDIR}/"
  trap - INT TERM EXIT
  exit
}


function ScriptInfo() { 
	HEAD_FILTER="^#-"
	[[ "$1" = "usage" ]] && HEAD_FILTER="^#+"
	[[ "$1" = "full" ]] && HEAD_FILTER="^#[%+]"
	[[ "$1" = "version" ]] && HEAD_FILTER="^#-"
	head -${SCRIPT_HEADSIZE:-99} ${0} | grep -e "${HEAD_FILTER}" | \
	sed -e "s/${HEAD_FILTER}//g" \
	    -e "s/\${SCRIPT_NAME}/${SCRIPT_NAME}/g" \
	    -e "s/\${SPEED}/${SPEED}/g" \
	    -e "s/\${DEFAULT_PORTSTRING}/${DEFAULT_PORTSTRING}/g"
}


function Usage() { 
	printf "Usage: "
	ScriptInfo usage
	exit
}


function Die () {
	echo "${*}"
	SafeExit
}


function AptError () {
   echo
   echo
   echo
   echo >&2 "ERROR while running '$1'.  Exiting."
   echo
   echo
   echo
   exit 1
}


function PiModel() {
   MODEL="$(egrep "^Model" /proc/cpuinfo | sed -e 's/ //;s/\t//g' | cut -d: -f2)"
   case $MODEL in
      "Raspberry Pi 2"*)
         echo "rpi2"
         ;;
      "Raspberry Pi 3"*)
         echo "rpi3"
         ;;
      "Raspberry Pi 4"*)
         echo "rpi4"
         ;;
      *)
         echo ""
         ;;
   esac
}


function LocalRepoUpdate() {

	# Checks if a local repository is set up and if not clones it. If there is a local
	# repo, then do a 'git pull' to see if there are updates. If no updates, return $FALSE 
	# otherwise return $TRUE.  
	#
	# arg1: Name of app to install/update
	# arg2: git URL for app
	
	UP_TO_DATE=$FALSE
	REQUEST="$1"
	URL="$2"
	GIT_DIR="$(echo ${URL##*/} | sed -e 's/\.git$//')"
	cd $SRC_DIR
	echo "============= $REQUEST install/update requested ========"
	# See if local git repository exists. Create it ('git clone') if not
	if ! [[ -s $SRC_DIR/$GIT_DIR/.git/HEAD ]]
	then
		git clone $URL || { echo >&2 "======= git clone $URL failed ========"; exit 1; }
	else  # See if local repo is up to date
		cd $GIT_DIR
		if git pull | tee /dev/stderr | grep -q "^Already"
		then
			echo "============= $REQUEST up to date ============="
			UP_TO_DATE=$TRUE
		fi
	fi
	cd $SRC_DIR
	[[ $UP_TO_DATE == $FALSE ]] && return $TRUE || return $FALSE
}


function NexusLocalRepoUpdate() {

	# Checks if a local Nexus repository is set up and if not clones it. If there 
	# is a local repo, then do a 'git pull' to see if there are updates. If no updates,
	# return $FALSE 
	# otherwise return $TRUE.  If there are updates, look for shell script named 
	# 'nexus-install' in repo and run it if present and executable.
	#
	# arg1: Name of app to install/update
	# arg2: git URL for app
	
	if (LocalRepoUpdate "$1" "$2") || [[ $FORCE == $TRUE ]]
	then
		cd $SRC_DIR
   	if [[ -x ${2##*/}/nexus-install ]]
   	then
   		${2##*/}/nexus-install
   	  	echo "======== $1 installed/updated ========"
			cd $SRC_DIR
      	return $TRUE
		fi
		return $TRUE
	else		
		cd $SRC_DIR
		return $FALSE
	fi
}


function InstalledPkgVersion() {

	# Checks if a deb package is installed and returns version if it is
	# arg1: Name of package
	# Returns version of installed package or empty string if package is
	# not installed
	
	INSTALLED_="$(dpkg -l "$1" 2>/dev/null | grep "$1" | tr -s ' ')"
	[[ $INSTALLED_ =~ ^ii ]] && echo "$INSTALLED_" | cut -d ' ' -f3 || echo ""
}


function InstallHamlib () {
	if command -v rigctl >/dev/null 2>&1
	then  # Hamlib installed
		if dpkg -l libhamlib2 >/dev/null 2>&1
		then  # Hamlib installed via apt. Remove it.
			sudo apt -y remove --purge libhamlib2 libhamlib-dev libhamlib-utils*
			sudo apt-mark hold libhamlib2
			echo
			echo
			echo
			echo "WARNING: You will have to re-install applications that were"
			echo "         built using the older Hamlib libraries; for example"
			echo "         Direwolf and Fldigi, after the newer version of Hamlib is "
			echo "         installed"
			echo
			echo
			echo
		fi
	fi
	if LocalRepoUpdate Hamlib $HAMLIB_GIT_URL
	then
		cd $SRC_DIR/Hamlib
		autoreconf -f -i
		./configure && make && sudo make install
		sudo ldconfig
		cd $SRC_DIR
	fi
	#sudo apt -y install libhamlib2 libhamlib-dev libhamlib-utils*
	#return $?
}


function InstallPiardop() {
	declare -A ARDOP
	ARDOP[1]="$PIARDOP_URL"
	ARDOP[2]="$PIARDOP2_URL"
  	cd $HOME
	for V in "${!ARDOP[@]}"
	do
   	echo "=========== Installing piardop version $V ==========="
   	PIARDOP_BIN="${ARDOP[$V]##*/}"
   	echo "=========== Downloading ${ARDOP[$V]} ==========="
   	wget -q -O $PIARDOP_BIN "${ARDOP[$V]}" || { echo >&2 "======= ${ARDOP[$V]} download failed with $? ========"; exit 1; }
   	chmod +x $PIARDOP_BIN
   	sudo mv $PIARDOP_BIN /usr/local/bin/
#	    cat > $HOME/.asoundrc << EOF
#pcm.ARDOP {
#type rate
#slave {
#pcm "plughw:1,0"
#rate 48000
#}
#}
#EOF
   	echo "=========== piardop version $V installed  ==========="
   done
}


function CheckInternet() {
	# Check for Internet connectivity
	if ! ping -q -w 1 -c 1 github.com > /dev/null 2>&1
	then
   	yad --center --title="$TITLE" --info --borders=30 \
      	 --text="<b>No Internet connection found.  Check your Internet connection \
and run this script again.</b>" --buttons-layout=center \
	       --button=Close:0
   exit 1
fi

}


function GenerateList () {
	# Creates a list of apps used for use in yad selection window
	# Takes 1 argument:  0 = Pick boxes for installed apps are not checked, 1 = Pick boxes for installed apps are checked.
	TFILE="$(mktemp)"
	declare -a CHECKED
	CHECKED[0]="FALSE"
	CHECKED[1]="TRUE"
	
	for A in $LIST 
	do 
		case $A in
			nexus-iptables|autohotspot|raspbian)
				echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE" 
				;;
			chirp)
				if command -v chirpw 1>/dev/null 2>&1
				then
					echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE" 
				else
					echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
				fi
				;;
			nexus-utilities)
				if [ -s /usr/local/src/nexus/nexus-utilities.version ]
				then
					echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE" 
				else
					echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
				fi
				;;
			nexus-rmsgw)
				if [[ -s /usr/local/src/nexus/nexus-rmsgw.version ]]
				then
					echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE" 
				else
					echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
				fi
				;;
			nexus-updater)
				echo -e "FALSE\n$A\n${DESC[$A]}\nUpdated Automatically" >> "$TFILE"
				;;
			piardop)
				if command -v piardopc 1>/dev/null 2>&1 && command -v piardop2 1>/dev/null 2>&1
				then
   				echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
				else
					echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
				fi		
				;;
			linbpq)
				if [[ -x $HOME/linbpq/linbpq ]]
				then
   				echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
				else
					echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
				fi		
				;;
			710)
		   	if command -v 710.sh 1>/dev/null 2>&1 
				then
	   			echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
				else
					echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
				fi
				;;
			nexus-backup-restore)
		   	if command -v nexus-backup-restore.sh 1>/dev/null 2>&1 
				then
	   			echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
				else
					echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
				fi
				;;
			*)
		   	if command -v $A 1>/dev/null 2>&1 
				then
	   			echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
				else
					echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
				fi
				;;
		esac
	done
}


function GenerateTable () {
	# Takes 1 argument:  The first word of the middle button ("Select" or "Unselect")

	ANS="$(yad --center --title="$TITLE" --list --borders=10 \
		--height=600 --width=900 --text-align=center \
		--text "<b>This script will install and/or check for and install updates for the apps you select below.\n \
If there are updates available, it will install them.</b>\n\n \
<b><span color='blue'>For information about or help with an app, double-click the app's name.</span></b>\n \
This will open the Pi's web browser.\n \
This Pi must be connected to the Internet for this script to work.\n\n \
<b><span color='red'>CLOSE ALL OTHER APPS</span></b> <u>before</u> you click OK.\n" \
--separator="," --checklist --grid-lines=hor \
--dclick-action="bash -c \"Help %s\"" \
--auto-kill --column Pick --column Applications --column Description \
--column Action < "$TFILE" --buttons-layout=center --button=Cancel:1 --button="$1 All Installed":2 --button=OK:0)"
}


function CheckDepInstalled() {
	# Checks the installation status of a list of packages. Installs them if they are not
	# installed.
	# Takes 1 argument: a string containing the apps to check with apps separated by space
	MISSING=$(dpkg --get-selections $1 2>&1 | grep -v 'install$' | awk '{ print $6 }')
	if [[ ! -z $MISSING ]]
	then
		sudo apt -y install $MISSING || AptError "$MISSING"
	fi
}

function AdjustSwap() {
	CURRENT_SWAP="$(grep "^CONF_SWAPSIZE" $SWAP_FILE)"
	[[ -z $CURRENT_SWAP ]] && return
	NEW_SWAP="CONF_SWAPSIZE=1024"
	if [[ $CURRENT_SWAP == $SWAP ]]
	then  # Use larger swap
		echo >&2 "Setting larger swap size"
		sudo sed -i -e "s/^CONF_SWAPSIZE=.*/$NEW_SWAP/" $SWAP_FILE
	else # Restore swap
		echo >&2 "Restoring original swap size"
		sudo sed -i -e "s/^CONF_SWAPSIZE=.*/$SWAP/" $SWAP_FILE
	fi
	sudo systemctl restart dphys-swapfile
}


function Help () {
	BROWSER="$(command -v chromium-browser)"
	declare -A APPS
	APPS[fldigi]="http://www.w1hkj.com/FldigiHelp"
	APPS[flmsg]="http://www.w1hkj.com/flmsg-help"
	APPS[flamp]="http://www.w1hkj.com/flamp-help"
	APPS[flrig]="http://www.w1hkj.com/flrig-help"
	APPS[flwrap]="http://www.w1hkj.com/flwrap-help"
	APPS[direwolf]="https://github.com/wb2osz/direwolf"
	APPS[pat]="https://getpat.io/"
	APPS[arim]="https://www.whitemesa.net/arim/arim.html"
	APPS[piardop]="https://www.whitemesa.net/arim/arim.html"
	APPS[chirp]="https://chirp.danplanet.com/projects/chirp/wiki/Home"
	APPS[wsjtx]="https://physics.princeton.edu/pulsar/K1JT/wsjtx.html"
	APPS[xastir]="http://xastir.org/index.php/Main_Page"
	APPS[nexus-backup-restore]="https://github.com/AG7GN/nexus-backup-restore/blob/master/README.md"
	APPS[hamapps]="https://github.com/AG7GN/hamapps/blob/master/README.md"
	APPS[nexus-iptables]="https://github.com/AG7GN/nexus-iptables/blob/master/README.md"
	APPS[nexus-utilities]="https://github.com/AG7GN/nexus-utilities/blob/master/README.md"
	APPS[autohotspot]="https://github.com/AG7GN/autohotspot/blob/master/README.md"
	APPS[710]="https://github.com/AG7GN/kenwood/blob/master/README.md"
	APPS[pmon]="https://www.p4dragon.com/en/PMON.html"
	APPS[nexus-rmsgw]="https://github.com/AG7GN/rmsgw/blob/master/README.md"
	APPS[js8call]="http://js8call.com"
	APPS[linbpq]="http://www.cantab.net/users/john.wiseman/Documents/InstallingLINBPQ.html"
	APPS[linpac]="https://sourceforge.net/projects/linpac/"
	APP="$2"
	$BROWSER ${APPS[$APP]} 2>/dev/null &
}
export -f Help


#============================
#  FILES AND VARIABLES
#============================

# Set Temp Directory
# -----------------------------------
# Create temp directory with three random numbers and the process ID
# in the name.  This directory is removed automatically at exit.
# -----------------------------------
TMPDIR="/tmp/${SCRIPT_NAME}.$RANDOM.$RANDOM.$RANDOM.$$"
(umask 077 && mkdir "${TMPDIR}") || {
  Die "Could not create temporary directory! Exiting."
}

  #== general variables ==#
SCRIPT_NAME="$(basename ${0})" # scriptname without path
SCRIPT_DIR="$( cd $(dirname "$0") && pwd )" # script directory
SCRIPT_FULLPATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
SCRIPT_ID="$(ScriptInfo | grep script_id | tr -s ' ' | cut -d' ' -f3)"
SCRIPT_HEADSIZE=$(grep -sn "^# END_OF_HEADER" ${0} | head -1 | cut -f1 -d:)
VERSION="$(ScriptInfo version | grep version | tr -s ' ' | cut -d' ' -f 4)" 

GITHUB_URL="https://github.com"
HAMLIB_LATEST_URL="$GITHUB_URL/Hamlib/Hamlib/releases/latest"
HAMLIB_GIT_URL="$GITHUB_URL/Hamlib/Hamlib"
FLROOT_URL="http://www.w1hkj.com/files/"
FLROOT_GIT_URL="git://git.code.sf.net/p/fldigi"
WSJTX_KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xB5E1FEF627613D4957BA72885794D54C862549F9"
WSJTX_URL="http://www.physics.princeton.edu/pulsar/k1jt/wsjtx.html"
DIREWOLF_GIT_URL="$GITHUB_URL/wb2osz/direwolf"
XASTIR_GIT_URL="$GITHUB_URL/Xastir/Xastir.git"
ARIM_URL="https://www.whitemesa.net/arim/arim.html"
GARIM_URL="https://www.whitemesa.net/garim/garim.html"
PIARDOP_URL="http://www.cantab.net/users/john.wiseman/Downloads/Beta/piardopc"
PIARDOP2_URL="http://www.cantab.net/users/john.wiseman/Downloads/Beta/piardop2"
PAT_GIT_URL="$GITHUB_URL/la5nta/pat/releases"
CHIRP_URL="https://trac.chirp.danplanet.com/chirp_daily/LATEST"
NEXUS_UPDATER_GIT_URL="$GITHUB_URL/AG7GN/nexus-updater"
NEXUSUTILS_GIT_URL="$GITHUB_URL/AG7GN/nexus-utilities"
IPTABLES_GIT_URL="$GITHUB_URL/AG7GN/nexus-iptables"
AUTOHOTSPOT_GIT_URL="$GITHUB_URL/AG7GN/autohotspot"
KENWOOD_GIT_URL="$GITHUB_URL/AG7GN/kenwood"
NEXUS_BU_RS_GIT_URL="$GITHUB_URL/AG7GN/nexus-backup-restore"
PMON_REPO="https://www.scs-ptc.com/repo/packages/"
PMON_GIT_URL="$GITHUB_URL/AG7GN/pmon"
NEXUS_RMSGW_GIT_URL="$GITHUB_URL/AG7GN/rmsgw"
JS8CALL_URL="http://files.js8call.com/latest.html"
FEPI_GIT_URL="$GITHUB_URL/AG7GN/fe-pi"
LINBPQ_URL="http://www.cantab.net/users/john.wiseman/Downloads/Beta/pilinbpq"
LINBPQ_DOC="http://www.cantab.net/users/john.wiseman/Downloads/Beta/HTMLPages.zip"
LINPAC_GIT_URL="https://git.code.sf.net/p/linpac/linpac"
REBOOT="NO"
SRC_DIR="/usr/local/src/nexus"
SHARE_DIR="/usr/local/share/nexus"
TITLE="Nexus Updater - version $VERSION"

declare -r TRUE=0
declare -r FALSE=1
SELF_UPDATE=$FALSE
GUI=$FALSE
FORCE=$FALSE
FLDIGI_DEPS_INSTALLED=$FALSE
SWAP_FILE="/etc/dphys-swapfile"
SWAP="$(grep "^CONF_SWAPSIZE" $SWAP_FILE)"

LIST="raspbian 710 arim autohotspot chirp direwolf flamp fldigi flmsg flrig flwrap hamlib js8call linbpq linpac nexus-backup-restore nexus-iptables nexus-rmsgw nexus-updater nexus-utilities pat piardop pmon wsjtx xastir"
declare -A DESC
DESC[raspbian]="Raspbian OS and Apps"
DESC[710]="Rig Control Scripts for Kenwood 710/71A"
DESC[arim]="Amateur Radio Instant Messaging"
DESC[autohotspot]="Wireless HotSpot on your Pi"
DESC[chirp]="Radio Programming Tool"
DESC[direwolf]="Packet Modem/TNC and APRS Encoder/Decoder"
DESC[flamp]="Amateur Multicast Protocol tool for Fldigi"
DESC[fldigi]="Fast Light DIGItal Modem"
DESC[flmsg]="Forms Manager for Fldigi"
DESC[flrig]="Rig Control for Fldigi"
DESC[flwrap]="File Encapsulation for Fldigi"
DESC[nexus-backup-restore]="Backup/Restore Home Folder"
DESC[nexus-iptables]="Firewall Rules for Nexus Image"
DESC[nexus-rmsgw]="RMS Gateway software for the Nexus Image"
DESC[nexus-updater]="This Updater script"
DESC[nexus-utilities]="Scripts and Apps for Nexus Image"
DESC[js8call]="Weak signal keyboard to keyboard messaging using JS8"
DESC[linpac]="AX.25 keyboard to keyboard chat and PBBS"
DESC[linbpq]="G8BPQ AX25 Networking Package"
DESC[pat]="Winlink Email Client"
DESC[piardop]="Amateur Radio Digital Open Protocol Modem Versions 1&#x26;2"
DESC[pmon]="PACTOR Monitoring Utility"
DESC[wsjtx]="Weak Signal Modes Modem"
DESC[xastir]="APRS Tracking and Mapping Utility"


#============================
#  PARSE OPTIONS WITH GETOPTS
#============================

#== set short options ==#
SCRIPT_OPTS='fslhv-:'

#== set long options associated with short one ==#
typeset -A ARRAY_OPTS
ARRAY_OPTS=(
	[help]=h
	[version]=v
	[dir]=d
	[file]=f
	[log]=l
)

LONG_OPTS="^($(echo "${!ARRAY_OPTS[@]}" | tr ' ' '|'))="

# Parse options
while getopts ${SCRIPT_OPTS} OPTION
do
	# Translate long options to short
	if [[ "x$OPTION" == "x-" ]]
	then
		LONG_OPTION=$OPTARG
		LONG_OPTARG=$(echo $LONG_OPTION | egrep "$LONG_OPTS" | cut -d'=' -f2-)
		LONG_OPTIND=-1
		[[ "x$LONG_OPTARG" = "x" ]] && LONG_OPTIND=$OPTIND || LONG_OPTION=$(echo $OPTARG | cut -d'=' -f1)
		[[ $LONG_OPTIND -ne -1 ]] && eval LONG_OPTARG="\$$LONG_OPTIND"
		OPTION=${ARRAY_OPTS[$LONG_OPTION]}
		[[ "x$OPTION" = "x" ]] &&  OPTION="?" OPTARG="-$LONG_OPTION"
		
		if [[ $( echo "${SCRIPT_OPTS}" | grep -c "${OPTION}:" ) -eq 1 ]]; then
			if [[ "x${LONG_OPTARG}" = "x" ]] || [[ "${LONG_OPTARG}" = -* ]]; then 
				OPTION=":" OPTARG="-$LONG_OPTION"
			else
				OPTARG="$LONG_OPTARG";
				if [[ $LONG_OPTIND -ne -1 ]]; then
					[[ $OPTIND -le $Optnum ]] && OPTIND=$(( $OPTIND+1 ))
					shift $OPTIND
					OPTIND=1
				fi
			fi
		fi
	fi

	# Options followed by another option instead of argument
	if [[ "x${OPTION}" != "x:" ]] && [[ "x${OPTION}" != "x?" ]] && [[ "${OPTARG}" = -* ]]
	then 
		OPTARG="$OPTION" OPTION=":"
	fi

	# Finally, manage options
	case "$OPTION" in
		h) 
			ScriptInfo full
			exit 0
			;;
		v) 
			ScriptInfo version
			exit 0
			;;
		f)
			FORCE=$TRUE
			;;
		s)
			SELF_UPDATE=$TRUE
			;;
		l)
			echo >&2
			echo "This script can install/update these applications:"
			echo >&2
			KEYS=( $( echo ${!DESC[@]} | tr ' ' $'\n' | sort ) )
			for I in "${KEYS[@]}"
			do
				printf "%20s: %s\n" "${I}" "${DESC[$I]}"
			done
			echo >&2
			exit 0
			;;
		:) 
			Die "${SCRIPT_NAME}: -$OPTARG: option requires an argument"
			;;
		?) 
			Die "${SCRIPT_NAME}: -$OPTARG: unknown option"
			;;
	esac
done
shift $((${OPTIND} - 1)) ## shift options

#============================
#  MAIN SCRIPT
#============================

# Trap bad exits with cleanup function
trap SafeExit EXIT INT TERM

# Exit on error. Append '||true' when you run the script if you expect an error.
#set -o errexit

# Check Syntax if set
$SYNTAX && set -n
# Run in debug mode, if set
$DEBUG && set -x 

(( $# == 0 )) && GUI=$TRUE

CheckInternet

# Check for self updates requested
if [[ $SELF_UPDATE == $TRUE ]] && NexusLocalRepoUpdate nexus-updater $NEXUS_UPDATER_GIT_URL
then
	if [[ $GUI == $TRUE ]]
	then
		yad --center --title="$TITLE" --info --borders=30 \
		--no-wrap --text="A new version of the Nexus Updater has been installed.\n\nPlease \
run <b>Raspberry > Hamradio > Nexus Updater</b> again." \
		--buttons-layout=center \
		--button=Close:0
  		exit 0
  	else
  		echo >&2
  		echo >&2 "A new version of this script has been installed. Please run it again."
  		echo >&2
  	fi
fi

#-----------------------------------------------------------------------------------------
# Backwards Compatibility Checks
# Change /boot/hampi.txt to nexus.txt
if [ -s /boot/hampi.txt ]
then
	sudo sed -i "s/HAMPI_RELEASE/NEXUS_VERSION/" /boot/hampi.txt
	sudo mv /boot/hampi.txt /boot/nexus.txt
	sudo rm -f /boot/hampi.txt*
fi
# Nexus versions of the following are now installed via nexus-utilities
sudo rm -f /usr/local/bin/hampi-release.sh
sudo rm -f /usr/local/share/applications/hampi-version.desktop

# Make nexus source and share folders if necessary
for D in $SRC_DIR $SHARE_DIR
do
	if [[ ! -d $D ]]
	then
		sudo mkdir -p $D
		sudo chown $USER:$USER $D
	fi	
	# Make sure ownership is $USER
	if [[ $(stat -c '%U:%G' $D) != "$USER:$USER" ]]
	then
		sudo chown -R $USER:$USER $D
	fi	
done

# Remove old hampi src folder
sudo rm -rf /usr/local/src/hampi
sudo rm -rf /usr/local/share/hampi
#-----------------------------------------------------------------------------------------

if [[ $GUI == $TRUE ]]
then
	RESULT=2
	# Initially generate app list with pick boxes for installed apps not checked
	GenerateList 0
	PICKBUTTON="Select"
	until [ $RESULT -ne 2 ]
	do 
		GenerateTable $PICKBUTTON 
		RESULT="$?"
		if [ $RESULT -eq 2 ]
		then # User clicked "*Select All Installed" button
			case $PICKBUTTON in
				Select)
					# Generate new list with pick box checked for each installed app
					GenerateList 1
					# Change button so user can de-select pick box for all installed apps
					PICKBUTTON="Unselect"
					;;
				Unselect)
					# Generate new list with pick box unchecked for each installed app
					GenerateList 0
					# Change button so user can check all installed apps.
					PICKBUTTON="Select"
					;;
			esac
		fi	
	done
	rm -f "$TFILE"
	if [ $RESULT -eq "1" ] || [[ $ANS == "" ]]
	then 
   	echo "Update Cancelled"
   	exit 0
	else
		APP_LIST="$(echo "$ANS" | grep "^TRUE" | cut -d, -f2 | tr '\n' ',' | sed 's/,$//')"
		if [ ! -z "$APP_LIST" ]
		then
      	echo "Update/install list: $APP_LIST..."
      	$0 $APP_LIST
      fi
     	exit 0
	fi
fi
# If we get here, script was called with apps to install/update, so no GUI

APPS="$(echo "${1,,}" | tr ',' '\n' | sort -u | xargs)"

# Check age of apt cache. Run apt update if more than an hour old
LAST_APT_UPDATE=$(stat -c %Z /var/lib/apt/lists/partial)
NOW=$(date +%s)
[[ -z $LAST_APT_UPDATE ]] && LAST_APT_UPDATE=0
if (( $( expr $NOW - $LAST_APT_UPDATE ) > 3600 ))
then
	echo >&2 "Updating apt cache"
	sudo apt update || AptError "'apt update' failed!"
#else
#	echo >&2 "apt cache less than an hour old"
fi

CheckDepInstalled "extra-xdg-menus bc dnsutils libgtk-3-bin jq moreutils exfat-utils build-essential autoconf automake libtool checkinstall git"

for APP in $APPS
do
	cd $SRC_DIR
   case $APP in

   	raspbian)
			echo -e "\n=========== Raspbian OS Update Requested ==========="
			sudo apt -m -y upgrade && echo -e "=========== Raspbian OS Update Finished ==========="
			# Make sure pulseaudio is not default sound device.  If pulseaudio is updated,
			# it might restore this file and make pulseaudio the default sound interface.
			# So, we make sure every nonempty line is commented out.
			sudo sed -i -e '/^[^#]/ s/^#*/#/' /usr/share/alsa/pulse-alsa.conf
   		;;

   	nexus-updater)
   		NexusLocalRepoUpdate nexus-updater $NEXUS_UPDATER_GIT_URL
   		;;

      fldigi|flamp|flmsg|flrig|flwrap)
         if [[ $FLDIGI_DEPS_INSTALLED == $FALSE ]]
         then
            echo "========= $APP install/update requested  =========="
            sudo sed -i 's/^#deb-src/deb-src/' /etc/apt/sources.list
            sudo sed -i 's/^#deb-src/deb-src/' /etc/apt/sources.list.d/raspi.list
			   #sudo apt update || AptError "sudo apt update"
            CheckDepInstalled "libasound2 libc6 libfltk-images1.3 libfltk1.3 libflxmlrpc1 libgcc1 libpng16-16 libportaudio2 libpulse0 libsamplerate0 libsndfile1 libstdc++6 libx11-6 zlib1g synaptic pavucontrol libusb-1.0-0-dev libusb-1.0-doc"
            InstallHamlib
            FLDIGI_DEPS_INSTALLED=$TRUE
         fi
      	if (LocalRepoUpdate $APP $FLROOT_GIT_URL/$APP) || [[ $FORCE == $TRUE ]]
      	then
      		AdjustSwap
      		cd $APP
      		autoreconf -f -i || { echo >&2 "======= autoreconf -f -i failed ========"; exit 1; }
      		CONFIGURE="./configure"
      		if [[ $APP == "fldigi" ]]
      		then
      			PI_MODEL=$(piModel)
      			[[ ! -z $PI_MODEL ]] && CONFIGURE="./configure --enable-optimizations=$PI_MODEL"
      		fi
      		[[ $FORCE == $TRUE ]] && make clean
      		if $CONFIGURE && make -j4 && sudo make install
      		then
					# Fix the *.desktop files
               FLDIGI_DESKTOPS="/usr/local/share/applications $HOME/.local/share/applications"
               for D in ${FLDIGI_DESKTOPS}
					do
						for F in ${D}/fl*.desktop
                  do
							[ -e "$F" ] || continue
                     sudo sed -i 's/Network;//g' $F
                     if [[ $F == "${FLDIGI_DESKTOPS}/flrig.desktop" ]]
                     then
                     	grep -q "\-\-debug-level 0" ${FLDIGI_DESKTOPS}/flrig.desktop 2>/dev/null || sudo sed -i 's/Exec=flrig/Exec=flrig --debug-level 0/' $F
                     fi
						done
               done  
               [ -f /usr/local/share/applications/${APP}.desktop ] && sudo mv -f /usr/local/share/applications/${APP}.desktop /usr/local/share/applications/${APP}.desktop.disabled
               [ -f /usr/local/share/applications/flarq.desktop ] && sudo mv -f /usr/local/share/applications/flarq.desktop /usr/local/share/applications/flarq.desktop.disabled
               lxpanelctl restart
               cd $SRC_DIR
               echo "========= $APP installation/update done ==========="
            else
               echo >&2 "========= $APP installation/update FAILED ========="
               cd $SRC_DIR
               AdjustSwap
               exit 1
            fi
            AdjustSwap
         fi
			;;

      xastir)
         echo "=========== Installing $APP ==========="
			if apt list --installed 2>/dev/null | grep -q xastir
			then
				echo "Removing existing binary that was installed from apt package"
				if [ -d /usr/share/xastir/maps ]
				then
					mkdir -p $HOME/maps
					cp -r /usr/share/xastir/maps/* $HOME/maps
				fi
				sudo apt -y remove xastir
				sudo apt -y autoremove
				if [ -d $HOME/maps ]
				then
					sudo cp -r $HOME/maps/* /usr/local/share/xastir/maps
					rm -rf $HOME/maps
				fi
				echo "Done."
			fi
			if (LocalRepoUpdate Xastir $XASTIR_GIT_URL) || [[ $FORCE == $TRUE ]]
			then
				echo "Building $APP from source"			
				CheckDepInstalled "xorg-dev graphicsmagick gv libmotif-dev libcurl4-openssl-dev gpsman gpsmanshp libpcre3-dev libproj-dev libdb5.3-dev python-dev libwebp-dev shapelib libshp-dev festival festival-dev libgeotiff-dev libgraphicsmagick1-dev xfonts-100dpi xfonts-75dpi"
				xset +fp /usr/share/fonts/X11/100dpi,/usr/share/fonts/X11/75dpi
            cd $SRC_DIR/Xastir
	         ./bootstrap.sh
   	      mkdir -p build
      	   cd build
         	../configure CPPFLAGS="-I/usr/include/geotiff"
         	if make -j4 && sudo make install
         	then
            	sudo chmod u+s /usr/local/bin/xastir
            	cat > $HOME/.local/share/applications/xastir.desktop << EOF
[Desktop Entry]
Name=Xastir
Encoding=UTF-8
GenericName=Xastir
Comment=APRS
Exec=xastir
Icon=/usr/local/share/xastir/symbols/icon.png
Terminal=false
Type=Application
Categories=HamRadio;
EOF
            	sudo mv -f $HOME/.local/share/applications/xastir.desktop /usr/local/share/applications/
					sed -i 's|\/usr\/share|\/usr\/local\/share|' $HOME/.xastir/config/xastir.cnf 2>/dev/null
            	lxpanelctl restart
            	echo "========= $APP install/update complete ==========="
         	else
            	echo "========= $APP installation FAILED ==========="
	            cd $SRC_DIR
	            exit 1
         	fi
         fi
			;;

		hamlib)
				if (LocalRepoUpdate Hamlib $HAMLIB_GIT_URL) || [[ $FORCE == $TRUE ]]
				then
					cd $SRC_DIR/Hamlib
					autoreconf -f -i
					./configure && make && sudo make install
					sudo ldconfig
					cd $SRC_DIR
				fi
			;;

		direwolf)
			if (LocalRepoUpdate $APP $DIREWOLF_GIT_URL) || [[ $FORCE == $TRUE ]]
			then
			   CheckDepInstalled "git gcc g++ make cmake libasound2-dev libudev-dev gpsd libgps-dev"
				InstallHamlib
				cd direwolf
				mkdir -p build && cd build
				make clean
				rm -f CMakeCache.txt
            if cmake .. && make -j4 && sudo make install
            then
               make install-conf
               [ -f /usr/local/share/applications/direwolf.desktop ] && sudo mv -f /usr/local/share/applications/direwolf.desktop /usr/local/share/applications/direwolf.desktop.disabled
               echo "========= $APP installation complete ==========="
            else
               echo >&2 "========= $APP installation FAILED ==========="
               exit 1
            fi
			fi
			;;

      piardop)
			InstallPiardop
			;;

      arim)
         echo "======== arim installation requested ==========="
         mkdir -p arim
         cd arim
         for URL in $ARIM_URL $GARIM_URL 
         do
            APP_NAME="$(echo ${URL##*/} | cut -d'.' -f1)"
            ARIM_FILE="${URL##*/}"
            wget -q -O $ARIM_FILE $URL || { echo >&2 "======= $URL download failed with $? ========"; exit 1; }
            TAR_FILE_URL="$(egrep 'https:.*arim.*[[:digit:]]+.tar.gz' $ARIM_FILE | grep -i 'current' | cut -d'"' -f2)"
            [[ $TAR_FILE_URL == "" ]] && { echo >&2 "======= Download failed.  Could not find tar file URL ========"; exit 1; }
            rm -f $ARIM_FILE
            TAR_FILE="${TAR_FILE_URL##*/}"
            FNAME="$(echo $TAR_FILE | sed 's/.tar.gz//')"
            LATEST_VERSION="$(echo $FNAME | cut -d'-' -f2)"
            INSTALLED_VERSION="$($APP_NAME -v 2>/dev/null | grep -i "^$APP_NAME" | cut -d' ' -f2)"
            if [[ $LATEST_VERSION != $INSTALLED_VERSION ]]
            then
     	         command -v piardopc >/dev/null || InstallPiardop
               echo "======== Downloading $TAR_FILE_URL ==========="
               wget -q -O $TAR_FILE $TAR_FILE_URL || { echo >&2 "======= $TAR_FILE_URL download failed with $? ========"; exit 1; }
               if [[ $APP_NAME == "arim" ]]
					then
						CheckDepInstalled "libncurses5-dev libncursesw5-dev"
					else
						CheckDepInstalled "libfltk1.3-dev"
					fi
               tar xzf $TAR_FILE
               ARIM_DIR="$(echo $TAR_FILE | sed 's/.tar.gz//')"
               cd $ARIM_DIR
               if ./configure && make -j4 && sudo make install
               then
						lxpanelctl restart
                  cd ..
                  rm -rf $ARIM_DIR
                  rm -f $TAR_FILE
                  echo "=========== $APP_NAME installed ==========="
               else
                  echo >&2 "===========  $APP_NAME installation FAILED ========="
                  cd $SRC_DIR
                  exit 1
               fi
            else
               echo "============= $APP_NAME is at latest version $LATEST_VERSION ================"
            fi
         done
         cd $SRC_DIR
			;;

      pat)
         echo "============= $APP installation requested ============="
         PAT_REL_URL="$(wget -qO - $PAT_GIT_URL | grep -m1 _linux_armhf.deb | grep -Eoi '<a [^>]+>' | grep -Eo 'href="[^\"]+"' | cut -d'"' -f2)"
  	      [[ $PAT_REL_URL == "" ]] && { echo >&2 "======= $PAT_GIT_URL download failed with $? ========"; exit 1; }
        	PAT_URL="${PAT_REL_URL}"
        	PAT_FILE="${PAT_URL##*/}"
        	INSTALLED_VERSION="$(InstalledPkgVersion pat)"
        	LATEST_VERSION="$(echo $PAT_FILE | cut -d '_' -f2)"
        	echo >&2 "Latest version: $LATEST_VERSION   Installed version: $INSTALLED_VERSION"
        	if [[ $INSTALLED_VERSION == $LATEST_VERSION && $FORCE == $FALSE ]]
        	then
        		echo >&2 "============= $APP installed and up to date ============="
				continue
			fi
			exit 0
			# Install or update needed. Get and install the package
			mkdir -p $APP
			rm -f $APP/*
			wget -q -O $APP/$PAT_FILE $PAT_URL || { echo >&2 "======= $PAT_URL download failed with $? ========"; exit 1; }
         [ -s "$APP/$PAT_FILE" ] || { echo >&2 "======= $PAT_FILE is empty ========"; exit 1; }
         sudo dpkg -i $APP/$PAT_FILE || { echo >&2 "======= pat installation failed with $? ========"; exit 1; }
         echo "============= $APP installed/updated ============="
			;;

      nexus-utilities)
      	NexusLocalRepoUpdate nexus-utilities $NEXUSUTILS_GIT_URL
      	;;

      fe-pi)
      	NexusLocalRepoUpdate fe-pi $FEPI_GIT_URL
      	;;

      autohotspot)
      	NexusLocalRepoUpdate autohotspot $AUTOHOTSPOT_GIT_URL
      	;;

      nexus-backup-restore)
      	NexusLocalRepoUpdate nexus-backup-restore $NEXUS_BU_RS_GIT_URL
      	;;

      710)
      	NexusLocalRepoUpdate "710 scripts" $KENWOOD_GIT_URL
      	;;

      nexus-iptables)
      	NexusLocalRepoUpdate nexus-iptables $IPTABLES_GIT_URL
      	;;

      chirp)
         echo "============= $APP installation requested ============"
   		if command -v chirpw >/dev/null
   		then
      		INSTALLED_VERSION="$($(command -v chirpw) --version | cut -d' ' -f 2)"
   		fi      
         CHIRP_TAR_FILE="$(wget -qO - $CHIRP_URL | grep "\.tar.gz" | grep -Eoi '<a [^>]+>' | grep -Eo 'href="[^\"]+"' | cut -d'"' -f2)"
         [[ $CHIRP_TAR_FILE == "" ]] && { echo >&2 "======= $CHIRP_URL download failed with $? ========"; exit 1; }
			LATEST_VERSION="$(echo $CHIRP_TAR_FILE | sed 's/^chirp-//;s/.tar.gz//')"
        	echo >&2 "Latest version: $LATEST_VERSION   Installed version: $INSTALLED_VERSION"
         if [[ $INSTALLED_VERSION == $LATEST_VERSION && $FORCE == $FALSE ]]
         then
         	echo >&2 "============= $APP installed and up to date ============="
				continue
			fi
        	CHIRP_URL="${CHIRP_URL}/${CHIRP_TAR_FILE}"
        	echo "============= Downloading $CHIRP_URL ============="
        	wget -q -O $CHIRP_TAR_FILE $CHIRP_URL || { echo >&2 "======= $CHIRP_URL download failed with $? ========"; exit 1; }
        	[ -s "$CHIRP_TAR_FILE" ] || { echo >&2 "======= $CHIRP_TAR_FILE is empty ========"; exit 1; }
        	CheckDepInstalled "python-gtk2 python-serial python-libxml2 python-future"
        	tar xzf $CHIRP_TAR_FILE
        	CHIRP_DIR="$(echo $CHIRP_TAR_FILE | sed 's/.tar.gz//')"
        	cd $CHIRP_DIR
        	sudo python setup.py install
			lxpanelctl restart
			cd ..
			rm -f $CHIRP_TAR_FILE
			sudo rm -rf $CHIRP_DIR
        	echo "============= $APP installed/updated ================"
			;;

      pmon)
         echo "============= pmon installation requested ============"
        	if grep -q scs-pts /etc/apt/sources.list.d/scs.list 2>/dev/null
        	then
            sudo apt install pmon || AptError "sudo apt install pmon"
        	else
           	echo "deb $PMON_REPO buster non-free" | sudo tee /etc/apt/sources.list.d/scs.list > /dev/null
           	wget -q -O - ${PMON_REPO}scs.gpg.key | sudo apt-key add -
           	#sudo apt update
           	sudo apt install pmon || AptError "sudo apt install pmon"
        	fi
        	if [[ $FORCE == $TRUE ]]
			then
				sudo apt install --reinstall pmon || AptError "sudo apt install pmon"
			fi
			NexusLocalRepoUpdate pmon $PMON_GIT_URL
     		;;
     	nexus-rmsgw)
     		echo "Handling $APP"
     		# LocalRepoUpdate nexus-rmsgw $NEXUS_RMSGW_GIT_URL
     		;;
      wsjtx|js8call)
      	[[ $APP == "wsjtx" ]] && URL="$WSJTX_URL" || URL="$JS8CALL_URL"
         echo "======== $APP install/upgrade was requested ========="
			PKG="$(wget -O - -q "$URL" | grep -m1 armhf.deb | cut -d'"' -f2)"
        	[[ $PKG =~ "armhf.deb" ]] || { echo >&2 "======= Failed to retrieve wsjtx from $WSJTX_URL ========"; exit 1; }
        	INSTALLED_VERSION="$(InstalledPkgVersion $APP)"
        	LATEST_VERSION="$(echo ${PKG##*/} | cut -d '_' -f2)"
        	echo >&2 "Latest version: $LATEST_VERSION   Installed version: $INSTALLED_VERSION"
        	if [[ $INSTALLED_VERSION == $LATEST_VERSION && $FORCE == $FALSE ]]
        	then
        		echo >&2 "============= $APP installed and up to date ============="
				continue
			fi
			[[ $PKG =~ ^http ]] && URL="$PKG"|| URL="$(dirname $URL)/$PKG"
         echo >&2 "=========== Retrieving $APP from $URL ==========="
         mkdir -p $APP
         cd $APP
			wget -q $URL || { echo >&2 "======= $URL download failed with $? ========"; exit 1; }
         echo >&2 "=========== Installing $APP ==========="
         CheckDepInstalled "libgfortran3 libqt5multimedia5-plugins libqt5serialport5 libqt5sql5-sqlite libfftw3-single3"    
			[[ ! -z $INSTALLED_VERSION ]] && (sudo apt remove -y $APP || AptError "sudo apt remove -y $APP")
         sudo dpkg -i ${PKG##*/} || { echo >&2 "======= ${PKG##*/} install failed with $? ========"; exit 1; }
         sudo sed -i 's/AudioVideo;Audio;//' /usr/share/applications/$APP.desktop /usr/share/applications/message_aggregator.desktop 2>/dev/null
         lxpanelctl restart
         rm -f ${PKG##*/}
         echo >&2 "========= $APP installed/updated ==========="
			;;

     	linbpq)
     		mkdir -p linbpq
     		cd linbpq
         echo >&2 "============= LinBPQ install/update requested ============"
         wget -q -O pilinbpq $LINBPQ_URL || { echo >&2 "======= $LINBPQ_URL download failed with $? ========"; exit 1; }
			chmod +x pilinbpq
			# LinBPQ documentation recommends installing app and config in $HOME
     	   if [[ -x $HOME/linbpq/linbpq ]]
     	   then # a version of linbpq is already installed
     	   	INSTALLED_VERSION="$($HOME/linbpq/linbpq -v | grep -i version)"
     	   	LATEST_VERSION="$(./pilinbpq -v | grep -i version)"
				if [[ $INSTALLED_VERSION == $LATEST_VERSION && $FORCE == $FALSE ]]
				then # No need to update.  No further action needed for $APP
					echo "============= $APP is installed and up to date ============="
					rm -f pilinbpq
					continue
				else # New version
					echo "============= Installing newer version of $APP ============="
				fi
			else # No linbpq installed
				echo "============= Installing LinBPQ ============"
			fi		
			mkdir -p $HOME/linbpq/HTML
			mv -f pilinbpq $HOME/linbpq/linbpq
			DOC="${LINBPQ_DOC##*/}"
			wget -q -O $DOC $LINBPQ_DOC || { echo >&2 "======= $LINBPQ_DOC download failed with $? ========"; exit 1; }
			unzip -o -d $HOME/linbpq/HTML $DOC || { echo >&2 "======= Failed to unzip $DOC ========"; exit 1; }
			rm -f $DOC
			sudo setcap "CAP_NET_ADMIN=ep CAP_NET_RAW=ep CAP_NET_BIND_SERVICE=ep" $HOME/linbpq/linbpq
     		echo >&2 "============= LinBPQ installed/updated ================="
			cd $SRC_DIR
			;;

		linpac)
				if (LocalRepoUpdate linpac $LINPAC_GIT_URL) || [[ $FORCE == $TRUE ]]
				then
					CheckDepInstalled "libax25 ax25-apps ax25-tools libncurses6"
					cd $SRC_DIR/linpac
					git checkout develop
					autoreconf --install
					if (./configure && make)
					then 
	            	sudo /bin/mkdir -p "/usr/share/linpac/contrib"
               	sudo /bin/mkdir -p "/usr/share/doc/linpac/czech"
               	sudo /bin/mkdir -p "/usr/share/linpac/macro/cz"
               	sudo /bin/mkdir -p "/usr/libexec/linpac"
						sudo make install
						sudo ldconfig
	     				echo >&2 "============= linpac installed/updated ================="
					else
     					echo >&2 "============= linpac install failed ================="	
					fi
				fi
			;;
			
      *)
         echo "Skipping unknown app \"$APP\"."
         ;;
   esac
done

				

	 



