. /lib/functions/system.sh

preinit_set_mac_address() {
	case $(board_name) in
	zyxel,nbg7815)
		ethaddr=$(mtd_get_mac_ascii "0:appsblenv" ethaddr)
		ip link set dev lan2 address $ethaddr
		ip link set dev lan3 address $ethaddr
		ip link set dev lan4 address $ethaddr
		ip link set dev 10g address $ethaddr
		ip link set dev wan address $(macaddr_add $ethaddr 1)
		;;
	esac
}

boot_hook_add preinit_main preinit_set_mac_address
