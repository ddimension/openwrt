#
# ath11k board data for the MikroTik Chateau 5G R17 ax
#
# Why a separate package and not ipq-wifi?
#   ipq-wifi takes its board files from an external git repository
#   (qca-wireless.git), which cannot be extended locally.
#
# Why not target/linux/qualcommax/ipq60xx/base-files?
#   That directory applies to the whole subtarget, so a board-2.bin placed
#   there would override the one from ath11k-firmware-ipq6018 for every
#   ipq60xx device, not just this one.
#
# Source of the file: Qualcomm QSDK, matching the firmware version running on
# this device:
#   https://git.codelinaro.org/clo/qsdk/oss/ath11k-bdf
#   NHSS.QSDK.12.4.5, IPQ6018/hw1.0/WLAN.HK.2.5.0.1/
#   WLAN.HK.2.5.0.1-01201-QCAHKSWPL_SILICONZ-1/board-2.bin
#
# It contains an entry for "bus=ahb,qmi-chip-id=0,qmi-board-id=255", which is
# exactly what this device requests and which the board data shipped in
# ath11k-firmware-ipq6018 lacks. Without it the 5 GHz band reports no HT
# capabilities and only plain 802.11a works.
#
# Per-device calibration still comes from RouterBOOT's hard_config via the
# caldata hotplug script, not from this file.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=ath11k-board-mikrotik-chateau
PKG_RELEASE:=1
PKG_FLAGS:=nonshared

include $(INCLUDE_DIR)/package.mk

define Package/ath11k-board-mikrotik-chateau
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=ath11k board-2.bin for MikroTik Chateau 5G R17 ax
  DEPENDS:=@TARGET_qualcommax_ipq60xx
endef

define Package/ath11k-board-mikrotik-chateau/description
Board data (board-2.bin) for the MikroTik Chateau 5G R17 ax, taken from
Qualcomm's QSDK for firmware version WLAN.HK.2.5.0.1. It provides the
qmi-board-id=255 entry that this device requests and that the upstream
ath11k-firmware-ipq6018 board data lacks.

Only install this on the MikroTik Chateau 5G R17 ax.
endef

define Build/Compile
endef

define Package/ath11k-board-mikrotik-chateau/install
	$(INSTALL_DIR) $(1)/lib/firmware/ath11k/IPQ6018/hw1.0
	$(INSTALL_DATA) ./files/board-2.bin \
		$(1)/lib/firmware/ath11k/IPQ6018/hw1.0/board-2.bin
endef

$(eval $(call BuildPackage,ath11k-board-mikrotik-chateau))
