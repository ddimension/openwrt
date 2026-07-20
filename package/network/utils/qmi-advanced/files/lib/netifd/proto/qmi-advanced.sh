#!/bin/sh

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_qmi_init_config() {
	proto_config_add_string "ctldevice"
	proto_config_add_string "device:device"
	proto_config_add_string apn
	proto_config_add_string auth
	proto_config_add_string username
	proto_config_add_string password
	proto_config_add_string pincode
	proto_config_add_string delay
	proto_config_add_string modes
	proto_config_add_string ipv4
	proto_config_add_string ipv6
	proto_config_add_boolean dhcp
	proto_config_add_string mcc
	proto_config_add_string mnc
	proto_config_add_string customroutes
	proto_config_add_string defaultroute
	proto_config_add_string peerdns
	proto_config_add_string metric
	proto_config_add_string ip4table
	proto_config_add_string ip6table
	proto_config_add_string failreboot 
	proto_config_add_string strongestnetwork
	proto_config_add_string autocreateif
	proto_config_add_string zero_rx_timeout
	proto_config_add_string mtu
	proto_config_add_string use_pushed_mtu
	proto_config_add_string location
	proto_config_add_array "at_init:list(string)"

}

proto_qmi_log() {
	local level="$1"
	shift
	[ -z "$1" ] && {
		logger -p "$level" -t "qmi[$$]"
		return 0
	}
	logger -p "$level" -t "qmi[$$]" -- "$@"
	return 0
}

proto_qmi_run_uqmi() {
	local timeout="$1"

	local start status dev_short device lockfile duration statedir
	duration=0

	dev_short=$(echo "$@" | awk '{for(i=1;i<=NF;i++) if ($i=="-d") print $(i+1)}' )
	dev_short=${dev_short##*/}
	device=$(echo /sys/class/usbmisc/${dev_short}/device/net/*)
	device=${device##*/}
	statedir="/tmp/qmi/${device}"
	lockfile="$statedir/${dev_short}.lock"

	shift
	start=$(date +%s)
	flock $lockfile timeout -s KILL "$timeout" uqmi "$@"
	status=$?
	let duration=$(date +%s)-$start
	if [ $duration -ge $timeout ]; then
		[ "$status" -gt 0 ] &&  proto_qmi_log daemon.err "Timeout occured running command uqmi $@"
		proto_qmi_interface_errorhandler "$device" 128
	else
		[ "$status" -gt 0 ] &&  proto_qmi_log daemon.err "Error $status occured running command uqmi command: $@"
		proto_qmi_interface_errorhandler "$device" $status
	fi
	return $?
}

proto_qmi_run_qmicli() {
	local timeout="$1"

	local start status dev_short device lockfile duration statedir
	duration=0

	dev_short=$(echo "$@" | awk '{for(i=1;i<=NF;i++) if ($i=="-d") print $(i+1)}' )
	dev_short=${dev_short##*/}
	device=$(echo /sys/class/usbmisc/${dev_short}/device/net/*)
	device=${device##*/}

	statedir="/tmp/qmi/${device}"
	lockfile="$statedir/${dev_short}.lock"
	##logger -t xxxx -- "$@"

	shift
	start=$(date +%s)
	flock $lockfile timeout -s KILL "$timeout" qmicli "$@"
	status=$?
	let duration=$(date +%s)-$start
	if [ $duration -ge $timeout ]; then
		[ "$status" -gt 0 ] &&  proto_qmi_log daemon.err "Timeout occured running command qmicli $@"
		proto_qmi_interface_errorhandler "$device" 128 "$IGNORE_ERROR"
	else
		[ "$status" -gt 0 ] && 	proto_qmi_log daemon.err "Error $status occured running command qmicli command: $@"
		proto_qmi_interface_errorhandler "$device" "$status" "$IGNORE_ERROR"
	fi
	return $?
}

proto_qmi_interface_errorhandler() {
	local device=$1
	local status=$2
	local ignore=$3
	local statedir="/tmp/qmi/${device}"
	local error_limit_reboot=25

	# check if initialized
	[ -d "$statedir" ] || {
		proto_qmi_log daemon.err "State directory $statedir is missing."
		return 254
	}

	# errorcounter
	local errorcounter
	local qmi_errors
	local qmi_errors_file="$statedir/qmi_errors"
	let errorcounter=0
	read qmi_errors <$qmi_errors_file 2>/dev/null || qmi_errors=0 
	let errorcounter+=$qmi_errors
	if [ -z "$ignore" ]; then
		if [ $status -gt 0 ]; then
			let errorcounter+=1
		else
			let errorcounter=0
		fi
	fi
	echo "$errorcounter" > $qmi_errors_file
	if [ -z "$ignore" ] && [ "$errorcounter" -gt 0 ] && [ "$status" -gt 0 ]; then
		proto_qmi_log daemon.err "ErrorCounter of $device raised to $errorcounter"
	fi
	if [ "$errorcounter" -gt "$error_limit_reboot" ]; then
		proto_qmi_log daemon.err "Error limit $error_limit_reboot reached with error counter $errocounter, rebooting."
		reboot
	fi
	return $status
}

proto_qmi_loc_start() {
	local ctldevice=$1
	local cid_loc
	result=`IGNORE_ERROR=1 proto_qmi_run_qmicli 120 -d "$ctldevice" --get-service-version-info`
	if ! echo "$result" | grep 'loc ' >/dev/null; then
		echo "Location service not available." >&2
	fi
	echo "Starting Location service" >&2 
	result=`IGNORE_ERROR=1 proto_qmi_run_qmicli 120 -d "$ctldevice" --loc-start  --client-no-release-cid`
	local rc=$?
	cid_loc=$(echo $result | proto_qmi_qmicli_result_getprop CID)
	if [ "$rc" -gt 0 ] && [ -n "$cid_loc" ]; then
		echo "Giving back location client ID $cid_loc." >&2
		IGNORE_ERROR=1 proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid $cid_loc --loc-noop >/dev/null 2>&1
		return 1
	fi
	if [ -n "$cid_loc" ]; then
			echo $cid_loc
	fi
	echo "$result" >&2
	return 0
}

proto_qmi_update_pdptype() {
	local ctldevice="$1"
	local profile="$2"
	local ipv4="$3"
	local ipv6="$4"

	local device=$(echo /sys/class/usbmisc/${ctldevice##*/}/device/net/*)
	device=${device##*/}
	local statedir="/tmp/qmi/${device}"
	local wds_cid=$(cat $statedir/wds_cid)

	# Update profile
	local pdptype=ipv4
	[ -n "$ipv4" -a -z "$ipv6" ] && pdptype=ipv4
	[ -z "$ipv4" -a -n "$ipv6" ] && pdptype=ipv6
	[ -n "$ipv4" -a -n "$ipv6" ] && pdptype=ipv4v6
	
	local current_pdp_raw=$(proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid "$wds_cid" --client-no-release-cid --wds-get-default-settings=3gpp | proto_qmi_qmicli_result_getprop 'PDP type')
	[ $? -gt 0 -o -z "current_pdp_raw" ] && {
		echo "Failed to get default default pdp type." >&2
		return 1
	}
	#echo "Current pdp default type: $current_pdp_raw V4:$ipv4 V6:$ipv6 pdptype:$pdptype" >&2

	local current_pdp
	if [ "$current_pdp_raw" == 'ipv4-or-ipv6' ]; then
		current_pdp=ipv4v6
	elif [ "$current_pdp_raw" == 'ipv6' ]; then
		current_pdp=ipv6
	else
		current_pdp=ipv4
	fi

	[ "$current_pdp" == "$pdptype" ] && {
		echo "Profile PDP Type $current_pdp_raw and configured PDP Type $pdptype are equal, no change" >&2
		return 0
	}
	echo "Profile PDP Type $current_pdp_raw and configured PDP Type $pdptype are different, change modem profile to $pdptype" >&2
	proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid "$wds_cid" --client-no-release-cid --wds-modify-profile=3gpp,${profile},pdp-type=${pdptype} >/dev/null
}

proto_qmi_qmicli_result_getprop() {
	local prop="$1"
	local no_quote="$2"
	local value line
	if [ -z "$no_quote" ]; then
		while IFS=$'\n' read -r line; do
			value=$(expr quote "$line" : ".*${prop}: '\(.*\)'")
			[ -n "$value" ] && {
				echo "$value"
				return 0
			}
		done
		return 1
	fi
	while IFS=$'\n' read -r line; do
		value=$(expr quote "$line" : ".*${prop}: \(.*\)")
		[ -n "$value" ] && {
			echo "$value"
			return 0
		}
	done
	return 1
}

proto_qmi_convert_from_uimbyte() {
	local input ifs_saved
	ifs_saved="$IFS"
	read -r input
	IFS=: 
	for i in ${input}; do 
		echo -n ${i:1:1}${i:0:1}
	done
	IFS="$ifs_saved"
	return 0
}

proto_qmi_find_virtual_interfaces() {
	local interface="$1"
	local proto_target="$2"
	local keys

	json_init
	json_load "$(ubus -v call uci get '{ "config": "network", "match": { "device": "@'${interface}'" } } }')"
	json_select values
	json_get_keys keys
	for key in $keys; do
		local name proto
		[ -z "$key" ] && continue
		json_select "$key"
		json_get_vars name proto
		json_select ..
		[ "$proto" == "$proto_target" ] && {
			echo "$name"
			return 0
		}
	done
	return 1
}

proto_qmi_find_primary_serial_interface() {
	local cdcdevice=$1
	local dev

	if grep ^zyxel,lte3301 /tmp/sysinfo/board_name > /dev/null; then
		echo /dev/ttyUSB2
		return 0
	elif grep ^zyxel,nr7101 /tmp/sysinfo/board_name > /dev/null; then
		echo /dev/ttyUSB2
		return 0
	fi

	# try to find ttydev
	dev=$(find /sys/devices/ -name $cdcdevice|head -n1)
	[ -z "$dev" ] && return 1

	dev=${dev%.*/*/*}
	[ -z "$dev" ] && return 1

	dev=$(find $dev.* -name ttyUSB\* 2>/dev/null | sort | head -n1 )
	[ -z "$dev" ] && return 1

	dev=/dev/${dev##*/}
	[ -c "$dev" ] && {
		echo $dev
		return 0
	}

	return 1
}

proto_qmi_usb_reset() {
	if usb-repower fork; then
		echo Resetting USB..
		killall qmi-proxy >/dev/null 2>&1
		return 0
	fi
	return 0
}

proto_qmi_reset_modes_fallback() {
	local ttydev="$1"
	local model="$2"
	local modes="$3"
	local cmd

	case "$model" in
		"E392"|"E398")
			cmd="AT^SYSCFGEX=\"00\",3fffffff,1,4,7fffffffffffffff,,"
			;;
		"XOLDD")
			# this is for 2g/3g modems only
			cmd="AT^SYSCFG=2,0,3fffffff,1,4"
			;;
		*)
			cmd="AT^SYSCFGEX=\"00\",3fffffff,1,4,7fffffffffffffff,,"
			;;
	esac

	[ -n "$cmd" ] && {
			echo -n "Falling back to full automatic network selecction with cs domain: "
			COMMAND="$cmd" gcom -d $ttydev -e -s /etc/gcom/runcommand.gcom
			return $?
	}
	return 1
}

proto_qmi_serial_init() {
	local ttydev="$1"
	local model="$2"
	local modes="$3"
	local cmd

	case "$model" in
		"EG06"|\
		"RG502Q-EA")
			proto_qmi_hotplug_log "Enable autoconfig for $model".
			cmd='AT+QMBNCFG="AutoSel",1'
			COMMAND="$cmd" gcom -d $ttydev -e -s /etc/gcom/runcommand.gcom

			#proto_qmi_hotplug_log "Disable VoLTE for $model".
			#cmd='AT+QCFG="volte_disable",1'
			#COMMAND="$cmd" gcom -d $ttydev -e -s /etc/gcom/runcommand.gcom
			break
			;;
		*)
			proto_qmi_hotplug_log "No serial init config for model $model."
			;;
	esac
}

proto_qmi_serial_run_atc() {
	local cmd="$1"
	local index="$2"
	local ttydev="$3"
	if [ -z "$ttydev" ] || [ -z "$cmd" ]; then
		return 1
	fi
	COMMAND="$cmd" gcom -d $ttydev -e -s /etc/gcom/runcommand.gcom
}

proto_qmi_watchdog() {
	local interface="$1"

	local statedir device ctldevice cid_4 pdh_4 cid_6 pdh_6 dhcp zero_rx_timeout
	json_load "$(ubus call network.interface.$interface status)" || {
		echo "Failed to load status"
		return 1
	}
	json_get_vars device
	json_select data
	json_get_vars ctldevice cid_4 pdh_4 cid_6 pdh_6

	[ -z "$ctldevice" -o -z "$device" ] && {
		ubus call network.interface.$interface status
		echo "Device key or device missing in interface data array."
		exit 1
	}
	statedir="/tmp/qmi/${device}"

	# Lookup interface config
	dhcp=$(uci get "network.${interface}.dhcp" 2>/dev/null)
	zero_rx_timeout=$(uci get "network.${interface}.zero_rx_timeout" 2>/dev/null)
	[ -z "$zero_rx_timeout" ] && zero_rx_timeout=$((6*3600))

	# Initial command gives sometimes error
	[ -n "$cid_4" -a -n "$pdh_4" ] && {
		proto_qmi_run_uqmi 30 -d $ctldevice --set-client-id wds,$cid_4 --get-data-status > /dev/null 2>&1
	}
	[ -n "$cid_6" -a -n "$pdh_6" ] && {
		proto_qmi_run_uqmi 30 -d $ctldevice --set-client-id wds,$cid_6 --get-data-status > /dev/null 2>&1
	}

	echo "uqmi-watchdog for interface $interface is running."

	local start_ts=$(date +%s)
	local found age
	local packets_tx_ts=0
	local packets_rx_ts=0
	local packets_last_tx=0
	local packets_last_rx=0

	while sleep 60; do
		local packet_stats=
		local packets_tx=0
		local packets_rx=0
		local now=$(date +%s)
		local skip_packet_counter=
		let age=$now
		let age-=$start_ts

		[ -n "$cid_4" -a -n "$pdh_4" ] && {
			if ! proto_qmi_run_uqmi 45 -d $ctldevice --set-client-id wds,$cid_4 --get-data-status | grep '"connected"' >/dev/null 2>&1; then
				echo "Lost IPv4 connection"
				proto_qmi_teardown $interface
				exit 1
			fi

			if [ "$dhcp" == "1" ]; then
				if [ $age -gt 60 ]; then
					if check_child "$interface" "dhcp" && [ -n "$(ip -o -4 address show dev $interface)" ]; then
						found=1
					fi
				fi
			else
				uci_revert_state network $interface connecttries
			fi
			if [ -n "$zero_rx_timeout" ]; then
				if packet_stats=$(proto_qmi_run_qmicli 10 -d $ctldevice --client-cid=$cid_4 --client-no-release-cid --wds-get-packet-statistics); then
					c=$(echo "$packet_stats" | proto_qmi_qmicli_result_getprop 'TX packets OK' 1)
					if [ -n "$c" ]; then
						let packets_tx+=c
					else
						skip_packet_check=1
					fi
					c=$(echo "$packet_stats" | proto_qmi_qmicli_result_getprop 'RX packets OK' 1)
					if [ -n "$c" ]; then
						let packets_rx+=c
					else
						skip_packet_check=1
					fi
				else 
					skip_packet_check=1
				fi
			fi
		}

		[ -n "$cid_6" -a -n "$pdh_6" ] && {
			if ! proto_qmi_run_uqmi 45 -d $ctldevice --set-client-id wds,$cid_6 --get-data-status | grep '"connected"' >/dev/null 2>&1; then
				echo "Lost IPv6 connection"
				proto_qmi_teardown $interface
				exit 1
			fi

			if [ "$dhcp" == "1" ]; then
				if [ $age -gt 60 ]; then
					if check_child "$interface" "dhcpv6" && [ -n "$(ip -o -6 address show dev $interface scope global)" ]; then
						found=1
					fi
				fi
			else
				uci_revert_state network $interface connecttries
			fi
			if [ -n "$zero_rx_timeout" ]; then
				if ! packet_stats=$(proto_qmi_run_qmicli 10 -d $ctldevice --client-cid=$cid_6 --client-no-release-cid --wds-get-packet-statistics); then
					c=$(echo "$packet_stats" | proto_qmi_qmicli_result_getprop 'TX packets OK' 1)
					if [ -n "$c" ]; then
						let packets_tx+=c
					else
						skip_packet_check=1
					fi
					c=$(echo "$packet_stats" | proto_qmi_qmicli_result_getprop 'RX packets OK' 1)
					if [ -n "$c" ]; then
						let packets_rx+=c
					else
						skip_packet_check=1
					fi
				fi
			fi
		}

		if [ "$dhcp" == "1" -a $age -gt 60 ]; then
			if [ -n "$found" ]; then
				uci_revert_state network $interface connecttries
			else
				echo "Timeout, no DHCP IPv4 or DHCP/RADVD IPv6 found for $interface, throwing error"
				proto_qmi_teardown $interface
				exit 1
			fi
		fi

		local cid_loc=$(uci_get_state network $interface cid_loc)
		if [ -n "$cid_loc" ]; then
			proto_qmi_run_qmicli 45 -d $ctldevice --client-cid=$cid_loc --loc-get-position-report --client-no-release-cid  >$statedir/locationreport 2>&1
		fi

		if [ -n "$zero_rx_timeout" -a -z "$skip_packet_check" ]; then
			[ "$packets_tx" -gt "$packets_tx_ts" ] && packets_last_tx=$now
			[ "$packets_rx" -gt "$packets_rx_ts" ] && packets_last_rx=$now
			packets_tx_ts=$packets_tx
			packets_rx_ts=$packets_rx

			[ "$packets_last_rx" -gt 0 -a $((now-packets_last_rx)) -gt $zero_rx_timeout ] && {
				set
				echo "Packet stats: packets_last_tx=$packets_last_tx packets_last_rx=$packets_last_rx packets_tx=$packets_tx packets_rx=$packets_rx"
				echo "Last received packet timestamp is $packets_last_rx . Restart connection. - USB repower"
				usb-repower </dev/null >/dev/null 2>&1 &
				return 1
			}
		fi

		# Cleanup serial
		empty_serial_buffers $ctldevice
	done
	proto_qmi_teardown $interface
}

proto_qmi_get_networks_by_strength() {
	local ctldevice="$1"
	local mccmncs weighted_mccmnc scan ret
	local device=$(echo /sys/class/usbmisc/${ctldevice##*/}/device/net/*)
	device=${device##*/}
	local statedir="/tmp/qmi/${device}"
	local nas_cid=$(cat $statedir/nas_cid)
	local dms_cid=$(cat $statedir/dms_cid)


	# Prepare
	while ! ret="$(proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id nas,"$nas_cid" --set-plmn --mcc 0)"; do
		echo Error setting automode: $ret, retry. 1>&2
		let ctr++
		#[ $ctr -gt 10 ] && break
		sleep 1
	done
	sleep 2

	json_init
	local ctr=0
	set -o pipefail
	while ! scan="$(proto_qmi_run_uqmi 180 -s -d "$ctldevice" --set-client-id nas,"$nas_cid" --network-scan)"; do
		echo Error: $scan, retry. 1>&2
		let ctr++
		#[ $ctr -gt 10 ] && break
		sleep 1
	done


	echo Scan result: $scan 1>&2
	json_load  "$scan"
	json_select network_info
	json_get_keys keys
	for key in $keys; do
		[ -z "$key" ] && continue
		json_select $key
		json_get_vars mcc mnc description
		json_select status
		json_get_values statusprops
		json_select ..
		json_select ..

		echo mcc: $mcc mnc: $mnc description: $description status: $statusprops 1>&2
		for i in $statusprops; do
			[ "$i" == "forbidden" ] && {
				echo "Status forbidden" 1>&2
				continue 2
			}
		done
		echo "Adding $mcc,$mnc to mccmncs list" 1>&2
		mccmncs="$mccmncs $mcc,$mnc"
	done
	echo MCC/MNC usable: $mccmncs 1>&2
	for mccmnc in $(echo $mccmncs | tr ' ' \\n |sort |uniq); do
		local mcc=${mccmnc%,*}
		local mnc=${mccmnc##*,}
		echo Trying to register to mcc: $mcc mnc: $mnc 1>&2
		proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id dms,"$dms_cid" --set-device-operating-mode low_power 1>&2
		sleep 2
		proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id dms,"$dms_cid" --set-device-operating-mode online 1>&2
	#	proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-plmn --mcc 0 || echo Failed to set mcc 0
	#	sleep 2
		proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id nas,"$nas_cid" --set-plmn --mcc "$mcc" --mnc "$mnc" 1>&2 || echo Failed to set mcc $mcc
		proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id nas,"$nas_cid" --set-plmn --mcc "$mcc" --mnc "$mnc" 1>&2 || echo Failed to set mcc $mcc
		local registration_ts=0
		local registration_start=$(date +%s)
		local registration_completed=
		local registration_duration=0
		while true; do
			local registration registration_duration plmn_mcc plmn_mnc plmn_description roaming
			json_init
			json_load "$(proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id nas,"$nas_cid" --get-serving-system)" || {
				[ $registration_duration -gt 70 ] && {
					echo Skipping network $mcc,$mnc. No registration 1>&2
					break
				}
				continue
			}
			json_get_vars registration plmn_mcc plmn_mnc plmn_description roaming
			let registration_duration=-$registration_start
			let registration_duration+=$(date +%s)
			if [ "$registration" == "registered" ]; then
				echo Modem is registered: registration: $registration, plmn_mcc: $plmn_mcc, plmn_mnc: $plmn_mnc, plmn_description: $plmn_description, roaming: $roaming 1>&2
				[ $mnc -gt 0 -a "$mcc" == "$plmn_mcc" -a "$mnc" == "$plmn_mnc" ] || {
					echo Registered to wrong network, current/target network mcc: $plmn_mcc/$mcc, mnc: $plmn_mnc,$mnc 1>&2
					[ $registration_duration -gt 60 ] && {
						echo Skipping network $mcc,$mnc. No registration 1>&2
						break
					}
					continue
				}
				[ $registration_ts -eq 0 ] && registration_ts=$(date +%s)
				local registration_age=0
				let registration_age+=$(date +%s)
				let registration_age-=$registration_ts
				echo Registration age: $registration_age 1>&2
				[ $registration_age -gt 30 ] && {
					echo "Registration settled for ${registration_age}s, ready for connection." 1>&2
					registration_completed=1
					break
				}
				sleep 5
				continue
			elif [ "$registration" == "registering_denied" -a $registration_duration -gt 10 ]; then
				echo Registration to MCC/MNC $mcc,$mnc denied. 1>&2
				break
			fi
			registration_ts=0
			#echo Duration: $registration_duration 1>&2
			[ $registration_duration -gt 60 ] && {
				echo Skipping network $mcc,$mnc. No registration 1>&2
				break
			}
			echo "Modem is not registered: registration: $registration, plmn_mcc: $plmn_mcc, plmn_mnc: $plmn_mnc,  plmn_description: $plmn_description, roaming: $roaming" 1>&2
			sleep 5;
		done

		[ -z "$registration_completed" ] && {
			echo Skipping this loop $mcc $mnc 1>&2
			continue
		}
		json_init
		json_load "$(proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id nas,"$nas_cid" --get-signal-info)"
		json_get_vars type signal rssi
		echo Type: $type, signal: $signal, rssi: $rssi 1>&2
		local weight=0
		case "$type" in
			lte)
				weight=100
				;;
			wcdma)
				weight=10
				signal=$rssi
				;;
			*)
				weight=1
				;;
		esac
		echo "Type Weight factor: $weight" 1>&2
		let signal+=120
		let signal=$signal
		let weight=$weight*$signal
		echo "Weighing mcc:$mcc / mnc: $mnc, signal: $signal, type: $type, type factor: $weight; resulting weight: $weight" 1>&2
		weighted_mccmnc="$weighted_mccmnc $weight:$mcc:$mnc"
	done
	echo WMC: $weighted_mccmnc 1>&2
	echo $weighted_mccmnc | tr ' ' \\n |sort -n -r
}

proto_qmi_setup() {
	local interface="$1"

	local ctldevice apn auth username password pincode delay modes ipv4 ipv6 dhcp $PROTO_DEFAULT_OPTIONS
	local mcc mnc device customroutes defaultroute peerdns metric ip4table ip6table
	local cid_4 pdh_4 cid_6 pdh_6 ipv4 autocreateif  strongestnetwork
	local ip subnet gateway dns1 dns2 ip_6 ip_prefix_length gateway_6 dns1_6 dns2_6
	local ctr model statedir failreboot at_init mtu use_pushed_mtu location
	json_get_vars ctldevice apn auth username password pincode delay modes ipv4 ipv6 dhcp $PROTO_DEFAULT_OPTIONS
	json_get_vars mcc mnc device customroutes defaultroute peerdns metric ip4table
	json_get_vars ip6table autocreateif strongestnetwork failreboot at_init mtu use_pushed_mtu location

	[ -z "$ipv4" ] && ipv4=1
	[ "$ipv4" == "0" ] && ipv4=

	[ -z "$ipv6" ] && ipv6=1
	[ "$ipv6" == "0" ] && ipv6=

	[ -z "$metric"  ] && metric="0"

	[ -z "$failreboot" ] && failreboot=100

	[ "$statedir" == "" ] && statedir="/tmp/qmi/${device}"

	set -o pipefail

	[ -n "$delay" ] && sleep "$delay"

	# Lock init 
	while ! [ -d ${statedir} ]; do
		echo "The interface is not initialized or existing yet."
		sleep 3
	done
	#	echo "The interface is not initialized or existing yet."
	#	proto_notify_error "$interface" NO_IFACE
	#	proto_set_available "$interface" 0
	#	sleep 3
	#	return 1
	#}
	exec 100>${statedir}/connection-setup.lock || {
			echo "The interface is not initialized or existing yet."
			proto_notify_error "$interface" NO_IFACE
			proto_set_available "$interface" 0
			sleep 3
			return 1
	}
	if ! flock -n 100; then
		echo "Waiting for device lock."
		if ! flock 100; then
			echo "The interface could not be found."
			proto_notify_error "$interface" NO_IFACE
			proto_set_available "$interface" 0
			sleep 3
			return 1
		fi
	fi

	while ! [ -f "$statedir/device_initialized" ]; do
		echo "Waiting until interface has been initialized by hotplug. $statedir/device_initialized"
		sleep 3
	done

	local dms_cid=$(cat $statedir/dms_cid)
	local nas_cid=$(cat $statedir/nas_cid)
	local wds_cid=$(cat $statedir/wds_cid)
	local uim_cid=$(cat $statedir/uim_cid)

	uci_revert_state network $interface setuppid
	uci_set_state network $interface setuppid $$

	[ -n "$ctl_device" ] && ctldevice=$ctl_device
	[ -z "$ctldevice" -a -n "$device" ] && {
		[ "${device:0:1}" == "@" ] && {
			device="$(uci get network.wan.device)"
		}
		ctldevice=$(ls -d /sys/class/net/${device}/device/usbmisc/cdc-wdm* /sys/class/net/${device}/lower_*/device/usbmisc/cdc-wdm* 2>/dev/null| head -n1)
		[ -n "$ctldevice" ] && ctldevice=/dev/${ctldevice##*/}
		while ! [ -c "$ctldevice" ]; do
			echo Waiting for device creation: $ctldevice
			sleep 2
		done
	}

	[ -n "$ctldevice" ] || {
		echo "No control device specified"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		flock -u 100
		return 1
	}
	[ -c "$ctldevice" ] || {
		echo "The specified control device does not exist"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		flock -u 100
		return 1
	}

	devname="${ctldevice##*/}"
	devpath="$(readlink -f /sys/class/usbmisc/$devname/device/)"

	[ -n "$device" ] || {
		echo "The interface could not be found."
		proto_notify_error "$interface" NO_IFACE
		proto_set_available "$interface" 0
		flock -u 100
		return 1
	}

	# check for muxed interface	
	local ep_id
	local mux_id
	if ! ep_id=$(readlink /sys/class/net/$device/device 2>/dev/null); then
		ep_id=$(readlink /sys/class/net/$device/lower_*/device 2>/dev/null)
	fi
	ep_id=${ep_id##*.}
	if echo "${device}" | egrep '^wwan[0-9].*m[0-9].*' >/dev/null 2>&1 ; then
		mux_id=$( echo ${device} |cut -dm -f2)
	fi
	if [ -n "$mux_id" ] && [ -z "$ep_id" ]; then
		echo "Could not detect endpoint id, needed for muxing."
		proto_notify_error "$interface" NO_IFACE
		proto_set_available "$interface" 0
		flock -u 100
		return 1
	fi

	# Try to find matching tty
	local ttydev=$(proto_qmi_find_primary_serial_interface $devname)
	[ -n "$ttydev" ] && echo Found tty $ttydev for $devname

	# Watch connection attempts
	let failreboot+=0 >/dev/null 2>&1
	local connecttries="$(uci_get_state network $interface connecttries 2>/dev/null)"
	uci_revert_state network $interface connecttries
	let connecttries+=1
	# Check connection attempts
	echo "Connection attempt no.: $connecttries"
	if [ "$failreboot" -gt 0 ]; then
		if [ $connecttries -eq 8 ]; then
			proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id dms,"$dms_cid" --set-device-operating-mode low_power
			sleep 2
			if ! proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id dms,"$dms_cid" --set-device-operating-mode online; then
				proto_qmi_usb_reset $interface
				flock -u 100
				return 1
			fi
			sleep 2
		elif [ $connecttries -eq 16 ]; then
			if ! proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id dms,"$dms_cid" --set-device-operating-mode offline; then
				proto_qmi_usb_reset $interface
				flock -u 100
				return 1
			fi
				
			proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id dms,"$dms_cid" --set-device-operating-mode reset
			sleep 1
			flock -u 100
			return 1
		elif [ $connecttries -gt $failreboot ]; then
			proto_qmi_usb_reset $interface
			flock -u 100
			return 1
		fi
	fi
	uci_set_state network $interface connecttries $connecttries

	# Set back ctldevice
	#[ -z "$mux_id" ] && proto_qmi_run_uqmi 10 -s -d "$ctldevice" --sync
	let ctr=0
	while !	IGNORE_ERROR=1 proto_qmi_run_uqmi 10 -s -d "$ctldevice" --get-versions >/dev/null; do
		let ctr+=1
		[ $ctr -gt 10 ] && {
			echo "Failed to get api versions."
			proto_qmi_usb_reset $interface
			flock -u 100
			return 1
		}
	done

	# Clean up ctldevice (Disabled since it disturbs registration process on retries)

	while IGNORE_ERROR=1 proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id dms,"$dms_cid" --get-pin-status | grep '"UIM uninitialized"' > /dev/null; do
		sleep 1;
	done

	[ -n "$ttydev" ] && {
		model="$(comgt -d $ttydev  -s /etc/gcom/getcardmodel.gcom)"
		echo "Detected model: $model"
		# Run device specific commands
		if [ -n "$at_init" ]; then
			echo "Running configured AT commands."
			json_for_each_item proto_qmi_serial_run_atc at_init $ttydev
		fi
	}

	# Add missing auth:
	[ -z "$auth" -a -n "$username" -a -n "$password" ] && auth="both"

	# Setup network modes
	modes=$(uci get network.${interface}.modes 2>/dev/null |tr \  ,)
	#[ -z "$modes" ] && modes="all"

	# never to reset to defaults to allow modem to select
	[ -n "$modes" ] && {
		local ctr
		let ctr=0
		echo "Settings network-modes to \"$modes\"."
		while !	proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id nas,"$nas_cid" --set-network-modes "$modes"; do
			let ctr+=1
			[ $ctr -gt 3 ] && {
				echo "Failed to set network modes $modes."
				[ -n "$ttydev" ] && proto_qmi_reset_modes_fallback "$ttydev" "$model" "$modes"
				break
			}
		done
		if [ "$modes" == "all" ]; then
			proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid=$nas_cid --client-no-release-cid --nas-set-technology-preference=ALL
		fi
	}

	# Setup MCC/MNC, never reset to defaults to allow modem to select
	[ -n "$mcc" -a -n "$mnc" ] && {
		local mccmnc=$(printf %03g%02g $mcc $mnc)
		let ctr=0
		echo "Setting PLMN to $mccmnc."
		while !	proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id nas,"$nas_cid" --set-plmn --mcc "$mcc" --mnc "$mnc"; do
			let ctr+=1
			[ $ctr -gt 3 ] && {
				if [ -n "$ttydev" ]; then
					break
					echo -n "Changing PLMN selection: "
					if [ "$mcc" == "0" ]; then
						COMMAND="AT+COPS=0" gcom -d $ttydev -e -s /etc/gcom/runcommand.gcom
					else
						COMMAND="AT+COPS=1,2,\"$mccmnc\"" gcom -d $ttydev -e -s /etc/gcom/runcommand.gcom
					fi
					break
				fi
				echo Failed to set PLMN $mccmnc
				break
			}
		done
	}

	# switch ctldevice online if not already
	proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id dms,"$dms_cid" --set-device-operating-mode online
	
	# Read SIM PIN properties and send PIN if needed
	local pin1_status
	json_init
	json_load "$(IGNORE_ERROR=1 proto_qmi_run_uqmi 10 -s -d $ctldevice --set-client-id dms,"$dms_cid" --get-pin-status)" 2>/dev/null
	json_get_vars pin1_status pin1_verify_tries
	if [ -n "$pin1_status" ]; then
		echo SIM PIN1 Status: $pin1_status, verify tries: $pin1_verify_tries
		if [ $pin1_verify_tries -lt 2 ]; then
			echo "Only $pin1_verify_tries SIM1 PIN tries left, refusing to lock!"
			echo "Unlock with uqmi 10 -s -d "${ctldevice}" --verify-pin1 pincode"
			proto_notify_error "$interface" PIN_FAILED
			proto_block_restart "$interface"
			flock -u 100
			return 1
		fi
		if [ "$pin1_status" != "disabled" -a "$pin1_status" != "verified" -a -n "$pincode" ]; then
			local result
			echo Unlocking PIN1
			result="$(proto_qmi_run_uqmi 10 -s -d "${ctldevice}" --set-client-id dms,"$dms_cid" --verify-pin1 "${pincode}")"
			if [ $? -gt 0 ]; then
				if [ "$result" == "\"No effect\"" ]; then
					echo "PIN1 not needed"
				else
					echo "Unable to verify PIN1"
					proto_notify_error "$interface" PIN_FAILED
					proto_block_restart "$interface"
					flock -u 100
					return 1
				fi
			fi
			sleep 5
		fi
		echo "IMSI :  $(IGNORE_ERROR=1 proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id dms,"$dms_cid" --get-imsi)"
		echo "ICCID:  $(IGNORE_ERROR=1 proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id dms,"$dms_cid" --get-iccid)"
		echo "MSISDN: $(IGNORE_ERROR=1 proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id dms,"$dms_cid" --get-msisdn)"
	else
		# Try uim service
		local uim_card_status=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid "$uim_cid" --client-no-release-cid  --uim-get-card-status)
		#echo UIM status:
		#echo "$uim_card_status"
		local uim_appstate=$(echo "$uim_card_status" | proto_qmi_qmicli_result_getprop 'Application state')
		echo "UIM appstate: $uim_appstate"
		if [ "$uim_appstate" ==  "pin1-or-upin-pin-required" ]; then
			local pin1_verify_tries=$(echo "$uim_card_status" | proto_qmi_qmicli_result_getprop 'PIN1 retries')
			if [ -n "$pin1_verify_tries" -a "$pin1_verify_tries" -lt 1 ]; then
				echo "Only $pin1_verify_tries SIM1 PIN tries left, refusing to lock!"
				echo "Unlock with uqmi 10 -s -d "${ctldevice}" --verify-pin1 pincode"
				proto_notify_error "$interface" PIN_FAILED
				proto_block_restart "$interface"
				flock -u 100
				return 1
			fi
			local uim_verify_status="$(proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid "$uim_cid" --client-no-release-cid --uim-verify-pin=PIN1,${pincode})"
			echo PIN1 verification status: "$uim_verify_status"
		elif [ "$uim_appstate" ==  "ready" ]; then
			echo "SIM is already unlocked and ready."
		else
			echo "unknown state $uim_appstate, continue."
		fi
		local uim_imsi=$(proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid "$uim_cid" --client-no-release-cid --uim-read-transparent=0x3F00,0x7FFF,0x6F07|grep -A1 "^Read result:$"|tail -n1 | proto_qmi_convert_from_uimbyte)
		uim_imsi=${uim_imsi:3}
		echo "IMSI :  $uim_imsi"
		local uim_iccid=$(proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid "$uim_cid" --client-no-release-cid --uim-read-transparent=0x3F00,0x2FE2|grep -A1 "^Read result:$"|tail -n1 | proto_qmi_convert_from_uimbyte)
		echo "ICCID:  $uim_iccid"
		#echo "MSISDN: $(proto_qmi_run_uqmi 10 -s -d "$ctldevice" --get-msisdn)"
	fi

	# Log some details about the card
	echo "IMEI:   $(IGNORE_ERROR=1 proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id uim,"$uim_cid" --get-imei)"

	# Create a network order list
	let strongestnetwork+=0
	if [ $strongestnetwork -gt 0 ]; then
		local best_scanage=0
		local best_scantime="$(uci_get_state network $interface best_scantime 2>/dev/null)"
		local best_mcc="$(uci_get_state network $interface best_mcc 2>/dev/null)"
		local best_mnc="$(uci_get_state network $interface best_mnc 2>/dev/null)"
		let best_scantime+=0
		let best_scanage+=$(date +%s)
		let best_scanage-=$best_scantime
		if [ $best_scantime -gt 0 -a $best_scanage -lt 86400 -a -n "$best_mcc" -a -n "$best_mnc" ]; then
			echo "Using cached results: Strongest MCC/MNC $mcc/$mnc, age: ${best_scanage}s."
		else
			echo Scanning for networks to find best.
			local networks="$(proto_qmi_get_networks_by_strength "$ctldevice")"
			echo "Network List ordered: $networks"
			local primary=$(echo -e "$networks" | head -n1)
			# Reset best_* state
			uci_revert_state network $interface best_mcc
			uci_revert_state network $interface best_mnc
			uci_revert_state network $interface best_scantime
			[ -n "$primary" ] && {
				best_mcc=$(echo $primary|cut -d: -f2)
				best_mnc=$(echo $primary|cut -d: -f3)
				echo Overwrting mcc and mnc to: $best_mcc,$best_mnc
				uci_set_state network $interface best_mcc "$best_mcc"
				uci_set_state network $interface best_mnc "$best_mnc"
				uci_set_state network $interface best_scantime "$(date +%s)"
			}
		fi
		if [ -n "$best_mcc" -a -n "$best_mnc" ]; then
			while ! proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id nas,"$nas_cid" --set-plmn --mcc $best_mcc --mnc $best_mnc; do
				echo Error setting best mcc/mnc: $ret, retry. 1>&2
				sleep 1
			done
		else
			echo Failed to find best mcc/mnc.
			while ! proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id nas,"$nas_cid" --set-plmn --mcc $mcc --mnc $mnc; do
				echo Error setting best mcc/mnc: $ret, retry. 1>&2
				sleep 1
			done
		fi
		sleep 2
	fi

	# try to clear previous autoconnect state
	# do not reuse previous wds client id to prevent hangs caused by stale data
	[ -z "$mux_id" ] && proto_qmi_run_uqmi 10 -s -d "$ctldevice" \
		--set-client-id wds,"$wds_cid" \
		--stop-network 0xffffffff \
		--autoconnect > /dev/null >/dev/null 2&>1

	echo "Waiting for network registration"
	local registration_ts=0
	local registration_start=$(date +%s)
	while true; do
		local registration registration_duration plmn_mcc plmn_mnc plmn_description roaming
		json_init
		json_load "$(proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id nas,"$nas_cid" --get-serving-system)"
		json_get_vars registration plmn_mcc plmn_mnc plmn_description roaming
		let registration_duration=0
		let registration_duration+=$(date +%s)
		let registration_duration=-$registration_start
		if [ "$registration" == "registered" ]; then
			echo Modem is registered: registration: $registration, plmn_mcc: $plmn_mcc, plmn_mnc: $plmn_mnc, plmn_description: $plmn_description, roaming: $roaming
			[ $registration_ts -eq 0 ] && registration_ts=$(date +%s)
			local registration_age=0
			let registration_age+=$(date +%s)
			let registration_age-=$registration_ts
			break
			echo Registration age: $registration_age
			[ $registration_age -gt 30 ] && {
				echo "Registration settled for ${registration_age}s, ready for connection."
				break
			}
			sleep 5
			continue
		fi
		registration_ts=0
		echo "Modem is not registered: registration: $registration, plmn_mcc: $plmn_mcc, plmn_mnc: $plmn_mnc,  plmn_description: $plmn_description, roaming: $roaming"
		[ $registration_duration -gt 240 ] && {
			echo "Failed to wait for network registration."
			proto_notify_error "$interface" REGISTRATION_FAILED
			flock -u 100
			return 1
		}
		sleep 5;
	done
	echo Provider information:
	cat /tmp/qmi/wwan0/modem.state 1>&2

	local profile
	if [ -z "$apn" ]; then
		profile=1
	elif [ "${apn:0:1}" == "#" ]; then
		profile=${apn:1}
		apn=""
	else
		profile=1
		[ -n "$mux_id" ] && profile=$mux_id
		[ "$profile" -lt 2 ] && proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid "$wds_cid" --client-no-release-cid \
			--wds-set-default-profile-number=3gpp,$profile
		# some devices do not know no-roaming flag
		proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid "$wds_cid" --client-no-release-cid \
			--wds-modify-profile=3gpp,$profile,name=default,disabled=no,apn=$apn${auth:+,auth=$auth}${username:+,username=$username}${password:+,password=$password}
		# retry with no-roaming flag set
		IGNORE_ERROR=1 proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid "$wds_cid" --client-no-release-cid \
			--wds-modify-profile=3gpp,$profile,name=default,disabled=no,no-roaming=no,apn=$apn${auth:+,auth=$auth}${username:+,username=$username}${password:+,password=$password} >/dev/null 2>&1
	fi

	proto_qmi_update_pdptype "$ctldevice" "$profile" "$ipv4" "$ipv6"
	echo "Starting network with APN: '$apn', profile: $profile"


	[ -n "$ipv4" ] && {
# moved inside	
		cid_4=`proto_qmi_run_uqmi 10 -s -d "$ctldevice" --get-client-id wds`
		[ $? -ne 0 ] && {
			echo "Unable to obtain wds client ID"
			proto_qmi_usb_reset $interface
			proto_notify_error "$interface" NO_CID
			flock -u 100
			return 1
		}

		echo "Starting IPv4"
		[ -n "$mux_id" ] && proto_qmi_run_qmicli 120 -d "$ctldevice" --wds-bind-mux-data-port=mux-id=${mux_id},ep-iface-number=${ep_id} --client-cid=$cid_4 --client-no-release-cid >/dev/null
		proto_qmi_run_uqmi 120 -s -d "$ctldevice" --set-client-id wds,"$cid_4" --set-ip-family ipv4
		result=`proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid "$cid_4"  --client-no-release-cid \
			--wds-start-network=ip-type=4${apn:+,apn=$apn}${auth:+,auth=$auth}${username:+,username=$username}${password:+,password=$password}${profile:+,3gpp-profile=$profile}`
		rc=$?
		if ! pdh_4=$(echo "$result" | proto_qmi_qmicli_result_getprop 'Packet data handle'); then
			echo "Unable to connect IPv4, Reason: $result"
			proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id wds,"$cid_4" --release-client-id wds
			ipv4=""
			cid_4=""
			local childinterfaces="$(proto_qmi_find_virtual_interfaces "$interface" dhcp)"
			if [ -n "$childinterfaces" ]; then
				echo Shutting down interface $childinterfaces
				ubus call network.interface down "{ \"interface\" : \"$childinterfaces\" }"
			fi

			# In case of missing IPv4, we return failure to force retry.
			proto_notify_error "$interface" NO_IPV4
			flock -u 100
			return 1
		else
			proto_init_update "$device" 1
			proto_set_keep 1
			proto_add_data
			json_add_string "ctldevice" "$ctldevice"
			json_add_string "cid_4" "$cid_4"
			json_add_string "pdh_4" "$pdh_4"
			proto_close_data
			proto_send_update "$interface"
			echo "Got IPv4 packet data handle $pdh_4 with wds client $cid_4."
		fi
	}

	[ -n "$ipv6" ] && {
		echo "Starting IPv6"
		sysctl -w net.ipv6.conf.$device.disable_ipv6=0 >/dev/null 2>&1
		cid_6=`proto_qmi_run_uqmi 10 -s -d "$ctldevice" --get-client-id wds` || {
			echo "Unable to obtain client ID"
			proto_qmi_usb_reset $interface
			proto_notify_error "$interface" NO_CID
			flock -u 100
			return 1
		}

		[ -n "$mux_id" ] && proto_qmi_run_qmicli 120 -d "$ctldevice" --wds-bind-mux-data-port=mux-id=${mux_id},ep-iface-number=${ep_id} --client-cid=$cid_6 --client-no-release-cid >/dev/null
		proto_qmi_run_uqmi 120 -s -d "$ctldevice" --set-client-id wds,"$cid_6" --set-ip-family ipv6
		if [ $? = 0 ]; then
			result=`proto_qmi_run_qmicli 120 -d "$ctldevice" --client-cid "$cid_6"  --client-no-release-cid \
				--wds-start-network=ip-type=6${apn:+,apn=$apn}${auth:+,auth=$auth}${username:+,username=$username}${password:+,password=$password}${profile:+,3gpp-profile=$profile}`
			rc=$?
			if ! pdh_6=$(echo "$result" | proto_qmi_qmicli_result_getprop 'Packet data handle'); then
				echo "Unable to connect IPv6, Reason: $result"
				proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id wds,"$cid_6" --release-client-id wds
				ipv6=""
				cid_6=""
				local childinterfaces="$(proto_qmi_find_virtual_interfaces "$interface" dhcpv6)"
				if [ -n "$childinterfaces" ]; then
					echo Shutting down interface $childinterfaces
					ubus call network.interface down "{ \"interface\" : \"$childinterfaces\" }"
				fi
			else
				echo "Got IPv6 packet data handle $pdh_6 with wds client $cid_6."
				proto_init_update "$device" 1
				proto_set_keep 1
				proto_add_data
				json_add_string "ctldevice" "$ctldevice"
				json_add_string "cid_6" "$cid_6"
				json_add_string "pdh_6" "$pdh_6"
				proto_close_data
				proto_send_update "$interface"
			fi

		else
			echo "Unable to connect IPv6"
			ipv6=""
		fi
	}

	[ -z "$ipv4" -a -z "$ipv6" ] && {
		echo "Unable to connect"
		proto_notify_error "$interface" CALL_FAILED
		flock -u 100
		return 1
	}

	# Instantiate loc Service if possible
	local cid_loc
	if [ "$(($location))" -gt 1 ] && [ "$(($mux_id))" -lt 2 ]; then
		cid_loc=$(proto_qmi_loc_start $ctldevice)
	fi
	uci_revert_state network $interface cid_loc
	uci_set_state network $interface cid_loc $cid_loc

	sleep 1
	if [ "$dhcp" = 0 ]; then
		echo "Setting up $device"
		local ipconfig
		local devmtu=$mtu
		[ -n "$ipv4" ] && {
			ipconfig=$(proto_qmi_run_uqmi 10 -s -d $ctldevice --set-client-id wds,$cid_4 --get-current-settings 2>/dev/null)
			ipconfig=$(proto_qmi_run_uqmi 10 -s -d $ctldevice --set-client-id wds,$cid_4 --get-current-settings 2>/dev/null)
			ipconfig=$(proto_qmi_run_uqmi 10 -s -d $ctldevice --set-client-id wds,$cid_4 --get-current-settings 2>/dev/null)
			echo "Retrieved IPv4 configuration: $ipconfig"
			json_load "$ipconfig"
			json_get_vars mtu
			json_select ipv4
			json_get_vars ip subnet gateway dns1 dns2

			if [ -n "$use_pushed_mtu" ] && [ "$use_pushed_mtu" -gt 0 ] && [ -n "$mtu" ] && [ "$mtu" -gt 1280 ]; then
				echo "Setting IPv4 interface MTU to value pushed by modem: $mtu"
				ip link set dev $device mtu $mtu
			fi
			proto_init_update "$device" 1
			proto_set_keep 1
			proto_add_ipv4_address "$ip" "32"
			[ "$defaultroute" = 0 ] || proto_add_ipv4_route "0.0.0.0" 0
			[ "$peerdns" = 0 ] || {
				proto_add_dns_server "$dns1"
				proto_add_dns_server "$dns2"
			}
			proto_send_update "$interface"
		}
	
		[ -n "$ipv6" ] && {
			ipconfig=$(proto_qmi_run_uqmi 10 -s -d $ctldevice --set-client-id wds,$cid_6 --get-current-settings 2>/dev/null)
			ipconfig=$(proto_qmi_run_uqmi 10 -s -d $ctldevice --set-client-id wds,$cid_6 --get-current-settings 2>/dev/null)
			ipconfig=$(proto_qmi_run_uqmi 10 -s -d $ctldevice --set-client-id wds,$cid_6 --get-current-settings 2>/dev/null)
			echo "Retrieved IPv6 configuration: $ipconfig"
			json_load "$ipconfig"
			json_get_vars mtu
			json_select ipv6
			json_get_var ip_6 ip
			json_get_var gateway_6 gateway
			json_get_var dns1_6 dns1
			json_get_var dns2_6 dns2
			json_get_var ip_prefix_length ip-prefix-length

			if [ -n "$use_pushed_mtu" ] && [ "$use_pushed_mtu" -gt 0 ] && [ -n "$mtu" ] && [ "$mtu" -gt 1280 ]; then
				echo "Setting IPv6 interface MTU to value pushed by modem: $mtu"
				[ -z "$ipv4" ] && ip link set dev $device mtu $mtu
				echo $mtu > /proc/sys/net/ipv6/conf/$device/mtu
			fi
			proto_init_update "$device" 1
			proto_set_keep 1
			# RFC 7278: Extend an IPv6 /64 Prefix to LAN
			proto_add_ipv6_address "$ip_6" "128"
			proto_add_ipv6_prefix "${ip_6}/${ip_prefix_length}"
			proto_add_ipv6_route "$gatew"
			[ "$defaultroute" = 0 ] || proto_add_ipv6_route "::0" 0 "" "" "" "${ip_6}/${ip_prefix_length}"
			[ "$peerdns" = 0 ] || {
				proto_add_dns_server "$dns1_6"
				proto_add_dns_server "$dns2_6"
			}
			proto_send_update "$interface"
		}
	else
		echo "Starting DHCP on $device"

		proto_init_update "$device" 1
		proto_add_data
		json_add_string "wda_cid" "$wda_cid"
		[ -n "$ipv4" ] && {
			json_add_string "cid_4" "$cid_4"
			json_add_string "pdh_4" "$pdh_4"
		}
		[ -n "$ipv6" ] && {
			json_add_string "cid_6" "$cid_6"
			json_add_string "pdh_6" "$pdh_6"
		}
		proto_close_data
		proto_send_update "$interface"

		[ -z "$autocreateif" ] && autocreateif=1
		let autocreateif+=0

		[ -n "$ipv4" ] && {
			local childinterfaces="$(proto_qmi_find_virtual_interfaces "$interface" dhcp)"
			if [ -n "$childinterfaces" ]; then
				ubus call network.interface up "{ \"interface\" : \"$childinterfaces\" }"
			else
				echo Adding interface ${interface}_4
				local _json_no_warning=1
				json_init
				if [ $autocreateif -eq 1 ]; then
					json_add_string "config" "network"
					json_add_string "type" "interface"
					json_add_string "name" "${interface}_4"
					json_add_object "values"
					json_select "values"
				fi

				json_add_string name "${interface}_4"
				json_add_string device "@$interface"
				json_add_string proto "dhcp"
				json_add_string forcep2p "1"
				json_add_string leasetime "180"
				if [ -n "$customroutes" ]; then
					json_add_string customroutes "$customroutes"
				fi
				if [ -n "$defaultroute" ]; then
					json_add_string defaultroute "$defaultroute"
				fi
				if [ -n "$peerdns" ]; then
					json_add_string peerdns "$peerdns"
				fi
				if [ -n "$metric" ]; then
					json_add_string metric "$metric"
				fi
				if [ -n "$ip4table" ]; then
					json_add_string ip4table "$ip4table"
				fi
				json_close_object

				if [ $autocreateif -eq 1 ]; then
					json_select ..
					json_close_object
					ubus call uci add "$(json_dump)" >/dev/null && \
					ubus call uci commit '{"config":"network"}'
				else
					ubus call network add_dynamic "$(json_dump)"
				fi
				ubus call network.interface up "{ \"interface\" : \"${interface_4}\" }"
			fi
		}

		[ -n "$ipv6" ] && {
			local childinterfaces="$(proto_qmi_find_virtual_interfaces "$interface" dhcpv6)"
			if [ -n "$childinterfaces" ]; then
				ubus call network.interface up "{ \"interface\" : \"$childinterfaces\" }"
			else
				local _json_no_warning=1
				json_init
				if [ $autocreateif -eq 1 ]; then
					echo Adding interface ${interface}_6
					json_add_string "config" "network"
					json_add_string "type" "interface"
					json_add_string "name" "${interface}_6"
					json_add_object "values"
					json_select "values"
				fi
				json_add_string name "${interface}_6"
				json_add_string device "@$interface"
				json_add_string proto "dhcpv6"
				# RFC 7278: Extend an IPv6 /64 Prefix to LAN
				json_add_string extendprefix 1
				if [ -n "$ip6table" ]; then
					json_add_string ip4table "$ip6table"
				fi
				json_close_object
				if [ $autocreateif -eq 1 ]; then
					json_select ..
					json_close_object
					ubus call uci add "$(json_dump)" >/dev/null && \
					ubus call uci commit '{"config":"network"}'
				else
					ubus call network add_dynamic "$(json_dump)"
				fi
			fi
		}
	fi

	uci_revert_state network $interface setuppid
	proto_init_update "$device" 1
	proto_set_keep 1
	proto_add_data
	json_add_string "ctldevice" "$ctldevice"
	json_add_string "cid_4" "$cid_4"
	json_add_string "pdh_4" "$pdh_4"
	json_add_string "cid_6" "$cid_6"
	json_add_string "pdh_6" "$pdh_6"
	[ -n "$cid_loc" ] && json_add_string "cid_loc" "$cid_loc"
	proto_close_data
	proto_send_update "$interface"

	echo Cell Neighborhood $ctldevice
	proto_qmi_run_qmicli 45 -d "$ctldevice" --client-cid=$nas_cid --client-no-release-cid --nas-get-cell-location-info 1>&2

	# Unlock init 
	flock -u 100
	echo "Starting Watchdog"
	proto_run_command "$interface" /usr/sbin/uqmi-watchdog "$interface"
}

proto_qmi_teardown() {
	#proto_qmi_teardown_fork "$@" </dev/null >/dev/null 2>&1 &
	proto_qmi_teardown_fork "$@" </dev/null >/dev/null 2>&1
	wait
}


proto_qmi_teardown_fork() {
	local interface="$1"
	local locked device ctldevice cid_4 pdh_4 cid_6 pdh_6 setuppid
	json_load "$(ubus call network.interface.$interface status)"
	json_get_vars device
	json_select data
	json_get_vars cid_4 pdh_4 cid_6 pdh_6 cid_loc ctldevice

	ctldevice=/dev/${ctldevice##*/}
	statedir="/tmp/qmi/${device}"

	# Kill running watchdog
	proto_kill_command "$interface"

	# Lock init
	exec 100>${statedir}/connection-setup.lock || {
		proto_qmi_log err "Failed to create lockfile ${statedir}/connection-setup.lock ."
	}
	if ! flock -n 100; then
		proto_qmi_log err "$interface: Failed to lock ${statedir}/connection-setup.lock ."
	else
		locked=1
		proto_qmi_log notice "$interface: Locked device $device for deconfiguration."
	fi

	# Cleanup qmi handles and clients
	#proto_qmi_log notice "$interface: Teardown $cid_4 $pdh_4 $cid_6 $pdh_6 $cid_loc"
	proto_qmi_log notice "$interface: Stopping network, interface $interface, device $device, qmi device $ctldevice"
	ps |grep "qmi.sh qmi setup $interface "|awk '{ print $1}'|xargs -r kill >/dev/null 2>&1
	# kill existing processes using our device
	ps |grep uqmi|grep -- "-d $ctldevice"|awk '{ print $1}'|grep -v $$ | xargs -r kill >/dev/null 2>&1
	sleep 2
	ps |grep uqmi|grep -- "-d $ctldevice"|awk '{ print $1}'|grep -v $$ | xargs -r kill -9 >/dev/null 2>&1

	# modem may disappear through reboot process
	if [ -c $ctldevice ] ; then
		# Give back packet data handle
		[ -n "$pdh_6" ] && {
			proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id wds,"$cid_6" --stop-network "$pdh_6" || \
			proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id wds,"$cid_6" --stop-network "$pdh_6"
			proto_qmi_log notice "$interface: Stopped IPv6 connection with pdh $pdh_6"
		}
		[ -n "$pdh_4" ] && {
			proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id wds,"$cid_4" --stop-network "$pdh_4" || \
			proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id wds,"$cid_4" --stop-network "$pdh_4"
			proto_qmi_log notice "$interface: Stopped IPv4 connection with pdh $pdh_4"
		}

		# Keep wds client by returning them, do not waste ids
		[ -n "$cid_6" ] && {
			proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id wds,"$cid_6" --release-client-id wds || \
			proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id wds,"$cid_6" --release-client-id wds
			proto_qmi_log notice "$interface: Released IPv6 wds client $cid_6"
		}
		[ -n "$cid_4" ] && {
			proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id wds,"$cid_4" --release-client-id wds || \
			proto_qmi_run_uqmi 10 -s -d "$ctldevice" --set-client-id wds,"$cid_4" --release-client-id wds
			proto_qmi_log notice "$interface: Released IPv4 wds client $cid_4"
		}

		uci_revert_state network $interface cid_loc
		if [ -n "$cid_loc" ]; then
			proto_qmi_run_qmicli 10 -d "$ctldevice" --loc-stop --client-cid=$cid_loc || \
			proto_qmi_run_qmicli 10 -d "$ctldevice" --loc-stop --client-cid=$cid_loc
			proto_qmi_log notice "$interface: Stopped location service client $cid_loc"
		fi
	fi
	# Stop possible parallel running setup
	setuppid=$(uci_get_state network $interface setuppid)
	uci_revert_state network $interface setuppid


	# finish teardown
	proto_init_update "*" 0
	proto_send_update "$interface"

	# Unlock
	[ -n "$locked" ] && {
		proto_qmi_log notice "$interface: Unlocked device $device."
		flock -u 100
	}
	exit 0
}

proto_qmi_hotplug() {
	# Verify type
	if [ "$DEVTYPE" != "wwan" ]; then
		proto_qmi_hotplug_finish
		return 0
	fi

	# Verify driver
	local DRIVER=$(readlink -f  /sys/$DEVPATH/device/driver)
	[ -n "$DRIVER" ] && DRIVER=$(basename $DRIVER)

	if [ "$DRIVER" == "cdc_mbim" ]; then
		proto_qmi_hotplug_finish
		return 0
	fi

	# Directory for state files
	local QMIHOME=/tmp/qmi
	local STATE=$QMIHOME/$DEVICENAME

	# Verify action
	if [ "$ACTION" = "remove" ]; then
		rm -rf "$STATE"
		proto_qmi_hotplug_log "Cleaned up state for device $DEVICENAME."
		proto_qmi_hotplug_finish
		return 0
	elif [ "$ACTION" != "add" ]; then
		proto_qmi_hotplug_log "Unknown action $ACTION"
		proto_qmi_hotplug_finish
		return 0
	fi

	# Run init procedure
	# assign exit trap
	#trap proto_qmi_hotplug_finish EXIT KILL

	# Initialize directory
	mkdir -p $STATE

	# resolve cdc device
	cdc=$(ls /sys/class/net/$DEVICENAME/device/usbmisc/cdc-wdm* -d)
	cdc=$(basename "$cdc")
	[ -z "$cdc" ] &&  {
		proto_qmi_hotplug_log CDC device not found for $DEVICENAME
		proto_qmi_hotplug_finish
		return 0
	}

	if ! ep_id=$(readlink /sys/class/net/$DEVICENAME/device); then
		ep_id=$(readlink /sys/class/net/$DEVICENAME/lower_*/device)
	fi
	ep_id=${ep_id##*.}

	services=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 45 -d /dev/$cdc --device-open-sync --get-service-version-info 2>&1)
	let i=0
	while ! echo "$services" | grep "Supported versions:" >/dev/null ; do
		let i=$(( $i + 1 ))
		sleep 1
		services=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 45 -d /dev/$cdc --device-open-sync --get-service-version-info 2>&1)

		if [ $i -gt 6 ]; then
			proto_qmi_hotplug_log "Failed to init module, reset it. counter=$i"
			usb-repower </dev/null >/dev/null 2>&1
			return 0
		fi
	done
	proto_qmi_hotplug_log "Services: "$(echo "$services" |tr \\n ,)

	dms_cid=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --dms-noop|grep CID: | cut -d\' -f2)
	while [ -z "dms_cid" ]; do
		proto_qmi_hotplug_log "Device $DEVICENAME did not create dms client, retry."
		sleep 1
		wda_cid=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --dms-noop|grep CID: | cut -d\' -f2)
	done
	proto_qmi_hotplug_log "Created dms cid: $dms_cid"

	proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --client-cid=$dms_cid --dms-get-manufacturer | head -n -3 | proto_qmi_hotplug_log
	proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --client-cid=$dms_cid --dms-get-model | head -n -3 | proto_qmi_hotplug_log
	proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --client-cid=$dms_cid --dms-get-revision | head -n -3 | proto_qmi_hotplug_log
	proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --client-cid=$dms_cid --dms-get-capabilities | head -n -3 | proto_qmi_hotplug_log

	nas_cid=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --nas-noop|grep CID: | cut -d\' -f2)
	while [ -z "nas_cid" ]; do
		proto_qmi_hotplug_log "Device $DEVICENAME did not create nas client, retry."
		sleep 1
		nas_cid=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --nas-noop|grep CID: | cut -d\' -f2)
	done
	proto_qmi_hotplug_log "Created nas cid: $nas_cid"

	wds_cid=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --wds-noop|grep CID: | cut -d\' -f2)
	while [ -z "wds_cid" ]; do
		proto_qmi_hotplug_log "Device $DEVICENAME did not create wds client, retry."
		sleep 1
		wds_cid=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --wds-noop|grep CID: | cut -d\' -f2)
	done
	proto_qmi_hotplug_log "Created wds cid: $wds_cid"

	if echo "$services" | grep 'uim' >/dev/null; then
		uim_cid=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --uim-noop|grep CID: | cut -d\' -f2)
		while [ -z "uim_cid" ]; do
			proto_qmi_hotplug_log "Device $DEVICENAME did not create uim client, retry."
			sleep 1
			nas_cid=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --uim-noop|grep CID: | cut -d\' -f2)
		done
		proto_qmi_hotplug_log "Created uim cid: $uim_cid"
	fi

	# Try to find matching tty, and run init
	local ttydev=$(proto_qmi_find_primary_serial_interface $cdc)
	[ -n "$ttydev" ] && {
		model="$(comgt -d $ttydev -s /etc/gcom/getcardmodel.gcom)"
		proto_qmi_hotplug_log "Detected model $model via $ttydev, running init sequence."
		proto_qmi_serial_init "$ttydev" "$model"
	}

	[ -n "$nas_cid" ] && {
		proto_qmi_run_qmicli 45 -d /dev/$cdc --client-cid=$nas_cid --client-no-release-cid --nas-get-system-info | proto_qmi_hotplug_log
		proto_qmi_run_qmicli 45 -d /dev/$cdc --client-cid=$nas_cid --client-no-release-cid --nas-get-system-selection-preference | proto_qmi_hotplug_log
	}

	if ! echo "$services" | grep 'wda' >/dev/null; then
		proto_qmi_hotlplug "Device $DEVICENAME has no wda support, skipping data format switch."
		if_changed=1
		proto_qmi_hotplug_finish
		return 0
	fi

	wda_cid=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --wda-noop|grep CID: | cut -d\' -f2)
	while [ -z "wda_cid" ]; do
		proto_qmi_hotplug_log "Device $DEVICENAME did not create wda client, retry."
		sleep 1
		wda_cid=$(IGNORE_ERROR=1 proto_qmi_run_qmicli 45 -d /dev/$cdc --client-no-release-cid --wda-noop|grep CID: | cut -d\' -f2)
	done
	proto_qmi_hotplug_log "Created wda cid: $wda_cid"

	# Configure WDA data format, set defaults
	local wda_format="link-layer-protocol=raw-ip,ep-type=hsusb,ep-iface-number=$ep_id"
	local muxes=
	#  .. For example, MDM9607 support up to 4KB, SDX20 support up to 16KB, SDX55 support up to 31KB.
	local mux_dgram_max_size=$(( 4 * 1024 ))
	local usb_urb_size
	# Device specific support
	if egrep '^zyxel,lte3301-plus|^zyxel,nr7101' /tmp/sysinfo/board_name > /dev/null; then
		mux_dgram_max_size=$(( 31 * 1024 ))
	fi
	usb_urb_size=$mux_dgram_max_size

	# check if we have qmimux devices
	if (ubus -v call uci get '{ "config": "network", "match": { "proto": "qmi", "auto": "" } } }' ;
	    ubus -v call uci get '{ "config": "network", "match": { "proto": "qmi", "auto": "1" } } }') | egrep '"wwan[0-9].*m[0-9].*"' >/dev/null ; then
		wda_format="link-layer-protocol=raw-ip,ul-protocol=qmap,dl-protocol=qmap,dl-max-datagrams=32,dl-datagram-max-size=$mux_dgram_max_size,ep-type=hsusb,ep-iface-number=$ep_id"
		muxes="1 2 3 4"
	fi

	local wda_data_format="$(proto_qmi_run_qmicli 45 -d /dev/$cdc --wda-get-data-format=ep-type=hsusb,ep-iface-number=$ep_id --client-cid=$wda_cid --client-no-release-cid)"
	echo -e "WDA data format:\n$wda_data_format" | proto_qmi_hotplug_log

	local device_llp=$(echo "$wda_data_format" | proto_qmi_qmicli_result_getprop 'Link layer protocol')
	if [ "$device_llp" == "raw-ip" ]; then
		proto_qmi_hotplug_log "WDA data format is already raw-ip."
	fi

	proto_qmi_hotplug_log "Requesting wda data format change to: $wda_format"
	wda_data_format=$(proto_qmi_run_qmicli 45 -d /dev/$cdc --wda-set-data-format=$wda_format --client-cid=$wda_cid --client-no-release-cid)
	echo -e "WDA data format after change:\n$wda_data_format" | proto_qmi_hotplug_log
	device_llp=$(echo "$wda_data_format" | proto_qmi_qmicli_result_getprop 'Link layer protocol')
	local driver_target_format="$device_llp"
	# Overwrite to qmap-pass-through if we want muxing and it is available
	if [ -n "$muxes" ] && [ -f /sys/class/net/$DEVICENAME/qmi/pass_through ] && [ -d /sys/module/rmnet ]; then
		driver_target_format="qmap-pass-through"
	fi

	# Change driver data format
	local driver_data_format=$(proto_qmi_run_qmicli 45 -d /dev/$cdc --get-expected-data-format)

	proto_qmi_hotplug_log Current value of drivers expected data format is: $driver_data_format
	if [ "$driver_data_format" == "$driver_target_format" ]; then
		proto_qmi_hotplug_log Current value of drivers expected data format is already $driver_target_format
	else
		if_changed=1
		ip link set dev $DEVICENAME down
		proto_qmi_change_driver_data_format $cdc "$driver_data_format" "$driver_target_format"
	fi

	# Configure QMAP with pass throgh, qmap with qmimux or simple raw-ip with no aggregation
	uplink_proto=$(echo "$wda_data_format" | proto_qmi_qmicli_result_getprop 'Uplink data aggregation protocol')
	if [ "$uplink_proto" == "qmap" ] && [ -d /sys/module/rmnet ] && [ "$(cut -b0-1 /sys/class/net/$DEVICENAME/qmi/pass_through)" == "Y" ]; then
		proto_qmi_hotplug_log Adding rmnet interfaces for muxing.
		if_changed=1
		ip link set dev $DEVICENAME mtu 1504
		for muxid in $muxes; do
			local muxif muxmtu
			muxif=${DEVICENAME}m${muxid}
			mux_devs="$mux_devs $muxif"
			ip link add $muxif link ${DEVICENAME} type rmnet mux_id $muxid || \
				proto_qmi_hotplug_log "Failed to create rmnet interface: ip link add $muxif link ${DEVICENAME} type rmnet mux_id $muxid"
		done

		# add qmap header to USB URB size
		usb_urb_size=$(($usb_urb_size+4))

		# corresponding wda_data format + 256 Byte, exactly dl-datagram-max-size gives domain error
		ip link set dev $DEVICENAME mtu $usb_urb_size
		mux_devs="${mux_devs:1}"
		for muxif in $mux_devs; do
			local muxmtu
			let muxmtu=$(ubus -v call uci get '{ "config": "network", "type": "interface", "match": { "proto": "qmi", "device": "'$muxif'" } } }'|grep mtu|cut -d'"' -f4)
			[ "$muxmtu" -gt 576 ] || muxmtu=1500
			ip link set dev $muxif mtu $muxmtu >/dev/null 2>&1
			proto_qmi_hotplug_log "Setting MTU $muxmtu for device $muxif, parent $DEVICENAME."
		done


		proto_qmi_hotplug_log "Initialized rmnet mux devices $mux_devs for parent $DEVICENAME."
	elif [ "$uplink_proto" == "qmap" ]; then
		proto_qmi_hotplug_log Adding qmimux interfaces for muxing.
		if_changed=1
		local mux_status
		# ### disable corresponding wda_data format + 256 Byte, exactly dl-datagram-max-size gives domain error
		# corresponding wda_data format + 4 Byte, exactly dl-datagram-max-size gives domain error
		# add qmap header to USB URB size
		usb_urb_size=$(($usb_urb_size+4))
		ip link set dev $DEVICENAME mtu $usb_urb_size
		for muxid in $muxes; do
			local muxmtu muxif muxifnew
			log Adding qmimux interfaces for muxing.
			mux_status=$(proto_qmi_run_qmicli 45 -d /dev/$cdc --link-add=iface=$DEVICENAME,prefix=qmimux,mux-id=$muxid) 
			muxif=$(echo "$mux_status" | grep iface\ name: | cut -d: -f2 | tr -d ' ')
			muxifnew=${DEVICENAME}m${muxid}
			ip link set dev $muxif name $muxifnew && muxif=$muxifnew
			mux_devs="$mux_devs $muxif"
			let muxmtu=$(ubus -v call uci get '{ "config": "network", "type": "interface", "match": { "proto": "qmi", "device": "'$muxif'" } } }'|grep mtu|cut -d'"' -f4)
			[ "$muxmtu" -gt 576 ] || muxmtu=1500

			proto_qmi_hotplug_log "Setting MTU $muxmtu for device $muxif, parent $DEVICENAME."
			ip link set dev ${i##*_} mtu $muxmtu >/dev/null 2>&1
		done
		mux_devs="${mux_devs:1}"


		proto_qmi_hotplug_log "Initialized mux devices $mux_devs for parent $DEVICENAME."
	else
		local mtu
		let mtu=$(ubus -v call uci get '{ "config": "network", "type": "interface", "match": { "proto": "qmi", "device": "'$DEVICENAME'" } } }'|grep mtu|cut -d'"' -f4)
		[ "$mtu" -gt 576 ] || mtu=1500
		ip link set dev $DEVICENAME mtu $mtu
		if_changed=1
	fi

	# USB URB Size Optimization
	local current_rx_urb_size
	let current_rx_urb_size=$(cat /sys/class/net/$DEVICENAME/qmi/rx_urb_size 2>/dev/null) && {
		proto_qmi_hotplug_log "qmi_wwan current USB URB Size: $current_rx_urb_size"
		if [ -n "$usb_urb_size" ] && [ "$current_rx_urb_size" != "$usb_urb_size" ]; then
			if [ -z "$if_changed" ]; then
				if_changed=1
				ip link set dev $DEVICENAME down
			fi
			if echo -n "$usb_urb_size" >/sys/class/net/$DEVICENAME/qmi/rx_urb_size; then
				proto_qmi_hotplug_log "Successfully set qmi_wwan USB URB Size to $usb_urb_size."
			else
				proto_qmi_hotplug_log "Failed to set qmi_wwan USB URB Size to $usb_urb_size_size, current is $(cat /sys/class/net/$DEVICENAME/qmi/rx_urb_size)."
			fi
		fi
	}

	proto_qmi_hotplug_finish
}

proto_qmi_hotplug_log() {
	logger -t "qmi-hotplug[$DEVICENAME]" -- "$@"
}

proto_qmi_hotplug_finish() {
	if [ -n "$if_changed" ]; then
		proto_qmi_hotplug_log Set link of $DEVICENAME up
		ip link set dev $DEVICENAME up
		for i in $mux_devs; do
			ip link set dev $i up
			rm -rf /tmp/qmi/$i
			#mkdir -p /tmp/qmi/$i
			ln -s $STATE /tmp/qmi/$i
			#touch /tmp/qmi/$i/device_initialized
		done
	fi
	touch ${STATE}/device_initialized
	[ -n "$wda_cid" ] && echo "$wda_cid" >${STATE}/wda_cid
	[ -n "$dms_cid" ] && echo "$dms_cid" >${STATE}/dms_cid
	[ -n "$nas_cid" ] && echo "$nas_cid" >${STATE}/nas_cid
	[ -n "$uim_cid" ] && echo "$uim_cid" >${STATE}/uim_cid
	[ -n "$wds_cid" ] && echo "$wds_cid" >${STATE}/wds_cid
	return 0
}

proto_qmi_change_driver_data_format() {
	local cdc="$1"
	local current_format="$2"
	local expected_format="$3"
	local tries=10
	local old_format
	local ctr
	local limit=10
	let ctr=1
	while [ "$current_format" != "$expected_format" ] && [ $ctr -lt $tries ]; do
		[ $ctr -gt 1 ] && {
			proto_qmi_hotplug_log Retry setting $expected_format , count $ctr.
			sleep 5
		}
		proto_qmi_run_qmicli 45 -d /dev/$cdc --set-expected-data-format=$expected_format 2>&1 | proto_qmi_hotplug_log

		old_format=$current_format
		current_format=$(proto_qmi_run_qmicli 45 -d /dev/$cdc --get-expected-data-format)
		proto_qmi_hotplug_log Value of drivers expected data format after change request: $current_format
		let ctr++
	done
	return 0
}


[ -n "$INCLUDE_ONLY" ] || {
	add_protocol qmi
}
