include $(TOPDIR)/rules.mk

PKG_NAME:=qmi-advanced
PKG_RELEASE:=8

PKG_LICENSE:=GPL-2.0
PKG_LICENSE_FILES:=

PKG_FLAGS:=nonshared

include $(INCLUDE_DIR)/package.mk

define Package/qmi-advanced
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  DEPENDS:=+libubox +libblobmsg-json +kmod-usb-net +kmod-usb-net-qmi-wwan +wwan +comgt +qmi-utils +uqmi +@BUSYBOX_CONFIG_TIMEOUT +@BUSYBOX_CONFIG_FLOCK
  TITLE:=Control utility for mobile broadband modems
endef

define Package/qmi-advanced/description
  qmi-advanced is an advanced connection manager for QMI modems. It also
  supports multiplexing and packet aggeration.
endef

define Build/Compile
endef

define Build/Configure
endef

define Package/qmi-advanced/install
	$(INSTALL_DIR) $(1)/sbin
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_DIR) $(1)/etc/gcom
	$(INSTALL_DIR) $(1)/etc/hotplug.d
	$(INSTALL_DIR) $(1)/etc/hotplug.d/net
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,qmi-advanced))
